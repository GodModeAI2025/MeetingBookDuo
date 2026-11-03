import XCTest
import PencilKit
import Observation
import SwiftUI
import MeetingBookCore
@testable import MeetingBook

@MainActor final class EditorSessionTests: XCTestCase {
    func testGroupedUndoRedoAndConflictPreservesHistory() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Undo",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        try await session.insert(templates:[TemplateInstance(),TemplateInstance()],after:note.pages[0].id)
        let ids=session.snapshot.note.pageIDs
        XCTAssertEqual(ids.count,3);XCTAssertTrue(session.canUndo)
        try await session.undo();XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        try await session.redo();XCTAssertEqual(session.snapshot.note.pageIDs,ids)
        let current=session.snapshot.pages[0]
        var foreign=current.content;foreign.textBlocks=[TextBlock(text:"Other window")]
        _ = try await store.commit(PageEditTransaction(pageID:current.id,expectedRevisionID:current.currentRevisionID,content:foreign))
        do { try await session.undo();XCTFail("stale undo") } catch { XCTAssertEqual(error as? NotebookError,.revisionConflict) }
        XCTAssertTrue(session.canUndo);XCTAssertEqual(session.snapshot.note.pageIDs,ids)
    }
    func testDraftsArePageLocalAndDefaultDoesNotRestyleLegacy() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.style.fontSize=24;content.textBlocks=[TextBlock(text:"old")]
        let note=try await store.createNote(title:"Draft",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        var draft=content;draft.textBlocks[0].text="new"
        session.setDraft(draft,pageID:note.pages[0].id)
        session.select(pageID:note.pages[1].id)
        try await session.flush()
        XCTAssertEqual(session.activePageID,note.pages[1].id)
        XCTAssertEqual(session.snapshot.pages[0].content.textBlocks[0].text,"new")
        XCTAssertEqual(session.snapshot.pages[1].content,note.pages[1].content)
    }
}

extension EditorSessionTests {
    func testLateReceiptDoesNotSaveNewGenerationOrSelectedPage() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Late",contents:[PageContent(),PageContent()])
        let session=EditorSession(store:store,snapshot:note),id=note.pages[0].id
        var first=note.pages[0].content;first.textBlocks=[TextBlock(text:"generation one")];session.setDraft(first,pageID:id)
        let save=Task { try await session.flush() }
        while !session.busy { await Task.yield() }
        var second=first;second.textBlocks[0].text="generation two";session.setDraft(second,pageID:id)
        session.select(pageID:note.pages[1].id)
        try await save.value
        XCTAssertEqual(session.drafts[id]?.content,second)
        XCTAssertEqual(session.drafts[id]?.state,.dirty)
        XCTAssertEqual(session.activePageID,note.pages[1].id)
        XCTAssertEqual(session.saveState,.saved)
        try await session.flush()
        let durable=try await store.openPage(id:id);XCTAssertEqual(durable.content,second)
    }
    func testPreviewRejectsInterveningUnsavedDraft() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Preview",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note),id=note.pages[0].id
        let preview=try session.preview(pageIDs:[id]) { $0.style.paper="white" }
        var draft=session.activeContent;draft.textBlocks=[TextBlock(text:"new typing")];session.setDraft(draft,pageID:id)
        do { try await session.apply(preview);XCTFail("preview replaced a newer draft") } catch { XCTAssertEqual(error as? NotebookError,.revisionConflict) }
        XCTAssertEqual(session.activeContent,draft)
    }
}

extension EditorSessionTests {
    func testOverflowIsOneAtomicUndoWithoutTouchingNeighbor() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Overflow",contents:[PageContent(),PageContent()])
        let session=EditorSession(store:store,snapshot:note),first=note.pages[0]
        var content=first.content;content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:String(repeating:"e\u{301} 👩🏽‍💻 🇩🇪 日本語\r\n",count:100),frame:region.frame)
        block.fontSize=30;block.ink="black";block.writingRegionID=region.id;block.baselineIndex=0
        content.textBlocks=[block];session.setDraft(content,pageID:first.id)
        try await session.commitText(blockID:block.id,pageID:first.id)
        XCTAssertGreaterThan(session.snapshot.pages.count,3)
        XCTAssertEqual(session.snapshot.pages.last,note.pages.last.map { var p=$0;p.orderKey=Int64(session.snapshot.pages.count-1);return p })
        let joined=session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined()
        XCTAssertEqual(joined.unicodeScalars.map(\.value),block.text.unicodeScalars.map(\.value))
        let ids=session.snapshot.note.pageIDs
        try await session.undo();XCTAssertEqual(session.snapshot.pages.map(\.content),note.pages.map(\.content))
        try await session.redo();XCTAssertEqual(session.snapshot.note.pageIDs,ids)
    }
}

extension EditorSessionTests {
    func testPageActionPreservesIndependentUnsavedDraft() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Independent",contents:[PageContent(),PageContent()])
        let session=EditorSession(store:store,snapshot:note),a=note.pages[0].id,b=note.pages[1].id
        var other=note.pages[1].content;other.textBlocks=[TextBlock(text:"Other draft")];session.setDraft(other,pageID:b)
        let preview=try session.preview(pageIDs:[a]) { $0.style.paper="classic" }
        try await session.apply(preview)
        XCTAssertEqual(session.drafts[b]?.content,other);XCTAssertEqual(session.drafts[b]?.state,.dirty)
    }
}

extension EditorSessionTests {
    func testEnteringDrawingCommitsCurrentTextFirst() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Draw",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        var content=session.activeContent;content.textBlocks=[TextBlock(text:"Before stroke")]
        session.setDraft(content,pageID:session.activePageID)
        try await session.setMode(.drawing)
        XCTAssertEqual(session.mode,.drawing)
        let saved=try await store.openPage(id:session.activePageID);XCTAssertEqual(saved.content,content)
    }
}

