import XCTest
import PencilKit
import MeetingBookCore
@testable import MeetingBook

@MainActor final class RetentionTests: XCTestCase {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testNewStoreUsesExplicitRetentionEnvelope() async throws {
        let store=try await NotebookStore.open(root:root())
        let snapshot=try await store.snapshot()
        let envelope=try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot) as? [String:Any])
        XCTAssertEqual(envelope["version"] as? Int,4)
    }
    func testEveryMetadataMutationHasCausalIntent() async throws {
        let store=try await NotebookStore.open(root:root())
        let note=try await store.createNote(title:"Journal")
        try await store.setBookmark(pageID:note.pageIDs[0],value:true)
        let snapshot=try await store.snapshot()
        let envelope=try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot) as? [String:Any])
        let rows=try XCTUnwrap(envelope["records"] as? [[String:String]])
        XCTAssertTrue(rows.contains{$0["kind"]=="causalOperation"})
    }
}

extension RetentionTests {
    func testExpiredPayloadBecomesHeaderAndBytesAreRemoved() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let bytes=Data("retained image".utf8),asset=try await store.assets.stage(data:bytes)
        _ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Retention",contents:[content])
        let page=note.pages[0]
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let result=try await store.collectRetention(now:Date().addingTimeInterval(32*86400))
        XCTAssertEqual(result.prunedRevisions,1)
        XCTAssertEqual(result.removedAssets,1)
        do { _ = try await store.assets.read(hash:asset.hash);XCTFail("eligible payload still exists") } catch { }
        let reopened=try await NotebookStore.open(root:url)
        let current=try await reopened.openPage(id:page.id);XCTAssertNil(current.content.drawingAssetHash)
        let data=try await reopened.snapshot(),envelope=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertTrue((envelope["records"] as? [[String:String]])!.contains{$0["kind"]=="revisionHeader" && $0["key"]==page.currentRevisionID.uuidString})
    }
    func testScopedAcknowledgementCannotConsumeNewerOrOtherAccountIntent() async throws {
        let store=try await NotebookStore.open(root:root()),other=try await NotebookStore.open(root:root())
        let note=try await store.createNote(title:"A")
        let local=try await store.syncScope()
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:local,engineID:UUID())
        let sent=try await store.pendingOperations(scope:scope)
        try await store.setBookmark(pageID:note.pageIDs[0],value:true)
        for operation in sent { try await store.acknowledge(operation,scope:scope) }
        let pending=try await store.pendingOperations(scope:scope)
        XCTAssertTrue(pending.contains{$0.entity.hasSuffix("/bookmark")})
        let old=scope
        let disabled=try await store.disableKeepingLocalData(expected:scope)
        do { try await store.acknowledge(pending[0],scope:old);XCTFail("late callback accepted") } catch { }
        do { _ = try await store.bindAccountAfterConsent(fingerprint:String(repeating:"b",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:disabled,engineID:UUID());XCTFail("A root rebound to B") } catch { }
        let b=try await other.syncScope();XCTAssertNotEqual(b.libraryID,scope.libraryID)
    }
}

extension RetentionTests {
    func testEditorHistoryAndPendingPublicationBlockCollection() async throws {
        let store=try await NotebookStore.open(root:root())
        let bytes=Data("undo bytes".utf8),asset=try await store.assets.stage(data:bytes);_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Undo",contents:[content])
        let session=EditorSession(store:store,snapshot:note)
        session.setDraft(PageContent(),pageID:note.pages[0].id);try await session.flush()
        let now=Date().addingTimeInterval(32*86400)
        let retained=try await store.collectRetention(now:now)
        XCTAssertEqual(retained.prunedRevisions,0)
        let token=session.beginAssetWrite(pageID:session.activePageID)
        let blocked=try await store.collectRetention(now:now);XCTAssertTrue(blocked.deferred)
        session.endAssetWrite(token)
    }
    func testPrunedGraphBackupRoundTripAndExportPin() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let asset=try await store.assets.stage(data:Data("export bytes".utf8));_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Export",contents:[content])
        var request:ExportRequest?=try await store.captureExport(selection:.note(note.note.id),format:.pdf)
        _ = try await store.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:PageContent()))
        let now=Date().addingTimeInterval(32*86400)
        _ = try await store.collectRetention(now:now)
        do { _ = try await store.assets.read(hash:asset.hash) } catch {XCTFail("export capture lost its bytes")}
        XCTAssertEqual(request?.pages.count,1);request=nil
        _ = try await store.collectRetention(now:now)
        let capture=try await store.captureBackup()
        let checked=try NotebookStore.validatePackageRecords(capture.files)
        XCTAssertEqual(checked.pages,1)
        await store.assets.releasePin(capture.pin)
    }
}

