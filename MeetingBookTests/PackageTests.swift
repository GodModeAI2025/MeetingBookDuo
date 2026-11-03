import XCTest
import CloudKit
import PencilKit
import ZIPFoundation
import SQLite3
import Darwin
import MeetingBookCore
@testable import MeetingBook

final class PackageTests: XCTestCase {
    func testChunkCodecPreservesRawBytesAndRejectsAmbiguity() throws {
        let rows=(0..<257).map {NotebookStore.RecordRow(key:String(format:"row-%04d",$0),kind:"revision",payload:Data("{ \"text\": \"e\u{301} / 日本語\" }".utf8))}
        let chunks=try RecordChunks.encode(rows)
        XCTAssertEqual(chunks.count,2)
        let decoded=try RecordChunks.decode(chunks)
        XCTAssertEqual(decoded.map(\.payload),rows.map(\.payload));XCTAssertEqual(decoded.map(\.key),rows.map(\.key))
        var missing=chunks;missing.removeValue(forKey:"records/000000.json");XCTAssertThrowsError(try RecordChunks.decode(missing))
        var duplicate=chunks;duplicate["records/000001.json"]=chunks["records/000000.json"];XCTAssertThrowsError(try RecordChunks.decode(duplicate))
        XCTAssertThrowsError(try RecordChunks.encode([.init(key:"x",kind:"unknown",payload:Data("{}".utf8))]))
        XCTAssertThrowsError(try RecordChunks.decode(["records/000000.json":Data("[]".utf8)]))
        XCTAssertThrowsError(try RecordChunks.encode([.init(key:"x",kind:"revision",payload:Data(repeating:32,count:16_000_001))]))
        XCTAssertThrowsError(try RecordChunks.decode(["records/000000.json":Data(repeating:32,count:24_000_001)]))
        let bad=NotebookStore.RecordRow(key:"x",kind:"revision",payload:Data("{\"a\":1,\"a\":2}".utf8))
        XCTAssertThrowsError(try RecordChunks.decode(RecordChunks.encode([bad])))
    }
    func testCanonicalChunkPaths() throws {
        XCTAssertTrue(ImportValidation.validPath("records/000000.json"))
        XCTAssertTrue(ImportValidation.validPath("records/004095.json"))
        for path in ["records/00000.json","records/004096.json","records/000000.JSON","records/../000000.json"] { XCTAssertFalse(ImportValidation.validPath(path)) }
    }
    func testValidStoredProfileAndAdversarialHeaders() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("test.notebookpkg")
        let valid=fixture(path:"library.json")
        try valid.write(to:url)
        let entries=try ImportValidation.inspectZIP(url:url)
        XCTAssertEqual(entries.map(\.path),["library.json"])
        for path in ["../evil.json","/library.json","LIBRARY.JSON","assets/../a.blob","C:\\evil","licenses/%2e.txt","licenses/é.txt"] {
            try fixture(path:path).write(to:url)
            XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url),path)
        }
        for (offset,value) in [(6,1),(8,8),(26,255),(28,1),(36,1),(46,1),(48,1),(50,8),(76,1),(78,255),(83,161)] {
            var bytes=valid;bytes[offset]=UInt8(value);try bytes.write(to:url)
            XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url),"offset \(offset)")
        }
        var suffix=valid;suffix.append(0);try suffix.write(to:url)
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url))
        try valid.dropLast().write(to:url)
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url))
    }
    // Independent, empty stored entry. Local=42 bytes, central=58 bytes, EOCD=22.
    private func fixture(path: String) -> Data {
        var b=Data()
        func u16(_ v: UInt16) { b.append(UInt8(v&255));b.append(UInt8(v>>8)) }
        func u32(_ v: UInt32) { u16(UInt16(v&65535));u16(UInt16(v>>16)) }
        let n=UInt16(path.utf8.count)
        u32(0x04034b50);u16(20);u16(0x800);u16(0);u16(0);u16(0);u32(0);u32(0);u32(0);u16(n);u16(0);b.append(contentsOf:path.utf8)
        let central=UInt32(b.count)
        u32(0x02014b50);u16(0x314);u16(20);u16(0x800);u16(0);u16(0);u16(0);u32(0);u32(0);u32(0);u16(n);u16(0);u16(0);u16(0);u16(0);u32(0x81a40000);u32(0);b.append(contentsOf:path.utf8)
        let size=UInt32(b.count)-central
        u32(0x06054b50);u16(0);u16(0);u16(1);u16(1);u32(size);u32(central);u16(0)
        return b
    }
}

@MainActor final class PackageRoundTripTests: XCTestCase {
    func testChunkedRecoveryRejectsDeclaredBoundsAndExtraFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        _ = try await store.createNote(title:"Recovery manifest")
        let rows=try await store.rawRowsForAcceptance()
        let recovery=try await store.writeChunkedRecovery(rows:rows,directory:root.appendingPathComponent("recovery"))
        let manifestURL=recovery.appendingPathComponent("manifest.json"),original=try Data(contentsOf:manifestURL)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        for (key,value) in [("rowCount",1_000_001),("rawMetadataBytes",576_000_001),("encodedMetadataBytes",768_000_001)] {
            var changed=object;changed[key]=value
            try JSONSerialization.data(withJSONObject:changed).write(to:manifestURL)
            XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:recovery),key)
        }
        for field in ["rowCount","size","sha256","path"] {
            var changed=object,chunks=try XCTUnwrap(object["chunks"] as? [[String:Any]])
            switch field {
            case "rowCount":chunks[0][field]=257
            case "size":chunks[0][field]=24_000_001
            case "sha256":chunks[0][field]="abcd"
            default:chunks[0][field]="records/000001.json"
            }
            changed["chunks"]=chunks;try JSONSerialization.data(withJSONObject:changed).write(to:manifestURL)
            XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:recovery),field)
        }
        try original.write(to:manifestURL)
        let extra=recovery.appendingPathComponent("records/extra.json");try Data().write(to:extra)
        XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:recovery))
        try FileManager.default.removeItem(at:extra)
        XCTAssertEqual(try NotebookStore.readMigrationEnvelope(at:recovery).count,rows.count)
        let alias=root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:recovery.deletingLastPathComponent())
        XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:alias.appendingPathComponent(recovery.lastPathComponent)))
    }
    func testChunkedRecoveryRejectsNativeCorruptionWithoutMutation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let note=try await store.createNote(title:"Native recovery boundary")
        let page=try await store.openPage(id:note.pageIDs[0])
        let staged=try await store.assets.stage(data:Data("invalid native drawing".utf8))
        let hash=try await store.assets.finalize(staged)
        var invalid=page.content;invalid.drawingAssetHash=hash
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:invalid))
        let rows=try await store.rawRowsForAcceptance()
        let recovery=try await store.writeChunkedRecovery(rows:rows,directory:root.appendingPathComponent("recovery"))
        let legacy=try NotebookStore.writeLocalRecovery(rows:rows,version:4,directory:root.appendingPathComponent("recovery"),protection:store.protection)
        XCTAssertEqual(legacy.pathExtension,"json")
        for checkpoint in [legacy,recovery] {
            let before=try await store.snapshot()
            do {try await store.rollbackMigrationBackup(at:checkpoint);XCTFail("Native-invalid checkpoint activated: \(checkpoint.pathExtension)")} catch {}
            let after=try await store.snapshot();XCTAssertEqual(after,before)
        }
    }
    func testGenerationMatchesLegacyBytesAndChunkedRoundTripRequiresOptIn() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        _ = try await store.createNote(title:"Slash / backslash \\ e\u{301} 日本語 👩🏽‍💻")
        let old=try await store.snapshot(),generation=try await store.snapshotGeneration()
        XCTAssertEqual(generation,AssetStore.hash(old))
        _ = try await store.createNote(title:"second")
        let changed=try await store.snapshotGeneration(),bytes=try await store.snapshot()
        XCTAssertEqual(changed,AssetStore.hash(bytes));XCTAssertNotEqual(changed,generation)
        let other=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        _ = try await other.createNote(title:"same-root generation invalidation")
        let shared=try await store.snapshotGeneration(),sharedBytes=try await store.snapshot()
        XCTAssertNotEqual(shared,changed);XCTAssertEqual(shared,AssetStore.hash(sharedBytes))
        let capture=try await store.captureBackup()
        let rows=try NotebookStore.importedRows(capture.files)
        let chunks=try RecordChunks.encode(rows)
        let large=BackupCapture(pin:capture.pin,files:chunks,assetHashes:capture.assetHashes,fonts:capture.fonts,generation:capture.generation)
        let writer=NotebookPackage(root:root.appendingPathComponent("packages"))
        let package=try await writer.create(capture:large,assets:store.assets)
        do {_ = try await writer.inspect(url:package,directory:PackageIO.directory(in:root));XCTFail("Unselected v2") } catch {}
        let inspected=try await writer.inspect(url:package,directory:PackageIO.directory(in:root),policy:.large)
        XCTAssertEqual(inspected.records,chunks)
        let recovery=try await store.writeChunkedRecovery(rows:rows,directory:root)
        let recovered=try NotebookStore.readMigrationEnvelope(at:recovery)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:recovered.map{($0.key,$0.payload)}),Dictionary(uniqueKeysWithValues:rows.map{($0.key,$0.payload)}))
        try Data("{}".utf8).write(to:recovery.appendingPathComponent("records/000000.json"))
        XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:recovery))
        try FileManager.default.removeItem(at:recovery.appendingPathComponent("records/000000.json"))
        let foreign=root.appendingPathComponent("foreign.json");try chunks["records/000000.json"]!.write(to:foreign)
        try FileManager.default.createSymbolicLink(at:recovery.appendingPathComponent("records/000000.json"),withDestinationURL:foreign)
        XCTAssertThrowsError(try NotebookStore.readMigrationEnvelope(at:recovery))
    }
    func testFullRestorePreservesHistoryAndIDsAndDisablesSync() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let note=try await source.createNote(title:"Äpfel €")
        let first=try await source.openPage(id:note.pageIDs[0])
        var content=first.content;content.textBlocks=[.init(text:"e\u{301} 👩🏽‍💻 日本語")]
        _ = try await source.commit(.init(pageID:first.id,expectedRevisionID:first.currentRevisionID,content:content))
        try await source.setBookmark(pageID:first.id,value:true)
        var preferences=await source.preferences();preferences.syncEnabled=true;try await source.savePreferences(preferences)
        let package=NotebookPackage(root:root.appendingPathComponent("transfer"))
        let url=try await package.create(store:source)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target"))
        let restore=RestoreService(store:target,root:root.appendingPathComponent("imports"))
        let preview=try await restore.inspectImport(url:url)
        try await restore.restore(preview,policy:.replace)
        let actual=try await target.openPage(id:first.id)
        XCTAssertEqual(actual.content,content)
        let history=try await target.checkpoints(pageID:first.id);XCTAssertEqual(history.count,1)
        let sync=await target.preferences().syncEnabled;XCTAssertFalse(sync)
        let bookmark=try await target.latestBookmarkedPageID();XCTAssertEqual(bookmark,first.id)
        let reopened=try await NotebookStore.open(root:root.appendingPathComponent("target"))
        let persisted=try await reopened.openPage(id:first.id);XCTAssertEqual(persisted,actual)
    }
}

