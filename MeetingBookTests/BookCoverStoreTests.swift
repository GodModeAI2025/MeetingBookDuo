import XCTest
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
@testable import MeetingBook

@MainActor final class BookCoverStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("BookCoverTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        return root
    }
    private func rejects(_ action: () async throws -> Void,file: StaticString=#filePath,line: UInt=#line) async {
        do {try await action();XCTFail("Expected rejection",file:file,line:line)} catch {}
    }
    private func fixture(width: Int=80,height: Int=40,orientation: Int=1,type: UTType = .jpeg,frames: Int=1) throws -> Data {
        let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setFillColor(UIColor.blue.cgColor);context.fill(CGRect(x:width/2,y:0,width:width/2,height:height))
        let image=try XCTUnwrap(context.makeImage()),bytes=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(bytes,type.identifier as CFString,frames,nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:orientation,kCGImagePropertyExifDictionary:[kCGImagePropertyExifUserComment:"PRIVATE"],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:49.0,kCGImagePropertyGPSLongitude:8.0]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    func testRoundtripPreservesConfigurationAndRevision() async throws {
        let root=try directory(),store=BookCoverStore(directory:root)
        await store.load()
        XCTAssertNil(store.snapshot.revision);XCTAssertNil(store.loadError)
        XCTAssertEqual(store.snapshot.configuration.title,"")
        XCTAssertEqual(store.snapshot.configuration.coverColor,.graphite)
        XCTAssertNil(EnvironmentValues().bookCover)
        var value=BookCoverConfiguration();value.title="März 📒";value.coverColor = .forest;value.bandColor = .linen
        let source=try fixture()
        value.imageData=try await Task.detached {try BookCoverStore.prepareImage(source)}.value
        value.cropX = -0.7;value.cropY=0.5
        try await store.save(value,expectedRevision:nil)
        let snapshot=store.snapshot
        XCTAssertNotNil(snapshot.revision)
        let reopened=BookCoverStore(directory:root);await reopened.load()
        XCTAssertEqual(reopened.snapshot,snapshot);XCTAssertEqual(reopened.snapshot.configuration,value)
        var blank=value;blank.title=""
        try await reopened.save(blank,expectedRevision:snapshot.revision)
        XCTAssertEqual(reopened.snapshot.configuration.title,"")
        XCTAssertFalse(reopened.snapshot.configuration.displayTitle.isEmpty)
    }
    func testUnreadableNewerOversizedAndUnknownPalettePreservedUntilRetry() async throws {
        let unknown=Data(#"{"version":1,"revision":"00000000-0000-0000-0000-000000000001","configuration":{"title":"","coverColor":"unknown","bandColor":"graphite","cropX":0,"cropY":0}}"#.utf8)
        for bytes in [Data("broken".utf8),Data(#"{"version":99}"#.utf8),Data(repeating:32,count:8*1024*1024+1),unknown] {
            let root=try directory(),file=root.appendingPathComponent("cover.json")
            try bytes.write(to:file)
            let store=BookCoverStore(directory:root);await store.load()
            XCTAssertNotNil(store.loadError)
            await rejects {try await store.save(BookCoverConfiguration(),expectedRevision:nil)}
            XCTAssertEqual(try Data(contentsOf:file),bytes);XCTAssertNil(store.snapshot.revision)
            try FileManager.default.removeItem(at:file);await store.load()
            XCTAssertNil(store.loadError)
            try await store.save(BookCoverConfiguration(),expectedRevision:nil)
        }
    }
    func testInvalidTitleAndCropPreserveSavedBytes() async throws {
        let root=try directory(),store=BookCoverStore(directory:root)
        try await store.save(BookCoverConfiguration(),expectedRevision:nil)
        let before=store.snapshot,bytes=try Data(contentsOf:root.appendingPathComponent("cover.json"))
        var invalid=[BookCoverConfiguration]()
        for title in [String(repeating:"a",count:121),String(repeating:"👨‍👩‍👧‍👦",count:30),"bad\u{0000}title"] {var v=BookCoverConfiguration();v.title=title;invalid.append(v)}
        for coordinate in [Double.nan,.infinity,-1.001,1.001] {var x=BookCoverConfiguration();x.cropX=coordinate;invalid.append(x);var y=BookCoverConfiguration();y.cropY=coordinate;invalid.append(y)}
        for value in invalid {await rejects {try await store.save(value,expectedRevision:before.revision)}}
        XCTAssertEqual(store.snapshot,before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("cover.json")),bytes)
    }
    func testConcurrentWindowDraftsCannotOverwriteWinner() async throws {
        let root=try directory(),store=BookCoverStore(directory:root)
        try await store.save(BookCoverConfiguration(),expectedRevision:nil)
        let revision=store.snapshot.revision
        var first=BookCoverConfiguration();first.title="First"
        var second=BookCoverConfiguration();second.title="Second"
        async let a: Void=store.save(first,expectedRevision:revision)
        async let b: Void=store.save(second,expectedRevision:revision)
        var successes=0
        do {try await a;successes+=1} catch {XCTAssertEqual(error as? BookCoverError,.conflict)}
        do {try await b;successes+=1} catch {XCTAssertEqual(error as? BookCoverError,.conflict)}
        XCTAssertEqual(successes,1)
        let reopened=BookCoverStore(directory:root);await reopened.load()
        XCTAssertEqual(reopened.snapshot,store.snapshot)
        await rejects {try await store.save(BookCoverConfiguration(),expectedRevision:nil)}
    }
    func testFailedWritePreservesPublishedStateAndBytes() async throws {
        let root=try directory(),store=BookCoverStore(directory:root)
        try await store.save(BookCoverConfiguration(),expectedRevision:nil)
        let before=store.snapshot,original=try Data(contentsOf:root.appendingPathComponent("cover.json")),retained=root.appendingPathExtension("retained")
        try FileManager.default.moveItem(at:root,to:retained)
        addTeardownBlock {try? FileManager.default.removeItem(at:retained)}
        try Data("blocked directory".utf8).write(to:root)
        var value=BookCoverConfiguration();value.title="Unsaved"
        await rejects {try await store.save(value,expectedRevision:before.revision)}
        XCTAssertEqual(store.snapshot,before)
        XCTAssertEqual(try Data(contentsOf:retained.appendingPathComponent("cover.json")),original)
    }
    func testImagePreparationRotatesDownsamplesAndRemovesPrivateMetadata() async throws {
        let input=try fixture(width:3000,height:1000,orientation:6)
        let output=try await Task.detached {try BookCoverStore.prepareImage(input)}.value
        let source=try XCTUnwrap(CGImageSourceCreateWithData(output as CFData,nil))
        let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int,2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int,683)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]);XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        XCTAssertLessThanOrEqual(output.count,4*1024*1024)
        var value=BookCoverConfiguration();value.imageData=output
        try await BookCoverStore(directory:try directory()).save(value,expectedRevision:nil)
    }
    func testPreparedImageSliceRemainsValidWithoutZeroBasedIndices() async throws {
        let original=try fixture()
        let prepared=try await Task.detached {try BookCoverStore.prepareImage(original)}.value
        var padded=Data([1,2,3,4,5]);padded.append(prepared)
        let slice=padded.dropFirst(5)
        var value=BookCoverConfiguration();value.imageData=slice
        let store=BookCoverStore(directory:try directory())
        try await store.save(value,expectedRevision:nil)
        XCTAssertEqual(store.snapshot.configuration.imageData,prepared)
    }
    func testImageLimitsRejectMalformedLargeAnimatedAndUnnormalizedImages() async throws {
        let invalid=[Data(),Data("not image".utf8),Data(repeating:0,count:25_000_001),try fixture(type:.gif,frames:2),try fixture(width:8001,height:5000)]
        for data in invalid {await rejects {_ = try await Task.detached {try BookCoverStore.prepareImage(data)}.value}}
        let store=BookCoverStore(directory:try directory())
        for data in [try fixture(),Data(repeating:0,count:4*1024*1024+1),try fixture(width:2049,height:2)] {
            var value=BookCoverConfiguration();value.imageData=data
            await rejects {try await store.save(value,expectedRevision:nil)}
        }
        XCTAssertNil(store.snapshot.revision)
    }
}
