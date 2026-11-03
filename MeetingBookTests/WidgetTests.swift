import XCTest
import MeetingBookCore
@testable import MeetingBook

final class WidgetRouteTests: XCTestCase {
    func testCanonicalRoutesAndRejectsSpoofedLexicalVariants() {
        let n="12345678-1234-1234-1234-123456789abc",p="abcdef12-1234-1234-1234-123456789abc"
        let valid="meetingbook://note/\(n)?page=\(p)"
        XCTAssertEqual(MeetingBookRoute.parse("meetingbook://new"),.new)
        XCTAssertEqual(MeetingBookRoute.parse(valid),.note(noteID:UUID(uuidString:n)!,pageID:UUID(uuidString:p)!))
        for value in ["meetingbook://new/","meetingbook://new?","meetingbook://new#","MEETINGBOOK://new","meetingbook://user@new","meetingbook://new:80",valid+"&page="+p,valid+"&x=1",valid+"#x",valid.replacingOccurrences(of:n,with:n.uppercased()),valid.replacingOccurrences(of:"/note/",with:"/note/%2f"),"https://new","meetingbook://note/../?page="+p,String(repeating:"x",count:40000)] {
            XCTAssertNil(MeetingBookRoute.parse(value),value)
        }
    }
}

final class WidgetSnapshotTests:XCTestCase {
    func testDefaultPrivacyAndBoundedUnicodeAndHostileSchema() throws {
        let id=UUID(),text=String(repeating:"e\u{301}🧑🏽‍💻",count:150)
        let neutral=WidgetSnapshot(last:.init(noteID:id,pageID:UUID(),preview:nil))
        let bytes=try neutral.encoded()
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("preview\""))
        let target=WidgetSnapshot.Target(noteID:id,pageID:UUID(),preview:WidgetSnapshot.boundedPreview(text))
        XCTAssertEqual(target.preview?.count,120)
        var snapshot=WidgetSnapshot(previewEnabled:true,last:target)
        XCTAssertEqual(try WidgetSnapshot.decode(snapshot.encoded()),snapshot)
        snapshot.previewEnabled=false
        XCTAssertThrowsError(try snapshot.encoded())
        snapshot.previewEnabled=true;snapshot.schemaVersion=2
        XCTAssertThrowsError(try snapshot.encoded())
        XCTAssertThrowsError(try WidgetSnapshot.decode(Data(repeating:32,count:32769)))
        XCTAssertThrowsError(try WidgetSnapshot.decode(Data("{}".utf8)))
    }
    func testMissingCorruptOversizeReadsAreNeutral() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        XCTAssertNil(WidgetSnapshot.read(from:nil).last)
        XCTAssertNil(WidgetSnapshot.read(from:dir).last)
        try Data(repeating:65,count:32769).write(to:dir.appendingPathComponent(WidgetSnapshot.filename))
        XCTAssertNil(WidgetSnapshot.read(from:dir).last)
    }
    func testPublisherRejectsOlderCaptureAndFailureKeepsWholeSnapshot() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let publisher=WidgetSnapshotPublisher(directory:dir,reload:{})
        let first=WidgetSnapshot(last:.init(noteID:UUID(),pageID:UUID(),preview:nil))
        let second=WidgetSnapshot(last:.init(noteID:UUID(),pageID:UUID(),preview:nil))
        _ = try await publisher.publish(second,revision:2)
        _ = try await publisher.publish(first,revision:1)
        XCTAssertEqual(WidgetSnapshot.read(from:dir),second)
        var invalid=first;invalid.schemaVersion=99
        do {_ = try await publisher.publish(invalid,revision:3);XCTFail()} catch {}
        XCTAssertEqual(WidgetSnapshot.read(from:dir),second)
        let missing=WidgetSnapshotPublisher(directory:nil,reload:{})
        do {_ = try await missing.publish(first,revision:1);XCTFail()} catch {}
    }
    func testAtomicReaderWriterRaceNeverObservesPartialDocument() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let publisher=WidgetSnapshotPublisher(directory:dir,reload:{})
        let a=WidgetSnapshot(last:.init(noteID:UUID(),pageID:UUID(),preview:nil)),b=WidgetSnapshot(last:.init(noteID:UUID(),pageID:UUID(),preview:nil))
        _ = try await publisher.publish(a,revision:0)
        async let reads:Void = Task.detached {
            for _ in 0..<500 {let value=WidgetSnapshot.read(from:dir);XCTAssertTrue(value==a || value==b)}
        }.value
        for i in 1...100 {_ = try await publisher.publish(i%2==0 ? a : b,revision:UInt64(i))}
        await reads
    }
}

