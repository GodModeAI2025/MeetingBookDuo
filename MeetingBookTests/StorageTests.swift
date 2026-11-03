import XCTest
import CoreData
import MeetingBookCore
@testable import MeetingBook

@MainActor final class StorageTests: XCTestCase {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testDurableUnicodeConflictAndRecovery() async throws {
        let url=root();
        var store: NotebookStore?=try await NotebookStore.open(root:url)
        let note=try await store!.createNote(title:"Äpfel €")
        let page=try await store!.openPage(id:note.pageIDs[0])
        var content=page.content;content.textBlocks=[TextBlock(text:"e\u{301} 👩🏽‍💻 日本語")]
        let receipt=try await store!.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        XCTAssertEqual(receipt.pageID,page.id)
        do { _ = try await store!.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()));XCTFail("stale accepted") } catch { XCTAssertEqual(error as? NotebookError,.revisionConflict) }
        store=nil
        let reopened=try await NotebookStore.open(root:url)
        let loaded=try await reopened.openPage(id:page.id);XCTAssertEqual(loaded.content,content);XCTAssertEqual(loaded.currentRevisionID,receipt.revision.id)
        let recovered=try await reopened.recoverPrevious(pageID:page.id);XCTAssertEqual(recovered.content,page.content)
        let outbox=try await reopened.outbox();XCTAssertEqual(outbox.count,3)
    }
    func testAssetIntegrityAndMissingReference() async throws {
        let url=root();
        let assets=try AssetStore(root:url)
        do { _ = try await assets.stage(data:Data("hi".utf8),expectedHash:String(repeating:"a",count:64));XCTFail("mismatch accepted") } catch { XCTAssertEqual(error as? NotebookError,.hashMismatch) }
        let staged=try await assets.stage(data:Data("hello".utf8));let hash=try await assets.finalize(staged)
        let data=try await assets.read(hash:hash);XCTAssertEqual(data,Data("hello".utf8))
        let file=url.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash+".blob")
        try Data("corrupt".utf8).write(to:file)
        do { _ = try await assets.read(hash:hash);XCTFail("corruption accepted") } catch { XCTAssertEqual(error as? NotebookError,.hashMismatch) }
    }
    func testDeletionOrderingTrashAndSnapshot() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"A");let first=try await store.openPage(id:note.pageIDs[0])
        do { try await store.deletePage(id:first.id,expectedRevisionID:first.currentRevisionID);XCTFail("last page deleted") } catch { XCTAssertEqual(error as? NotebookError,.lastPage) }
        let second=try await store.insertPage(noteID:note.id,after:first.id)
        try await store.deletePage(id:first.id,expectedRevisionID:first.currentRevisionID)
        let notes=try await store.listNotes();XCTAssertEqual(notes[0].pageIDs,[second.id])
        let preserved=try await store.openPage(id:first.id);XCTAssertEqual(preserved.id,first.id)
        try await store.trash(noteID:note.id);let empty=try await store.listNotes();XCTAssertTrue(empty.isEmpty)
        try await store.restore(noteID:note.id);let restored=try await store.listNotes();XCTAssertEqual(restored[0].id,note.id)
        let snapshot=try await store.snapshot();XCTAssertFalse(snapshot.isEmpty)
    }
    func testFailedMissingAssetCommitLeavesHeadAndOutboxUnchanged() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"A");let page=try await store.openPage(id:note.pageIDs[0])
        var content=page.content;content.drawingAssetHash=String(repeating:"a",count:64)
        do { _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content));XCTFail("missing asset accepted") } catch {}
        let unchanged=try await store.openPage(id:page.id);XCTAssertEqual(unchanged,page)
        let outbox=try await store.outbox();XCTAssertEqual(outbox.count,1)
    }
    func testMigrationRollbackRestoresConsistentSnapshot() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Original");let backup=try await store.migrationBackup()
        _ = try await store.createNote(title:"After backup")
        try await store.rollbackMigrationBackup(at:backup)
        let notes=try await store.listNotes();XCTAssertEqual(notes,[note])
        let reopened=try await NotebookStore.open(root:url);let durable=try await reopened.listNotes();XCTAssertEqual(durable,[note])
    }
    func testCheckpointRetentionAndPageIdentity() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"A");var page=try await store.openPage(id:note.pageIDs[0])
        let other=try await store.insertPage(noteID:note.id,after:page.id)
        for index in 0..<25 { var content=page.content;content.textBlocks=[TextBlock(text:"\(index)")];_ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content));page=try await store.openPage(id:page.id) }
        let checkpoints=try await store.checkpoints(pageID:page.id);XCTAssertEqual(checkpoints.count,20)
        let expired=try await store.checkpoints(pageID:page.id,now:Date().addingTimeInterval(31*86400));XCTAssertTrue(expired.isEmpty)
        let untouched=try await store.openPage(id:other.id);XCTAssertEqual(untouched,other)
    }

    func testBackgroundRepositoryConcurrentExpectedRevisionAndReopen() async throws {
        let url=root()
        // Construction must not require a MainActor hop; persistence owns its executor.
        let store=try await Task.detached { try await NotebookStore.open(root:url) }.value
        let note=try await store.createNote(title:"Concurrent")
        let first=try await store.openPage(id:note.pageIDs[0])
        let other=try await store.insertPage(noteID:note.id,after:first.id)
        let outcomes=await withTaskGroup(of:Bool.self,returning:[Bool].self) { group in
            for value in ["first candidate","second candidate"] {
                group.addTask {
                    var content=first.content;content.textBlocks=[TextBlock(text:value)]
                    do { _ = try await store.commit(.init(pageID:first.id,expectedRevisionID:first.currentRevisionID,content:content));return true }
                    catch NotebookError.revisionConflict { return false }
                    catch { XCTFail("Unexpected commit error: \(error)");return false }
                }
            }
            var result: [Bool] = [];for await outcome in group { result.append(outcome) };return result
        }
        XCTAssertEqual(outcomes.filter { $0 }.count,1)
        let untouched=try await store.openPage(id:other.id);XCTAssertEqual(untouched,other)
        let winner=try await store.openPage(id:first.id)
        let reopened=try await Task.detached { try await NotebookStore.open(root:url) }.value
        let durable=try await reopened.openPage(id:first.id);XCTAssertEqual(durable,winner)
    }

    private func rewriteBackup(_ url: URL, mutation: (inout [[String:Any]]) throws -> Void) throws {
        var envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        var rows=(envelope["records"] as! [[String:String]]).map { row -> [String:Any] in
            ["key":row["key"]!,"kind":row["kind"]!,"value":try! JSONSerialization.jsonObject(with:Data(base64Encoded:row["payload"]!)!)]
        }
        try mutation(&rows)
        envelope["records"]=try rows.map { row in ["key":row["key"] as! String,"kind":row["kind"] as! String,"payload":try JSONSerialization.data(withJSONObject:row["value"]!,options:[.sortedKeys,.fragmentsAllowed]).base64EncodedString()] }
        try JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys]).write(to:url)
    }
    func testDamagedRollbackGraphIsRejectedBeforeReplacingLibrary() async throws {
        let store=try await NotebookStore.open(root:root())
        let note=try await store.createNote(title:"Original");let page=try await store.openPage(id:note.pageIDs[0])
        let before=try await store.snapshot();let backup=try await store.migrationBackup()
        try rewriteBackup(backup) { rows in
            let i=rows.firstIndex { $0["kind"] as? String == "library" }!
            var value=rows[i]["value"] as! [String:Any];var notes=value["notes"] as! [[String:Any]]
            notes[0]["pageIDs"]=[page.currentRevisionID.uuidString];value["notes"]=notes;rows[i]["value"]=value
        }
        do { try await store.rollbackMigrationBackup(at:backup);XCTFail("revision ID admitted as a page") } catch {}
        let after=try await store.snapshot();XCTAssertEqual(after,before)
        let stillThere=try await store.openPage(id:page.id);XCTAssertEqual(stillThere,page)
    }
    func testExistingDatabaseMissingRootFailsWithoutWrites() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Keep records")
        // An isolated Core Data coordinator damages only the root row, leaving real pages/revisions.
        let model=NSManagedObjectModel();let entity=NSEntityDescription();entity.name="Record";entity.managedObjectClassName="NSManagedObject"
        entity.properties=[("key",NSAttributeType.stringAttributeType),("kind",.stringAttributeType),("payload",.binaryDataAttributeType)].map { name,type in let a=NSAttributeDescription();a.name=name;a.attributeType=type;a.isOptional=false;return a };entity.uniquenessConstraints=[["key"]];model.entities=[entity]
        let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        let persistent=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:url.appendingPathComponent("metadata.sqlite"))
        let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
        let request=NSFetchRequest<NSManagedObject>(entityName:"Record");request.predicate=NSPredicate(format:"key == %@","library")
        context.delete(try XCTUnwrap(context.fetch(request).first));try context.save()
        let countBefore=try context.count(for:NSFetchRequest<NSFetchRequestResult>(entityName:"Record"))
        do { _ = try await NotebookStore.open(root:url);XCTFail("missing root was bootstrapped") } catch {}
        context.reset();let countAfter=try context.count(for:NSFetchRequest<NSFetchRequestResult>(entityName:"Record"));XCTAssertEqual(countAfter,countBefore)
        XCTAssertTrue(try context.fetch(request).isEmpty)
        let pageRequest=NSFetchRequest<NSManagedObject>(entityName:"Record");pageRequest.predicate=NSPredicate(format:"key == %@",note.pageIDs[0].uuidString);XCTAssertEqual(try context.fetch(pageRequest).count,1)
        try coordinator.remove(persistent)
    }
    func testDestructiveCheckpointSurvivesOrdinaryAgeWindow() async throws {
        let store=try await NotebookStore.open(root:root());let note=try await store.createNote(title:"Recovery")
        var page=try await store.openPage(id:note.pageIDs[0]);var content=page.content;content.textBlocks=[TextBlock(text:"Protected original")]
        let original=try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:original.revision.id,content:PageContent(),reason:.clear))
        page=try await store.openPage(id:page.id);content=page.content;content.textBlocks=[TextBlock(text:"Later ordinary edit")]
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        let checkpoints=try await store.checkpoints(pageID:page.id,now:Date().addingTimeInterval(31*86400))
        XCTAssertEqual(checkpoints.map(\.id),[original.revision.id]);XCTAssertEqual(checkpoints.first?.content.textBlocks.first?.text,"Protected original")
    }
    func testGermanLocalizationIsCompiledIntoAppBundle() throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"de",withExtension:"lproj"))
        let german=try XCTUnwrap(Bundle(url:url))
        XCTAssertEqual(german.localizedString(forKey:"Create note",value:nil,table:nil),"Notiz erstellen")
    }

    func testRollbackRejectsTypedOwnershipParentsOutboxTombstoneAndFonts() async throws {
        let store=try await NotebookStore.open(root:root());let a=try await store.createNote(title:"A"),b=try await store.createNote(title:"B")
        let pageA=try await store.openPage(id:a.pageIDs[0]),pageB=try await store.openPage(id:b.pageIDs[0])
        var content=pageA.content;content.textBlocks=[TextBlock(text:"Keep this")]
        _ = try await store.commit(.init(pageID:pageA.id,expectedRevisionID:pageA.currentRevisionID,content:content))
        let current=try await store.openPage(id:pageA.id);let before=try await store.snapshot()
        for corruption in 0..<8 {
            let backup=try await store.migrationBackup()
            try rewriteBackup(backup) { rows in
                switch corruption {
                case 0,1,7:
                    let i=rows.firstIndex { $0["kind"] as? String == "library" }!;var value=rows[i]["value"] as! [String:Any]
                    if corruption == 7 { var preferences=value["preferences"] as! [String:Any];preferences["version"]=3;value["preferences"]=preferences }
                    else { var notes=value["notes"] as! [[String:Any]];notes[1]["pageIDs"]=[pageA.id.uuidString];if corruption == 1 { notes[0]["pageIDs"]=[pageB.id.uuidString] };value["notes"]=notes }
                    rows[i]["value"]=value
                case 2,3:
                    let i=rows.firstIndex { $0["key"] as? String == current.currentRevisionID.uuidString }!;var value=rows[i]["value"] as! [String:Any]
                    value["parentRevisionIDs"]=[corruption == 2 ? pageB.currentRevisionID.uuidString : UUID().uuidString];rows[i]["value"]=value
                case 4:
                    let i=rows.firstIndex { $0["kind"] as? String == "outbox" }!;var value=rows[i]["value"] as! [String:Any];value["pageID"]=pageB.id.uuidString;value["revisionID"]=current.currentRevisionID.uuidString;rows[i]["value"]=value
                case 5:
                    rows.append(["key":"deleted-page-"+UUID().uuidString,"kind":"pageTombstone","value":0.0])
                default:
                    let i=rows.firstIndex { $0["key"] as? String == current.currentRevisionID.uuidString }!;var value=rows[i]["value"] as! [String:Any]
                    var invalid=current.content;invalid.textBlocks[0].fontVersionID=UUID()
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(invalid)
                    value["content"]=try JSONSerialization.jsonObject(with:data);value["contentHash"]=AssetStore.hash(data);rows[i]["value"]=value
                }
            }
            do { try await store.rollbackMigrationBackup(at:backup);XCTFail("accepted graph corruption \(corruption)") } catch {}
            let after=try await store.snapshot();XCTAssertEqual(after,before,"replaced original for corruption \(corruption)")
        }
    }
    func testDurableAssetFileAndDirectoryFailuresPropagate() async throws {
        for failDirectory in [false,true] {
            let assets=try AssetStore(root:root(),synchronize: { url,directory in
                if directory == failDirectory { throw POSIXError(.EIO) }
                try AssetStore.synchronize(url,directory)
            })
            let staged=try await assets.stage(data:Data("barrier failure".utf8))
            do { _ = try await assets.finalize(staged);XCTFail("durability error acknowledged") } catch { XCTAssertEqual(error as? POSIXError,POSIXError(.EIO)) }
            if failDirectory {
                // A renamed, readable file is still not a confirmed durable reference.
                let readable=try await assets.read(hash:staged.hash);XCTAssertFalse(readable.isEmpty)
                do { try await assets.ensureDurable(hash:staged.hash);XCTFail("directory error bypassed at commit boundary") } catch { XCTAssertEqual(error as? POSIXError,POSIXError(.EIO)) }
            }
        }
        XCTAssertThrowsError(try AssetStore.synchronize(root(),false))
    }

    func testConcurrentFontVersionCollisionAllowsOneSaveAndReopens() async throws {
        let url=root();let store=try await NotebookStore.open(root:url)
        let staged=try await store.assets.stage(data:Data("font metadata concurrency fixture".utf8))
        let hash=try await store.assets.finalize(staged)
        let version=FontVersion(assetHash:hash,postScriptName:"ConcurrentFixture")
        let projects=[FontProject(name:"A",versions:[version]),FontProject(name:"B",versions:[version])]
        let outcomes=await withTaskGroup(of:Bool.self,returning:[Bool].self) { group in
            for project in projects { group.addTask {
                do { try await store.saveFontProject(project);return true }
                catch NotebookError.invalidModel { return false }
                catch { XCTFail("Unexpected font save error: \(error)");return false }
            } }
            var result: [Bool]=[];for await outcome in group { result.append(outcome) };return result
        }
        XCTAssertEqual(outcomes.filter { $0 }.count,1)
        let saved=await store.fontProjects();XCTAssertEqual(saved.count,1)
        let reopened=try await NotebookStore.open(root:url)
        let durable=await reopened.fontProjects();XCTAssertEqual(durable,saved)
    }

}