extension EditorSessionTests {
    func testDelayedDrawingCannotResurrectAfterClearOrUndo() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Delayed",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note),id=note.pages[0].id
        var content=session.activeContent;content.textBlocks=[TextBlock(text:"saved")];session.setDraft(content,pageID:id);try await session.flush()
        let token=session.beginAssetWrite(pageID:id)
        let points=[CGPoint(x:80,y:100),CGPoint(x:180,y:140)]
        let path=PKStrokePath(controlPoints:points.enumerated().map { index,point in PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:5,height:5),opacity:1,force:1,azimuth:0,altitude:.pi/2) },creationDate:Date())
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.blue),path:path)])
        let staged=try await store.assets.stage(data:drawing.dataRepresentation())
        do { try await session.clear(pageID:id);XCTFail("clear discarded pending ink") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        do { try await session.undo();XCTFail("undo discarded pending ink") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        XCTAssertEqual(session.activeContent.textBlocks.first?.text,"saved")
        let delayedHash=try await store.assets.finalize(staged)
        XCTAssertTrue(session.completeDrawingWrite(token,hash:delayedHash));session.endAssetWrite(token)
        try await session.flush()
        try await session.clear(pageID:id)
        XCTAssertFalse(session.completeDrawingWrite(token,hash:delayedHash))
        XCTAssertNil(session.activeContent.drawingAssetHash)
        let cleared=try await store.openPage(id:id);XCTAssertNil(cleared.content.drawingAssetHash)
        try await session.undo()
        XCTAssertEqual(session.activeContent.drawingAssetHash,delayedHash)
        let restored=try await store.openPage(id:id);XCTAssertEqual(restored.content.drawingAssetHash,delayedHash)
        XCTAssertEqual(restored.content.textBlocks.first?.text,"saved")
        let resources=try await PageRenderer.resources(for:restored.content,store:store);XCTAssertEqual(resources.drawing.strokes.count,1)
        let redoToken=session.beginAssetWrite(pageID:id)
        do { try await session.redo();XCTFail("redo discarded pending ink") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        session.endAssetWrite(redoToken);try await session.redo()
        XCTAssertFalse(session.completeDrawingWrite(redoToken,hash:delayedHash))
        XCTAssertTrue(session.activeContent.textBlocks.isEmpty);XCTAssertNil(session.activeContent.drawingAssetHash)
    }
    func testExactUnicodeUndoRedoAcrossMixedPagesAndEmptyAction() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"\u{e9}")];content.prepareForEditing()
        let note=try await store.createNote(title:"Exact",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        let preview=try session.preview(pageIDs:Set(note.note.pageIDs)) { page in
            if page.textBlocks.isEmpty { page.style.paper="rose" } else { page.textBlocks[0].text="e\u{301}" }
        }
        try await session.apply(preview);try await session.undo()
        XCTAssertEqual(session.snapshot.pages[0].content.textBlocks[0].text.unicodeScalars.map(\.value),[0xe9])
        try await session.redo()
        XCTAssertEqual(session.snapshot.pages[0].content.textBlocks[0].text.unicodeScalars.map(\.value),[0x65,0x301])
        let empty=try session.preview(pageIDs:[note.pages[0].id]) { _ in }
        try await session.apply(empty);try await session.undo();try await session.redo()
    }
    func testPreviewRejectsOverflowAndTallInkBeforePublishing() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:String(repeating:"word ",count:160),frame:region.frame);block.fontSize=24;block.writingRegionID=region.id;block.baselineIndex=0;content.textBlocks=[block]
        try TextBlockView(block:block,content:content,versions:[]).validateVisibleContent()
        let note=try await store.createNote(title:"Fit",contents:[content]),session=EditorSession(store:store,snapshot:note)
        XCTAssertThrowsError(try session.preview(pageIDs:[note.pages[0].id]) { $0.textBlocks[0].fontSize=36 })
        XCTAssertThrowsError(try session.preview(pageIDs:[note.pages[0].id]) { $0.textBlocks[0].text="A"+String(repeating:"\u{301}",count:30) })
        var invalid=content;invalid.textBlocks[0].fontSize=36
        let bypass=EditorSession.Preview(snapshot:note,contents:[note.pages[0].id:invalid],reason:.fontApply,generations:session.drafts.mapValues(\.generation))
        do { try await session.apply(bypass);XCTFail("invalid native content published") } catch {}
        let saved=try await store.openPage(id:note.pages[0].id);XCTAssertEqual(saved.currentRevisionID,note.pages[0].currentRevisionID)
        XCTAssertEqual(session.activeContent.textBlocks[0].text.utf8.map { $0 },block.text.utf8.map { $0 })
    }
}