@MainActor final class WidgetNavigationTests:XCTestCase {
    func testPendingNewSurvivesUnreadyStoreAndLeaveFailure() async throws {
        let router=WidgetRouteCoordinator()
        router.receive(.new)
        let unready=try await router.resolve(store:nil,leave:{})
        XCTAssertNil(unready)
        XCTAssertNotNil(router.pending)
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do {_ = try await router.resolve(store:store,leave:{throw NotebookError.revisionConflict});XCTFail()} catch {}
        XCTAssertNotNil(router.pending)
        let result=try await router.resolve(store:store,leave:{})
        XCTAssertEqual(result,.new)
        XCTAssertNotNil(router.pending)
        router.finish()
        XCTAssertNil(router.pending)
        let notes=try await store.listNotes()
        XCTAssertTrue(notes.isEmpty)
    }
    func testAuthoritativeMembershipRejectsForeignTrashAndFallsBackForDeletedPage() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a=try await store.createNote(title:"A",contents:[PageContent()]),b=try await store.createNote(title:"B",contents:[PageContent()])
        let foreign=try await store.resolveWidgetRoute(.note(noteID:a.note.id,pageID:b.pages[0].id))
        XCTAssertEqual(foreign,.unavailable)
        let stale=try await store.resolveWidgetRoute(.note(noteID:a.note.id,pageID:UUID()))
        XCTAssertEqual(stale,.page(a.pages[0].id))
        try await store.trash(noteID:a.note.id)
        let deleted=try await store.resolveWidgetRoute(.note(noteID:a.note.id,pageID:a.pages[0].id))
        XCTAssertEqual(deleted,.unavailable)
    }
    func testCommittedSnapshotExcludesDirtyDraftAndOmitsTextUntilConsent() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Saved text")]
        let note=try await store.createNote(title:"Never shared title",contents:[content])
        var prefs=await store.preferences();prefs.lastPageID=note.pages[0].id;try await store.savePreferences(prefs)
        try await store.setBookmark(pageID:note.pages[0].id,value:true)
        let editor=EditorSession(store:store,snapshot:note)
        var draft=content;draft.textBlocks=[TextBlock(text:"Unsaved secret")];editor.setDraft(draft,pageID:note.pages[0].id)
        let neutral=try await store.widgetSnapshot(previewEnabled:false)
        XCTAssertNil(neutral.last?.preview)
        let consented=try await store.widgetSnapshot(previewEnabled:true)
        XCTAssertEqual(consented.last?.preview,"Saved text");XCTAssertEqual(consented.bookmark?.preview,"Saved text")
        XCTAssertEqual(editor.saveState,.dirty)
    }
}