extension StorageTests {
    func testNewNotePersistsExplicitEqualAuthorDates() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Dates")
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(note)) as? [String:Any])
        XCTAssertNotNil(json["createdAt"])
        XCTAssertEqual(json["createdAt"] as? Double,json["modifiedAt"] as? Double)
        let reopened=try await NotebookStore.open(root:url),notes=try await reopened.listNotes()
        XCTAssertEqual(notes,[note])
    }
}


extension StorageTests {
    func testAuthorDatesTrackSemanticTransactionsAndNotNoopsOrFailures() async throws {
        let store=try await NotebookStore.open(root:root()),created=Date(timeIntervalSince1970:200),rolledBack=Date(timeIntervalSince1970:100)
        let note=try await store.createNote(title:"Dates",contents:[PageContent()],now:created)
        XCTAssertEqual(note.note.createdAt,created);XCTAssertEqual(note.note.modifiedAt,created)
        var page=note.pages[0]
        let unchanged=try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:page.content),now:rolledBack)
        XCTAssertEqual(unchanged.revision.id,page.currentRevisionID)
        try await store.setBookmark(pageID:page.id,value:true)
        var preferences=await store.preferences();preferences.lastPageID=page.id;try await store.savePreferences(preferences)
        let unmodified=try await store.openNote(id:note.note.id);XCTAssertEqual(unmodified.note.modifiedAt,created)
        var content=page.content;content.style.ink="red"
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content),now:rolledBack)
        let edited=try await store.openNote(id:note.note.id);XCTAssertEqual(edited.note.createdAt,created);XCTAssertEqual(edited.note.modifiedAt,rolledBack)
        do {_ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content),now:Date(timeIntervalSince1970:999));XCTFail("stale")} catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        let failed=try await store.openNote(id:note.note.id);XCTAssertEqual(failed.note,edited.note)
        page=edited.pages[0]
        let second=try await store.insertPage(noteID:note.note.id,after:page.id,now:Date(timeIntervalSince1970:300))
        let inserted=try await store.openNote(id:note.note.id);XCTAssertEqual(inserted.note.modifiedAt,Date(timeIntervalSince1970:300))
        try await store.deletePage(id:second.id,expectedRevisionID:second.currentRevisionID,now:Date(timeIntervalSince1970:400))
        try await store.deletePage(id:second.id,expectedRevisionID:second.currentRevisionID,now:Date(timeIntervalSince1970:999))
        let deleted=try await store.openNote(id:note.note.id);XCTAssertEqual(deleted.note.modifiedAt,Date(timeIntervalSince1970:400))
        _ = try await store.restoreDeletedPage(id:second.id,now:Date(timeIntervalSince1970:500))
        let restored=try await store.openNote(id:note.note.id);XCTAssertEqual(restored.note.modifiedAt,Date(timeIntervalSince1970:500))
        // Trash retention uses a current date while modification ordering is informational.
        let trashDate=Date();try await store.trash(noteID:note.note.id,now:trashDate)
        try await store.trash(noteID:note.note.id,now:Date(timeIntervalSince1970:999))
        let trashed=try await store.listNotes(includeDeleted:true);XCTAssertEqual(trashed[0].modifiedAt,trashDate)
        try await store.restore(noteID:note.note.id,now:rolledBack)
        try await store.restore(noteID:note.note.id,now:created)
        let final=try await store.openNote(id:note.note.id);XCTAssertEqual(final.note.modifiedAt,rolledBack);XCTAssertEqual(final.note.createdAt,created)
    }
}