extension EditorSessionTests {
    func testPendingWriteBlocksFlushAndPreparedApplyWithoutLosingReceipt() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Pending",contents:[PageContent()]),session=EditorSession(store:store,snapshot:note)
        let id=note.pages[0].id,preview=try session.preview(pageIDs:[id]) { $0.style.paper="rose" }
        let token=session.beginAssetWrite(pageID:id)
        do { try await session.flush();XCTFail("pending write ignored") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        do { try await session.apply(preview);XCTFail("pending stroke replaced") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        let staged=try await store.assets.stage(data:PKDrawing().dataRepresentation()),hash=try await store.assets.finalize(staged)
        XCTAssertTrue(session.completeDrawingWrite(token,hash:hash));session.endAssetWrite(token)
        try await session.flush();let saved=try await store.openPage(id:id)
        XCTAssertEqual(saved.content.drawingAssetHash,hash);XCTAssertEqual(saved.content.style.paper,note.pages[0].content.style.paper)
    }
}

extension EditorSessionTests {
    func testImagePublicationCompletesOwnLeaseButRejectsOtherPendingWriter() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Image lease",contents:[PageContent()]),session=EditorSession(store:store,snapshot:note)
        let data=UIGraphicsImageRenderer(size:CGSize(width:2,height:2)).image { _ in UIColor.blue.setFill();UIRectFill(CGRect(x:0,y:0,width:2,height:2)) }.pngData()!
        let token=session.beginAssetWrite(pageID:session.activePageID)
        do { try await session.importImage(data);XCTFail("other writer ignored") } catch { XCTAssertEqual(error as? EditorOperationError,.inProgress) }
        XCTAssertTrue(session.activeContent.images.isEmpty);session.endAssetWrite(token)
        try await session.importImage(data);XCTAssertEqual(session.activeContent.images.count,1);XCTAssertTrue(session.pendingAssetWrites.isEmpty)
    }
    func testPhotoLeaseKeepsOriginalPageAndRejectsStaleToken() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Delayed photo",contents:[PageContent(),PageContent()]),session=EditorSession(store:store,snapshot:note)
        let data=UIGraphicsImageRenderer(size:CGSize(width:2,height:2)).image { _ in UIColor.blue.setFill();UIRectFill(CGRect(x:0,y:0,width:2,height:2)) }.pngData()!
        let original=note.pages[0].id,other=note.pages[1].id,token=session.beginAssetWrite(pageID:original)
        let started=AsyncStream<Void>.makeStream(),release=AsyncStream<Void>.makeStream()
        let transfer=Task {try await session.importImage(completingAssetToken:token) {
            started.continuation.yield();var iterator=release.stream.makeAsyncIterator();_ = await iterator.next();return data
        }}
        var iterator=started.stream.makeAsyncIterator();_ = await iterator.next()
        session.select(pageID:other);release.continuation.yield();try await transfer.value
        let saved=try await store.openPage(id:original);XCTAssertEqual(saved.content.images.count,1)
        XCTAssertTrue(session.activeContent.images.isEmpty);XCTAssertFalse(session.hasCurrentAssetWrites);XCTAssertTrue(session.pendingAssetWrites.isEmpty)
        let stale=session.beginAssetWrite(pageID:other);session.endAssetWrite(stale)
        do {try await session.importImage(completingAssetToken:stale) {data};XCTFail("stale picker write published")}
        catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        XCTAssertTrue(session.pendingAssetWrites.isEmpty)
        do {try await session.importImage(Data());XCTFail("invalid image accepted")}
        catch {XCTAssertEqual(error as? NotebookError,.invalidAsset)}
        XCTAssertTrue(session.pendingAssetWrites.isEmpty)
    }
    func testPhotoHandoffReleasesLeaseOnNilErrorAndCancellation() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Photo cleanup",contents:[PageContent()]),session=EditorSession(store:store,snapshot:note)
        let nilToken=session.beginAssetWrite(pageID:session.activePageID)
        try await session.importImage(completingAssetToken:nilToken) {nil}
        XCTAssertTrue(session.pendingAssetWrites.isEmpty)
        let errorToken=session.beginAssetWrite(pageID:session.activePageID)
        do {try await session.importImage(completingAssetToken:errorToken) {throw NotebookError.invalidAsset};XCTFail("transfer error ignored")}
        catch {XCTAssertEqual(error as? NotebookError,.invalidAsset)}
        XCTAssertTrue(session.pendingAssetWrites.isEmpty)
        let cancelToken=session.beginAssetWrite(pageID:session.activePageID),started=AsyncStream<Void>.makeStream()
        let transfer=Task {try await session.importImage(completingAssetToken:cancelToken) {
            started.continuation.yield();try await Task.sleep(for:.seconds(30));return Data()
        }}
        var iterator=started.stream.makeAsyncIterator();_ = await iterator.next();transfer.cancel()
        do {try await transfer.value;XCTFail("cancelled transfer continued")}
        catch {XCTAssertTrue(error is CancellationError)}
        XCTAssertTrue(session.pendingAssetWrites.isEmpty);XCTAssertFalse(session.hasCurrentAssetWrites)
    }
}


extension EditorSessionTests {
    func testImmediateCustomizeDrainPreservesUnicodeThroughPreviewApplyUndo() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Immediate customization",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        var draft=session.activeContent;draft.prepareForEditing()
        draft.textBlocks=[TextBlock(text:"Äß e\u{301} 👩🏽‍💻")]
        session.setDraft(draft,pageID:session.activePageID)
        try await session.leave()
        let preview=try session.preview(pageIDs:[session.activePageID]) {$0.style.paper="cream"}
        XCTAssertEqual(preview.contents[session.activePageID]?.textBlocks[0].text.unicodeScalars.map(\.value),draft.textBlocks[0].text.unicodeScalars.map(\.value))
        XCTAssertEqual(session.activeContent.style.paper,draft.style.paper)
        try await session.apply(preview);try await session.undo()
        XCTAssertEqual(session.activeContent,draft)
        var marked=draft;marked.textBlocks[0].text="Composition"
        session.setDraft(marked,pageID:session.activePageID,markedText:true)
        do {try await session.leave();XCTFail("Marked draft must remain editable")} catch {}
        XCTAssertEqual(session.activeContent,marked)
    }
    func testAutosaveStartsAtSpecifiedHalfSecondDebounce() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Debounce",contents:[PageContent()]),session=EditorSession(store:store,snapshot:note)
        var draft=session.activeContent;draft.textBlocks=[TextBlock(text:"last unmarked edit")]
        let receipt=expectation(description:"durable receipt")
        let start=ContinuousClock.now
        session.didCommit={_ in receipt.fulfill()}
        session.setDraft(draft,pageID:session.activePageID)
        await fulfillment(of:[receipt],timeout:1)
        let elapsed=start.duration(to:.now)
        XCTAssertGreaterThanOrEqual(elapsed,.milliseconds(490))
        XCTAssertLessThan(elapsed,.milliseconds(800))
        let saved=try await store.openPage(id:session.activePageID)
        XCTAssertEqual(saved.content.textBlocks[0].text,"last unmarked edit")
    }
}

