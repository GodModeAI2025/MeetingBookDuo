import XCTest
import PencilKit
import SwiftUI
@testable import MeetingBook

@MainActor final class PersonalSymbolTests: XCTestCase {
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("PersonalSymbolTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    private func drawing(width: CGFloat=80, mask: UIBezierPath?=nil) -> PKDrawing {
        let points=[CGPoint(x:20,y:30),CGPoint(x:20+width,y:30)]
        let path=PKStrokePath(controlPoints:points.enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)*0.05,size:CGSize(width:8,height:8),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        },creationDate:Date(timeIntervalSince1970:0))
        return PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:path,mask:mask)])
    }
    private func rejects(_ operation: () async throws -> Void, file: StaticString=#filePath, line: UInt=#line) async {
        do { try await operation();XCTFail("Expected rejection",file:file,line:line) } catch {}
    }
    func testDrawingRoundtripReload() async throws {
        let root=try directory(),store=PersonalSymbolStore(directory:root),source=drawing()
        await store.load()
        XCTAssertNil(store.snapshot(for:.pen).revision)
        try await store.save(source,for:.pen,expectedRevision:nil)
        let revision=try XCTUnwrap(store.snapshot(for:.pen).revision)
        let reopened=PersonalSymbolStore(directory:root);await reopened.load()
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.snapshot(for:.pen).revision,revision)
        let restored=reopened.snapshot(for:.pen).drawing
        XCTAssertEqual(restored.strokes.count,1)
        XCTAssertEqual(restored.strokes[0].path.count,source.strokes[0].path.count)
        for (actual,expected) in zip(restored.strokes[0].path,source.strokes[0].path) {
            XCTAssertEqual(actual.location,expected.location);XCTAssertEqual(actual.size,expected.size)
            XCTAssertEqual(actual.opacity,expected.opacity);XCTAssertEqual(actual.force,expected.force)
        }
        let document=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("symbols.json"))) as? [String:Any])
        let entries=try XCTUnwrap(document["entries"] as? [String:[String:Any]])
        let stored=try XCTUnwrap(entries["pen"]?["drawing"] as? String)
        XCTAssertEqual(Data(base64Encoded:stored),source.dataRepresentation())
    }
    func testPartialFallbackToggleRetainsDrawingsAndDefaultHostIsSafe() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        _ = AppSymbol.pen.image(in:EnvironmentValues().personalSymbols)
        try await store.save(drawing(),for:.pen,expectedRevision:nil)
        XCTAssertNotNil(store.customImage(for:.pen));XCTAssertNil(store.customImage(for:.eraser))
        let revision=store.snapshot(for:.pen).revision
        try await store.setEnabled(false)
        XCTAssertNil(store.customImage(for:.pen));XCTAssertNotNil(store.images[.pen])
        try await store.setEnabled(true)
        XCTAssertNotNil(store.customImage(for:.pen));XCTAssertEqual(store.snapshot(for:.pen).revision,revision)
    }
    func testConcurrentDifferentSymbolsMergeAndReload() async throws {
        let root=try directory(),store=PersonalSymbolStore(directory:root)
        let firstDrawing=drawing(),secondDrawing=drawing(width:40)
        async let first: Void=store.save(firstDrawing,for:.pen,expectedRevision:nil)
        async let second: Void=store.save(secondDrawing,for:.eraser,expectedRevision:nil)
        _ = try await (first,second)
        let reopened=PersonalSymbolStore(directory:root);await reopened.load()
        XCTAssertNotNil(reopened.customImage(for:.pen));XCTAssertNotNil(reopened.customImage(for:.eraser))
    }
    func testStaleSaveResetAndTombstoneCannotReplaceLatest() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        try await store.save(drawing(),for:.pen,expectedRevision:nil)
        let original=store.snapshot(for:.pen)
        try await store.save(drawing(width:40),for:.pen,expectedRevision:original.revision)
        let latest=store.snapshot(for:.pen)
        await rejects { try await store.save(original.drawing,for:.pen,expectedRevision:original.revision) }
        await rejects { try await store.reset(.pen,expectedRevision:original.revision) }
        XCTAssertEqual(store.snapshot(for:.pen).revision,latest.revision)
        try await store.reset(.pen,expectedRevision:latest.revision)
        let tombstone=try XCTUnwrap(store.snapshot(for:.pen).revision)
        XCTAssertTrue(store.snapshot(for:.pen).drawing.strokes.isEmpty)
        await rejects { try await store.save(original.drawing,for:.pen,expectedRevision:nil) }
        await rejects { try await store.save(original.drawing,for:.pen,expectedRevision:latest.revision) }
        XCTAssertEqual(store.snapshot(for:.pen).revision,tombstone)
        try await store.save(original.drawing,for:.pen,expectedRevision:tombstone)
    }
    func testUnreadableAndUnknownVersionPreservedUntilRetry() async throws {
        for bytes in [Data("broken".utf8),Data(#"{"version":99,"enabled":true,"entries":{}}"#.utf8),Data(repeating:32,count:8*1024*1024+1)] {
            let root=try directory(),file=root.appendingPathComponent("symbols.json")
            try bytes.write(to:file)
            let store=PersonalSymbolStore(directory:root);await store.load()
            XCTAssertNotNil(store.loadError)
            await rejects {try await store.save(drawing(),for:.pen,expectedRevision:nil)}
            await rejects {try await store.reset(.pen,expectedRevision:nil)}
            await rejects {try await store.setEnabled(false)}
            XCTAssertEqual(try Data(contentsOf:file),bytes)
            try FileManager.default.removeItem(at:file);await store.load()
            XCTAssertNil(store.loadError)
            try await store.save(drawing(),for:.pen,expectedRevision:nil)
        }
    }
    func testFailedWritePreservesPublishedStateAndOriginalBytes() async throws {
        let root=try directory(),store=PersonalSymbolStore(directory:root)
        try await store.save(drawing(),for:.pen,expectedRevision:nil)
        let previous=store.snapshot(for:.pen),original=try Data(contentsOf:root.appendingPathComponent("symbols.json"))
        let retained=root.appendingPathExtension("retained")
        try FileManager.default.moveItem(at:root,to:retained)
        addTeardownBlock {try? FileManager.default.removeItem(at:retained)}
        try Data("blocked directory".utf8).write(to:root)
        await rejects { try await store.save(drawing(width:40),for:.pen,expectedRevision:previous.revision) }
        await rejects { try await store.setEnabled(false) }
        XCTAssertTrue(store.enabled);XCTAssertEqual(store.snapshot(for:.pen).revision,previous.revision)
        XCTAssertEqual(try Data(contentsOf:retained.appendingPathComponent("symbols.json")),original)
    }
    func testEmptyErasedNonfiniteAndOversizedDrawingsRejected() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        let erased=drawing(mask:UIBezierPath(rect:CGRect(x:300,y:300,width:20,height:20)))
        let infinite=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:drawing().strokes[0].path,transform:CGAffineTransform(translationX:.infinity,y:0))])
        let many=PKDrawing(strokes:Array(repeating:drawing().strokes[0],count:129))
        let points=(0...16000).map { i in PKStrokePoint(location:CGPoint(x:Double(i%300),y:30),timeOffset:Double(i)*0.001,size:CGSize(width:8,height:8),opacity:1,force:1,azimuth:0,altitude:.pi/2) }
        let dense=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date()))])
        for invalid in [PKDrawing(),erased,infinite,many,dense] {
            await rejects {try await store.save(invalid,for:.pen,expectedRevision:nil)}
            XCTAssertNil(store.snapshot(for:.pen).revision);XCTAssertNil(store.images[.pen])
        }
    }
    private func alphaBounds(_ image: UIImage) throws -> CGRect {
        let cg=try XCTUnwrap(image.cgImage),width=cg.width,height=cg.height
        var pixels=Array(repeating:UInt8(0),count:width*height*4)
        let context=try XCTUnwrap(CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        var bounds=CGRect.null
        for y in 0..<height { for x in 0..<width where pixels[(y*width+x)*4+3]>16 { bounds=bounds.union(CGRect(x:x,y:y,width:1,height:1)) } }
        return bounds
    }
    func testMaskProducesBoundedTemplateWithPaddingProportionAndSelectionIndicator() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        let clipped=drawing(mask:UIBezierPath(rect:CGRect(x:30,y:26,width:40,height:8)))
        try await store.save(clipped,for:.bookmark,expectedRevision:nil)
        let image=try XCTUnwrap(store.customImage(for:.bookmark)),bounds=try alphaBounds(image)
        XCTAssertEqual(image.renderingMode,.alwaysTemplate);XCTAssertEqual(image.size,CGSize(width:24,height:24))
        XCTAssertLessThanOrEqual(try XCTUnwrap(image.cgImage).width,96)
        XCTAssertGreaterThan(bounds.minX,2);XCTAssertLessThan(bounds.maxX,94)
        XCTAssertEqual(bounds.width/bounds.height,5,accuracy:0.6)
        let selected=try XCTUnwrap(store.customImage(for:.bookmark,selected:true))
        XCTAssertNotEqual(image.pngData(),selected.pngData())
        XCTAssertEqual(AppSymbol.bookmark.systemName(selected:true),"bookmark.fill")
        XCTAssertEqual(AppSymbol.favorite.systemName(selected:true),"star.fill")
    }
    func testPerDrawingByteLimitRejectsOtherwiseBoundedGeometry() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        var seed: UInt64=42
        func random() -> CGFloat {
            seed=seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed>>32)/CGFloat(UInt32.max)
        }
        let strokes=(0..<128).map { _ in
            let points=(0..<125).map { i in
                PKStrokePoint(location:CGPoint(x:random()*380,y:random()*380),timeOffset:Double(i)*0.05,size:CGSize(width:2+random()*6,height:2+random()*6),opacity:0.5+random()*0.5,force:random(),azimuth:random()*6,altitude:random())
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:0)))
        }
        let source=PKDrawing(strokes:strokes)
        XCTAssertGreaterThan(source.dataRepresentation().count,256*1024)
        await rejects {try await store.save(source,for:.pen,expectedRevision:nil)}
        XCTAssertNil(store.images[.pen]);XCTAssertNil(store.snapshot(for:.pen).revision)
    }
    func testDenseFullCatalogLoadsOffMainActorAndUsesCachedMasks() async throws {
        let root=try directory(),store=PersonalSymbolStore(directory:root)
        let strokes=(0..<24).map { row in
            let points: [PKStrokePoint]=(0..<120).map { i in
                let x=10.0+Double(i)*3.0
                let y=10.0+Double(row)*15.0+sin(Double(i)*0.2)*5.0
                return PKStrokePoint(location:CGPoint(x:x,y:y),timeOffset:Double(i)*0.01,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:0)))
        }
        let source=PKDrawing(strokes:strokes),started=Date.timeIntervalSinceReferenceDate
        for symbol in AppSymbol.allCases {try await store.save(source,for:symbol,expectedRevision:nil)}
        let saved=Date.timeIntervalSinceReferenceDate
        let heartbeat=Task { @MainActor in
            var previous=Date.timeIntervalSinceReferenceDate,maxGap=0.0
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(5))
                let now=Date.timeIntervalSinceReferenceDate;maxGap=max(maxGap,now-previous);previous=now
            }
            return maxGap
        }
        let reopened=PersonalSymbolStore(directory:root);await reopened.load()
        let loaded=Date.timeIntervalSinceReferenceDate
        heartbeat.cancel();let maxGap=await heartbeat.value
        XCTAssertNil(reopened.loadError);XCTAssertEqual(reopened.images.count,AppSymbol.allCases.count)
        let cached=try XCTUnwrap(reopened.images[.pen])
        for _ in 0..<100 {XCTAssertTrue(reopened.customImage(for:.pen) === cached)}
        print("PERSONAL_SYMBOL_DENSE symbols=\(AppSymbol.allCases.count) strokesPerSymbol=24 pointsPerSymbol=2880 drawingBytes=\(source.dataRepresentation().count) saveSeconds=\(saved-started) loadSeconds=\(loaded-saved) mainHeartbeatMaxGapSeconds=\(maxGap)")
    }

    func testCatalogFallbacksExistAndCustomDirectionsDoNotMirror() async throws {
        for symbol in AppSymbol.allCases {
            XCTAssertNotNil(UIImage(systemName:symbol.standardSymbol),symbol.rawValue)
            XCTAssertNotNil(UIImage(systemName:symbol.systemName(selected:true)),symbol.rawValue)
        }
        let root=try directory(),store=PersonalSymbolStore(directory:root)
        try await store.save(drawing(),for:.previous,expectedRevision:nil)
        XCTAssertFalse(try XCTUnwrap(store.customImage(for:.previous)).flipsForRightToLeftLayoutDirection)
        try await store.setEnabled(false)
        let reopened=PersonalSymbolStore(directory:root);await reopened.load()
        XCTAssertFalse(reopened.enabled);XCTAssertNil(reopened.customImage(for:.previous))
        XCTAssertNotNil(reopened.images[.previous])
        let original=reopened.snapshot(for:.previous)
        try await reopened.reset(.previous,expectedRevision:original.revision)
        let resetRevision=reopened.snapshot(for:.previous).revision
        let reset=PersonalSymbolStore(directory:root);await reset.load()
        XCTAssertEqual(reset.snapshot(for:.previous).revision,resetRevision)
        XCTAssertTrue(reset.snapshot(for:.previous).drawing.strokes.isEmpty)
        await rejects {try await reset.save(original.drawing,for:.previous,expectedRevision:original.revision)}
    }

    func testCompleteFileProtectionOnSupportedFilesystem() async throws {
        let root=try directory(),store=PersonalSymbolStore(directory:root)
        try await store.save(drawing(),for:.pen,expectedRevision:nil)
        let attributes=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("symbols.json").path)
        #if targetEnvironment(simulator)
        guard attributes[.protectionKey] != nil else {throw XCTSkip("Simulator does not expose a Data Protection class. Physical lock-state verification remains open.")}
        #endif
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,.complete)
    }

    func testStudioPreviewUsesExactSavedMaskAndRejectsEmpty() async throws {
        let store=PersonalSymbolStore(directory:try directory()),source=drawing()
        let preview=try await PersonalSymbolStore.previewImage(for:source)
        try await store.save(source,for:.pen,expectedRevision:nil)
        XCTAssertEqual(preview.size,CGSize(width:24,height:24))
        XCTAssertEqual(preview.pngData(),store.images[.pen]?.pngData())
        await rejects {_ = try await PersonalSymbolStore.previewImage(for:PKDrawing())}
    }
    func testStudioDraftClearUndoAndConflictingSaveRetainDrawing() async throws {
        let store=PersonalSymbolStore(directory:try directory())
        await store.load()
        let draft=SymbolDraft();draft.load(.pen,from:store)
        draft.change(drawing());let edited=draft.drawing.dataRepresentation()
        XCTAssertTrue(draft.dirty)
        draft.change(PKDrawing());XCTAssertTrue(draft.drawing.strokes.isEmpty)
        draft.undo();XCTAssertEqual(draft.drawing.dataRepresentation(),edited)
        try await store.save(drawing(width:40),for:.pen,expectedRevision:nil)
        do {try await draft.save(to:store);XCTFail("Stale draft must conflict")}
        catch PersonalSymbolError.conflict {} catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertTrue(draft.dirty);XCTAssertNil(draft.revision)
        XCTAssertEqual(draft.drawing.dataRepresentation(),edited)
        draft.load(.pen,from:store)
        XCTAssertFalse(draft.dirty)
        XCTAssertEqual(draft.drawing.dataRepresentation(),store.snapshot(for:.pen).drawing.dataRepresentation())
        draft.change(drawing(width:25));try await draft.save(to:store)
        XCTAssertFalse(draft.dirty);XCTAssertEqual(draft.revision,store.snapshot(for:.pen).revision)
    }
    func testStudioRetainedDraftAcknowledgesRevisionAndRejectsLaterConflict() async throws {
        let store=PersonalSymbolStore(directory:try directory()),original=drawing(width:20),retained=drawing()
        try await store.save(original,for:.pen,expectedRevision:nil)
        let draft=SymbolDraft();draft.load(.pen,from:store)
        let originalRevision=draft.revision
        draft.change(retained)
        draft.preview=try await PersonalSymbolStore.previewImage(for:retained)
        let edited=retained.dataRepresentation(),history=draft.history.map {$0.dataRepresentation()}
        let preview=draft.preview?.pngData()
        XCTAssertNotNil(preview)

        try await store.save(drawing(width:40),for:.pen,expectedRevision:originalRevision)
        do {try await draft.save(to:store);XCTFail("Stale draft must conflict")}
        catch PersonalSymbolError.conflict {} catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertTrue(draft.dirty);XCTAssertEqual(draft.revision,originalRevision)
        XCTAssertEqual(draft.drawing.dataRepresentation(),edited)
        XCTAssertEqual(draft.history.map {$0.dataRepresentation()},history)
        XCTAssertEqual(draft.preview?.pngData(),preview)

        let acknowledged=store.snapshot(for:.pen)
        draft.keepDraft(from:store)
        XCTAssertEqual(draft.revision,acknowledged.revision);XCTAssertTrue(draft.dirty)
        XCTAssertEqual(draft.drawing.dataRepresentation(),edited)
        XCTAssertEqual(draft.history.map {$0.dataRepresentation()},history)
        XCTAssertEqual(draft.preview?.pngData(),preview)
        XCTAssertEqual(store.snapshot(for:.pen).drawing.dataRepresentation(),acknowledged.drawing.dataRepresentation())

        try await store.save(drawing(width:60),for:.pen,expectedRevision:acknowledged.revision)
        let latest=store.snapshot(for:.pen)
        do {try await draft.save(to:store);XCTFail("A save after acknowledgement must still conflict")}
        catch PersonalSymbolError.conflict {} catch {XCTFail("Unexpected error: \(error)")}
        XCTAssertTrue(draft.dirty);XCTAssertEqual(draft.revision,acknowledged.revision)
        XCTAssertEqual(draft.drawing.dataRepresentation(),edited)
        XCTAssertEqual(draft.history.map {$0.dataRepresentation()},history)
        XCTAssertEqual(draft.preview?.pngData(),preview)
        XCTAssertEqual(store.snapshot(for:.pen).revision,latest.revision)
        XCTAssertEqual(store.snapshot(for:.pen).drawing.dataRepresentation(),latest.drawing.dataRepresentation())

        draft.keepDraft(from:store)
        draft.undo()
        XCTAssertEqual(draft.drawing.dataRepresentation(),original.dataRepresentation())
        XCTAssertTrue(draft.dirty,"Undo to the old version is still unsaved against the acknowledged version")
        draft.change(retained)
        try await draft.save(to:store)
        XCTAssertFalse(draft.dirty);XCTAssertEqual(draft.revision,store.snapshot(for:.pen).revision)
        XCTAssertEqual(store.snapshot(for:.pen).drawing.dataRepresentation(),edited)
    }

}