@MainActor final class RecoveryFailureTests: XCTestCase {
    func testEditedDestinationRejectsPreviewWithoutChangingData() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        _ = try await store.createNote(title:"Original")
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store)
        let service=RestoreService(store:store,root:root.appendingPathComponent("imports"))
        let preview=try await service.inspectImport(url:url)
        _ = try await store.createNote(title:"After preview")
        let before=try await store.snapshot()
        do { try await service.restore(preview,policy:.replace);XCTFail("stale preview accepted") } catch { XCTAssertEqual(error as? NotebookError,.revisionConflict) }
        let after=try await store.snapshot();XCTAssertEqual(after,before)
    }
    func testPickerSwapCannotReplaceRetainedInputAndMergePreservesLiteralUUIDText() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let note=try await store.createNote(title:"Merge"),page=try await store.openPage(id:note.pageIDs[0])
        var content=page.content;content.textBlocks=[.init(text:page.id.uuidString)]
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        try await store.setBookmark(pageID:page.id,value:true)
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store)
        let service=RestoreService(store:store,root:root.appendingPathComponent("imports")),preview=try await service.inspectImport(url:url)
        try Data("changed picker bytes".utf8).write(to:url)
        try await service.restore(preview,policy:.merge)
        let notes=try await store.listNotes();XCTAssertEqual(notes.count,2);XCTAssertNotEqual(notes[1].id,note.id)
        let copy=try await store.openPage(id:notes[1].pageIDs[0]);XCTAssertNotEqual(copy.id,page.id)
        XCTAssertEqual(copy.content.textBlocks[0].text,page.id.uuidString)
        XCTAssertNotEqual(copy.content.textBlocks[0].id,content.textBlocks[0].id)
        let bookmark=try await store.latestBookmarkedPageID();XCTAssertEqual(bookmark,copy.id)
    }
    func testDuplicateEscapedJSONKeysAndNestingAndBudgetsAreRejected() throws {
        for json in ["{\"version\":1,\"version\":2}","{\"a\":1,\"\\u0061\":2}",String(repeating:"[",count:65)+"0"+String(repeating:"]",count:65)] {
            XCTAssertThrowsError(try ImportValidation.validateJSON(Data(json.utf8)))
        }
        try ImportValidation.validateJSON(Data("{\"text\":\"é 日本語\",\"items\":[1,true,null]}".utf8))
        XCTAssertThrowsError(try ImportValidation.validateJSON(Data("[1,2,3]".utf8),maximum:3))
    }
    func testPinLifetimeAndEmergencyGlyphOverlayDoesNotMutateStore() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let note=try await store.createNote(title:"Glyph untouched")
        let project=FontProject(name:"Draft");try await store.saveFontProject(project)
        let bytes=PKDrawing().dataRepresentation()
        let metrics=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:620,leftBearing:40)
        let capture=try await store.captureBackup(glyph:.init(projectID:project.id,codePoint:65,bytes:bytes,metrics:metrics))
        let noteAfter=try NotebookStore.validateGraph(NotebookStore.importedRows(capture.files)).library.notes[0];XCTAssertEqual(noteAfter,note)
        let hash=AssetStore.hash(bytes)
        XCTAssertEqual(capture.memoryAssets[hash],bytes);XCTAssertTrue(capture.unsaved)
        let projects=await store.fontProjects();XCTAssertNil(projects[0].glyphAssetHashes[65])
        let captured=try JSONDecoder().decode(FontProject.self,from:XCTUnwrap(capture.files["font-projects/"+project.id.uuidString.lowercased()+".json"]))
        XCTAssertEqual(captured.glyphMetrics[65],metrics);XCTAssertEqual(captured.glyphAssetHashes[65],hash)
        let pins=await store.assets.pinnedHashes;XCTAssertTrue(pins.contains(hash))
        await store.assets.releasePin(capture.pin)
        let released=await store.assets.pinnedHashes;XCTAssertTrue(released.isEmpty)
    }
}

@MainActor final class ColdRecoveryTests: XCTestCase {
    func testExplicitColdRecoveryPreservesFailedRootAndReopensOnlyValidatedRoot() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failed=root.appendingPathComponent("NotebookLibrary")
        try FileManager.default.createDirectory(at:failed,withIntermediateDirectories:true)
        let broken=failed.appendingPathComponent("metadata.sqlite"),original=Data("corrupt original database".utf8)
        try original.write(to:broken)
        let source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let note=try await source.createNote(title:"Recovered")
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:source)
        let cold=ColdRecoveryService(baseRoot:failed)
        let preview=try await cold.inspectImport(url:url)
        let before=try await cold.selectedRoot();XCTAssertEqual(before,failed)
        XCTAssertEqual(try Data(contentsOf:broken),original)
        try await cold.activate(preview)
        let selected=try await ColdRecoveryService(baseRoot:failed).selectedRoot();XCTAssertNotEqual(selected,failed)
        let reopened=try await NotebookStore.open(root:selected),notes=try await reopened.listNotes()
        XCTAssertEqual(notes,[note]);XCTAssertEqual(try Data(contentsOf:broken),original)
        let preferences=await reopened.preferences();XCTAssertFalse(preferences.syncEnabled)
    }
    func testBadColdImportAndDiscardNeverActivateCandidate() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failed=root.appendingPathComponent("NotebookLibrary"),cold=ColdRecoveryService(baseRoot:failed)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bad=root.appendingPathComponent("bad.notebookpkg");try Data("bad zip".utf8).write(to:bad)
        do { _ = try await cold.inspectImport(url:bad);XCTFail("bad package accepted") } catch {}
        let selected=try await cold.selectedRoot();XCTAssertEqual(selected,failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
    }
}

@MainActor final class AdversarialPackageTests: XCTestCase {
    private func makeStore() async throws -> (URL,NotebookStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        _ = try await store.createNote(title:"Adversarial fixture")
        return (root,store)
    }
    func testUnknownSchemaMissingAssetsAndForgedManifestRejectBeforeMutation() async throws {
        let (root,store)=try await makeStore(),capture=try await store.captureBackup()
        defer { Task { await store.assets.releasePin(capture.pin) } }
        for variant in 0..<5 {
            var files=capture.files
            files["licenses/personal-fonts.txt"]=Data("Fixture license".utf8)
            if variant==0 {
                var value=try JSONSerialization.jsonObject(with:files["library.json"]!) as! [String:Any];value["version"]=999
                files["library.json"]=try JSONSerialization.data(withJSONObject:value)
            }
            if variant==1 { files["assets/"+String(repeating:"a",count:64)+".blob"]=Data("wrong content-address".utf8) }
            var rows=files.keys.sorted().map{PackageManifest.File(path:$0,size:UInt64(files[$0]!.count),sha256:AssetStore.hash(files[$0]!))}
            if variant==2 { rows.removeLast() }
            if variant==3 { let first=rows.removeFirst();rows.append(.init(path:first.path,size:first.size+1,sha256:first.sha256)) }
            if variant==4 { let first=rows.removeFirst();rows.append(.init(path:first.path,size:first.size,sha256:String(repeating:"0",count:64))) }
            files["manifest.json"]=try JSONEncoder().encode(PackageManifest(version:1,profile:"zip32-stored-v1",exportedAt:Date(),appVersion:"test",unsaved:false,files:rows))
            let url=root.appendingPathComponent("bad-\(variant).notebookpkg")
            try write(files:files,url:url)
            let before=try await store.snapshot(),service=RestoreService(store:store,root:root.appendingPathComponent("imports"))
            do { _ = try await service.inspectImport(url:url);XCTFail("variant \(variant) accepted") } catch {}
            let after=try await store.snapshot();XCTAssertEqual(after,before)
        }
    }
    func testForeignBookmarksAndMissingFontReferencesAndRevisionCycleReject() async throws {
        let (_,store)=try await makeStore(),capture=try await store.captureBackup()
        defer { Task { await store.assets.releasePin(capture.pin) } }
        var files=capture.files
        var envelope=try JSONSerialization.jsonObject(with:files["library.json"]!) as! [String:Any]
        var library=envelope["library"] as! [String:Any];library["bookmarkOrder"]=[UUID().uuidString];envelope["library"]=library
        files["library.json"]=try JSONSerialization.data(withJSONObject:envelope)
        XCTAssertThrowsError(try NotebookStore.validatePackageRecords(files),"foreign bookmark")
        files=capture.files
        let path=files.keys.first{$0.hasPrefix("revisions/")}!
        let old=try JSONDecoder().decode(PageRevision.self,from:files[path]!)
        var content=old.content;content.textBlocks=[TextBlock(text:"Missing font",fontVersionID:UUID())]
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        files[path]=try encoder.encode(PageRevision(id:old.id,pageID:old.pageID,parentRevisionIDs:old.parentRevisionIDs,deviceID:old.deviceID,sequence:old.sequence,createdAt:old.createdAt,contentHash:AssetStore.hash(try encoder.encode(content)),content:content,reason:old.reason))
        XCTAssertThrowsError(try NotebookStore.validatePackageRecords(files),"missing font")
        files=capture.files
        files[path]=try encoder.encode(PageRevision(id:old.id,pageID:old.pageID,parentRevisionIDs:[old.id],deviceID:old.deviceID,sequence:old.sequence,createdAt:old.createdAt,contentHash:old.contentHash,content:old.content,reason:old.reason))
        XCTAssertThrowsError(try NotebookStore.validatePackageRecords(files),"self ancestor")
    }
    func testRetainedSourceTamperingAndReplayFail() async throws {
        let (root,store)=try await makeStore()
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store)
        let imports=root.appendingPathComponent("imports"),service=RestoreService(store:store,root:imports)
        let preview=try await service.inspectImport(url:url),before=try await store.snapshot()
        let owned=try XCTUnwrap(FileManager.default.enumerator(at:imports,includingPropertiesForKeys:nil)?.allObjects.compactMap{$0 as? URL}.first{$0.lastPathComponent=="source.notebookpkg"})
        try Data("tampered staged source".utf8).write(to:owned)
        do { try await service.restore(preview,policy:.replace);XCTFail("changed retained bytes accepted") } catch { XCTAssertEqual(error as? NotebookError,.hashMismatch) }
        do { try await service.restore(preview,policy:.replace);XCTFail("consumed preview replayed") } catch {}
        let after=try await store.snapshot();XCTAssertEqual(after,before)
    }
    func testRealDatabaseSaveFailureRollsBackAllLogicalRows() async throws {
        let (root,store)=try await makeStore()
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store)
        let service=RestoreService(store:store,root:root.appendingPathComponent("imports")),preview=try await service.inspectImport(url:url)
        let before=try await store.snapshot()
        var database:OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("store/metadata.sqlite").path,&database),SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,"CREATE TRIGGER fail_restore BEFORE INSERT ON ZRECORD BEGIN SELECT RAISE(FAIL, 'injected save failure'); END",nil,nil,nil),SQLITE_OK)
        do { try await service.restore(preview,policy:.replace);XCTFail("failed save reported success") } catch {}
        let after=try await store.snapshot();XCTAssertEqual(after,before)
        XCTAssertEqual(sqlite3_exec(database,"DROP TRIGGER fail_restore",nil,nil,nil),SQLITE_OK)
    }
    private func write(files: [String:Data],url: URL) throws {
        let archive=try Archive(url:url,accessMode:.create)
        for (path,data) in files.sorted(by:{$0.key<$1.key}) {
            try archive.addEntry(with:path,type:.file,uncompressedSize:Int64(data.count),compressionMethod:.none) { offset,count in data.subdata(in:Int(offset)..<Int(offset)+count) }
        }
    }
}