extension RetentionTests {
    func testRepeatedCleanupPreservesLatestDestructiveParentAfterActionPayloadPrunes() async throws {
        let store=try await NotebookStore.open(root:root())
        let note=try await store.createNote(title:"Clear")
        var page=try await store.openPage(id:note.pageIDs[0])
        let original=page.currentRevisionID
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent(),reason:.clear))
        page=try await store.openPage(id:page.id)
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let now=Date().addingTimeInterval(32*86400)
        _ = try await store.collectRetention(now:now)
        _ = try await store.collectRetention(now:now)
        let checkpoints=try await store.checkpoints(pageID:page.id,now:now)
        XCTAssertEqual(checkpoints.map(\.id),[original])
    }
    func testExpiredTrashKeepsCausalIdentityInFirstEnableBootstrap() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Trashed")
        try await store.trash(noteID:note.id)
        let result=try await store.collectRetention(now:Date().addingTimeInterval(32*86400))
        XCTAssertEqual(result.expiredPages,1)
        let reopened=try await NotebookStore.open(root:url)
        let notes=try await reopened.listNotes(includeDeleted:true);XCTAssertTrue(notes.isEmpty)
        let scope=try await reopened.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:reopened.syncScope(),engineID:UUID())
        let operations=try await reopened.pendingOperations(scope:scope)
        XCTAssertTrue(operations.contains{$0.entity=="note/"+note.id.uuidString+"/deleted"})
    }
}

extension RetentionTests {
    func testOwnedScopeRoutingUsesExistingPointerAndPreservesOldStore() async throws {
        let base=root(),service=ColdRecoveryService(baseRoot:base)
        let a=try await service.createOwnedLibrary()
        _ = try await a.store.createNote(title:"A")
        let aScope=try await a.store.syncScope()
        try await service.activateOwnedLibrary(rootID:a.rootID,expectedScope:aScope)
        let b=try await service.createOwnedLibrary()
        let bScope=try await b.store.syncScope()
        try await service.activateOwnedLibrary(rootID:b.rootID,expectedScope:bScope)
        let prepared=try await service.prepareOwnedLibrary(rootID:a.rootID)
        try await service.activateOwnedLibrary(rootID:a.rootID,expectedScope:aScope)
        let selected=try await service.selectedRoot()
        XCTAssertEqual(selected.lastPathComponent,a.rootID.uuidString.lowercased())
        let notes=try await prepared.store.listNotes();XCTAssertEqual(notes.map(\.title),["A"])
        XCTAssertNotEqual(a.store.identity,b.store.identity)
    }
    func testOldMigrationBackupPinsUntilExplicitRetirement() async throws {
        let store=try await NotebookStore.open(root:root())
        let asset=try await store.assets.stage(data:PKDrawing().dataRepresentation());_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Backup",contents:[content]),page=note.pages[0]
        let backup=try await store.migrationBackup()
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let now=Date().addingTimeInterval(32*86400)
        let first=try await store.collectRetention(now:now);XCTAssertEqual(first.prunedRevisions,1);XCTAssertEqual(first.removedAssets,0)
        try await store.rollbackMigrationBackup(at:backup)
        let restored=try await store.openPage(id:page.id);XCTAssertEqual(restored.content,content)
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:restored.currentRevisionID,content:PageContent()))
        try await store.retireMigrationBackup(at:backup)
        let final=try await store.collectRetention(now:now);XCTAssertEqual(final.removedAssets,1)
    }
    func testPendingTransportAndInboxPinExactOldPayloadUntilReleased() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Pending")
        let page=try await store.openPage(id:note.pageIDs[0])
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let now=Date().addingTimeInterval(32*86400)
        let pending=try await store.pendingOperations(scope:scope)
        let incoming=try XCTUnwrap(pending.first{$0.revisions.contains(page.currentRevisionID)})
        try await store.stageIncoming(incoming,systemFields:Data(),scope:scope)
        for operation in pending {try await store.acknowledge(operation,scope:scope)}
        let pinned=try await store.collectRetention(now:now);XCTAssertEqual(pinned.prunedRevisions,0)
        try await store.retireIncoming(incoming,scope:scope)
        let free=try await store.collectRetention(now:now);XCTAssertEqual(free.prunedRevisions,1)
    }
}