extension StorageTests {
    func testRetentionAndMigrationPreserveExpiredNoteDates() async throws {
        let store=try await NotebookStore.open(root:root()),now=Date()
        let note=try await store.createNote(title:"Expired",now:now.addingTimeInterval(-100))
        try await store.trash(noteID:note.id,now:now)
        let before=try await store.listNotes(includeDeleted:true)
        _ = try await store.collectRetention(now:now.addingTimeInterval(31*86400))
        let expired=try await store.records("expiredNote").map{try JSONDecoder().decode(Note.self,from:$0)}
        XCTAssertEqual(expired,before)
        let capture=try await store.captureBackup(),graph=try NotebookStore.validateGraph(NotebookStore.importedRows(capture.files))
        XCTAssertEqual(graph.library.version,4)
        await store.assets.releasePin(capture.pin)
        let backup=try await store.migrationBackup();try await store.rollbackMigrationBackup(at:backup)
        let restored=try await store.records("expiredNote").map{try JSONDecoder().decode(Note.self,from:$0)};XCTAssertEqual(restored,expired)
    }
}

extension StorageTests {
    func testCanonicalEquivalentScalarEditIsNotANoopAndExactRepeatIs() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        var original=PageContent();original.textBlocks=[TextBlock(text:"\u{e9}")]
        let note=try await store.createNote(title:"Scalar",contents:[original],now:Date(timeIntervalSince1970:10))
        let page=note.pages[0];var edited=original;edited.textBlocks[0].text="e\u{301}"
        let receipt=try await store.commit(PageEditTransaction(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:edited),now:Date(timeIntervalSince1970:20))
        XCTAssertNotEqual(receipt.revision.id,page.currentRevisionID)
        let reopened=try await NotebookStore.open(root:url),saved=try await reopened.openNote(id:note.note.id)
        XCTAssertEqual(saved.pages[0].content.textBlocks[0].text.unicodeScalars.map(\.value),[101,769])
        XCTAssertEqual(saved.note.modifiedAt,Date(timeIntervalSince1970:20))
        let noop=try await reopened.commit(PageEditTransaction(pageID:page.id,expectedRevisionID:saved.pages[0].currentRevisionID,content:edited),now:Date(timeIntervalSince1970:30))
        XCTAssertEqual(noop.revision.id,saved.pages[0].currentRevisionID)
        let unchanged=try await reopened.openNote(id:note.note.id);XCTAssertEqual(unchanged.note.modifiedAt,saved.note.modifiedAt)
    }
}