extension EditorSessionTests {
    func testOverlappingNativeOverflowCallbacksCommitOnceAndUndoExactUnicode() async throws {
        try await exerciseOverlappingNativeOverflow(atBottom:false)
    }
    func testBottomLineNewlineDoesNotCreateRepeatedEmptyContinuations() async throws {
        try await exerciseOverlappingNativeOverflow(atBottom:true)
    }
    func testEditingAnotherBlockDoesNotRepaginateSavedTrailingNewline() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        let baseline=region.baselines.count-1,y=region.frame.y+region.baselines[baseline]-region.baselines[0]
        var block=TextBlock(text:"Original",frame:.init(x:region.frame.x,y:y,width:region.frame.width,height:region.frame.y+region.frame.height-y))
        block.fontSize=30;block.fontCatalogID="bundled.caveat";block.writingRegionID=region.id;block.baselineIndex=baseline
        content.textBlocks=[block]
        let note=try await store.createNote(title:"Saved newline",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        content.textBlocks[0].text="Unterste Zeile\n"
        session.setDraft(content,pageID:note.pages[0].id);try await session.flush()
        let pageIDs=session.snapshot.note.pageIDs
        var next=session.drafts[note.pages[0].id]!.content
        next.textBlocks.append(TextBlock(text:"Neuer Block",frame:region.frame))
        session.setDraft(next,pageID:note.pages[0].id);try await session.flush()
        XCTAssertEqual(session.snapshot.note.pageIDs,pageIDs)
        XCTAssertEqual(session.snapshot.pages[0].content,next)
    }
    private func exerciseOverlappingNativeOverflow(atBottom: Bool) async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:"Original Ä",frame:region.frame)
        block.fontSize=30;block.fontCatalogID="bundled.caveat";block.writingRegionID=region.id;block.baselineIndex=0
        if atBottom {
            let baseline=region.baselines.count-1
            let y=region.frame.y+region.baselines[baseline]-region.baselines[0]
            block.frame = .init(x:region.frame.x,y:y,width:region.frame.width,height:region.frame.y+region.frame.height-y)
            block.baselineIndex=baseline
        }
        content.textBlocks=[block]
        let note=try await store.createNote(title:"Native overflow",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();try await session.setMode(.typing)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        let value=atBottom ? "Größe ÄÖÜ ß Ω ✓\nUntere Zeile Café 👋" : String(repeating:"e\u{301} 👩🏽‍💻 🇩🇪 日本語\r\n",count:100)
        let committed=expectation(description:"Atomic continuation commit");var commits=0,errors=[String]()
        session.didCommit={_ in commits += 1;if commits==1 {committed.fulfill()}}
        controller.reportError={errors.append($0.localizedDescription)}
        text.text=value;controller.textViewDidChange(text);controller.textViewDidChange(text)
        await fulfillment(of:[committed],timeout:10)
        try await session.leave()
        XCTAssertTrue(errors.isEmpty,"Native callback errors: \(errors)");XCTAssertNil(session.errorMessage)
        XCTAssertEqual(commits,1)
        if atBottom {XCTAssertEqual(session.snapshot.pages.count,3,"One continuation and the original neighboring page")}
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array(value.utf8))
        XCTAssertEqual(Set(session.snapshot.note.pageIDs).count,session.snapshot.note.pageIDs.count)
        XCTAssertEqual(session.snapshot.pages.last?.id,note.pages.last?.id)
        XCTAssertEqual(session.snapshot.pages.last?.content,note.pages.last?.content)
        try await session.undo()
        XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        XCTAssertEqual(session.snapshot.pages.map(\.content),note.pages.map(\.content));XCTAssertFalse(session.canUndo)
    }
}

extension EditorSessionTests {
    func testCoalescedOverflowPropagatesConflictAndUnlocksBothCallers() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Conflicting overflow",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note),page=note.pages[0]
        var external=page.content;external.style.paper="white"
        _=try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:external))
        var draft=page.content;draft.prepareForEditing();let region=draft.template.writingRegions[0]
        var block=TextBlock(text:String(repeating:"Ä e\u{301} 👩🏽‍💻\n",count:100),frame:region.frame)
        block.writingRegionID=region.id;block.baselineIndex=0;draft.textBlocks=[block]
        session.setDraft(draft,pageID:page.id)
        let first=Task {try await session.commitText(blockID:block.id,pageID:page.id)}
        let second=Task {try await session.commitText(blockID:block.id,pageID:page.id)}
        for task in [first,second] {
            do {try await task.value;XCTFail("Stale overflow accepted")} catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        }
        XCTAssertFalse(session.busy);XCTAssertTrue(session.frozenPageIDs.isEmpty)
        XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),Array(block.text.utf8))
        XCTAssertFalse(session.canUndo)
    }
}


extension EditorSessionTests {
    func testNativeOverflowWaitsForAlreadyRunningSaveAndKeepsLatestUnicode() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assets=await store.assets
        let staged=try await assets.stage(data:PKDrawing().dataRepresentation())
        let hash=try await assets.finalize(staged)
        var content=PageContent();content.prepareForEditing();content.drawingAssetHash=hash
        let region=content.template.writingRegions[0]
        var block=TextBlock(text:"Original Ä",frame:region.frame)
        block.fontSize=30;block.fontCatalogID="bundled.caveat";block.writingRegionID=region.id;block.baselineIndex=0
        content.textBlocks=[block]
        let note=try await store.createNote(title:"Save before overflow",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();try await session.setMode(.typing)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        var saved=content;saved.textBlocks[0].text="Saved before overflow"
        session.setDraft(saved,pageID:note.pages[0].id)
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next()
        defer {release.signal()}
        let saving=AsyncStream<Void>.makeStream()
        withObservationTracking { _=session.busy } onChange: {saving.continuation.yield()}
        let save=Task {try await session.flush()}
        var si=saving.stream.makeAsyncIterator();_ = await si.next()
        XCTAssertTrue(session.busy)
        let value=String(repeating:"e\u{301} 👩🏽‍💻 🇩🇪 日本語\r\n",count:100)
        var errors=[String]();controller.reportError={errors.append($0.localizedDescription)}
        text.text=value;controller.textViewDidChange(text)
        // Drain the native callback's queued commit while the durable asset actor remains gated.
        await Task.yield()
        release.signal();await holder.value;try await save.value
        try await session.leave()
        XCTAssertTrue(errors.isEmpty,"Native callback errors: \(errors)")
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array(value.utf8))
        XCTAssertEqual(Set(session.snapshot.note.pageIDs).count,session.snapshot.note.pageIDs.count)
        XCTAssertEqual(session.snapshot.pages.last?.content,note.pages.last?.content)
        try await session.undo()
        XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        XCTAssertEqual(session.snapshot.pages[0].content,saved)
    }
}