import SQLite3
extension RetentionTests {
    private func sql(_ sql: String,root: URL) throws {
        var database:OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("metadata.sqlite").path,&database)==SQLITE_OK else {throw NotebookError.invalidModel}
        defer{sqlite3_close(database)}
        guard sqlite3_exec(database,sql,nil,nil,nil)==SQLITE_OK else {throw NotebookError.invalidModel}
    }
    func testLegacyMigrationPreservesRawRevisionAndPinsOldBackup() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Legacy")
        let before=try NotebookStore.envelopeRows(await store.snapshot())
        let rootRow=try XCTUnwrap(before.first{$0.kind=="library"})
        var metadata=try JSONSerialization.jsonObject(with:rootRow.payload) as! [String:Any]
        metadata["version"]=1;metadata.removeValue(forKey:"ownership")
        metadata["notes"]=(metadata["notes"] as? [[String:Any]])?.map { note in
            var legacy=note;legacy.removeValue(forKey:"createdAt");legacy.removeValue(forKey:"modifiedAt");return legacy
        }
        // Actual predecessor a3ba881 Library1 has precisely these fields; preferences2 and
        // FontProject3 are Task6 producer formats, not retention-v2 fields.
        XCTAssertEqual(Set(metadata.keys),Set(["version","deviceID","sequence","notes","preferences","fonts"]))
        let legacyRows=before.filter{["library","page","revision","outbox","pageTombstone"].contains($0.kind)}
        XCTAssertFalse(legacyRows.contains{["revisionHeader","expiredPage","expiredNote","operationAck","incomingOperation","engineCheckpoint"].contains($0.kind)})
        let bytes=try JSONSerialization.data(withJSONObject:metadata,options:.sortedKeys)
        try sql("UPDATE ZRECORD SET ZPAYLOAD=X'"+bytes.map{String(format:"%02x",$0)}.joined()+"' WHERE ZKEY='library'; DELETE FROM ZRECORD WHERE ZKIND='causalOperation';",root:url)
        let reopened=try await NotebookStore.open(root:url)
        let after=try NotebookStore.envelopeRows(await reopened.snapshot())
        XCTAssertEqual(before.first{$0.kind=="revision"}?.payload,after.first{$0.kind=="revision"}?.payload)
        let page=try await reopened.openPage(id:note.pageIDs[0]);XCTAssertEqual(page.noteID,note.id)
        let backups=try FileManager.default.contentsOfDirectory(at:url.appendingPathComponent("recovery"),includingPropertiesForKeys:nil)
        XCTAssertTrue(backups.contains{$0.lastPathComponent.hasPrefix("schema1-")})
        let scope=try await reopened.syncScope();XCTAssertEqual(scope.version,1)
    }
    func testPruneFailureBeforeCommitAndAfterCommitNeverLosesRequiredBytes() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let asset=try await store.assets.stage(data:Data("failure bytes".utf8));_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Failure",contents:[content]),page=note.pages[0]
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let before=try await store.snapshot(),now=Date().addingTimeInterval(32*86400)
        try sql("CREATE TRIGGER fail_prune BEFORE UPDATE ON ZRECORD WHEN OLD.ZKIND='revision' BEGIN SELECT RAISE(FAIL, 'injected prune failure'); END",root:url)
        do {_ = try await store.collectRetention(now:now);XCTFail("save failure ignored")} catch {}
        let failed=try await store.snapshot();XCTAssertEqual(before,failed)
        _ = try await store.assets.read(hash:asset.hash)
        try sql("DROP TRIGGER fail_prune",root:url)
        let invalid=url.appendingPathComponent("assets/00/"+String(repeating:"0",count:64)+".blob")
        try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        do {_ = try await store.collectRetention(now:now);XCTFail("unlink boundary failure ignored")} catch {}
        let reopened=try await NotebookStore.open(root:url)
        let current=try await reopened.openPage(id:page.id);XCTAssertNil(current.content.drawingAssetHash)
        _ = try await store.assets.read(hash:asset.hash)
        try FileManager.default.removeItem(at:invalid)
        let retried=try await reopened.collectRetention(now:now);XCTAssertEqual(retried.removedAssets,1)
    }
    func testValidatorRejectsStubRecoveryEvenWhenAncestryAndHeadAreComplete() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Protected")
        let page=try await store.openPage(id:note.pageIDs[0])
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent(),reason:.clear))
        var rows=try NotebookStore.envelopeRows(await store.snapshot())
        let index=try XCTUnwrap(rows.firstIndex{$0.key==page.currentRevisionID.uuidString})
        let revision=try JSONDecoder().decode(PageRevision.self,from:rows[index].payload)
        rows[index]=NotebookStore.RecordRow(key:rows[index].key,kind:"revisionHeader",payload:try JSONEncoder().encode(RevisionHeader(revision)))
        rows.removeAll{$0.kind=="outbox"}
        XCTAssertThrowsError(try NotebookStore.validateGraph(rows))
    }
    func testSharedAssetSurvivesUntilLastReferenceAndConcurrentCommit() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let asset=try await store.assets.stage(data:Data("shared bytes".utf8));_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let first=try await store.createNote(title:"One",contents:[content]),second=try await store.createNote(title:"Two",contents:[content])
        let now=Date().addingTimeInterval(32*86400)
        _ = try await store.commit(.init(pageID:first.pages[0].id,expectedRevisionID:first.pages[0].currentRevisionID,content:PageContent()))
        let held=try await store.collectRetention(now:now);XCTAssertEqual(held.removedAssets,0)
        async let collection=store.collectRetention(now:now)
        async let edit=store.commit(PageEditTransaction(pageID:second.pages[0].id,expectedRevisionID:second.pages[0].currentRevisionID,content:PageContent()))
        _ = try await (collection,edit)
        _ = try await store.collectRetention(now:now)
        do {_ = try await store.assets.read(hash:asset.hash);XCTFail("last reference did not release asset")} catch {}
        _ = try await NotebookStore.open(root:url)
    }
}