extension StorageTests {
    func testTransactionRecordLookupTracksBulkMutationAndRollback() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        _ = try await store.createNote(title:"Preserved")
        let before=try await store.snapshot()
        let observations=try await store.exerciseTransactionRecordLookup()
        XCTAssertTrue(observations.allSatisfy{$0})
        let after=try await store.snapshot();XCTAssertEqual(after,before)
        let rows=try await store.rawRowsForAcceptance()
        do {try await store.rejectDuplicateReplacement(rows+[rows[0]]);XCTFail("Duplicate replacement accepted")} catch {}
        let afterDuplicate=try await store.snapshot();XCTAssertEqual(afterDuplicate,before)
        _ = try await store.createNote(title:"After rollback")
        let other=try await NotebookStore.open(root:url),notes=try await other.listNotes()
        XCTAssertEqual(notes.map(\.title),["Preserved","After rollback"])
    }
}
extension NotebookStore {
    func exerciseTransactionRecordLookup() throws -> [Bool] {
        let context=self.context,rows=try context.performAndWait{try Self.rows(context:context)}
        var observations:[Bool]=[]
        do {try transaction(journalChanges:false) {
            observations.append(try record("probe")==nil)
            try put("first",key:"probe",kind:"outbox")
            observations.append(try get("probe",as:String.self)=="first")
            let first=try encoder.encode("first"),second=try encoder.encode("second")
            try put("second",key:"probe",kind:"page")
            observations.append(try !records("outbox").contains(first) && records("page").contains(second))
            try removeRecord("probe");observations.append(try record("probe")==nil)
            observations.append(try !records("page").contains(second))
            try putRemoteBytes(first,key:"probe",kind:"outbox")
            observations.append(try record("probe")==first)
            try replaceRows(rows)
            observations.append(try record("probe")==nil && record("library") != nil)
            try putRemoteBytes(second,key:"probe",kind:"revision")
            observations.append(try record("probe")==second)
            throw NotebookError.invalidAsset
        }} catch NotebookError.invalidAsset {}
        return observations
    }
    func rejectDuplicateReplacement(_ rows:[RecordRow]) throws {try transaction(journalChanges:false){try replaceRows(rows)}}
}

extension StorageTests {
    func testCheckpointRefreshesSharedRootBeforeCaptureAndRollback() async throws {
        let url=root(),first=try await NotebookStore.open(root:url)
        _ = try await first.createNote(title:"First")
        let second=try await NotebookStore.open(root:url)
        _ = try await second.createNote(title:"Other actor")
        let backup=try await first.migrationBackup()
        let graph=try NotebookStore.validateGraph(NotebookStore.readMigrationEnvelope(at:backup))
        XCTAssertEqual(graph.library.notes.map(\.title),["First","Other actor"])
        _ = try await second.createNote(title:"Later")
        try await first.rollbackMigrationBackup(at:backup)
        let notes=try await second.listNotes();XCTAssertEqual(notes.map(\.title),["First","Other actor"])
    }
}