extension EditorSessionTests {
    func testPaginatedTypingUndoRedoRestoresExistingFieldFocusAndSelection() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        let last=region.baselines.count-1,y=region.frame.y+region.baselines[last]-region.baselines[0]
        var block=TextBlock(text:"",frame:.init(x:region.frame.x,y:y,width:region.frame.width,height:region.frame.y+region.frame.height-y))
        block.writingRegionID=region.id;block.baselineIndex=last;content.textBlocks=[block]
        let note=try await store.createNote(title:"Undo existing empty field",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();session.selectedElementID=block.id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),controller=PageCanvasController(session:session)
        window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded();defer {window.isHidden=true}
        let field=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first)
        XCTAssertTrue(field.becomeFirstResponder())
        let value="Letzte Zeile\nFortsetzung e\u{301} 👋"
        field.insertText(value);controller.textViewDidChange(field);try await session.leave();controller.refresh()
        let afterPage=session.activePageID,afterBlock=try XCTUnwrap(session.selectedElementID)
        let afterRange=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first(where: \.isFirstResponder)).selectedRange
        controller.view.endEditing(true);try await session.undo();controller.refresh()
        XCTAssertEqual(session.mode,.typing);XCTAssertEqual(session.activePageID,note.pages[0].id)
        XCTAssertEqual(session.activeContent.textBlocks,[block]);XCTAssertEqual(session.selectedElementID,block.id)
        let restored=controller.page.subviews.compactMap {$0 as? TextBlockView}.first(where: \.isFirstResponder)
        XCTAssertEqual(restored?.blockID,block.id);XCTAssertEqual(restored?.selectedRange,NSRange(location:0,length:0))
        try await session.redo();controller.refresh()
        XCTAssertEqual(session.mode,.typing);XCTAssertEqual(session.activePageID,afterPage);XCTAssertEqual(session.selectedElementID,afterBlock)
        let redone=controller.page.subviews.compactMap {$0 as? TextBlockView}.first(where: \.isFirstResponder)
        XCTAssertEqual(redone?.blockID,afterBlock);XCTAssertEqual(redone?.selectedRange,afterRange)
        redone?.insertText("✓");if let redone {controller.textViewDidChange(redone)};try await session.leave()
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array((value+"✓").utf8))
    }
    func testPaginationCompletionPreservesNewerOtherBlockFocusAndFollowingInput() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assets=await store.assets
        let staged=try await assets.stage(data:PKDrawing().dataRepresentation()),hash=try await assets.finalize(staged)
        var content=PageContent();content.prepareForEditing();content.drawingAssetHash=hash
        let region=content.template.writingRegions[0],last=content.template.writingRegions[0].baselines.count-1
        let y=region.frame.y+region.baselines[last]-region.baselines[0]
        var a=TextBlock(text:"Block A",frame:.init(x:region.frame.x,y:y,width:region.frame.width,height:region.frame.y+region.frame.height-y))
        a.writingRegionID=region.id;a.baselineIndex=last
        var b=TextBlock(text:"Block B",frame:region.frame);b.writingRegionID=region.id;b.baselineIndex=0
        content.textBlocks=[a,b]
        let note=try await store.createNote(title:"Newer block focus",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        session.selectedElementID=a.id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),controller=PageCanvasController(session:session)
        window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded()
        defer {window.isHidden=true}
        let textA=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first {$0.blockID == a.id})
        XCTAssertTrue(textA.becomeFirstResponder())
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next();defer {release.signal()}
        let saving=AsyncStream<Void>.makeStream()
        withObservationTracking {_=session.busy} onChange: {saving.continuation.yield()}
        let value="Untere Zeile A\nFortsetzung A"
        textA.text=value;textA.selectedRange=NSRange(location:(value as NSString).length,length:0)
        controller.textViewDidChange(textA)
        var si=saving.stream.makeAsyncIterator();_ = await si.next()
        let textB=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first {$0.blockID == b.id})
        XCTAssertTrue(textB.becomeFirstResponder());textB.selectedRange=NSRange(location:2,length:2)
        controller.textViewDidChangeSelection(textB)
        let generation=session.drafts[note.pages[0].id]?.generation
        XCTAssertEqual(session.selectedElementID,b.id)
        release.signal();await holder.value;try await session.leave();controller.refresh()
        XCTAssertEqual(session.activePageID,note.pages[0].id)
        XCTAssertEqual(session.selectedElementID,b.id)
        XCTAssertTrue(textB.isFirstResponder);XCTAssertTrue(textB.superview === controller.page)
        XCTAssertEqual(textB.selectedRange,NSRange(location:2,length:2))
        XCTAssertEqual(session.drafts[note.pages[0].id]?.generation,generation)
        let focused=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first(where: \.isFirstResponder))
        focused.insertText("✓");controller.textViewDidChange(focused);try await session.leave()
        let savedB=try XCTUnwrap(session.snapshot.pages[0].content.textBlocks.first {$0.id == b.id})
        XCTAssertEqual(savedB.text,"Bl✓k B")
        let savedA=session.snapshot.pages.flatMap(\.content.textBlocks).filter {$0.id != b.id}.map(\.text).joined()
        XCTAssertEqual(Array(savedA.utf8),Array(value.utf8))
    }
    func testCancelledAssetBeforeCommitReleasesWaitingPagination() async throws {
        try await exerciseAssetCleanupBeforeCommit(cancel:true)
    }
    func testFailedAssetFinalizationReleasesWaitingPagination() async throws {
        try await exerciseAssetCleanupBeforeCommit(cancel:false)
    }
    private func exerciseAssetCleanupBeforeCommit(cancel: Bool) async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assets=await store.assets,note=try await store.createNote(title:"Asset cleanup",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        var content=note.pages[0].content;content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:String(repeating:"Unicode e\u{301}\n",count:60),frame:region.frame)
        block.writingRegionID=region.id;block.baselineIndex=0;content.textBlocks=[block]
        let token=session.beginAssetWrite(pageID:note.pages[0].id)
        session.setDraft(content,pageID:note.pages[0].id)
        let pagination=Task {try await session.commitText(blockID:block.id,pageID:note.pages[0].id)}
        await Task.yield()
        XCTAssertFalse(session.busy);XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        let asset=Task {
            defer {session.endAssetWrite(token)}
            if cancel {try Task.checkCancellation()}
            _=try await assets.finalize(StagedAsset(id:UUID(),hash:String(repeating:"a",count:64)))
        }
        if cancel {asset.cancel()}
        do {try await asset.value;XCTFail("Asset must fail before starting a store commit")}
        catch {if cancel {XCTAssertTrue(error is CancellationError)}}
        try await pagination.value;try await session.leave()
        XCTAssertTrue(session.pendingAssetWrites.isEmpty)
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array(block.text.utf8))
        try await session.undo();XCTAssertEqual(session.snapshot.pages.map(\.content),note.pages.map(\.content))
    }
    func testEarlierAssetCompletionKeepsItsOwnUndoBeforeWaitingPagination() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assets=await store.assets
        let staged=try await assets.stage(data:PKDrawing().dataRepresentation()),hash=try await assets.finalize(staged)
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:"Original",frame:region.frame)
        block.writingRegionID=region.id;block.baselineIndex=0;content.textBlocks=[block]
        let note=try await store.createNote(title:"Prior asset",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();try await session.setMode(.typing)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let text=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first)
        let token=session.beginAssetWrite(pageID:note.pages[1].id)
        let value=String(repeating:"e\u{301} 日本語\n",count:50)
        text.text=value;controller.textViewDidChange(text)
        await Task.yield()
        XCTAssertFalse(session.busy)
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next();defer {release.signal()}
        var attachment=PageContent();attachment.drawingAssetHash=hash
        let saving=AsyncStream<Void>.makeStream()
        withObservationTracking {_=session.busy} onChange: {saving.continuation.yield()}
        let assetSave=Task {defer {session.endAssetWrite(token)};try await session.paste(content:attachment,completingAssetToken:token)}
        var si=saving.stream.makeAsyncIterator();_ = await si.next()
        release.signal();await holder.value;try await assetSave.value;try await session.leave()
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array(value.utf8))
        XCTAssertEqual(session.snapshot.pages.last?.content,attachment)
        try await session.undo()
        XCTAssertEqual(session.snapshot.pages.count,3)
        XCTAssertEqual(session.snapshot.pages[0].content,note.pages[0].content)
        XCTAssertEqual(session.snapshot.pages.last?.content,attachment)
        try await session.undo()
        XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        XCTAssertFalse(session.canUndo)
    }
    func testNativeInputDuringStructuralSaveRetainsUnicodeCompositionAndDelete() async throws {
        try await exerciseNativeInputDuringStructuralSave()
    }
    func testCompositionAcrossStructuralReceiptCanShrinkBackToOriginalPage() async throws {
        try await exerciseNativeInputDuringStructuralSave(shrink:true)
    }
    func testStructuralRetryAfterFirstReceiptReusesContinuationAndOneUndo() async throws {
        try await exerciseNativeInputDuringStructuralSave(failSecondSave:true)
    }
    func testStructuralSaveKeepsSelectionInItsContainingChunk() async throws {
        try await exerciseNativeInputDuringStructuralSave(selectFirstChunk:true)
    }
    func testPendingCompositionRejectsAnotherPageFlushWithoutRecursing() async throws {
        try await exerciseNativeInputDuringStructuralSave(shrink:true,blockOtherPage:true)
    }
    private func exerciseNativeInputDuringStructuralSave(shrink: Bool = false, failSecondSave: Bool = false, selectFirstChunk: Bool = false, blockOtherPage: Bool = false) async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assets=await store.assets
        let staged=try await assets.stage(data:PKDrawing().dataRepresentation())
        let hash=try await assets.finalize(staged)
        var content=PageContent();content.prepareForEditing();content.drawingAssetHash=hash
        let region=content.template.writingRegions[0],baseline=content.template.writingRegions[0].baselines.count-1
        let y=region.frame.y+region.baselines[baseline]-region.baselines[0]
        var block=TextBlock(text:"Original",frame:.init(x:region.frame.x,y:y,width:region.frame.width,height:region.frame.y+region.frame.height-y))
        block.fontSize=30;block.fontCatalogID="bundled.caveat";block.writingRegionID=region.id;block.baselineIndex=baseline
        content.textBlocks=[block]
        let note=try await store.createNote(title:"Typing during overflow",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();try await session.setMode(.typing)
        session.selectedElementID=block.id
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        var errors=[String]();controller.reportError={errors.append($0.localizedDescription)}
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next();defer {release.signal()}
        let saving=AsyncStream<Void>.makeStream()
        withObservationTracking {_=session.busy} onChange: {saving.continuation.yield()}
        let prefix="Größe ÄÖÜ ß Ω ✓\n"
        text.text=prefix;text.selectedRange=NSRange(location:(prefix as NSString).length,length:0)
        controller.textViewDidChange(text)
        var si=saving.stream.makeAsyncIterator();_ = await si.next()
        XCTAssertTrue(session.busy)
        for character in "Untere Zeile Caf" {text.insertText(String(character))}
        text.setMarkedText("é",selectedRange:NSRange(location:1,length:0))
        XCTAssertNotNil(text.markedTextRange,"Automatic saving must retain native composition")
        if shrink {
            controller.textViewDidChange(text)
            release.signal();await holder.value
            do {try await session.flush();XCTFail("Marked pagination must remain pending")} catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
            XCTAssertTrue(Set(session.snapshot.note.pageIDs.dropLast()).isSubset(of:session.leasedPageIDs))
            controller.refresh()
            XCTAssertTrue(controller.page.subviews.contains {$0 === text})
            XCTAssertEqual(session.activePageID,note.pages[0].id)
            XCTAssertNotNil(text.markedTextRange)
            if blockOtherPage {
                var neighbor=session.drafts[note.pages[1].id]!.content
                neighbor.textBlocks=[TextBlock(text:String(repeating:"Other page\n",count:100),frame:region.frame)]
                session.setDraft(neighbor,pageID:note.pages[1].id)
                do {try await session.flush();XCTFail("A second page must not recurse behind marked pagination")} catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
                return
            }
        }
        text.unmarkText();controller.textViewDidChange(text)
        text.insertText(" 👋");text.deleteBackward();text.insertText("👋")
        controller.textViewDidChange(text)
        var expected=prefix+"Untere Zeile Café 👋"
        if shrink {
            expected="Kurz 👋"
            text.selectedRange=NSRange(location:0,length:(text.text as NSString).length)
            text.insertText(expected);controller.textViewDidChange(text)
        }
        XCTAssertEqual(Array(text.text.utf8),Array(expected.utf8),"Automatic saving must accept every native edit")
        if selectFirstChunk {
            text.selectedRange=NSRange(location:2,length:3);controller.textViewDidChange(text)
        }
        if failSecondSave {
            var first=true
            session.didCommit={_ in
                if first {
                    first=false
                    var latest=session.drafts[note.pages[0].id]!.content
                    latest.drawingAssetHash=String(repeating:"a",count:64)
                    session.setDraft(latest,pageID:note.pages[0].id)
                }
            }
        }
        release.signal();await holder.value
        if failSecondSave {
            do {try await session.leave();XCTFail("Missing asset should fail reconciliation")} catch {}
            XCTAssertEqual(session.snapshot.pages.count,3)
            let owned=Set(session.snapshot.note.pageIDs)
            let token=session.beginAssetWrite(pageID:note.pages[1].id)
            do {try await session.paste(content:PageContent(),completingAssetToken:token);XCTFail("Pending pagination must keep unrelated Undo separate")}
            catch {XCTAssertTrue(error is EditorOperationError,"Unexpected error: \(error)")}
            session.endAssetWrite(token)
            var retained=session.drafts[note.pages[0].id]!.content
            XCTAssertEqual(Array(retained.textBlocks[0].text.utf8),Array(expected.utf8))
            retained.drawingAssetHash=hash;session.setDraft(retained,pageID:note.pages[0].id)
            session.didCommit=nil
            try await session.leave()
            XCTAssertEqual(Set(session.snapshot.note.pageIDs),owned)
            errors=[]
        }
        try await session.leave()
        XCTAssertTrue(errors.isEmpty,"Native errors: \(errors)")
        XCTAssertEqual(Array(session.snapshot.pages.flatMap(\.content.textBlocks).map(\.text).joined().utf8),Array(expected.utf8))
        XCTAssertEqual(session.snapshot.pages.count,shrink ? 2 : 3)
        XCTAssertEqual(session.snapshot.pages.last?.content,note.pages.last?.content)
        if selectFirstChunk {
            controller.refresh()
            XCTAssertEqual(session.activePageID,note.pages[0].id)
            XCTAssertEqual(text.selectedRange,NSRange(location:2,length:3))
        }
        try await session.undo()
        XCTAssertEqual(session.snapshot.note.pageIDs,note.note.pageIDs)
        XCTAssertEqual(session.snapshot.pages.map(\.content),note.pages.map(\.content))
        XCTAssertFalse(session.canUndo)
    }
}