extension RetentionTests {
    func testJournalCarriesExactBaseValueAndRejectsUnknownEntity() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Bases")
        try await store.setBookmark(pageID:note.pageIDs[0],value:true)
        let operations=try await store.journal()
        let bookmark=try XCTUnwrap(operations.last{$0.entity=="page/"+note.pageIDs[0].uuidString+"/bookmark"})
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(bookmark)) as! [String:Any]
        XCTAssertEqual(object["baseValueHash"] as? String,AssetStore.hash(try JSONEncoder().encode(false)))
        object["entity"]="unknown/entity"
        let unknown=try JSONDecoder().decode(CausalOperation.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertThrowsError(try unknown.validate())
    }
    func testRegisteredUsePinSurvivesStoreOwnerLifetime() {
        let url=root(),hash=String(repeating:"a",count:64)
        var owner:StorageProtection?=StorageProtection.forRoot(url)
        owner?.register(hash);owner=nil
        XCTAssertTrue(StorageProtection.forRoot(url).snapshot.hashes.contains(hash))
    }
    func testEditablePasteTokenExcludesCleanupAcrossMultiAssetPublication() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Paste")
        let session=EditorSession(store:store,snapshot:try await store.openNote(id:note.id))
        let token=session.beginAssetWrite(pageID:session.activePageID)
        defer{session.endAssetWrite(token)}
        var content=PageContent()
        for number in 0..<2 {
            let asset=try await store.assets.stage(data:Data("synthetic paste \(number)".utf8));_ = try await store.assets.finalize(asset)
            content.images.append(ImageElement(frame:.init(x:56+Double(number)*110,y:64,width:100,height:100),assetHash:asset.hash,altText:"Synthetic"))
            let result=try await store.collectRetention(now:Date().addingTimeInterval(32*86400));XCTAssertTrue(result.deferred)
        }
        try await session.paste(content:content,completingAssetToken:token)
        XCTAssertEqual(session.snapshot.pages.count,2)
        let saved=session.snapshot.pages[1]
        XCTAssertEqual(saved.content.images.count,2)
        for image in saved.content.images {_ = try await store.assets.read(hash:image.assetHash)}
    }
}