extension WidgetNavigationTests {
    func testFailedOptOutRemainsPendingAcrossModelReopenWithoutUndoingLocalSave() async throws {
        let name="WidgetTests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=LibraryModel(root:root,widgetPublisher:WidgetSnapshotPublisher(directory:nil,reload:{}),widgetDefaults:defaults)
        await model.open()
        let store=try XCTUnwrap(model.store)
        let note=try await store.createNote(title:"Still saved",contents:[PageContent()])
        await model.setWidgetPreview(true)
        await model.setWidgetPreview(false)
        XCTAssertTrue(model.widgetRevocationPending);XCTAssertTrue(model.widgetPublicationFailed)
        let saved=try await store.listNotes();XCTAssertEqual(saved.first?.id,note.note.id)
        let reopened=LibraryModel(root:root,widgetPublisher:WidgetSnapshotPublisher(directory:nil,reload:{}),widgetDefaults:defaults)
        XCTAssertFalse(reopened.widgetPreviewEnabled);XCTAssertTrue(reopened.widgetRevocationPending)
    }
    func testNewRouteReplacesSuspendedRouteAndDoesNotConsumeEitherOnReadinessFailure() async throws {
        let router=WidgetRouteCoordinator(),store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let old=MeetingBookRoute.note(noteID:UUID(),pageID:UUID());router.receive(old)
        let resolved=try await router.resolve(store:store,leave:{router.receive(.new)})
        XCTAssertNil(resolved);XCTAssertEqual(router.pending,.new)
        let new=try await router.resolve(store:store,leave:{})
        XCTAssertEqual(new,.new)
    }
}


extension WidgetSnapshotTests {
    func testSchemaRejectsUnknownPayloadAndOversizedUnicodeCluster() throws {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:WidgetSnapshot().encoded()) as? [String:Any])
        object["notebookText"]="Unexpected private payload"
        XCTAssertThrowsError(try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject:object)))
        let cluster="e"+String(repeating:"\u{301}",count:20000)
        XCTAssertLessThanOrEqual(WidgetSnapshot.boundedPreview(cluster).utf8.count,12000)
    }
}

extension WidgetNavigationTests {
    func testColdFailureThenRetryRetainsRouteAndSuppressesStartupSelection() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let obstacle=root.appendingPathComponent("incomplete-import")
        try Data("Keep this file".utf8).write(to:obstacle)
        let model=LibraryModel(root:root,widgetPublisher:WidgetSnapshotPublisher(directory:nil,reload:{}))
        let router=WidgetRouteCoordinator();router.receive(.new)
        await model.open()
        XCTAssertFalse(model.storeReady);XCTAssertNil(model.store)
        let failed=try await router.resolve(store:model.store,leave:{})
        XCTAssertNil(failed);XCTAssertEqual(router.pending,.new);XCTAssertTrue(router.hasReceivedRoute)
        XCTAssertTrue(FileManager.default.fileExists(atPath:obstacle.path))
        try FileManager.default.removeItem(at:obstacle)
        await model.retry()
        XCTAssertTrue(model.storeReady)
        let ready=try await router.resolve(store:model.store,leave:{})
        XCTAssertEqual(ready,.new);router.finish()
        let again=try await router.resolve(store:model.store,leave:{XCTFail("Already consumed route repeated")})
        XCTAssertNil(again)
    }
}

extension WidgetNavigationTests {
    func testCommittedCaptureCannotPublishAfterLaterSaveButDirtyDraftDoesNotBlockIt() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Saved",contents:[PageContent()])
        var prefs=await store.preferences();prefs.lastPageID=note.pages[0].id;try await store.savePreferences(prefs)
        let old=try await store.widgetCapture(previewEnabled:true)
        try await store.setBookmark(pageID:note.pages[0].id,value:true)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),writer=WidgetSnapshotPublisher(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),reload:{})
        do {_ = try await writer.publish(old.snapshot,revision:1,commitGuard:old.guardValue);XCTFail("Stale committed capture published")} catch {}
        let editor=EditorSession(store:store,snapshot:note)
        var draft=PageContent();draft.textBlocks=[TextBlock(text:"Private draft")];editor.setDraft(draft,pageID:note.pages[0].id)
        let current=try await store.widgetCapture(previewEnabled:true)
        let dirtyWriter=WidgetSnapshotPublisher(directory:dir,reload:{})
        _ = try await dirtyWriter.publish(current.snapshot,revision:2,commitGuard:current.guardValue)
        XCTAssertEqual(WidgetSnapshot.read(from:dir).last?.preview,"")
        XCTAssertEqual(editor.saveState,.dirty)
    }
    func testAccountArchiveNeutralizesPreviouslyConsentedSnapshot() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Local",contents:[PageContent()])
        var prefs=await store.preferences();prefs.lastPageID=note.pages[0].id;try await store.savePreferences(prefs)
        let original=try await store.widgetSnapshot(previewEnabled:true);XCTAssertNotNil(original.last)
        let scope=try await store.syncScope();_ = try await store.archiveScope(expected:scope)
        let neutral=try await store.widgetSnapshot(previewEnabled:true)
        XCTAssertNil(neutral.last);XCTAssertNil(neutral.bookmark);XCTAssertFalse(neutral.previewEnabled)
    }
}