extension EditorSessionTests {
    func testRefreshReconcilesWireRemovedActiveCleanPage() async throws {
        let sender=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let receiver=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let fingerprint=String(repeating:"a",count:64)
        let a=try await sender.bindAccountAfterConsent(fingerprint:fingerprint,container:"iCloud.de.meetingbook.app",environment:"development",expected:sender.syncScope(),engineID:UUID())
        let b=try await receiver.bindAccountAfterConsent(fingerprint:fingerprint,container:"iCloud.de.meetingbook.app",environment:"development",expected:receiver.syncScope(),engineID:UUID())
        var first=PageContent(),second=PageContent()
        first.textBlocks=[TextBlock(text:"A")];second.textBlocks=[TextBlock(text:"B")]
        let note=try await sender.createNote(title:"Refresh membership",contents:[first,second])
        for wire in try await sender.prepareWireOutbox(scope:a) {
            try await receiver.stageWire(wire,scope:b);try await sender.acknowledgeWire(wire,scope:a,systemFields:Data())
        }
        _ = try await receiver.reconcileWire(scope:b)
        let session=EditorSession(store:receiver,snapshot:try await receiver.openNote(id:note.note.id))
        let removed=note.pages[1]
        session.select(pageID:removed.id);try await session.setMode(.typing)
        session.selectedElementID=second.textBlocks[0].id;session.activeRegionID=UUID()
        session.textSelection = .init(pageID:removed.id,blockID:second.textBlocks[0].id,range:NSRange(location:1,length:0))
        try await sender.deletePage(id:removed.id,expectedRevisionID:removed.currentRevisionID)
        for wire in try await sender.prepareWireOutbox(scope:a) {try await receiver.stageWire(wire,scope:b)}
        _ = try await receiver.reconcileWire(scope:b)
        try await session.refresh()
        XCTAssertFalse(session.isUnavailable)
        XCTAssertEqual(session.snapshot.note.pageIDs,[note.pages[0].id])
        XCTAssertEqual(session.activePageID,note.pages[0].id)
        XCTAssertEqual(Set(session.drafts.keys),Set(session.snapshot.note.pageIDs))
        XCTAssertNil(session.selectedElementID);XCTAssertNil(session.activeRegionID);XCTAssertNil(session.textSelection)
        var edited=session.activeContent;edited.textBlocks[0].text += "✓"
        session.setDraft(edited,pageID:session.activePageID);try await session.flush()
        let durable=try await receiver.openPage(id:note.pages[0].id)
        XCTAssertEqual(durable.content.textBlocks[0].text,"A✓")
    }