import PencilKit
extension RetentionTests {
    func testIncomingDownloadedBytesArePartOfDurableBackupClosure() async throws {
        let source=try await NotebookStore.open(root:root()),destination=try await NotebookStore.open(root:root())
        let fingerprint=String(repeating:"a",count:64)
        let a=try await source.bindAccountAfterConsent(fingerprint:fingerprint,container:"iCloud.de.meetingbook.app",environment:"development",expected:source.syncScope(),engineID:UUID())
        let b=try await destination.bindAccountAfterConsent(fingerprint:fingerprint,container:"iCloud.de.meetingbook.app",environment:"development",expected:destination.syncScope(),engineID:UUID())
        let bytes=PKDrawing().dataRepresentation(),asset=try await source.assets.stage(data:bytes);_ = try await source.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        _ = try await source.createNote(title:"Incoming",contents:[content])
        let sourcePending=try await source.pendingOperations(scope:a)
        let operation=try XCTUnwrap(sourcePending.first{$0.assets.contains(asset.hash)})
        try await destination.stageIncoming(operation,systemFields:Data([1,2,3]),scope:b)
        try await destination.stageIncomingAsset(bytes,hash:asset.hash,operationID:operation.id,scope:b)
        let capture=try await destination.captureBackup()
        XCTAssertTrue(capture.assetHashes.contains(asset.hash))
        await destination.assets.releasePin(capture.pin)
        let outgoing=try await source.capturePending(scope:a)
        XCTAssertFalse(outgoing.revisionPayloads.isEmpty)
        try await source.acknowledge(operation,scope:a,systemFields:Data([4,5]))
        let fields=try await source.acknowledgedSystemFields(operationID:operation.id,scope:a);XCTAssertEqual(fields,Data([4,5]))
    }
    func testJournalCoversDeletionRestoreGlyphPublicationAndPreferences() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Mutations")
        let page=try await store.insertPage(noteID:note.id,after:note.pageIDs[0])
        try await store.deletePage(id:page.id,expectedRevisionID:page.currentRevisionID)
        _ = try await store.restoreDeletedPage(id:page.id)
        try await store.trash(noteID:note.id);try await store.restore(noteID:note.id)
        var preferences=await store.preferences();preferences.textDefaults=TextDefaults(fontCatalogID:"system");try await store.savePreferences(preferences)
        let project=FontProject(name:"Glyphs");try await store.saveFontProject(project)
        let asset=try await store.assets.stage(data:PKDrawing().dataRepresentation());_ = try await store.assets.finalize(asset)
        let metrics=GlyphCaptureMetrics(baselineY:80,emSize:100,xHeight:50,capHeight:70,advanceWidth:70,leftBearing:5)
        _ = try await store.saveFontGlyph(projectID:project.id,codePoint:65,expectedHash:nil,expectedMetrics:nil,hash:asset.hash,metrics:metrics)
        let id=UUID(),name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(550,700),.init(550,0)]],advanceWidth:600)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map{($0,outline)});glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let fontAsset=try await store.assets.stage(data:TrueTypeWriter.build(glyphs:glyphs,postScriptName:name));_ = try await store.assets.finalize(fontAsset)
        let version=FontVersion(id:id,assetHash:fontAsset.hash,postScriptName:name,metrics:FontMetrics())
        try await PersonalFontService(assets:store.assets).register(version:version)
        XCTAssertTrue(store.protection.snapshot.hashes.contains(fontAsset.hash))
        _ = try await store.publishFontVersion(projectID:project.id,version:version)
        let operations=try await store.journal(),entities=Set(operations.map(\.entity))
        for entity in ["note/\(note.id)/title","note/\(note.id)/pages","note/\(note.id)/deleted","page/\(page.id)/deleted","preference/textDefaults","font/\(project.id)/glyph/65","font/\(project.id)/publications","fontVersion/\(id)"] {XCTAssertTrue(entities.contains(entity),entity)}
        let deletes=operations.filter{$0.entity=="page/\(page.id)/deleted"}
        XCTAssertEqual(deletes.count,3);XCTAssertEqual(deletes[2].bases,[deletes[1].id]);XCTAssertEqual(deletes[2].baseValueHash,deletes[1].valueHash)
    }
}

extension RetentionTests {
    func testStoreOwnedDraftAndStrokeLeaseIsAvailableToRemoteActivation() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Lease")
        let session=EditorSession(store:store,snapshot:try await store.openNote(id:note.id))
        let page=note.pageIDs[0]
        let clean=await store.isPageLeasedForRemoteActivation(page);XCTAssertFalse(clean)
        session.strokeActive=true
        let drawing=await store.isPageLeasedForRemoteActivation(page);XCTAssertTrue(drawing)
        session.strokeActive=false
        session.setDraft(PageContent(),pageID:page,markedText:true)
        let composing=await store.isPageLeasedForRemoteActivation(page);XCTAssertTrue(composing)
    }
    func testRecoveryProtectionUsesAncestryAcrossDeviceSequences() {
        let page=UUID(),a=UUID(),b=UUID(),r0=UUID(),r1=UUID(),r2=UUID(),r3=UUID()
        func header(_ id:UUID,_ parent:UUID?,_ device:UUID,_ sequence:Int64,_ reason:RevisionReason)->RevisionHeader {
            RevisionHeader(PageRevision(id:id,pageID:page,parentRevisionIDs:parent.map{[$0]} ?? [],deviceID:device,sequence:sequence,createdAt:Date(),contentHash:String(repeating:"a",count:64),content:PageContent(),reason:reason))
        }
        let headers=[header(r0,nil,a,1,.edit),header(r1,r0,a,20,.clear),header(r2,r1,a,30,.edit),header(r3,r2,b,1,.clear)]
        XCTAssertEqual(RevisionHeader.protectedRecoveryParents(headers),[r2])
        let incomparable=header(UUID(),r0,b,2,.fontApply)
        XCTAssertEqual(RevisionHeader.protectedRecoveryParents(headers+[incomparable]),[r2,r0])
    }
}

extension RetentionTests {
    func testNoteCaptureLeaseProtectsTransferToWindowBeforeSessionConstruction() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Window capture")
        var capture:(snapshot:NoteSnapshot,lease:StorageLease)?=try await store.captureNote(id:note.id)
        let page=try XCTUnwrap(capture?.snapshot.pages.first)
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let now=Date().addingTimeInterval(32*86400)
        let pinned=try await store.collectRetention(now:now);XCTAssertEqual(pinned.prunedRevisions,0)
        capture=nil
        let released=try await store.collectRetention(now:now);XCTAssertEqual(released.prunedRevisions,1)
    }
}