final class ZIPBoundaryTests: XCTestCase {
    func testDuplicateEntriesLimitsAndUnsupportedProfiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("fixture.notebookpkg")
        try zip(paths:["manifest.json","manifest.json"]).write(to:url)
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url))
        try zip(paths:["manifest.json","library.json"],size:1).write(to:url)
        XCTAssertEqual(try ImportValidation.inspectZIP(url:url,limits:.init(entries:2,payload:2,file:1000)).count,2)
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url,limits:.init(entries:1,payload:2,file:1000)))
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url,limits:.init(entries:2,payload:1,file:1000)))
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url,limits:.init(entries:2,payload:2,file:1)))
        let valid=zip(paths:["manifest.json"])
        for (offset,value) in [(6,8),(8,8),(28,1),(42+6,45),(42+8,1),(42+38+3,0xa1)] {
            var bytes=valid
            // This fixture's manifest filename is 13 bytes, so its CD begins at 43.
            let actual=offset>=42 ? offset+1 : offset
            bytes[actual]=UInt8(value);try bytes.write(to:url)
            XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url))
        }
        try zip(paths:(0..<20_000).map{"licenses/f\($0).txt"}).write(to:url)
        XCTAssertEqual(try ImportValidation.inspectZIP(url:url).count,20_000)
        try zip(paths:(0..<20_001).map{"licenses/f\($0).txt"}).write(to:url)
        XCTAssertThrowsError(try ImportValidation.inspectZIP(url:url))
    }
    func testExclusiveNoFollowDestinationDoesNotOverwriteSymlinkTarget() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let original=root.appendingPathComponent("original"),link=root.appendingPathComponent("link")
        try Data("intact".utf8).write(to:original);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:original)
        XCTAssertThrowsError(try PackageIO.create(link));XCTAssertEqual(try Data(contentsOf:original),Data("intact".utf8))
        XCTAssertThrowsError(try PackageIO.openRegular(link))
    }
    private func zip(paths: [String],size: Int = 0) -> Data {
        var result=Data(),central=Data()
        func append(_ value: UInt32,_ count: Int,to data: inout Data) { for i in 0..<count { data.append(UInt8((value>>UInt32(i*8))&255)) } }
        for path in paths {
            let offset=UInt32(result.count),name=Data(path.utf8),n=UInt32(name.count)
            for (value,count):(UInt32,Int) in [(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(0,2),(0,4),(UInt32(size),4),(UInt32(size),4),(n,2),(0,2)] { append(value,count,to:&result) }
            result.append(name);result.append(Data(repeating:0,count:size))
            for (value,count):(UInt32,Int) in [(0x02014b50,4),(0x314,2),(20,2),(0x800,2),(0,2),(0,2),(0,2),(0,4),(UInt32(size),4),(UInt32(size),4),(n,2),(0,2),(0,2),(0,2),(0,2),(0x81a40000,4),(offset,4)] { append(value,count,to:&central) }
            central.append(name)
        }
        let start=UInt32(result.count);result.append(central)
        for (value,count):(UInt32,Int) in [(0x06054b50,4),(0,2),(0,2),(UInt32(paths.count),2),(UInt32(paths.count),2),(UInt32(central.count),4),(start,4),(0,2)] { append(value,count,to:&result) }
        return result
    }
}

extension ColdRecoveryTests {
    func testPointerFailureBeforeAndAfterRenameKeepsRecoverableRoots() async throws {
        for afterRename in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let base=root.appendingPathComponent("NotebookLibrary"),source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
            let note=try await source.createNote(title:"Durable candidate")
            let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:source)
            let service=ColdRecoveryService(baseRoot:base,synchronize:{ url,isDirectory in
                if afterRename ? (isDirectory && url.lastPathComponent.hasSuffix("-RecoveryRoots")) : url.lastPathComponent.hasPrefix("pointer-") { throw POSIXError(.EIO) }
                try AssetStore.synchronize(url,isDirectory)
            })
            let preview=try await service.inspectImport(url:url)
            do { try await service.activate(preview);XCTFail("injected flush failure ignored") } catch {}
            let selected=try await ColdRecoveryService(baseRoot:base).selectedRoot()
            if afterRename {
                XCTAssertNotEqual(selected,base)
                let reopened=try await NotebookStore.open(root:selected),notes=try await reopened.listNotes();XCTAssertEqual(notes,[note])
            } else { XCTAssertEqual(selected,base) }
            XCTAssertFalse(FileManager.default.fileExists(atPath:base.path))
        }
    }
    func testDanglingOrUnknownPointerNeverSilentlySelectsEmptyLibrary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),base=root.appendingPathComponent("NotebookLibrary")
        let directory=root.appendingPathComponent("NotebookLibrary-RecoveryRoots")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let pointer=directory.appendingPathComponent("active-root.json")
        try FileManager.default.createSymbolicLink(at:pointer,withDestinationURL:root.appendingPathComponent("missing"))
        let service=ColdRecoveryService(baseRoot:base)
        do { _ = try await service.selectedRoot();XCTFail("dangling marker accepted") } catch {}
        try FileManager.default.removeItem(at:pointer)
        try Data("{\"version\":99,\"rootID\":\"../escape\"}".utf8).write(to:pointer)
        do { _ = try await service.selectedRoot();XCTFail("unknown marker accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.path))
    }
}

@MainActor final class FontMergeTests: XCTestCase {
    func testDivergentProjectsKeepInterleavedSharedPublicationOrderAndLaterPublish() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target")),source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let shared=try await font(assets:target.assets),first=try await font(assets:source.assets),last=try await font(assets:source.assets)
        let bytes=try await target.assets.read(hash:shared.assetHash),copy=try await source.assets.stage(data:bytes);_ = try await source.assets.finalize(copy)
        let empty=PKDrawing().dataRepresentation(),glyph=try await target.assets.stage(data:empty),glyphHash=try await target.assets.finalize(glyph)
        let path=PKStrokePath(controlPoints:[CGPoint(x:40,y:80),CGPoint(x:90,y:160)].enumerated().map { index,point in PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2) },creationDate:Date())
        let sourceBytes=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:path)]).dataRepresentation()
        let sourceGlyph=try await source.assets.stage(data:sourceBytes),sourceHash=try await source.assets.finalize(sourceGlyph)
        let projectID=UUID(),a=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:500,leftBearing:30),b=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:620,leftBearing:40)
        let existing=FontProject(id:projectID,name:"Existing source",glyphAssetHashes:[65:glyphHash],glyphMetrics:[65:a],versions:[shared])
        let incoming=FontProject(id:projectID,name:"Incoming source",glyphAssetHashes:[65:sourceHash],glyphMetrics:[65:b],versions:[first,shared,last])
        try await target.saveFontProject(existing);try await source.saveFontProject(incoming)
        var content=PageContent();content.textBlocks=[TextBlock(text:"Shared font Äß €",fontVersionID:shared.id)]
        _ = try await source.createNote(title:"Shared",contents:[content])
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:source)
        let restore=RestoreService(store:target,root:root.appendingPathComponent("imports")),preview=try await restore.inspectImport(url:url)
        try await restore.restore(preview,policy:.merge)
        let projects=await target.fontProjects();XCTAssertEqual(projects.count,2)
        let imported=try XCTUnwrap(projects.first{$0.id != projectID})
        XCTAssertEqual(projects.first{$0.id==projectID},existing)
        XCTAssertEqual(imported.glyphMetrics,[65:b]);XCTAssertEqual(imported.glyphAssetHashes,[65:sourceHash])
        XCTAssertEqual(imported.publicationIDs,[first.id,shared.id,last.id])
        XCTAssertEqual(projects.flatMap(\.versions).filter{$0.id==shared.id}.count,1)
        let next=try await font(assets:target.assets),published=try await target.publishFontVersion(projectID:imported.id,version:next)
        XCTAssertEqual(published.publicationIDs,[first.id,shared.id,last.id,next.id])
        let again=try await NotebookPackage(root:root.appendingPathComponent("again")).create(store:target)
        let fresh=try await NotebookStore.open(root:root.appendingPathComponent("fresh")),service=RestoreService(store:fresh,root:root.appendingPathComponent("again-import"))
        try await service.restore(service.inspectImport(url:again),policy:.replace)
        let final=await fresh.fontProjects();XCTAssertEqual(final.first{$0.id==imported.id},published)
        let exact=try await fresh.assets.read(hash:shared.assetHash);XCTAssertEqual(exact,bytes)
        let reopenedGlyph=try await fresh.assets.read(hash:sourceHash);XCTAssertEqual(reopenedGlyph,sourceBytes)
    }
    private func font(assets: AssetStore,id: UUID = UUID(),advance: Int = 600) async throws -> FontVersion {
        let name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(40,0),.init(40,600),.init(500,600),.init(500,0)]],advanceWidth:advance)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map{($0,outline)});glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let data=try TrueTypeWriter.build(glyphs:glyphs,postScriptName:name),staged=try await assets.stage(data:data),hash=try await assets.finalize(staged)
        return FontVersion(id:id,assetHash:hash,postScriptName:name,metrics:FontMetrics())
    }
}

