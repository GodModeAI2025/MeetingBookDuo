import XCTest
import ImageIO
import UIKit
import PDFKit
import ZIPFoundation
import MeetingBookCore
@testable import MeetingBook
@MainActor final class ImageImportTests: XCTestCase {
    func testSanitizedIndependentAssetsAndPreflight() async throws {
        let assets=try AssetStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:80,height:40),format:format).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:80,height:40)) }
        let service=ImageImportService(assets:assets)
        let result=try await service.importData(image.jpegData(compressionQuality:0.9)!)
        let bytes=try await assets.read(hash:result.assetHash)
        XCTAssertNotNil(UIImage(data:bytes));XCTAssertEqual(result.width,80);XCTAssertEqual(result.height,40)
        do { _ = try await service.importData(Data(repeating:0,count:25_000_001));XCTFail("oversize accepted") } catch { XCTAssertEqual(error as? NotebookError,.invalidAsset) }
        let cancelled=Task { try Task.checkCancellation();return try await service.importData(image.pngData()!) };cancelled.cancel()
        do { _ = try await cancelled.value;XCTFail("cancel accepted") } catch is CancellationError {} catch { XCTFail("wrong error") }
    }
}

extension ImageImportTests {
    func testOrientationAndGPSAreRemovedFromOriginal() async throws {
        let assets=try AssetStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:80,height:40),format:format).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:80,height:40)) }
        let bytes=NSMutableData()
        let destination=CGImageDestinationCreateWithData(bytes,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image.cgImage!,[kCGImagePropertyOrientation:6,kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:52.0,kCGImagePropertyGPSLatitudeRef:"N"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let imported=try await ImageImportService(assets:assets).importData(bytes as Data)
        XCTAssertEqual(imported.width,40);XCTAssertEqual(imported.height,80)
        let sanitized=try await assets.read(hash:imported.assetHash)
        let source=CGImageSourceCreateWithData(sanitized as CFData,nil)!
        let metadata=CGImageSourceCopyPropertiesAtIndex(source,0,nil)! as NSDictionary
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary]);XCTAssertNil(metadata[kCGImagePropertyExifDictionary])
    }
}

extension ImageImportTests {
    func testGPSBearingImageIsSanitizedThroughPackagePNGAndPDF() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:80,height:40),format:format).image {context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:80,height:40))}
        let bytes=NSMutableData(),marker="private-location-marker-8c"
        let output=try XCTUnwrap(CGImageDestinationCreateWithData(bytes,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(output,image.cgImage!,[kCGImagePropertyOrientation:6,kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:52.0,kCGImagePropertyGPSLatitudeRef:"N"],kCGImagePropertyExifDictionary:[kCGImagePropertyExifUserComment:marker]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        func properties(_ bytes:Data) throws -> NSDictionary {
            let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil)) as NSDictionary
        }
        XCTAssertNotNil(try properties(bytes as Data)[kCGImagePropertyGPSDictionary])
        let imported=try await ImageImportService(assets:store.assets).importData(bytes as Data)
        XCTAssertEqual(imported.width,40);XCTAssertEqual(imported.height,80)
        let sanitized=try await store.assets.read(hash:imported.assetHash)
        XCTAssertNil(try properties(sanitized)[kCGImagePropertyGPSDictionary]);XCTAssertNil(try properties(sanitized)[kCGImagePropertyExifDictionary])
        var content=PageContent();content.version=2;content.images=[ImageElement(frame:.init(x:56,y:64,width:40,height:80),assetHash:imported.assetHash,altText:"Fixture")]
        let note=try await store.createNote(title:"Metadata fixture",contents:[content])
        let exporter=ExportService(store:store,root:root.appendingPathComponent("exports"))
        let png=try await exporter.export(.init(format:.png,pages:note.pages,fonts:[],unsaved:false))
        let pngBytes=try Data(contentsOf:png.urls[0]);XCTAssertNil(try properties(pngBytes)[kCGImagePropertyGPSDictionary]);XCTAssertNil(try properties(pngBytes)[kCGImagePropertyExifDictionary])
        let pdf=try await exporter.export(.init(format:.pdf,pages:note.pages,fonts:[],unsaved:false))
        let document=try XCTUnwrap(PDFDocument(url:pdf.urls[0]));XCTAssertEqual(document.pageCount,1)
        XCTAssertFalse(String(describing:document.documentAttributes).lowercased().contains("gps"))
        XCTAssertNil(try Data(contentsOf:pdf.urls[0]).range(of:Data(marker.utf8)))
        let packageWriter=NotebookPackage(root:root.appendingPathComponent("packages")),package=try await packageWriter.create(store:store)
        let inspected=try await packageWriter.inspect(url:package,directory:PackageIO.directory(in:root))
        let packed=try Data(contentsOf:XCTUnwrap(inspected.assets[imported.assetHash]));XCTAssertEqual(packed,sanitized)
        let archive=try Archive(url:package,accessMode:.read);var manifest=Data()
        _ = try archive.extract(XCTUnwrap(archive["manifest.json"])) {manifest.append($0)}
        XCTAssertFalse(String(decoding:manifest,as:UTF8.self).contains(marker));XCTAssertFalse(String(decoding:manifest,as:UTF8.self).contains("GPS"))
    }
}