extension WidgetSnapshotTests {
    func testCoalescingKeepsExactBytesButPublishesChangedUnicodeScalars() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),note=UUID(),page=UUID()
        let writer=WidgetSnapshotPublisher(directory:dir,reload:{})
        let first=WidgetSnapshot(previewEnabled:true,last:.init(noteID:note,pageID:page,preview:"\u{e9}"))
        _ = try await writer.publish(first,revision:1)
        var same=first;same.generation=UUID()
        _ = try await writer.publish(same,revision:2)
        XCTAssertEqual(WidgetSnapshot.read(from:dir).generation,first.generation)
        let different=WidgetSnapshot(previewEnabled:true,last:.init(noteID:note,pageID:page,preview:"e\u{301}"))
        _ = try await writer.publish(different,revision:3)
        XCTAssertEqual(WidgetSnapshot.read(from:dir).last?.preview?.unicodeScalars.map(\.value),[101,769])
        XCTAssertTrue(try dir.appendingPathComponent(WidgetSnapshot.filename).resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}

extension WidgetNavigationTests {
    func testRealDirtyCompositionAndStrokeBlockRouteThenWarmRequestOpensSavedTarget() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Draft",contents:[PageContent()]),target=try await store.createNote(title:"Target",contents:[PageContent()])
        let editor=EditorSession(store:store,snapshot:note),router=WidgetRouteCoordinator()
        var draft=editor.activeContent;draft.textBlocks=[TextBlock(text:"Keep e\u{301}")]
        editor.setDraft(draft,pageID:editor.activePageID,markedText:true)
        router.receive(.note(noteID:target.note.id,pageID:target.pages[0].id))
        do {_ = try await router.resolve(store:store,leave:{try await editor.leave()});XCTFail()} catch {}
        XCTAssertEqual(editor.activePageID,note.pages[0].id)
        XCTAssertEqual(editor.activeContent.textBlocks[0].text.unicodeScalars.map(\.value),[75,101,101,112,32,101,769])
        XCTAssertNotNil(router.pending)
        editor.setDraft(draft,pageID:editor.activePageID);editor.strokeActive=true
        do {_ = try await router.resolve(store:store,leave:{try await editor.leave()});XCTFail()} catch {}
        XCTAssertNotNil(router.pending)
        editor.strokeActive=false
        let ready=try await router.resolve(store:store,leave:{try await editor.leave()})
        XCTAssertEqual(ready,.page(target.pages[0].id));router.finish()
        let saved=try await store.openPage(id:note.pages[0].id)
        XCTAssertEqual(saved.content.textBlocks[0].text.unicodeScalars.map(\.value),[75,101,101,112,32,101,769])
        router.receive(.new)
        let warm=try await router.resolve(store:store,leave:{try await editor.leave()})
        XCTAssertEqual(warm,.new)
    }
}


extension WidgetSnapshotTests {
    func testPhysicalCompleteFileProtection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator does not expose NSFileProtection attributes; physical lock/unlock proof remains a release gate.")
        #else
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer=WidgetSnapshotPublisher(directory:dir,reload:{})
        _ = try await writer.publish(WidgetSnapshot(),revision:1)
        let attributes=try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent(WidgetSnapshot.filename).path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,.complete)
        #endif
    }
}