extension FontMergeTests {
    func testSameImmutableFontIDDifferentBytesRejectsMergeAtomically() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target")),source=try await NotebookStore.open(root:root.appendingPathComponent("source")),id=UUID()
        let original=try await font(assets:target.assets,id:id,advance:600),changed=try await font(assets:source.assets,id:id,advance:650)
        try await target.saveFontProject(FontProject(name:"Original",versions:[original]));try await source.saveFontProject(FontProject(name:"Collision",versions:[changed]))
        let before=try await target.snapshot(),url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:source)
        let service=RestoreService(store:target,root:root.appendingPathComponent("imports")),preview=try await service.inspectImport(url:url)
        do { try await service.restore(preview,policy:.merge);XCTFail("immutable font collision accepted") } catch { XCTAssertEqual(error as? NotebookError,.invalidModel) }
        let after=try await target.snapshot();XCTAssertEqual(after,before)
    }
    func testVersionedPublicationReferencesRejectDanglingAndInconsistentOrder() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=try await NotebookStore.open(root:root)
        let first=try await font(assets:store.assets),second=try await font(assets:store.assets)
        var project=FontProject(name:"References",versions:[first,second]);project.formatVersion=3;project.publishedVersionIDs=[first.id,UUID(),second.id]
        do { try await store.saveFontProject(project);XCTFail("dangling publication accepted") } catch { XCTAssertEqual(error as? NotebookError,.invalidModel) }
        project.publishedVersionIDs=[second.id,first.id];XCTAssertThrowsError(try project.validateMetadata())
        project.publishedVersionIDs=[first.id,first.id,second.id];XCTAssertThrowsError(try project.validateMetadata())
        project.publishedVersionIDs=[first.id,second.id];try project.validateMetadata()
        let bytes=try JSONEncoder().encode(project),decoded=try JSONDecoder().decode(FontProject.self,from:bytes)
        XCTAssertEqual(decoded,project);XCTAssertEqual(decoded.formatVersion,3)
        project.formatVersion=2
        XCTAssertThrowsError(try JSONDecoder().decode(FontProject.self,from:JSONEncoder().encode(project)),"old schema must not carry meaningful references")
    }
}

extension RecoveryFailureTests {
    func testUnsavedPagePackageCapturesExactUnicodeWithoutSavingSource() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let note=try await store.createNote(title:"Emergency"),page=try await store.openPage(id:note.pageIDs[0]),before=try await store.snapshot()
        var content=page.content;content.textBlocks=[TextBlock(text:"UNSAVED e\u{301} 👩🏽‍💻 日本語")]
        let capture=try await store.captureBackup(drafts:[.init(pageID:page.id,baseRevisionID:page.currentRevisionID,generation:1,content:content)])
        XCTAssertTrue(capture.unsaved)
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(capture:capture,assets:store.assets)
        let after=try await store.snapshot();XCTAssertEqual(after,before)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target")),service=RestoreService(store:target,root:root.appendingPathComponent("imports"))
        let preview=try await service.inspectImport(url:url)
        XCTAssertTrue(preview.unsaved)
        try await service.restore(preview,policy:.replace)
        let recovered=try await target.openPage(id:page.id);XCTAssertEqual(recovered.content.textBlocks[0].text.utf8.elementsEqual(content.textBlocks[0].text.utf8),true)
        let prior=try await target.recoverPrevious(pageID:page.id);XCTAssertEqual(prior.content,page.content)
    }
    func testCancelledImportAndWriteFailurePublishNothingAndReleasePins() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let note=try await store.createNote(title:"Cancel"),page=try await store.openPage(id:note.pageIDs[0])
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store),service=RestoreService(store:store,root:root.appendingPathComponent("imports"))
        let before=try await store.snapshot()
        let task=Task { withUnsafeCurrentTask{$0?.cancel()};return try await service.inspectImport(url:url) }
        do { _ = try await task.value;XCTFail("cancelled import returned preview") } catch { XCTAssertTrue(error is CancellationError) }
        let blocked=root.appendingPathComponent("not-a-directory");try Data("blocked".utf8).write(to:blocked)
        do { _ = try await ExportService(store:store,root:blocked).export(.init(format:.pdf,pages:[page],fonts:[],unsaved:true));XCTFail("failed output published") } catch {}
        let pins=await store.assets.pinnedHashes;XCTAssertTrue(pins.isEmpty)
        let after=try await store.snapshot();XCTAssertEqual(after,before)
    }
}

extension RecoveryFailureTests {
    func testNextLaunchClearsTemporaryExportsButKeepsVerifiedSafetyPackages() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=try await NotebookStore.open(root:root)
        let note=try await store.createNote(title:"Cleanup"),page=try await store.openPage(id:note.pageIDs[0])
        let paths=try await store.prepareTransferDirectories()
        let result=try await ExportService(store:store,root:paths.temporary.appendingPathComponent("Exports")).export(.init(format:.txt,pages:[page],fonts:[],unsaved:false))
        let safety=try await NotebookPackage(root:paths.safety).create(store:store)
        _ = try await store.prepareTransferDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath:result.urls[0].path));XCTAssertTrue(FileManager.default.fileExists(atPath:safety.path))
        let retained=try await store.safetyPackages();XCTAssertEqual(retained.map(\.url),[safety])
    }
}

extension AdversarialPackageTests {
    func testTruncatedImageCannotBecomeSuccessfulBackup() async throws {
        let (root,store)=try await makeStore()
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let png=UIGraphicsImageRenderer(size:CGSize(width:4,height:4),format:format).image { renderer in UIColor.red.setFill();renderer.fill(CGRect(x:0,y:0,width:4,height:4)) }.pngData()!
        let bytes=Data(png.dropLast(12)),asset=try await store.assets.stage(data:bytes),hash=try await store.assets.finalize(asset)
        var content=PageContent();content.images=[ImageElement(frame:.init(x:56,y:200,width:100,height:100),assetHash:hash,altText:"truncated fixture")]
        _ = try await store.createNote(title:"Corrupt image",contents:[content])
        do { _ = try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store);XCTFail("truncated image published") } catch {}
    }
}

final class ZIPWriterStressTests: XCTestCase {
    func testPinnedWriterTwentyThousandStoredEntries() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("boundary.zip"),start=ProcessInfo.processInfo.systemUptime
        // Container stress, intentionally independent of the typed package graph fixture.
        do {
            let archive=try Archive(url:url,accessMode:.create)
            for index in 0..<20_000 {
                let path="assets/"+String(format:"%064x",index)+".blob"
                try archive.addEntry(with:path,type:.file,uncompressedSize:Int64(1),permissions:0o600,compressionMethod:.none,bufferSize:65_536) { _,_ in Data([42]) }
            }
        }
        let writeMS=(ProcessInfo.processInfo.systemUptime-start)*1000
        try AssetStore.synchronize(url,false)
        let entries=try ImportValidation.inspectZIP(url:url)
        XCTAssertEqual(entries.count,20_000)
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        print("TASK6_ZIP20K writerMilliseconds=\(writeMS) peakProcessResidentBytes=\(usage.ru_maxrss) bytes=\(try Data(contentsOf:url).count)")
    }
}

