import XCTest
import MeetingBookCore
@testable import MeetingBook

@MainActor final class NoteTransactionTests: XCTestCase {
    func testConfiguredCreationAndAtomicConflict() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Original 👩🏽‍💻")]
        let initial=try await store.createNote(title:"Configured",contents:[content,content])
        XCTAssertEqual(initial.pages.map(\.content),[content,content])
        let p=initial.pages[0];var changed=content;changed.textBlocks[0].text="Changed"
        _ = try await store.commit(PageEditTransaction(pageID:p.id,expectedRevisionID:p.currentRevisionID,content:changed))
        let before=try await store.snapshot()
        do {
            _ = try await store.commit(NoteEditTransaction(snapshot:initial,changes:[.update(pageID:p.id,content:content,reason:.edit),.insert(id:UUID(),content:content,after:p.id)]))
            XCTFail("stale batch accepted")
        } catch { XCTAssertEqual(error as? NotebookError,.revisionConflict) }
        let after=try await store.snapshot();XCTAssertEqual(before,after)
    }
    func testInsertRemoveRestoreSameIdentityAndFailureRollback() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let initial=try await store.createNote(title:"A",contents:[PageContent()]);let first=initial.pages[0].id,new=UUID()
        let inserted=try await store.commit(NoteEditTransaction(snapshot:initial,changes:[.insert(id:new,content:PageContent(),after:first)]))
        XCTAssertEqual(inserted.snapshot.note.pageIDs,[first,new])
        let removed=try await store.commit(NoteEditTransaction(snapshot:inserted.snapshot,changes:[.remove(pageID:new)]))
        var restore=NoteEditTransaction(snapshot:removed.snapshot,changes:[.restore(pageID:new,after:first)])
        restore.expectedRevisionIDs[new]=inserted.snapshot.pages[1].currentRevisionID
        let restored=try await store.commit(restore)
        XCTAssertEqual(restored.snapshot.note.pageIDs,[first,new])
        let before=try await store.snapshot()
        do { _ = try await store.commit(NoteEditTransaction(snapshot:restored.snapshot,changes:[.remove(pageID:first),.remove(pageID:new)]));XCTFail("empty note") } catch { XCTAssertEqual(error as? NotebookError,.lastPage) }
        let after=try await store.snapshot();XCTAssertEqual(before,after)
    }
}

extension NoteTransactionTests {
    func testMissingAssetDuplicateAndForeignChangesLeaveEverythingUnchanged() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Target",contents:[PageContent()])
        let foreign=try await store.createNote(title:"Other",contents:[PageContent()])
        var missing=PageContent();missing.drawingAssetHash=String(repeating:"a",count:64)
        let duplicate=UUID()
        let changes: [[NoteChange]]=[
            [.insert(id:UUID(),content:PageContent(),after:note.pages[0].id),.insert(id:UUID(),content:missing,after:note.pages[0].id)],
            [.insert(id:duplicate,content:PageContent(),after:nil),.insert(id:duplicate,content:PageContent(),after:nil)],
            [.remove(pageID:foreign.pages[0].id)]
        ]
        for change in changes {
            let before=try await store.snapshot()
            do { _ = try await store.commit(NoteEditTransaction(snapshot:note,changes:change));XCTFail("invalid batch") } catch {}
            let after=try await store.snapshot();XCTAssertEqual(before,after)
        }
    }
}

extension NoteTransactionTests {
    func testImportedImmutableFontAndContentPublishTogether() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root),note=try await store.createNote(title:"Import",contents:[PageContent()])
        let id=UUID(),name="MeetingBook-"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let fontID=UUID(),postScriptName="MeetingBook-"+fontID.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(550,700),.init(550,0)]],advanceWidth:600)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map { ($0,outline) });glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let bytes=try TrueTypeWriter.build(glyphs:glyphs,postScriptName:postScriptName)
        let staged=try await store.assets.stage(data:bytes),hash=try await store.assets.finalize(staged)
        let font=FontVersion(id:fontID,assetHash:hash,postScriptName:postScriptName)
        var content=PageContent();content.textBlocks=[TextBlock(text:"Font",fontVersionID:fontID)]
        var transaction=NoteEditTransaction(snapshot:note,changes:[.insert(id:id,content:content,after:note.pages[0].id)])
        transaction.importedFonts=[font]
        _ = try await store.commit(transaction)
        let reopened=try await NotebookStore.open(root:root)
        let saved=try await reopened.openPage(id:id);XCTAssertEqual(saved.content,content)
        let fonts=await reopened.fontProjects().flatMap(\.versions);XCTAssertTrue(fonts.contains(font))
        var mismatched=NoteEditTransaction(snapshot:try await store.openNote(id:note.note.id),changes:[.insert(id:UUID(),content:PageContent(),after:nil)])
        mismatched.importedFonts=[FontVersion(assetHash:hash,postScriptName:name)]
        let before=try await store.snapshot()
        do { _ = try await store.commit(mismatched);XCTFail("mismatched font accepted") } catch {}
        let after=try await store.snapshot();XCTAssertEqual(before,after)
    }
}


extension NoteTransactionTests {
    func testBatchDatesAdvanceOnceAndNoopKeepsHead() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let start=Date(timeIntervalSince1970:10),later=Date(timeIntervalSince1970:20)
        let initial=try await store.createNote(title:"Batch",contents:[PageContent(),PageContent()],now:start)
        let noop=try await store.commit(NoteEditTransaction(snapshot:initial,changes:[.update(pageID:initial.pages[0].id,content:initial.pages[0].content,reason:.edit)]),now:later)
        XCTAssertEqual(noop.snapshot,initial)
        var content=initial.pages[0].content;content.style.ink="red"
        let edited=try await store.commit(NoteEditTransaction(snapshot:initial,changes:initial.pages.map{.update(pageID:$0.id,content:content,reason:.edit)}),now:later)
        XCTAssertEqual(edited.snapshot.note.createdAt,start);XCTAssertEqual(edited.snapshot.note.modifiedAt,later)
        let history=try await store.journal(),times=history.filter{$0.entity=="note/"+initial.note.id.uuidString+"/timestamps"}
        XCTAssertEqual(times.count,2)
        _ = try await store.recoverPrevious(pageID:initial.pages[0].id)
        let recovered=try await store.openNote(id:initial.note.id);XCTAssertEqual(recovered.note.createdAt,start);XCTAssertNotEqual(recovered.note.modifiedAt,later)
    }
}