extension RetentionTests {
    func testFontOwnerIsSeparateFromImmutableVersionBody() async throws {
        let store=try await NotebookStore.open(root:root())
        let asset=try await store.assets.stage(data:Data("ownership fixture".utf8));_ = try await store.assets.finalize(asset)
        let version=FontVersion(assetHash:asset.hash,postScriptName:"OwnershipFixture")
        let owner=FontProject(name:"Owner",versions:[version]);try await store.saveFontProject(owner)
        var reference=FontProject(name:"Reference");reference.formatVersion=3;reference.publishedVersionIDs=[version.id];try await store.saveFontProject(reference)
        let operations=try await store.journal()
        let relation=try XCTUnwrap(operations.last{$0.entity=="fontVersion/\(version.id)/owner"})
        XCTAssertEqual(try JSONDecoder().decode(UUID.self,from:XCTUnwrap(relation.value)),owner.id)
        let immutable=try XCTUnwrap(operations.first{$0.entity=="fontVersion/\(version.id)"})
        XCTAssertEqual(try JSONDecoder().decode(FontVersion.self,from:XCTUnwrap(immutable.value)),version)
        XCTAssertEqual(operations.filter{$0.entity=="fontVersion/\(version.id)"}.count,1)
    }
    func testArchivedAccountRootIsExcludedFromCollectionUntilExplicitReactivation() async throws {
        let store=try await NotebookStore.open(root:root()),note=try await store.createNote(title:"Archive")
        let page=try await store.openPage(id:note.pageIDs[0])
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        for operation in try await store.pendingOperations(scope:scope) {try await store.acknowledge(operation,scope:scope)}
        let archived=try await store.archiveScope(expected:scope)
        let now=Date().addingTimeInterval(32*86400)
        let blocked=try await store.collectRetention(now:now);XCTAssertTrue(blocked.deferred);XCTAssertEqual(blocked.prunedRevisions,0)
        _ = try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:archived,engineID:UUID())
        let active=try await store.collectRetention(now:now);XCTAssertFalse(active.deferred);XCTAssertEqual(active.prunedRevisions,1)
    }
}

extension RetentionTests {
    private func bindRestoreTest(_ store: NotebookStore) async throws -> SyncScope {
        let scope=try await store.syncScope()
        return try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:scope,engineID:UUID())
    }
    func testSameContentReplacePreservesPendingDestinationJournal() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let scope=try await bindRestoreTest(store)
        let note=try await store.createNote(title:"Pending")
        let pending=try await store.pendingOperations(scope:scope),acked=try XCTUnwrap(pending.first)
        try await store.acknowledge(acked,scope:scope,systemFields:Data("ack".utf8))
        let capture=try await store.captureBackup(),generation=AssetStore.hash(try await store.snapshot())
        try await store.activateRestore(files:capture.files,expectedGeneration:generation,policy:.replace)
        let reopened=try await NotebookStore.open(root:url),disabled=try await reopened.syncScope()
        XCTAssertFalse(disabled.enabled);XCTAssertGreaterThan(disabled.generation,scope.generation)
        do {try await reopened.acknowledge(pending.last!,scope:scope);XCTFail("old completion accepted")} catch {}
        let active=try await bindRestoreTest(reopened),remaining=try await reopened.pendingOperations(scope:active)
        XCTAssertEqual(Set(remaining.map(\.id)),Set(pending.dropFirst().map(\.id)))
        let fields=try await reopened.acknowledgedSystemFields(operationID:acked.id,scope:active)
        XCTAssertEqual(fields,Data("ack".utf8))
        let notes=try await reopened.listNotes();XCTAssertEqual(notes.map(\.id),[note.id])
    }
    func testChangedReplacePreservesExactPriorBasesAndPayloads() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let scope=try await bindRestoreTest(store),note=try await store.createNote(title:"Changed")
        let capture=try await store.captureBackup(),page=try await store.openPage(id:note.pageIDs[0])
        let asset=try await store.assets.stage(data:Data("newer pending bytes".utf8));_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let newer=try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        let prior=try await store.journal(),entity="page/"+page.id.uuidString+"/head"
        let head=try XCTUnwrap(prior.last{$0.entity==entity}),raw=try await store.fullRevisionPayload(id:newer.revision.id)
        try await store.activateRestore(files:capture.files,expectedGeneration:AssetStore.hash(try await store.snapshot()),policy:.replace)
        let reopened=try await NotebookStore.open(root:url),after=try await reopened.journal()
        XCTAssertTrue(prior.allSatisfy{after.contains($0)})
        let restored=try XCTUnwrap(after.last{$0.entity==entity});XCTAssertEqual(restored.bases,[head.id]);XCTAssertEqual(restored.baseValueHash,head.valueHash)
        let bytes=try await reopened.fullRevisionPayload(id:newer.revision.id);XCTAssertEqual(bytes,raw)
        let current=try await reopened.openPage(id:page.id);XCTAssertEqual(current.currentRevisionID,page.currentRevisionID)
        let active=try await bindRestoreTest(reopened),pending=try await reopened.pendingOperations(scope:active)
        XCTAssertTrue(pending.contains(head));XCTAssertTrue(pending.contains(restored))
        let loaded=try await reopened.assets.read(hash:asset.hash);XCTAssertEqual(loaded,Data("newer pending bytes".utf8))
        XCTAssertEqual(active.accountFingerprint,scope.accountFingerprint)
    }
    func testMigrationRollbackPreservesNewerScopedIntent() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let scope=try await bindRestoreTest(store),note=try await store.createNote(title:"Rollback")
        let backup=try await store.migrationBackup()
        let later=try await store.createNote(title:"Later omitted note")
        let laterPage=try await store.openPage(id:later.pageIDs[0])
        let laterRaw=try await store.fullRevisionPayload(id:laterPage.currentRevisionID)
        try await store.setBookmark(pageID:note.pageIDs[0],value:true)
        let prior=try await store.journal(),entity="page/"+note.pageIDs[0].uuidString+"/bookmark",tip=try XCTUnwrap(prior.last{$0.entity==entity})
        try await store.acknowledge(tip,scope:scope,systemFields:Data("new checkpoint".utf8))
        try await store.rollbackMigrationBackup(at:backup)
        let reopened=try await NotebookStore.open(root:url),after=try await reopened.journal()
        XCTAssertTrue(prior.allSatisfy{after.contains($0)})
        let restored=try XCTUnwrap(after.last{$0.entity==entity});XCTAssertEqual(restored.bases,[tip.id]);XCTAssertEqual(restored.baseValueHash,tip.valueHash)
        let page=try await reopened.openPage(id:note.pageIDs[0]);XCTAssertFalse(page.bookmark)
        let disabled=try await reopened.syncScope();XCTAssertFalse(disabled.enabled);XCTAssertGreaterThan(disabled.generation,scope.generation)
        let active=try await bindRestoreTest(reopened),pending=try await reopened.pendingOperations(scope:active)
        XCTAssertTrue(pending.contains(restored));XCTAssertFalse(pending.contains(tip))
        let fields=try await reopened.acknowledgedSystemFields(operationID:tip.id,scope:active);XCTAssertEqual(fields,Data("new checkpoint".utf8))
        let laterBytes=try await reopened.fullRevisionPayload(id:laterPage.currentRevisionID);XCTAssertEqual(laterBytes,laterRaw)
        let notes=try await reopened.listNotes();XCTAssertEqual(notes.map(\.id),[note.id])
        let capture=try await reopened.captureBackup();_ = try NotebookStore.validatePackageRecords(capture.files)
    }
}