extension RecoveryFailureTests {
    func testPickerSymbolicLinkIsRejectedWithoutTouchingTarget() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        _ = try await store.createNote(title:"Original")
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(store:store)
        let bytes=try Data(contentsOf:url),link=root.appendingPathComponent("link.notebookpkg")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:url)
        let service=RestoreService(store:store,root:root.appendingPathComponent("imports"))
        do { _ = try await service.inspectImport(url:link);XCTFail("picker symlink accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
}

extension FontMergeTests {
    func testReplaceKeepsHiddenFontDependencyWithoutResurrectingProject() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("target")),source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let local=try await store.syncScope(),scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:local,engineID:UUID())
        let version=try await font(assets:store.assets),glyphBytes=PKDrawing().dataRepresentation(),glyph=try await store.assets.stage(data:glyphBytes)
        let glyphHash=try await store.assets.finalize(glyph),project=FontProject(name:"Omitted editable source",glyphAssetHashes:[65:glyphHash],versions:[version])
        try await store.saveFontProject(project)
        var content=PageContent();content.textBlocks=[TextBlock(text:"Retained handwriting",fontVersionID:version.id)]
        let note=try await store.createNote(title:"Omitted note",contents:[content]),page=note.pages[0]
        let raw=try await store.fullRevisionPayload(id:page.currentRevisionID),ttf=try await store.assets.read(hash:version.assetHash),prior=try await store.journal()
        _ = try await source.createNote(title:"Replacement")
        let replacement=try await source.captureBackup()
        try await store.activateRestore(files:replacement.files,expectedGeneration:AssetStore.hash(try await store.snapshot()),policy:.replace)
        let reopened=try await NotebookStore.open(root:root.appendingPathComponent("target")),projects=await reopened.fontProjects()
        XCTAssertTrue(projects.isEmpty)
        let resolved=try await reopened.fontVersion(id:version.id);XCTAssertEqual(resolved,version)
        let missingFont=try await reopened.fontVersion(id:UUID());XCTAssertNil(missingFont)
        let confirmed=try await reopened.validateAssets([content]);XCTAssertTrue(confirmed.contains(version.assetHash))
        let dependencies=try await reopened.entityDependencies("revision/"+page.currentRevisionID.uuidString)
        XCTAssertTrue(dependencies.1.contains(version.assetHash))
        let restoredRaw=try await reopened.fullRevisionPayload(id:page.currentRevisionID);XCTAssertEqual(restoredRaw,raw)
        let capture=try await reopened.captureBackup();XCTAssertEqual(capture.fonts,[version])
        let rows=try NotebookStore.envelopeRows(await reopened.snapshot()),dependency=try XCTUnwrap(rows.first{$0.kind=="retainedFontVersion"})
        let snapshotBytes=try await reopened.snapshot()
        let envelope=try JSONSerialization.jsonObject(with:snapshotBytes) as! [String:Any];XCTAssertEqual(envelope["version"] as? Int,4)
        var unknown=try JSONSerialization.jsonObject(with:dependency.payload) as! [String:Any];unknown["version"]=999
        let invalid=rows.map{$0.key==dependency.key ? NotebookStore.RecordRow(key:$0.key,kind:$0.kind,payload:try! JSONSerialization.data(withJSONObject:unknown)) : $0}
        XCTAssertThrowsError(try NotebookStore.validateGraph(invalid))
        let metadata=try JSONSerialization.jsonObject(with:dependency.payload) as! [String:Any]
        XCTAssertEqual(metadata["ownerProjectID"] as? String,project.id.uuidString);XCTAssertEqual(metadata["originLibraryID"] as? String,scope.libraryID.uuidString)
        let disabled=try await reopened.syncScope(),active=try await reopened.bindAccountAfterConsent(fingerprint:scope.accountFingerprint!,container:scope.container!,environment:scope.environment!,expected:disabled,engineID:UUID())
        let pending=try await reopened.capturePending(scope:active)
        XCTAssertEqual(pending.fontDependencies.first{$0.font.id==version.id}?.ownerProjectID,project.id);XCTAssertEqual(pending.fontDependencies.first{$0.font.id==version.id}?.font,version)
        XCTAssertEqual(pending.revisionPayloads[page.currentRevisionID],raw);XCTAssertTrue(prior.filter{$0.accountFingerprint != nil}.allSatisfy{pending.operations.contains($0)})
        let resources=try await PageRenderer.resources(for:content,store:reopened);XCTAssertTrue(resources.fontWarnings.isEmpty);XCTAssertTrue(resources.versions.contains(version))
        _ = try await reopened.collectRetention(now:Date().addingTimeInterval(32*86400))
        let retainedTTF=try await reopened.assets.read(hash:version.assetHash);XCTAssertEqual(retainedTTF,ttf)
        let retainedGlyph=try await reopened.assets.read(hash:glyphHash);XCTAssertEqual(retainedGlyph,glyphBytes)
        let export=try await reopened.captureExport(selection:.library,format:.pdf);XCTAssertTrue(export.fonts.contains(version))
        let package=try await NotebookPackage(root:root.appendingPathComponent("packages")).create(store:reopened)
        let fresh=try await NotebookStore.open(root:root.appendingPathComponent("fresh")),service=RestoreService(store:fresh,root:root.appendingPathComponent("import"))
        try await service.restore(service.inspectImport(url:package),policy:.replace)
        let freshProjects=await fresh.fontProjects();XCTAssertTrue(freshProjects.isEmpty)
        let roundTrip=try await fresh.captureBackup();XCTAssertEqual(roundTrip.fonts,[version])
        let freshRows=try NotebookStore.envelopeRows(await fresh.snapshot());XCTAssertEqual(freshRows.first{$0.kind=="retainedFontVersion"}?.payload,dependency.payload)
        let freshTTF=try await fresh.assets.read(hash:version.assetHash);XCTAssertEqual(freshTTF,ttf)
    }
    func testSameImmutableFontIDDifferentBytesRejectsReplaceAtomically() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target")),source=try await NotebookStore.open(root:root.appendingPathComponent("source")),id=UUID()
        let original=try await font(assets:target.assets,id:id,advance:600),changed=try await font(assets:source.assets,id:id,advance:650)
        try await target.saveFontProject(FontProject(name:"Original",versions:[original]));try await source.saveFontProject(FontProject(name:"Collision",versions:[changed]))
        let capture=try await source.captureBackup(),before=try await target.snapshot()
        do {try await target.activateRestore(files:capture.files,expectedGeneration:AssetStore.hash(before),policy:.replace);XCTFail("immutable collision accepted")} catch {XCTAssertEqual(error as? NotebookError,.invalidModel)}
        let after=try await target.snapshot();XCTAssertEqual(after,before)
    }
}

@MainActor final class SyncConsentIntegrationTests: XCTestCase {
    func testCloudImportPreservesPromotedScopeAndCloudDefaults() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        let local=try await source.createNote(title:"Local copy")
        let capture=try await source.captureBackup()
        defer { Task { await source.assets.releasePin(capture.pin) } }
        let destination=try await NotebookStore.open(root:root.appendingPathComponent("cloud"))
        let inspection=try await destination.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:destination.syncScope(),engineID:UUID())
        let promoted=try await destination.bindAccountAfterConsent(fingerprint:inspection.accountFingerprint!,container:inspection.container!,environment:inspection.environment!,expected:inspection,engineID:UUID())
        let token=try await destination.syncGraphToken(),generation=AssetStore.hash(try await destination.snapshot())
        try await destination.importChosenLocalLibrary(files:capture.files,expectedScope:promoted,expectedGeneration:generation,expectedGraphToken:token)
        let scope=try await destination.syncScope(),notes=try await destination.listNotes(),pending=try await destination.pendingOperations(scope:promoted)
        XCTAssertEqual(scope,promoted);XCTAssertEqual(notes.map(\.title),["Local copy"]);XCTAssertNotEqual(notes.first?.id,local.id)
        XCTAssertFalse(pending.isEmpty);XCTAssertTrue(pending.allSatisfy{$0.accountFingerprint==promoted.accountFingerprint && $0.libraryID==promoted.libraryID})
        XCTAssertFalse(pending.contains{$0.entity=="preference/textDefaults"})
    }
    func testPublicationRejectsInvalidatedEpochAtBoundary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=ColdRecoveryService(baseRoot:root.appendingPathComponent("base"))
        let candidate=try await service.createOwnedLibrary(),scope=try await candidate.store.syncScope()
        let epoch=CloudKitAccountEpoch(),token=epoch.read();epoch.invalidate()
        do {try await service.activateOwnedLibrary(rootID:candidate.rootID,expectedScope:scope,publication:{action in try epoch.withCurrent(token,action)});XCTFail("stale account published")}
        catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        let selected=try await service.selectedRoot();XCTAssertEqual(selected,root.appendingPathComponent("base"))
    }
}

extension SyncConsentIntegrationTests {
    func testLocalAdoptionPreservesContentAndRetainedRootCanBeSelectedAfterRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),base=root.appendingPathComponent("base")
        let source=try await NotebookStore.open(root:base),note=try await source.createNote(title:"Keep local")
        let before=try await source.snapshot(),scope=try await source.syncScope(),service=ColdRecoveryService(baseRoot:base)
        let owned=try await service.adoptLocalBase(source:source,expectedScope:scope,expectedGeneration:AssetStore.hash(before),publication:{try $0()})
        let actual=try await owned.store.listNotes(),after=try await source.snapshot()
        XCTAssertEqual(actual.map(\.id),[note.id]);XCTAssertEqual(before,after);XCTAssertNotEqual(source.identity,owned.store.identity)
        let reopened=ColdRecoveryService(baseRoot:base),selected=try await reopened.selectedRoot()
        let ownedRoot=await owned.store.root;XCTAssertEqual(selected.path,ownedRoot.path)
        let retained=try await reopened.prepareOwnedLibrary(rootID:owned.rootID)
        let retainedIDs=try await retained.store.listNotes().map(\.id);XCTAssertEqual(retainedIDs,[note.id])
    }
    func testAppOpenIsLocalAndLateReceiptDoesNotRefreshAnotherLibrary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=LibraryModel(root:root)
        await model.open()
        let original=try XCTUnwrap(model.store)
        XCTAssertEqual(model.syncStatus,.local)
        XCTAssertNil(model.syncService)
        let other=try await NotebookStore.open(root:root.appendingPathComponent("other"))
        _ = try await other.createNote(title:"Other")
        await model.localCommit(from:other)
        XCTAssertTrue(model.notes.isEmpty);XCTAssertEqual(model.store?.identity,original.identity)
    }
}

extension SyncConsentIntegrationTests {
    func testSourceCommitAfterCaptureBlocksFinalRootPublication() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),source=try await NotebookStore.open(root:root.appendingPathComponent("base"))
        let scope=try await source.syncScope(),generation=AssetStore.hash(try await source.snapshot())
        let gate=try await source.publicationGuard(expectedScope:scope,expectedGeneration:generation)
        let service=ColdRecoveryService(baseRoot:root.appendingPathComponent("base")),candidate=try await service.createOwnedLibrary()
        _ = try await source.createNote(title:"Late source edit")
        do {try await service.activateOwnedLibrary(rootID:candidate.rootID,expectedScope:candidate.store.syncScope(),publication:{action in try gate.perform(action)});XCTFail("source edit ignored")}
        catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
    }
    func testUndoRetirementRequiresSavedDraftAndDoesNotDiscardDirtyText() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Protected",contents:[PageContent()]),editor=EditorSession(store:store,snapshot:note)
        var content=note.pages[0].content;content.textBlocks=[TextBlock(text:"Retain me")];editor.setDraft(content,pageID:note.pages[0].id)
        XCTAssertThrowsError(try editor.retireUndoHistoryAfterConsent())
        XCTAssertEqual(editor.drafts[note.pages[0].id]?.content,content)
        try await editor.flush();XCTAssertTrue(editor.canUndo)
        try editor.retireUndoHistoryAfterConsent();XCTAssertFalse(editor.canUndo)
        let saved=try await store.openPage(id:note.pages[0].id);XCTAssertEqual(saved.content,content)
    }
}