    func testRefreshKeepsInputArrivingDuringCaptureRecoverable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        var content=PageContent();content.textBlocks=[TextBlock(text:"B")]
        let note=try await store.createNote(title:"Refresh race",contents:[PageContent(),content]),page=note.pages[1]
        let session=EditorSession(store:store,snapshot:note);session.select(pageID:page.id)
        try await store.deletePage(id:page.id,expectedRevisionID:page.currentRevisionID)
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await store.holdForRefreshTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next();defer {release.signal()}
        let began=AsyncStream<Void>.makeStream()
        let refresh=Task {began.continuation.yield();try await session.refresh()}
        var bi=began.stream.makeAsyncIterator();_ = await bi.next()
        let value="B e\u{301} 👩🏽‍💻 unsaved"
        var dirty=content;dirty.textBlocks[0].text=value;session.setDraft(dirty,pageID:page.id)
        release.signal();await holder.value;try await refresh.value
        XCTAssertEqual(session.activeContent.textBlocks[0].text,value)
        XCTAssertEqual(session.draftLeases.map(\.pageID),[page.id])
        XCTAssertEqual(session.saveState,.conflict);XCTAssertTrue(session.isUnavailable);XCTAssertEqual(session.mode,.reading)
        let capture=try await store.captureBackup(drafts:session.draftLeases)
        let url=try await NotebookPackage(root:root.appendingPathComponent("packages")).create(capture:capture,assets:store.assets)
        let recovered=try await NotebookStore.open(root:root.appendingPathComponent("recovered"))
        let restore=RestoreService(store:recovered,root:root.appendingPathComponent("imports"))
        let preview=try await restore.inspectImport(url:url);try await restore.restore(preview,policy:.replace)
        let restored=try await recovered.restoreDeletedPage(id:page.id)
        XCTAssertEqual(Array(restored.content.textBlocks[0].text.utf8),Array(value.utf8))
    }

    func testRefreshOfDeletedCleanNoteStopsEditingWithoutDiscardingSnapshot() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Deleted note",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note);try await session.setMode(.typing)
        try await store.trash(noteID:note.note.id)
        try await session.refresh()
        XCTAssertTrue(session.isUnavailable);XCTAssertEqual(session.mode,.reading)
        XCTAssertEqual(session.snapshot,note)
        XCTAssertTrue(session.draftLeases.isEmpty)
    }
    func testRefreshKeepsInputAfterWholeNoteDeletionInEmergencyPackage() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Original")]
        let note=try await store.createNote(title:"Deleted during capture",contents:[content])
        let session=EditorSession(store:store,snapshot:note);try await session.setMode(.typing)
        session.selectedElementID=content.textBlocks[0].id
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let field=try XCTUnwrap(controller.page.subviews.compactMap {$0 as? TextBlockView}.first)
        try await store.trash(noteID:note.note.id)
        let held=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
        let holder=Task.detached {await store.holdForRefreshTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next();defer {release.signal()}
        let began=AsyncStream<Void>.makeStream()
        let refresh=Task {began.continuation.yield();try await session.refresh()}
        var bi=began.stream.makeAsyncIterator();_ = await bi.next()
        let value="Unstored Ω e\u{301} 👋"
        var dirty=content;dirty.textBlocks[0].text=value;session.setDraft(dirty,pageID:note.pages[0].id)
        release.signal();await holder.value;try await refresh.value
        XCTAssertTrue(session.isUnavailable);XCTAssertEqual(session.saveState,.conflict)
        field.insertText("blocked");XCTAssertEqual(field.text,"Original")
        controller.refresh();XCTAssertFalse(field.isEditable);XCTAssertEqual(field.text,value)
        let capture=try await store.captureBackup(drafts:session.draftLeases)
        let url=try await NotebookPackage(root:root.appendingPathComponent("packages")).create(capture:capture,assets:store.assets)
        let recovered=try await NotebookStore.open(root:root.appendingPathComponent("recovered"))
        let restore=RestoreService(store:recovered,root:root.appendingPathComponent("imports"))
        let preview=try await restore.inspectImport(url:url);try await restore.restore(preview,policy:.replace)
        try await recovered.restore(noteID:note.note.id)
        let restored=try await recovered.openNote(id:note.note.id)
        XCTAssertEqual(Array(restored.pages[0].content.textBlocks[0].text.utf8),Array(value.utf8))
    }

    func testHostedRefreshShowsSurvivingPageThenClosesDeletedNote() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let initial=try await NotebookStore.open(root:root)
        var a=PageContent(),b=PageContent();a.textBlocks=[TextBlock(text:"Surviving A")];b.textBlocks=[TextBlock(text:"Removed B")]
        let note=try await initial.createNote(title:"Hosted refresh",contents:[a,b])
        var preferences=await initial.preferences();preferences.lastPageID=note.pages[1].id;try await initial.savePreferences(preferences)
        let defaults=try XCTUnwrap(UserDefaults(suiteName:UUID().uuidString));defaults.set("last",forKey:"startup")
        let model=LibraryModel(root:root,widgetPublisher:WidgetSnapshotPublisher(directory:nil,reload:{}),widgetDefaults:defaults)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:NotebookView(library:model).defaultAppStorage(defaults))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        func fields(_ view:UIView) -> [TextBlockView] {view.subviews.flatMap {($0 as? TextBlockView).map {[$0]} ?? fields($0)}}
        for _ in 0..<100 where !fields(host.view).contains(where:{$0.text=="Removed B"}) {try await Task.sleep(for:.milliseconds(50))}
        let field=try XCTUnwrap(fields(host.view).first(where:{$0.text=="Removed B"}))
        let controller=try XCTUnwrap(field.delegate as? PageCanvasController),session=controller.session
        let store=try XCTUnwrap(model.store)
        try await store.deletePage(id:note.pages[1].id,expectedRevisionID:note.pages[1].currentRevisionID)
        try await model.reload(wakeSync:false);try await session.refresh()
        for _ in 0..<100 where !fields(host.view).contains(where:{$0.text=="Surviving A"}) {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(session.activePageID,note.pages[0].id)
        XCTAssertEqual(fields(host.view).map(\.text),["Surviving A"])
        try await store.trash(noteID:note.note.id);try await model.reload(wakeSync:false);try await session.refresh()
        for _ in 0..<100 where !fields(host.view).isEmpty {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertTrue(fields(host.view).isEmpty)
        XCTAssertTrue(session.isUnavailable);XCTAssertEqual(model.error,NotebookError.notFound.localizedDescription)
    }

}

private extension NotebookStore {
    func holdForRefreshTest(started:AsyncStream<Void>.Continuation,release:DispatchSemaphore) {started.yield();release.wait()}
}