@MainActor final class WidgetRouteOrchestrationTests:XCTestCase {
    func testStartupNewThenLinkRetiresOnlyAutomaticChooserAndNavigatesWithoutDismissal() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Link target",contents:[PageContent()])
        let route=WidgetRouteCoordinator()
        route.presentChooser(.startup)
        XCTAssertTrue(route.chooserPresented)
        route.receive(.note(noteID:note.note.id,pageID:note.pages[0].id))
        XCTAssertFalse(route.chooserPresented,"Cold-launch link must retire startup-owned chooser without a user dismissal")
        let began=route.beginAttempt(eligible:!route.chooserPresented)
        XCTAssertTrue(began)
        if began {
            let destination=try await route.resolve(store:store,leave:{})
            XCTAssertEqual(destination,.page(note.pages[0].id));route.finish()
            XCTAssertFalse(route.endAttempt())
        }
        route.presentChooser(.user)
        route.receive(.new)
        XCTAssertTrue(route.chooserPresented,"A user-owned chooser must not be dismissed")
        XCTAssertFalse(route.beginAttempt(eligible:!route.chooserPresented))
        route.chooserPresented=false
        XCTAssertTrue(route.beginAttempt(eligible:true))
        let userDismissed=try await route.resolve(store:store,leave:{})
        XCTAssertEqual(userDismissed,.new);route.finish();XCTAssertFalse(route.endAttempt())
        let notes=try await store.listNotes();XCTAssertEqual(notes.count,1)
    }
    func testRootAndReadinessNotificationsDuringAwaitQueueOneTrailingResolutionForSameRoute() async throws {
        let old=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let replacement=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await replacement.createNote(title:"New selected store",contents:[PageContent()])
        let route=WidgetRouteCoordinator()
        route.receive(.note(noteID:note.note.id,pageID:note.pages[0].id))
        let generation=route.generation
        XCTAssertTrue(route.beginAttempt(eligible:true))
        var resume:CheckedContinuation<Void,Never>?
        let oldAttempt=Task {try await route.resolve(store:old,leave:{await withCheckedContinuation {resume=$0}})}
        while resume == nil {await Task.yield()}
        // Root transition and readiness notifications are delivered before the old await returns.
        XCTAssertFalse(route.beginAttempt(eligible:false))
        XCTAssertFalse(route.beginAttempt(eligible:true))
        XCTAssertFalse(route.beginAttempt(eligible:true))
        resume!.resume()
        let obsolete=try await oldAttempt.value
        XCTAssertEqual(obsolete,.unavailable)
        // NotebookView rejects that result because its captured store is no longer selected.
        XCTAssertEqual(route.generation,generation);XCTAssertNotNil(route.pending)
        let retry=route.endAttempt()
        XCTAssertTrue(retry,"Unchanged pending route must not lose completed root/readiness notifications")
        var delivered=0
        if retry,route.beginAttempt(eligible:true) {
            let current=try await route.resolve(store:replacement,leave:{})
            XCTAssertEqual(current,.page(note.pages[0].id));delivered+=1;route.finish()
            XCTAssertFalse(route.endAttempt())
        }
        XCTAssertEqual(delivered,1)
        XCTAssertFalse(route.beginAttempt(eligible:true),"Consumed route must not run twice")
    }
}

extension WidgetRouteOrchestrationTests {
    func testLeaveFailureRetainsRequestWithoutAnUnrequestedRetryLoop() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let route=WidgetRouteCoordinator();route.receive(.new)
        XCTAssertTrue(route.beginAttempt(eligible:true))
        do {_ = try await route.resolve(store:store,leave:{throw NotebookError.revisionConflict});XCTFail()} catch {}
        XCTAssertFalse(route.endAttempt());XCTAssertEqual(route.pending,.new)
        XCTAssertTrue(route.beginAttempt(eligible:true))
        route.receive(.note(noteID:UUID(),pageID:UUID()))
        XCTAssertTrue(route.endAttempt(),"A newer request is a genuine trailing event")
        XCTAssertTrue(route.beginAttempt(eligible:true))
        route.finish();XCTAssertFalse(route.endAttempt())
    }
}