extension SyncConsentIntegrationTests {
    /// Deterministic fixture: no account discovery, CKContainer or native engine is constructed.
    func preparedChoice() async throws -> (LibraryModel,NotebookStore,ColdRecoveryService.OwnedLibrary) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),model=LibraryModel(root:root)
        await model.open();let initial=try XCTUnwrap(model.store),service=try XCTUnwrap(model.recoveryService)
        _ = try await initial.createNote(title:"Local")
        try await model.prepareLocalForInspection(token:model.accountEpoch.read())
        let source=try XCTUnwrap(model.store)
        let configuration=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        let candidate=try await service.createCloudInspectionCandidate(configuration:configuration,fingerprint:String(repeating:"a",count:64))
        model.inspection=candidate;model.inspectionScope=try await candidate.store.syncScope();model.inspectionToken=try await candidate.store.syncGraphToken()
        return (model,source,candidate)
    }
    func testExplicitMergeAndSeparateChoiceAndMissingFontConsent() async throws {
        for merge in [false,true] {
            let (model,source,candidate)=try await preparedChoice()
            do {_ = try await model.activateCloudChoice(merge:merge,personalContentConsent:false);XCTFail("missing consent accepted")} catch {}
            XCTAssertEqual(model.store?.identity,source.identity)
            let selected=try await model.activateCloudChoice(merge:merge,personalContentConsent:true)
            XCTAssertEqual(selected.store.identity,candidate.store.identity);XCTAssertEqual(model.store?.identity,candidate.store.identity)
            let notes=try await selected.store.listNotes();XCTAssertEqual(notes.count,merge ? 1 : 0)
            let scope=try await selected.store.syncScope();XCTAssertEqual(scope,selected.scope);XCTAssertNotEqual(scope.receiveOnly,true)
            XCTAssertNil(model.syncService)
            let sourceRoot=await source.root;XCTAssertNotEqual(model.transferDirectory?.deletingLastPathComponent().path,sourceRoot.path)
        }
    }
    func testAccountChangeRetainsOriginalWindowDrafts() async throws {
        let (model,source,_)=try await preparedChoice(),notes=try await source.listNotes(),snapshot=try await source.openNote(id:notes[0].id)
        let first=EditorSession(store:source,snapshot:snapshot),second=EditorSession(store:source,snapshot:snapshot)
        model.register(first);model.register(second)
        var draft=snapshot.pages[0].content;draft.textBlocks=[TextBlock(text:"Unsaved A")];first.setDraft(draft,pageID:snapshot.pages[0].id)
        await model.accountChanged()
        XCTAssertEqual(first.drafts[snapshot.pages[0].id]?.content,draft);XCTAssertEqual(first.store.identity,source.identity)
        XCTAssertEqual(model.store?.identity,source.identity);XCTAssertNil(model.inspection)
    }
}

extension SyncConsentIntegrationTests {
    func testFailedSourceSaveKeepsPublicationGuardEligible() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),source=try await NotebookStore.open(root:root)
        let guardToken=try await source.publicationGuard(expectedScope:source.syncScope(),expectedGeneration:AssetStore.hash(source.snapshot()))
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("metadata.sqlite").path,&database),SQLITE_OK)
        defer {sqlite3_close(database)}
        XCTAssertEqual(sqlite3_exec(database,"CREATE TRIGGER fail_sync_save BEFORE INSERT ON ZRECORD BEGIN SELECT RAISE(FAIL, 'injected save failure'); END",nil,nil,nil),SQLITE_OK)
        do {_ = try await source.createNote(title:"Must roll back");XCTFail("save unexpectedly succeeded")} catch {}
        var published=false;try guardToken.perform {published=true};XCTAssertTrue(published)
    }
    func testAccountRootSwitchRetainsDirtyEditorsAndRecomputesPaths() async throws {
        let (model,source,_)=try await preparedChoice(),service=try XCTUnwrap(model.recoveryService)
        let note=try await source.listNotes()[0],snapshot=try await source.openNote(id:note.id),editor=EditorSession(store:source,snapshot:snapshot)
        model.register(editor)
        var draft=editor.activeContent;draft.textBlocks=[TextBlock(text:"Original account draft")];editor.setDraft(draft,pageID:editor.activePageID)
        let other=try await service.createOwnedLibrary(),initial=try await other.store.syncScope()
        _ = try await other.store.bindAccountAfterConsent(fingerprint:String(repeating:"b",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:initial,engineID:UUID())
        await model.selectRetainedRoot(other.rootID)
        XCTAssertEqual(model.store?.identity,other.store.identity);XCTAssertEqual(editor.store.identity,source.identity)
        XCTAssertEqual(editor.drafts[editor.activePageID]?.content,draft)
        let otherRoot=await other.store.root;XCTAssertEqual(model.transferDirectory?.path,otherRoot.appendingPathComponent("Transfers/Temporary").path)
        await model.localCommit(from:source);XCTAssertTrue(model.notes.isEmpty)
    }
    func testDisconnectKeepsInspectionScopeButRejectsLateProvider() async throws {
        let (_,_,candidate)=try await preparedChoice(),scope=try await candidate.store.syncScope()
        let native=CloudKitSyncService(store:candidate.store,scope:scope)
        await native.disconnect()
        let after=try await candidate.store.syncScope();XCTAssertEqual(after,scope)
        do {_ = try await native.prepareOutgoing();XCTFail("disconnected provider accepted")} catch {}
    }
    func testPendingProjectionShowsQuotaAndOfflineWithoutLosingLocalSave() async throws {
        let (model,_,_)=try await preparedChoice(),selected=try await model.activateCloudChoice(merge:false,personalContentConsent:true)
        model.syncService=CloudKitSyncService(store:selected.store,scope:selected.scope)
        try await selected.store.setTransportIssue("transport",issue:.init(code:.quota,retryAfter:nil),scope:selected.scope)
        try await model.refreshSyncDiagnostics();XCTAssertEqual(model.syncStatus,.quota)
        _ = try await selected.store.createNote(title:"Saved despite quota")
        try await selected.store.setTransportIssue("transport",issue:.init(code:.offline,retryAfter:Date().addingTimeInterval(60)),scope:selected.scope)
        try await model.refreshSyncDiagnostics();XCTAssertEqual(model.syncStatus,.offline)
        let saved=try await selected.store.listNotes();XCTAssertEqual(saved.map(\.title),["Saved despite quota"])
        await model.disableCloud();let scope=try await selected.store.syncScope();XCTAssertFalse(scope.enabled)
    }
}

extension SyncConsentIntegrationTests {
    func testConflictingWindowSaveBlocksChoiceAndRetainsDraft() async throws {
        let (model,source,_)=try await preparedChoice(),note=try await source.listNotes()[0],snapshot=try await source.openNote(id:note.id)
        let first=EditorSession(store:source,snapshot:snapshot),second=EditorSession(store:source,snapshot:snapshot)
        model.register(first);model.register(second)
        var a=snapshot.pages[0].content,b=a;a.textBlocks=[TextBlock(text:"Window A")];b.textBlocks=[TextBlock(text:"Window B")]
        first.setDraft(a,pageID:first.activePageID);second.setDraft(b,pageID:second.activePageID)
        do {_ = try await model.activateCloudChoice(merge:true,personalContentConsent:true);XCTFail("conflicting flush accepted")} catch {}
        XCTAssertEqual(model.store?.identity,source.identity);XCTAssertEqual(second.drafts[second.activePageID]?.content,b);XCTAssertFalse(model.restoring)
    }
    func testChangedInspectionGraphRejectsPreviouslyPresentedChoice() async throws {
        let (model,source,candidate)=try await preparedChoice(),scope=try await candidate.store.syncScope()
        _ = try await candidate.store.resumeCloudInspection(expected:scope,engineID:UUID())
        do {_ = try await model.activateCloudChoice(merge:false,personalContentConsent:true);XCTFail("stale inspected scope accepted")} catch {}
        XCTAssertEqual(model.store?.identity,source.identity);XCTAssertNil(model.syncService)
    }
    func testCloudImportSQLiteFailureRollsBackScopeContentAndJournal() async throws {
        let (_,source,candidate)=try await preparedChoice(),old=try await candidate.store.syncScope()
        let scope=try await candidate.store.bindAccountAfterConsent(fingerprint:old.accountFingerprint!,container:old.container!,environment:old.environment!,expected:old,engineID:UUID())
        let capture=try await source.captureBackup(),before=try await candidate.store.snapshot(),token=try await candidate.store.syncGraphToken(),root=await candidate.store.root
        defer {Task {await source.assets.releasePin(capture.pin)}}
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("metadata.sqlite").path,&database),SQLITE_OK);defer{sqlite3_close(database)}
        XCTAssertEqual(sqlite3_exec(database,"CREATE TRIGGER fail_cloud_import BEFORE INSERT ON ZRECORD BEGIN SELECT RAISE(FAIL, 'injected save failure'); END",nil,nil,nil),SQLITE_OK)
        do {try await candidate.store.importChosenLocalLibrary(files:capture.files,expectedScope:scope,expectedGeneration:AssetStore.hash(before),expectedGraphToken:token);XCTFail("save failure ignored")} catch {}
        let after=try await candidate.store.snapshot();XCTAssertEqual(after,before)
    }
}

extension SyncConsentIntegrationTests {
    func testOpeningAnotherWindowPreservesSharedTransportProjection() async throws {
        let (model,_,_)=try await preparedChoice(),selected=try await model.activateCloudChoice(merge:false,personalContentConsent:true)
        model.syncService=CloudKitSyncService(store:selected.store,scope:selected.scope)
        try await selected.store.setTransportIssue("transport",issue:.init(code:.quota,retryAfter:nil),scope:selected.scope)
        try await model.refreshSyncDiagnostics();XCTAssertEqual(model.syncStatus,.quota)
        await model.open()
        XCTAssertEqual(model.store?.identity,selected.store.identity);XCTAssertEqual(model.syncStatus,.quota)
    }
}