extension RetentionTests {
    func testReplaceQuarantinesForeignAccountWhileKeepingDestinationDependencies() async throws {
        let url=root(),store=try await NotebookStore.open(root:url),source=try await NotebookStore.open(root:root())
        let scope=try await bindRestoreTest(store),old=try await store.createNote(title:"Destination")
        let oldPage=try await store.openPage(id:old.pageIDs[0]),oldBytes=try await store.fullRevisionPayload(id:oldPage.currentRevisionID)
        let sourceLocal=try await source.syncScope()
        let sourceScope=try await source.bindAccountAfterConsent(fingerprint:String(repeating:"b",count:64),container:"iCloud.de.meetingbook.app",environment:"production",expected:sourceLocal,engineID:UUID())
        let imported=try await source.createNote(title:"Source"),sourceJournal=try await source.journal()
        try await source.checkpointEngine(Data("foreign cursor".utf8),scope:sourceScope)
        let capture=try await source.captureBackup(),oldJournal=try await store.journal()
        try await store.activateRestore(files:capture.files,expectedGeneration:AssetStore.hash(try await store.snapshot()),policy:.replace)
        let reopened=try await NotebookStore.open(root:url),actualScope=try await reopened.syncScope(),journal=try await reopened.journal()
        XCTAssertEqual(actualScope.libraryID,scope.libraryID);XCTAssertEqual(actualScope.accountFingerprint,scope.accountFingerprint);XCTAssertEqual(actualScope.environment,"development");XCTAssertFalse(actualScope.enabled)
        XCTAssertTrue(oldJournal.allSatisfy{journal.contains($0)});XCTAssertTrue(Set(sourceJournal.map(\.id)).isDisjoint(with:journal.map(\.id)))
        let cursor=try await reopened.engineCheckpoint(scope:actualScope);XCTAssertNil(cursor)
        let notes=try await reopened.listNotes();XCTAssertEqual(notes.map(\.id),[imported.id])
        let bytes=try await reopened.fullRevisionPayload(id:oldPage.currentRevisionID);XCTAssertEqual(bytes,oldBytes)
        let restoredCapture=try await reopened.captureBackup();_ = try NotebookStore.validatePackageRecords(restoredCapture.files)
    }
}