extension SyncConsentIntegrationTests {
    func testArchivedMarkedDraftDoesNotParticipateInAnotherRootsChoice() async throws {
        let (model,source,_)=try await preparedChoice(),service=try XCTUnwrap(model.recoveryService),note=try await source.listNotes()[0]
        let editor=EditorSession(store:source,snapshot:try await source.openNote(id:note.id));model.register(editor)
        var draft=editor.activeContent;draft.textBlocks=[TextBlock(text:"Unfinished original composition")]
        editor.setDraft(draft,pageID:editor.activePageID,markedText:true)
        let other=try await service.createOwnedLibrary();await model.selectRetainedRoot(other.rootID)
        let config=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        let candidate=try await service.createCloudInspectionCandidate(configuration:config,fingerprint:String(repeating:"b",count:64))
        model.inspection=candidate;model.inspectionScope=try await candidate.store.syncScope();model.inspectionToken=try await candidate.store.syncGraphToken()
        _ = try await model.activateCloudChoice(merge:false,personalContentConsent:true)
        XCTAssertEqual(editor.drafts[editor.activePageID]?.content,draft);XCTAssertEqual(editor.store.identity,source.identity)
    }
}

extension SyncConsentIntegrationTests {
    func testInterruptedPublishedSelectionReopensActualRootWithoutSending() async throws {
        let (model,source,candidate)=try await preparedChoice(),service=try XCTUnwrap(model.recoveryService),old=try await candidate.store.syncScope()
        let promoted=try await candidate.store.bindAccountAfterConsent(fingerprint:old.accountFingerprint!,container:old.container!,environment:old.environment!,expected:old,engineID:UUID())
        try await service.activateOwnedLibrary(rootID:candidate.rootID,expectedScope:promoted)
        XCTAssertEqual(model.store?.identity,source.identity)
        model.accountEpoch.invalidate()
        let recovered=try await model.recoverInterruptedSelection();XCTAssertTrue(recovered)
        XCTAssertEqual(model.store?.identity,candidate.store.identity);XCTAssertNil(model.syncService)
        let scope=try await candidate.store.syncScope();XCTAssertFalse(scope.enabled)
    }
}

@MainActor final class LaunchSyncResumeTests:XCTestCase {
    final class Probe:@unchecked Sendable {
        var discoveries=0;var connections=0;var requests=0
        var onDiscover:(@MainActor () async throws -> Void)?
        var onConnect:(@MainActor () async throws -> Void)?
        var onRequest:(@MainActor () async throws -> Void)?
    }
    func fixture(enabled:Bool=true,inspection:Bool=false,selected:Bool=true,archived:Bool=false,restored:Bool=false) async throws -> (URL,NotebookStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),service=ColdRecoveryService(baseRoot:root)
        _ = try await NotebookStore.open(root:root)
        let candidate=try await service.createCloudInspectionCandidate(configuration:.init(container:"iCloud.de.meetingbook.app",environment:"development"),fingerprint:String(repeating:"a",count:64))
        var scope=try await candidate.store.syncScope()
        if !inspection {scope=try await candidate.store.bindAccountAfterConsent(fingerprint:scope.accountFingerprint!,container:scope.container!,environment:scope.environment!,expected:scope,engineID:UUID())}
        if archived {scope=try await candidate.store.archiveScope(expected:scope)}
        else if !enabled {scope=try await candidate.store.disableKeepingLocalData(expected:scope)}
        if restored {
            let capture=try await candidate.store.captureBackup()
            try await candidate.store.activateRestore(files:capture.files,expectedGeneration:capture.generation,policy:.replace)
            await candidate.store.assets.releasePin(capture.pin);scope=try await candidate.store.syncScope()
        }
        if selected {try await service.activateOwnedLibrary(rootID:candidate.rootID,expectedScope:scope)}
        return (root,candidate.store)
    }
    func operations(_ probe:Probe,account:String=String(repeating:"a",count:64),environment:String="development",configured:Bool=true) -> LaunchSyncOperations {
        // Deterministic test dependencies only. No native account or engine is constructed.
        LaunchSyncOperations(configuration:{try CloudKitConfiguration(container:configured ? "iCloud.de.meetingbook.app" : nil,environment:environment)},discover:{_ in
            await MainActor.run {probe.discoveries+=1};try await probe.onDiscover?();return account
        },connect:{store,scope,_ in
            await MainActor.run {probe.connections+=1};try await probe.onConnect?();return CloudKitSyncService(store:store,scope:scope)
        },request:{_ in await MainActor.run {probe.requests+=1};try await probe.onRequest?()})
    }
    func testSelectedConsentedLaunchResumesOnceAfterLocalOpenAcrossWindows() async throws {
        let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe))
        await model.open();XCTAssertNotNil(model.store)
        await model.open();await model.launchResumeTask?.value
        XCTAssertEqual(probe.discoveries,1);XCTAssertEqual(probe.connections,1);XCTAssertEqual(probe.requests,1)
    }
    func testUnselectedInspectionDisabledArchivedUnconfiguredAndEnvironmentMismatchNeverConnect() async throws {
        for mode in ["unselected","inspection","disabled","archived","restored","unconfigured","environment"] {
            let (root,_)=try await fixture(enabled:mode != "disabled",inspection:mode=="inspection",selected:mode != "unselected",archived:mode=="archived",restored:mode=="restored"),probe=Probe()
            let model=LibraryModel(root:root,launchSync:operations(probe,environment:mode=="environment" ? "production" : "development",configured:mode != "unconfigured"))
            await model.open();await model.launchResumeTask?.value
            XCTAssertNotNil(model.store);XCTAssertEqual(probe.connections,0,mode);XCTAssertEqual(probe.requests,0,mode)
            XCTAssertEqual(probe.discoveries,0,mode)
        }
    }
    func testAccountMismatchAndLateEpochChangeNeverSend() async throws {
        for late in [false,true] {
            let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe,account:late ? String(repeating:"a",count:64) : String(repeating:"b",count:64)))
            if late {probe.onDiscover={model.accountEpoch.invalidate()}}
            await model.open();await model.launchResumeTask?.value
            XCTAssertEqual(probe.connections,0);XCTAssertEqual(probe.requests,0);XCTAssertNotNil(model.store);XCTAssertEqual(model.syncStatus,.accountBlocked)
        }
    }
    func testRootChangeAfterConnectionStopsBeforeRequest() async throws {
        let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe))
        probe.onConnect={
            let service=try XCTUnwrap(model.recoveryService),other=try await service.createOwnedLibrary()
            try await service.activateOwnedLibrary(rootID:other.rootID,expectedScope:other.store.syncScope())
        }
        await model.open();await model.launchResumeTask?.value
        XCTAssertEqual(probe.connections,1);XCTAssertEqual(probe.requests,0);XCTAssertNil(model.syncService)
    }
}


extension LaunchSyncResumeTests {
    func testLocalSaveWorksWhileDiscoveryIsSuspended() async throws {
        let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe))
        probe.onDiscover={
            let local=try XCTUnwrap(model.store)
            XCTAssertFalse(model.restoring)
            _ = try await local.createNote(title:"Local before connection")
            try await model.reload()
            XCTAssertEqual(model.notes.map(\.title),["Local before connection"])
        }
        await model.open();XCTAssertNotNil(model.store);await model.launchResumeTask?.value
        XCTAssertEqual(probe.requests,1);XCTAssertEqual(model.notes.map(\.title),["Local before connection"])
    }
    func testUnavailableAccountKeepsLocalWorkAndDoesNotRepeatForNewWindow() async throws {
        let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe))
        probe.onDiscover={throw CloudKitAccountDiscovery.AccountUnavailable(status:.noAccount)}
        await model.open();await model.launchResumeTask?.value;await model.open()
        XCTAssertEqual(probe.discoveries,1);XCTAssertEqual(probe.requests,0);XCTAssertEqual(model.syncStatus,.accountBlocked)
        let local=try XCTUnwrap(model.store);_ = try await local.createNote(title:"Still local")
        let notes=try await local.listNotes();XCTAssertEqual(notes.map(\.title),["Still local"])
    }
}


extension LaunchSyncResumeTests {
    func testReceivedContentRefreshesEvenWhenOutgoingRequestFails() async throws {
        let (root,initial)=try await fixture(),probe=Probe()
        let peer=try await NotebookStore.open(root:root.appendingPathComponent("Peer"))
        let note=try await peer.createNote(title:"Remote original")
        let a=try await peer.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:peer.syncScope(),engineID:UUID())
        let b=try await initial.syncScope()
        for wire in try await peer.prepareWireOutbox(scope:a) {try await initial.stageWire(wire,scope:b);try await peer.acknowledgeWire(wire,scope:a,systemFields:Data())}
        _ = try await initial.reconcileWire(scope:b)
        var dependencies=operations(probe)
        var model:LibraryModel!
        var clean:EditorSession!,dirty:EditorSession!,undo:EditorSession!
        var dirtyContent:PageContent!
        dependencies.request={_ in
            await MainActor.run {XCTAssertNotNil(model.store)}
            let local=try await MainActor.run {try XCTUnwrap(model.store)},scope=try await local.syncScope()
            let page=try await peer.openPage(id:note.pageIDs[0]);var content=page.content
            content.textBlocks=[TextBlock(text:"Received before send failed")]
            _ = try await peer.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
            _ = try await peer.createNote(title:"New remote note")
            for wire in try await peer.prepareWireOutbox(scope:a) {try await local.stageWire(wire,scope:scope)}
            _ = try await local.reconcileWire(scope:scope)
            try await local.setTransportIssue("transport",issue:.init(code:.offline,retryAfter:nil),scope:scope)
            throw CKError(.networkFailure)
        }
        model=LibraryModel(root:root,launchSync:dependencies)
        probe.onDiscover={
            let local=try XCTUnwrap(model.store)
            clean=EditorSession(store:local,snapshot:try await local.openNote(id:note.id));model.register(clean)
            let other=try await local.createNote(title:"Protected draft")
            dirty=EditorSession(store:local,snapshot:try await local.openNote(id:other.id));model.register(dirty)
            dirtyContent=dirty.activeContent;dirtyContent.textBlocks=[TextBlock(text:"Unsaved composition")]
            dirty.setDraft(dirtyContent,pageID:dirty.activePageID,markedText:true)
            let saved=try await local.createNote(title:"Saved Undo")
            undo=EditorSession(store:local,snapshot:try await local.openNote(id:saved.id));model.register(undo)
            let change=try undo.preview(pageIDs:[undo.activePageID],transform:{$0.textBlocks=[TextBlock(text:"Saved with Undo")]})
            try await undo.apply(change);XCTAssertTrue(undo.canUndo)
        }
        await model.open();await model.launchResumeTask?.value
        XCTAssertTrue(model.notes.contains{$0.title=="New remote note"})
        XCTAssertEqual(clean.activeContent.textBlocks.first?.text,"Received before send failed")
        XCTAssertEqual(dirty.activeContent,dirtyContent);XCTAssertTrue(dirty.leasedPageIDs.contains(dirty.activePageID))
        XCTAssertTrue(undo.canUndo);XCTAssertEqual(model.syncStatus,.offline);XCTAssertNotNil(model.syncMessage)
    }
}


extension PackageTests {
    func testTimestampPackageRestoreMergeAndDraftCapture() async throws {
        let source=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await source.createNote(title:"Provenance",now:Date(timeIntervalSince1970:123))
        let page=try await source.openPage(id:note.pageIDs[0]),capture=try await source.captureBackup()
        let target=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await target.activateRestore(files:capture.files,expectedGeneration:AssetStore.hash(try await target.snapshot()),policy:.replace)
        let replaced=try await target.listNotes();XCTAssertEqual(replaced,[note])
        try await target.activateRestore(files:capture.files,expectedGeneration:AssetStore.hash(try await target.snapshot()),policy:.merge)
        let merged=try await target.listNotes();XCTAssertEqual(merged.count,2)
        XCTAssertTrue(merged.allSatisfy{$0.createdAt==note.createdAt && $0.modifiedAt==note.modifiedAt})
        var content=page.content;content.style.ink="red"
        let draft=try await source.captureBackup(drafts:[.init(pageID:page.id,baseRevisionID:page.currentRevisionID,generation:1,content:content)])
        let captured=try NotebookStore.validateGraph(NotebookStore.importedRows(draft.files)).library.notes[0]
        XCTAssertEqual(captured.createdAt,note.createdAt);XCTAssertNotEqual(captured.modifiedAt,note.modifiedAt)
        let live=try await source.listNotes();XCTAssertEqual(live,[note])
        let noop=try await source.captureBackup(drafts:[.init(pageID:page.id,baseRevisionID:page.currentRevisionID,generation:2,content:page.content)])
        let unchanged=try NotebookStore.validateGraph(NotebookStore.importedRows(noop.files)).library.notes[0];XCTAssertEqual(unchanged,note)
        var future=capture.files,metadata=try JSONSerialization.jsonObject(with:future["library.json"]!) as! [String:Any]
        metadata["version"]=5;future["library.json"]=try JSONSerialization.data(withJSONObject:metadata)
        let before=try await target.snapshot()
        do {try await target.activateRestore(files:future,expectedGeneration:AssetStore.hash(before),policy:.replace);XCTFail("future accepted")} catch {XCTAssertEqual(error as? NotebookError,.unsupportedVersion)}
        let after=try await target.snapshot();XCTAssertEqual(before,after)
        await source.assets.releasePin(capture.pin);await source.assets.releasePin(draft.pin);await source.assets.releasePin(noop.pin)
    }
}


extension PackageTests {
    func testLegacyPackageKeepsUnknownDatesThroughRestoreAndFirstEdit() async throws {
        let source=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await source.createNote(title:"Legacy"),capture=try await source.captureBackup()
        var files=capture.files,envelope=try JSONSerialization.jsonObject(with:files["library.json"]!) as! [String:Any]
        var metadata=envelope["library"] as! [String:Any];metadata["version"]=3;envelope["version"]=3;envelope["library"]=metadata
        envelope["technical"]=(envelope["technical"] as! [[String:Any]]).filter{($0["kind"] as? String) != "causalOperation"}
        files["library.json"]=try JSONSerialization.data(withJSONObject:envelope)
        let path="notes/"+note.id.uuidString.lowercased()+".json"
        var json=try JSONSerialization.jsonObject(with:files[path]!) as! [String:Any]
        json.removeValue(forKey:"createdAt");json.removeValue(forKey:"modifiedAt");files[path]=try JSONSerialization.data(withJSONObject:json)
        let target=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await target.activateRestore(files:files,expectedGeneration:AssetStore.hash(try await target.snapshot()),policy:.replace)
        let restored=try await target.openNote(id:note.id);XCTAssertNil(restored.note.createdAt);XCTAssertNil(restored.note.modifiedAt)
        var content=restored.pages[0].content;content.style.ink="red"
        _ = try await target.commit(.init(pageID:restored.pages[0].id,expectedRevisionID:restored.pages[0].currentRevisionID,content:content),now:Date(timeIntervalSince1970:5))
        let edited=try await target.openNote(id:note.id);XCTAssertNil(edited.note.createdAt);XCTAssertEqual(edited.note.modifiedAt,Date(timeIntervalSince1970:5))
        await source.assets.releasePin(capture.pin)
    }
}

extension RecoveryFailureTests {
    func testCanonicalEquivalentDraftPackageRetainsExactScalarsWithoutSavingSource() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),source=try await NotebookStore.open(root:root.appendingPathComponent("source"))
        var content=PageContent();content.textBlocks=[TextBlock(text:"\u{e9}")]
        let note=try await source.createNote(title:"Scalars",contents:[content]),page=note.pages[0]
        content.textBlocks[0].text="e\u{301}"
        let before=try await source.snapshot()
        let capture=try await source.captureBackup(drafts:[.init(pageID:page.id,baseRevisionID:page.currentRevisionID,generation:1,content:content)])
        let url=try await NotebookPackage(root:root.appendingPathComponent("exports")).create(capture:capture,assets:source.assets)
        let target=try await NotebookStore.open(root:root.appendingPathComponent("target")),service=RestoreService(store:target,root:root.appendingPathComponent("imports"))
        let preview=try await service.inspectImport(url:url);try await service.restore(preview,policy:.replace)
        let recovered=try await target.openPage(id:page.id)
        XCTAssertEqual(recovered.content.textBlocks[0].text.unicodeScalars.map(\.value),[101,769])
        let after=try await source.snapshot();XCTAssertEqual(before,after)
    }
}


extension LaunchSyncResumeTests {
    func testFutureCommitDuringRequestGetsOneTrailingDrainAndForegroundCoalesces() async throws {
        let (root,_)=try await fixture(),probe=Probe(),model=LibraryModel(root:root,launchSync:operations(probe))
        await model.open();await model.launchResumeTask?.value
        probe.onRequest={
            if probe.requests==2 {
                let store=try XCTUnwrap(model.store)
                _ = try await store.createNote(title:"During request")
                await model.localCommit(from:store)
                model.syncForeground();model.syncForeground()
            }
        }
        let store=try XCTUnwrap(model.store)
        _ = try await store.createNote(title:"Future edit")
        await model.localCommit(from:store)
        try await Task.sleep(for:.seconds(2))
        XCTAssertEqual(probe.requests,3)
        XCTAssertEqual(model.notes.count,2)
        model.syncForeground();model.syncForeground()
        try await Task.sleep(for:.seconds(1))
        XCTAssertEqual(probe.requests,4)
    }
    func testAutomaticWakeupsNeverEnableDisabledInspectionOrMismatchedRoots() async throws {
        for mode in ["disabled","inspection","mismatch"] {
            let (root,_)=try await fixture(enabled:mode != "disabled",inspection:mode=="inspection"),probe=Probe()
            let model=LibraryModel(root:root,launchSync:operations(probe,account:mode=="mismatch" ? String(repeating:"b",count:64) : String(repeating:"a",count:64)))
            await model.open();await model.launchResumeTask?.value
            let store=try XCTUnwrap(model.store)
            if mode=="disabled" {_ = try await store.createNote(title:"Local only")}
            await model.localCommit(from:store);model.syncForeground()
            try await Task.sleep(for:.seconds(1))
            XCTAssertEqual(probe.requests,0,mode)
            XCTAssertEqual(model.notes.count,mode=="disabled" ? 1 : 0)
        }
    }
}


extension PackageTests {
    func testAuthoredDeltaSaveFailureRetainsEpochSearchDraftAndHistoricalBytes() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        var content=PageContent();content.textBlocks=[TextBlock(text:"durable prior")]
        let note=try await store.createNote(title:"Fault",contents:[content])
        let before=try await store.snapshot(),epoch=store.protection.currentCommitEpoch
        var database:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("metadata.sqlite").path,&database),SQLITE_OK)
        defer {sqlite3_close(database)}
        XCTAssertEqual(sqlite3_exec(database,"CREATE TRIGGER fail_delta BEFORE INSERT ON ZRECORD BEGIN SELECT RAISE(FAIL, 'injected save failure'); END",nil,nil,nil),SQLITE_OK)
        content.textBlocks[0].text="not acknowledged"
        do {_ = try await store.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:content));XCTFail("failed save acknowledged")} catch {}
        let after=try await store.snapshot();XCTAssertEqual(after,before);XCTAssertEqual(store.protection.currentCommitEpoch,epoch)
        var hits=try await store.search(query:"durable prior",scope:"notes");XCTAssertEqual(hits.count,1)
        hits=try await store.search(query:"not acknowledged",scope:"notes");XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(sqlite3_exec(database,"DROP TRIGGER fail_delta",nil,nil,nil),SQLITE_OK)
        _ = try await store.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:content))
        let reopened=try await NotebookStore.open(root:root)
        hits=try await reopened.search(query:"not acknowledged",scope:"notes");XCTAssertEqual(hits.count,1)
    }
}