extension RetentionTests {
    func testCancelledCollectionDoesNotPruneOrUnlink() async throws {
        let store=try await NotebookStore.open(root:root())
        _ = try await store.createNote(title:"Cancellation")
        let priorProcess=try AssetStore(root:await store.root.appendingPathComponent("assets"),protection:StorageProtection())
        let staged=try await priorProcess.stage(data:Data("unreferenced cancellation fixture".utf8))
        let hash=try await priorProcess.finalize(staged),file=try await priorProcess.verifiedURL(hash:hash)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-3*86400)],ofItemAtPath:file.path)
        let before=try await store.snapshot()
        let worker=Task {try await store.collectRetention(now:Date().addingTimeInterval(32*86400))};worker.cancel()
        do {_ = try await worker.value;XCTFail("Cancelled collection completed")} catch is CancellationError {}
        let after=try await store.snapshot();XCTAssertEqual(after,before)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
}

#if DEBUG
extension NotebookStore {
    func setRetentionPlanHook(_ hook:@escaping @Sendable () throws -> Void) {retentionPlanReady=hook}
}
extension RetentionTests {
    func testLateRevisionPinPreservesExpiredNotesCurrentHeads() async throws {
        let url=root(),store=try await NotebookStore.open(root:url)
        let note=try await store.createNote(title:"Late pin",contents:[PageContent(),PageContent()])
        let original=note.pages[0]
        var changed=original.content;changed.textBlocks=[TextBlock(text:"New current head")]
        let current=try await store.commit(.init(pageID:original.id,expectedRevisionID:original.currentRevisionID,content:changed))
        try await store.trash(noteID:note.note.id)
        let lease=store.protection.retain()
        await store.setRetentionPlanHook {lease.update(hashes:[],revisions:[original.currentRevisionID])}
        let result=try await store.collectRetention(now:Date().addingTimeInterval(32*86400))
        XCTAssertFalse(result.deferred);XCTAssertEqual(result.expiredPages,0)
        let reopened=try await NotebookStore.open(root:url)
        let notes=try await reopened.listNotes(includeDeleted:true);XCTAssertEqual(notes.first?.pageIDs,note.note.pageIDs)
        for id in [original.currentRevisionID,current.revision.id,note.pages[1].currentRevisionID] {
            let bytes=try await reopened.fullRevisionPayload(id:id);XCTAssertNotNil(bytes)
        }
    }
}
#endif

#if DEBUG
extension RetentionTests {
    func testCheckpointPublicationInvalidatesPreviouslyScannedPlanEvenWhenSyncFails() async throws {
        for chunked in [false,true] {for failSync in [false,true] {
            let url=root(),store=try await NotebookStore.open(root:url)
            let bytes=PKDrawing().dataRepresentation(),asset=try await store.assets.stage(data:bytes)
            _ = try await store.assets.finalize(asset)
            var content=PageContent();content.drawingAssetHash=asset.hash
            let note=try await store.createNote(title:"Checkpoint publication",contents:[content]),page=note.pages[0]
            _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:PageContent()))
            let rows=try await store.rawRowsForAcceptance(),directory=url.appendingPathComponent("recovery")
            let checkpoint=try chunked
                ? NotebookStore.writeChunkedRecovery(rows:rows,directory:directory,libraryVersion:4,protection:store.protection)
                : NotebookStore.writeLocalRecovery(rows:rows,version:4,directory:directory,protection:store.protection)
            let staging=url.appendingPathComponent("parked-checkpoint")
            try FileManager.default.moveItem(at:checkpoint,to:staging)
            let protection=store.protection
            await store.setRetentionPlanHook {
                // The planner has finished scanning; publication and lease release both precede its final guard.
                do {
                    try NotebookStore.publishRecovery(staging:staging,destination:checkpoint,protection:protection,synchronize:{directory,isDirectory in
                        if failSync {throw POSIXError(.EIO)}
                        try AssetStore.synchronize(directory,isDirectory)
                    })
                    if failSync {XCTFail("Injected directory synchronization did not fail")}
                } catch {
                    guard failSync,(error as? POSIXError)?.code == .EIO else {throw error}
                }
            }
            let result=try await store.collectRetention(now:Date().addingTimeInterval(32*86400))
            XCTAssertTrue(result.deferred);XCTAssertEqual(result.removedAssets,0)
            let preserved=try await store.assets.read(hash:asset.hash);XCTAssertEqual(preserved,bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath:checkpoint.path))
            try await store.rollbackMigrationBackup(at:checkpoint)
            let restored=try await store.fullRevisionPayload(id:page.currentRevisionID);XCTAssertNotNil(restored)
        }}
    }
}
#endif
