import XCTest
import PencilKit
import CloudKit
import MeetingBookCore
@testable import MeetingBook

@MainActor final class SyncTests: XCTestCase {
    func operation(_ entity: String="page/00000000-0000-0000-0000-000000000001/head", bases: [UUID]=[], value: String="00000000-0000-0000-0000-000000000002", sequence: Int64=1) -> CausalOperation {
        let bytes=try! JSONEncoder().encode(value)
        return CausalOperation(id:UUID(),transactionID:UUID(),libraryID:UUID(),accountFingerprint:String(repeating:"a",count:64),entity:entity,bases:bases,baseValueHash:nil,deviceID:UUID(),sequence:sequence,createdAt:Date(),value:bytes,valueHash:AssetStore.hash(bytes),revisions:[],assets:[])
    }
    func testCausalRestoreWinsDespiteOlderRevisionValue() throws {
        let original=operation(value:"R0"),edit=operation(bases:[original.id],value:"R1")
        let restore=operation(bases:[edit.id],value:"R0")
        let graph=[original,edit,restore]
        XCTAssertEqual(try RevisionConflictResolver.classify(local:edit,incoming:restore,operations:graph),.incoming)
        XCTAssertEqual(try RevisionConflictResolver.classify(local:restore,incoming:edit,operations:graph),.local)
    }
    func testIncompleteAncestryDoesNotBecomeConflict() throws {
        let local=operation(),remote=operation(bases:[UUID()])
        XCTAssertEqual(try RevisionConflictResolver.classify(local:local,incoming:remote,operations:[local,remote]),.incomplete)
    }
    func testConcurrentAndDuplicateClassificationIsOrderIndependent() throws {
        let base=operation(),a=operation(bases:[base.id],value:"A"),b=operation(bases:[base.id],value:"B")
        XCTAssertEqual(try RevisionConflictResolver.classify(local:a,incoming:b,operations:[base,a,b]),.concurrent)
        XCTAssertEqual(try RevisionConflictResolver.classify(local:b,incoming:a,operations:[b,a,base]),.concurrent)
        XCTAssertEqual(try RevisionConflictResolver.classify(local:a,incoming:a,operations:[base,a]),.same)
        XCTAssertEqual(RevisionConflictResolver.copyID(entity:a.entity,operations:[a.id,b.id]),RevisionConflictResolver.copyID(entity:a.entity,operations:[b.id,a.id]))
    }
}

extension SyncTests {
    func testWireRejectsUnknownSchemaAndForgedIdentity() throws {
        let op=operation(),bytes=try JSONEncoder().encode(operation())
        XCTAssertThrowsError(try SyncWireRecord(id:"operation-"+op.id.uuidString,kind:.operation,bytes:bytes).validate())
        let valid=SyncWireRecord(id:"operation-"+op.id.uuidString,kind:.operation,bytes:try JSONEncoder().encode(op))
        XCTAssertNoThrow(try valid.validate())
        var invalid=valid;invalid.version=99;XCTAssertThrowsError(try invalid.validate())
    }
    func testOwnedWireStageSurvivesReopenAndRejectsLateScope() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:url),initial=try await store.syncScope()
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:initial,engineID:UUID())
        let op=operation(),wire=SyncWireRecord(id:"operation-"+op.id.uuidString,kind:.operation,bytes:try JSONEncoder().encode(op))
        try await store.stageWire(wire,scope:scope)
        let reopened=try await NotebookStore.open(root:url),received=try await reopened.wireRecords(scope:scope)
        XCTAssertTrue(received.contains{$0.record==wire})
        _ = try await store.disableKeepingLocalData(expected:scope)
        do {try await store.stageWire(wire,scope:scope);XCTFail("late wire accepted")} catch {}
    }
}

extension SyncTests {
    func testWireInboxIsPackagedAndAccountBound() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let op=operation(),wire=SyncWireRecord(id:"operation-"+op.id.uuidString,kind:.operation,bytes:try JSONEncoder().encode(op))
        try await store.stageWire(wire,scope:scope)
        let capture=try await store.captureBackup()
        XCTAssertNoThrow(try NotebookStore.validatePackageRecords(capture.files))
        await store.assets.releasePin(capture.pin)
    }
}

extension SyncTests {
    func testOutgoingManifestIncludesEveryMemberAndExactAcknowledgement() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Cloud")
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let sent=try await store.prepareWireOutbox(scope:scope)
        let operation=try XCTUnwrap(sent.first{$0.kind == .operation})
        try await store.setBookmark(pageID:note.pageIDs[0],value:true)
        for record in sent {try await store.acknowledgeWire(record,scope:scope,systemFields:Data())}
        let remaining=try await store.pendingOperations(scope:scope)
        XCTAssertTrue(remaining.contains{$0.entity.hasSuffix("/bookmark")})
        XCTAssertFalse(remaining.contains{$0.id.uuidString==String(operation.id.dropFirst("operation-".count))})
        let manifests=try sent.filter{$0.kind == .transaction}.map{try JSONDecoder().decode(SyncTransactionManifest.self,from:$0.bytes)}
        let journal=try await store.journal()
        for manifest in manifests {XCTAssertEqual(Set(manifest.members),Set(journal.filter{$0.transactionID==manifest.id}.map(\.id)))}
    }
}

extension SyncTests {
    func testReversedBootstrapActivatesOnlyCompleteGraphWithoutEcho() async throws {
        let sender=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let receiver=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await sender.createNote(title:"Remote")
        let a=try await sender.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:sender.syncScope(),engineID:UUID())
        let b=try await receiver.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:receiver.syncScope(),engineID:UUID())
        let wires=try await sender.prepareWireOutbox(scope:a)
        for wire in wires.reversed() {try await receiver.stageWire(wire,scope:b);_ = try await receiver.reconcileWire(scope:b)}
        let notes=try await receiver.listNotes()
        XCTAssertEqual(notes.map(\.id),[note.id])
        let pending=try await receiver.pendingOperations(scope:b)
        XCTAssertTrue(pending.allSatisfy{$0.libraryID==b.libraryID})
    }
}

extension SyncTests {
    func testMissingHeaderDeliveryCannotAcknowledgeGraph() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await store.createNote(title:"Graph")
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let sent=try await store.prepareWireOutbox(scope:scope)
        for wire in sent where wire.kind != .header {try await store.acknowledgeWire(wire,scope:scope,systemFields:Data())}
        let pending=try await store.pendingOperations(scope:scope)
        XCTAssertFalse(pending.isEmpty,"incomplete publication was acknowledged")
    }
}

extension SyncTests {
    func testUndoOwnershipBlocksRemoteButCleanReadDoesNot() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Lease",contents:[PageContent()])
        var session:EditorSession?=EditorSession(store:store,snapshot:note)
        let clean=await store.isPageLeasedForRemoteActivation(note.pages[0].id);XCTAssertFalse(clean)
        var changed=PageContent();changed.style.ink="blue"
        session!.setDraft(changed,pageID:note.pages[0].id);try await session!.flush()
        let withHistory=await store.isPageLeasedForRemoteActivation(note.pages[0].id);XCTAssertTrue(withHistory)
        session=nil
        let released=await store.isPageLeasedForRemoteActivation(note.pages[0].id);XCTAssertFalse(released)
    }
}

extension SyncTests {
    func testPageForkCreatesStableEditableConflictCopy() async throws {
        let sender=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let receiver=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await sender.createNote(title:"Fork")
        let a=try await sender.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:sender.syncScope(),engineID:UUID())
        let b=try await receiver.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:receiver.syncScope(),engineID:UUID())
        let initial=try await sender.prepareWireOutbox(scope:a)
        for wire in initial {try await receiver.stageWire(wire,scope:b);try await sender.acknowledgeWire(wire,scope:a,systemFields:Data())}
        _ = try await receiver.reconcileWire(scope:b)
        let page=try await sender.openPage(id:note.pageIDs[0])
        var left=page.content,right=page.content;left.style.ink="blue";right.style.ink="red"
        _ = try await sender.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:left),now:Date(timeIntervalSince1970:111))
        _ = try await receiver.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:right),now:Date(timeIntervalSince1970:222))
        let sendA=try await sender.prepareWireOutbox(scope:a),sendB=try await receiver.prepareWireOutbox(scope:b)
        for wire in sendA {try await receiver.stageWire(wire,scope:b)}
        for wire in sendB.reversed() {try await sender.stageWire(wire,scope:a)}
        _ = try await sender.reconcileWire(scope:a);_ = try await receiver.reconcileWire(scope:b)
        let conflictsA=try await sender.syncConflicts(),conflictsB=try await receiver.syncConflicts()
        XCTAssertEqual(conflictsA.map(\.id),conflictsB.map(\.id));XCTAssertEqual(conflictsA.count,1)
        let notesA=try await sender.listNotes(),notesB=try await receiver.listNotes()
        XCTAssertEqual(Set(notesA.map(\.id)),Set(notesB.map(\.id)));XCTAssertEqual(notesA.count,2)
        let copyID=try XCTUnwrap(conflictsA.first?.copyNoteID)
        let copyA=try await sender.openNote(id:copyID),copyB=try await receiver.openNote(id:copyID)
        XCTAssertEqual(copyA.note,copyB.note)
        XCTAssertEqual(copyA.note.createdAt,note.createdAt)
        XCTAssertEqual(copyA.note.modifiedAt,Date(timeIntervalSince1970:copyA.pages[0].content.style.ink=="blue" ? 111 : 222))
        var promoted=copyA.pages[0].content;promoted.style.ink="green"
        _ = try await sender.commit(.init(pageID:copyA.pages[0].id,expectedRevisionID:copyA.pages[0].currentRevisionID,content:promoted),now:Date(timeIntervalSince1970:333))
        let editedCopy=try await sender.openNote(id:copyID)
        XCTAssertEqual(editedCopy.note.createdAt,note.createdAt);XCTAssertEqual(editedCopy.note.modifiedAt,Date(timeIntervalSince1970:333))
    }
}

extension SyncTests {
    func testAuthorTransactionPredecessorPreventsCrossEntityReordering() async throws {
        let sender=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),receiver=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await sender.createNote(title:"Causal")
        let a=try await sender.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:sender.syncScope(),engineID:UUID())
        let b=try await receiver.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:receiver.syncScope(),engineID:UUID())
        try await sender.setBookmark(pageID:note.pageIDs[0],value:true)
        let authored=try await sender.journal()
        let bookmarkTx=try XCTUnwrap(authored.last{$0.entity.hasSuffix("/bookmark")}).transactionID
        let page=try await sender.openPage(id:note.pageIDs[0]);var content=page.content;content.style.ink="red"
        _ = try await sender.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        let wires=try await sender.prepareWireOutbox(scope:a)
        for wire in wires where wire.id != "transaction-"+bookmarkTx.uuidString {try await receiver.stageWire(wire,scope:b)}
        _ = try await receiver.reconcileWire(scope:b)
        let before=try await receiver.openPage(id:page.id);XCTAssertNotEqual(before.content.style.ink,"red")
        try await receiver.stageWire(try XCTUnwrap(wires.first{$0.id=="transaction-"+bookmarkTx.uuidString}),scope:b)
        _ = try await receiver.reconcileWire(scope:b)
        let after=try await receiver.openPage(id:page.id);XCTAssertEqual(after.content.style.ink,"red");XCTAssertTrue(after.bookmark)
    }
}

extension SyncTests {
    func testAcknowledgementKeepsOperationOwnSystemFields() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await store.createNote(title:"Receipt")
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let wires=try await store.prepareWireOutbox(scope:scope)
        for wire in wires {try await store.acknowledgeWire(wire,scope:scope,systemFields:Data(wire.id.utf8))}
        let wire=try XCTUnwrap(wires.first{$0.kind == .operation}),operation=try JSONDecoder().decode(CausalOperation.self,from:wire.bytes)
        let fields=try await store.acknowledgedSystemFields(operationID:operation.id,scope:scope)
        XCTAssertEqual(fields,Data(wire.id.utf8))
    }
}

extension SyncTests {
    func boundStore() async throws -> (NotebookStore,SyncScope) {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        return (store,scope)
    }
    func testForeignManifestRejectedBeforeDurableStage() async throws {
        let (store,scope)=try await boundStore(),id=UUID()
        let context=SyncTransactionContext(id:id,libraryID:UUID(),deviceID:UUID(),accountFingerprint:String(repeating:"b",count:64),dependencies:[])
        let manifest=SyncTransactionManifest(id:id,members:[UUID()],context:context)
        do {try await store.stageWire(.init(id:"transaction-"+id.uuidString,kind:.transaction,bytes:JSONEncoder().encode(manifest)),scope:scope);XCTFail("foreign manifest staged")} catch {}
        let received=try await store.wireRecords(scope:scope);XCTAssertTrue(received.isEmpty)
    }
    func testStagedContextCycleIsCorruptRatherThanIncomplete() async throws {
        let (store,scope)=try await boundStore(),a=UUID(),b=UUID(),library=UUID(),device=UUID()
        let note=try await store.createNote(title:"Local content")
        func wire(_ id:UUID,_ dependency:UUID) throws -> SyncWireRecord {
            let context=SyncTransactionContext(id:id,libraryID:library,deviceID:device,accountFingerprint:scope.accountFingerprint!,dependencies:[dependency])
            let manifest=SyncTransactionManifest(id:id,members:[UUID()],context:context)
            return .init(id:"transaction-"+id.uuidString,kind:.transaction,bytes:try JSONEncoder().encode(manifest))
        }
        let first=try wire(a,b),second=try wire(b,a)
        try await store.stageWire(first,scope:scope)
        do {try await store.stageWire(second,scope:scope);XCTFail("cycle completing record durably staged")} catch {}
        let received=try await store.wireRecords(scope:scope);XCTAssertEqual(received.map(\.record),[first])
        let reopened=try await NotebookStore.open(root:store.root)
        let pending=try await reopened.pendingWireTransactions(scope:scope);XCTAssertEqual(pending.count,1);XCTAssertEqual(pending.first?.reason,.incomplete)
        let pkg=NotebookPackage(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString));_ = try await pkg.create(store:reopened)
        try await reopened.setBookmark(pageID:note.pageIDs[0],value:true)
        let page=try await reopened.openPage(id:note.pageIDs[0]);XCTAssertTrue(page.bookmark)
    }
    func testStagedManifestMustMatchMaterializedContextAndMembers() async throws {
        let (store,scope)=try await boundStore()
        _ = try await store.createNote(title:"Local")
        let contexts=try await store.transactionContexts(),context=try XCTUnwrap(contexts.last),journal=try await store.journal()
        let members=journal.filter{$0.transactionID==context.id}.map(\.id).sorted{$0.uuidString<$1.uuidString}
        let wrongContext=SyncTransactionContext(id:context.id,libraryID:context.libraryID,deviceID:context.deviceID,accountFingerprint:context.accountFingerprint,dependencies:[UUID()])
        for manifest in [SyncTransactionManifest(id:context.id,members:[UUID()],context:context),SyncTransactionManifest(id:context.id,members:members,context:wrongContext)] {
            let wire=SyncWireRecord(id:"transaction-"+manifest.id.uuidString,kind:.transaction,bytes:try JSONEncoder().encode(manifest))
            do {try await store.stageWire(wire,scope:scope);XCTFail("manifest disagreed with materialized history")} catch {}
        }
        let wires=try await store.wireRecords(scope:scope);XCTAssertTrue(wires.isEmpty)
        _ = try await NotebookStore.open(root:store.root)
    }
    func testWireRejectsMalformedTypedHead() throws {
        let op=operation(value:"not a UUID")
        XCTAssertThrowsError(try SyncWireRecord(id:"operation-"+op.id.uuidString,kind:.operation,bytes:JSONEncoder().encode(op)).validate())
    }
    func testWireRevisionRejectsSelfParent() throws {
        let id=UUID(),content=PageContent(),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let revision=PageRevision(id:id,pageID:UUID(),parentRevisionIDs:[id],deviceID:UUID(),sequence:1,createdAt:Date(),contentHash:AssetStore.hash(try encoder.encode(content)),content:content,reason:.edit)
        XCTAssertThrowsError(try SyncWireRecord(id:"revision-"+id.uuidString,kind:.revision,bytes:encoder.encode(revision)).validate())
    }
}

extension SyncTests {
    func deliver(_ wires:[SyncWireRecord],to store:NotebookStore,scope:SyncScope) async throws {
        for wire in wires {try await store.stageWire(wire,scope:scope)}
        _ = try await store.reconcileWire(scope:scope)
    }
    func testInvalidNativeDrawingCannotActivate() async throws {
        let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
        let invalid=try await sender.assets.stage(data:Data("not a PencilKit drawing".utf8));_ = try await sender.assets.finalize(invalid)
        var content=PageContent();content.drawingAssetHash=invalid.hash
        _ = try await sender.createNote(title:"Malformed drawing",contents:[content])
        let wires=try await sender.prepareWireOutbox(scope:a)
        for wire in wires {try await receiver.stageWire(wire,scope:b)}
        do {_ = try await receiver.reconcileWire(scope:b);XCTFail("invalid native drawing activated")} catch {}
        let notes=try await receiver.listNotes();XCTAssertTrue(notes.isEmpty)
    }
    func testStructuralNoteDeletionHonorsPageLease() async throws {
        let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
        let note=try await sender.createNote(title:"Lease")
        let initial=try await sender.prepareWireOutbox(scope:a);try await deliver(initial,to:receiver,scope:b)
        for wire in initial {try await sender.acknowledgeWire(wire,scope:a,systemFields:Data())}
        var lease:StorageLease?=receiver.protection.retain(remotePages:Set(note.pageIDs))
        try await sender.trash(noteID:note.id)
        try await deliver(sender.prepareWireOutbox(scope:a),to:receiver,scope:b)
        let held=try await receiver.listNotes();XCTAssertEqual(held.map(\.id),[note.id])
        withExtendedLifetime(lease) {};lease=nil
        _ = try await receiver.reconcileWire(scope:b)
        let released=try await receiver.listNotes();XCTAssertTrue(released.isEmpty)
    }
    func testTechnicalRowsCannotForgeAppliedTransactionOrDelivery() async throws {
        let (store,scope)=try await boundStore(),rows=try NotebookStore.envelopeRows(await store.snapshot())
        let missing=UUID(),applied=AppliedSyncTransaction(id:missing,scope:scope)
        XCTAssertThrowsError(try NotebookStore.validateGraph(rows+[.init(key:"sync-applied-"+missing.uuidString,kind:"syncApplied",payload:JSONEncoder().encode(applied))]))
        let receipt=SyncWireReceipt(id:"operation-"+missing.uuidString,bodyHash:String(repeating:"a",count:64),scope:scope,systemFields:Data())
        XCTAssertThrowsError(try NotebookStore.validateGraph(rows+[.init(key:"sync-delivered-"+receipt.id,kind:"syncDelivery",payload:JSONEncoder().encode(receipt))]))
    }
}

extension SyncTests {
    func testConcurrentAppendConvergesWithUUIDTieBreaker() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore()
        let note=try await a.createNote(title:"Append")
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        let left=try await a.insertPage(noteID:note.id,after:note.pageIDs.last,now:Date(timeIntervalSince1970:-1000)),right=try await b.insertPage(noteID:note.id,after:note.pageIDs.last,now:Date(timeIntervalSince1970:1000))
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa.reversed(),to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
        let expected=note.pageIDs+[left.id,right.id].sorted{$0.uuidString<$1.uuidString}
        let na=try await a.openNote(id:note.id),nb=try await b.openNote(id:note.id)
        XCTAssertEqual(na.note.pageIDs,expected);XCTAssertEqual(nb.note.pageIDs,expected)
        XCTAssertEqual(na.note.modifiedAt,nb.note.modifiedAt);XCTAssertEqual(na.note.createdAt,note.createdAt)
        XCTAssertEqual(na.pages.map(\.orderKey),[0,1,2]);XCTAssertEqual(nb.pages.map(\.orderKey),[0,1,2])
    }
    func testForeignObservedRestoreBlocksReversedEditIngress() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),(c,sc)=try await boundStore()
        let note=try await a.createNote(title:"Observed restore");try await a.trash(noteID:note.id)
        let initial=try await a.prepareWireOutbox(scope:sa)
        try await deliver(initial,to:b,scope:sb);try await deliver(initial,to:c,scope:sc)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await b.restore(noteID:note.id)
        let restored=try await b.prepareWireOutbox(scope:sb);try await deliver(restored,to:a,scope:sa)
        let journal=try await b.journal(),restore=try XCTUnwrap(journal.last{$0.entity=="note/"+note.id.uuidString+"/deleted" && $0.libraryID==sb.libraryID})
        let page=try await a.openPage(id:note.pageIDs[0]);var content=page.content;content.style.ink="red"
        _ = try await a.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        let edit=try await a.prepareWireOutbox(scope:sa)
        for wire in edit where wire.id != "transaction-"+restore.transactionID.uuidString {try await c.stageWire(wire,scope:sc)}
        _ = try await c.reconcileWire(scope:sc)
        let waiting=try await c.openPage(id:page.id);XCTAssertNotEqual(waiting.content.style.ink,"red")
        try await deliver(restored,to:c,scope:sc)
        let applied=try await c.openPage(id:page.id),notes=try await c.listNotes()
        XCTAssertEqual(applied.content.style.ink,"red");XCTAssertTrue(notes.contains{$0.id==note.id})
    }
}

extension SyncTests {
    func testHeaderIntentMustMatchImmutableRevisionBody() async throws {
        let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
        _ = try await sender.createNote(title:"Header integrity")
        var wires=try await sender.prepareWireOutbox(scope:a)
        let index=try XCTUnwrap(wires.firstIndex{wire in guard wire.kind == .operation,let op=try? JSONDecoder().decode(CausalOperation.self,from:wire.bytes) else {return false};return op.entity.hasPrefix("revision/")})
        let original=try JSONDecoder().decode(CausalOperation.self,from:wires[index].bytes)
        var header=try JSONSerialization.jsonObject(with:original.value!) as! [String:Any];header["contentHash"]=String(repeating:"b",count:64)
        let value=try JSONSerialization.data(withJSONObject:header,options:[.sortedKeys])
        let forged=CausalOperation(id:original.id,transactionID:original.transactionID,libraryID:original.libraryID,accountFingerprint:original.accountFingerprint,entity:original.entity,bases:original.bases,baseValueHash:original.baseValueHash,deviceID:original.deviceID,sequence:original.sequence,createdAt:original.createdAt,value:value,valueHash:AssetStore.hash(value),revisions:original.revisions,assets:original.assets)
        wires[index]=SyncWireRecord(id:wires[index].id,kind:.operation,bytes:try JSONEncoder().encode(forged))
        for wire in wires {try await receiver.stageWire(wire,scope:b)}
        do {_ = try await receiver.reconcileWire(scope:b);XCTFail("mismatched immutable header intent accepted")} catch {}
        let notes=try await receiver.listNotes();XCTAssertTrue(notes.isEmpty)
    }
    func testFontProjectLeaseBlocksRemoteGlyphState() async throws {
        let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
        let project=FontProject(name:"Original");try await sender.saveFontProject(project)
        let initial=try await sender.prepareWireOutbox(scope:a);try await deliver(initial,to:receiver,scope:b)
        for wire in initial {try await sender.acknowledgeWire(wire,scope:a,systemFields:Data())}
        var lease:StorageLease?=receiver.protection.retain(remoteFonts:[project.id])
        let asset=try await sender.assets.stage(data:PKDrawing().dataRepresentation());_ = try await sender.assets.finalize(asset)
        _ = try await sender.saveFontGlyph(projectID:project.id,codePoint:65,expectedHash:nil,expectedMetrics:nil,hash:asset.hash,metrics:GlyphCaptureMetrics(baselineY:180,emSize:200,xHeight:100,capHeight:140,advanceWidth:120,leftBearing:8))
        try await deliver(sender.prepareWireOutbox(scope:a),to:receiver,scope:b)
        let held=await receiver.fontProjects();XCTAssertNil(held.first?.glyphAssetHashes[65])
        withExtendedLifetime(lease) {};lease=nil
        _ = try await receiver.reconcileWire(scope:b)
        let released=await receiver.fontProjects();XCTAssertEqual(released.first?.glyphAssetHashes[65],asset.hash)
    }
}

extension NotebookStore {
    func mutateConflictNoteForTest(_ id:UUID,rename:Bool) throws {
        try transaction {
            guard let index=library.notes.firstIndex(where:{$0.id==id}) else {throw NotebookError.notFound}
            if rename {library.notes[index].title="Authored name"} else {library.notes[index].orderKey=7}
        }
    }
}

extension SyncTests {
    func forkedStores() async throws -> (NotebookStore,SyncScope,NotebookStore,SyncScope,SyncConflict) {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Fork")
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        let page=try await a.openPage(id:note.pageIDs[0]);var left=page.content,right=page.content;left.style.ink="blue";right.style.ink="red"
        _ = try await a.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:left))
        _ = try await b.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:right))
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
        let conflicts=try await a.syncConflicts();return (a,sa,b,sb,try XCTUnwrap(conflicts.first))
    }
    func testEveryFirstAuthoringActionPromotesCompleteConflictClosure() async throws {
        for action in ["bookmark","delete","name","order","edit"] {
            let (store,scope,other,_,conflict)=try await forkedStores()
            let original=try await store.fullRevisionPayload(id:conflict.copyRevisionID),peer=try await other.fullRevisionPayload(id:conflict.copyRevisionID)
            XCTAssertEqual(original,peer)
            let marker="derived-copy-"+conflict.copyPageID.uuidString
            let before=try await store.get(marker,as:DerivedSyncCopy.self);XCTAssertFalse(before.promoted)
            switch action {
            case "bookmark": try await store.setBookmark(pageID:conflict.copyPageID,value:true)
            case "delete": try await store.trash(noteID:conflict.copyNoteID)
            case "name","order": try await store.mutateConflictNoteForTest(conflict.copyNoteID,rename:action=="name")
            default:
                let page=try await store.openPage(id:conflict.copyPageID);var content=page.content;content.style.ink="green"
                _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
            }
            let after=try await store.get(marker,as:DerivedSyncCopy.self);XCTAssertTrue(after.promoted,action)
            let authored=try await store.journal().filter{$0.libraryID==scope.libraryID && $0.entity.contains(conflict.copyPageID.uuidString)}
            XCTAssertTrue(authored.contains{$0.entity.hasSuffix("/head")},action)
            XCTAssertTrue(authored.contains{$0.entity.hasSuffix("/owner")},action)
            let preserved=try await store.fullRevisionPayload(id:conflict.copyRevisionID);XCTAssertEqual(preserved,original)
            let reopened=try await NotebookStore.open(root:store.root),reopenedMarker=try await reopened.get(marker,as:DerivedSyncCopy.self);XCTAssertTrue(reopenedMarker.promoted)
        }
    }
    func testConcurrentPromotionAndReplayAreIdempotent() async throws {
        let (a,sa,b,sb,conflict)=try await forkedStores()
        try await a.setBookmark(pageID:conflict.copyPageID,value:true);try await b.setBookmark(pageID:conflict.copyPageID,value:true)
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb.reversed(),to:a,scope:sa)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
        let na=try await a.listNotes(),nb=try await b.listNotes();XCTAssertEqual(Set(na.map(\.id)),Set(nb.map(\.id)));XCTAssertEqual(na.count,2)
        let ca=try await a.syncConflicts(),cb=try await b.syncConflicts();XCTAssertEqual(ca,cb);XCTAssertEqual(ca.count,1)
    }
}

extension SyncTests {
    func testUndeliveredDeclaredDependencyPreventsWholeTransactionActivation() async throws {
        let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
        let note=try await sender.createNote(title:"Complete closure")
        var wires=try await sender.prepareWireOutbox(scope:a)
        let index=try XCTUnwrap(wires.firstIndex{wire in guard wire.kind == .operation,let op=try? JSONDecoder().decode(CausalOperation.self,from:wire.bytes) else {return false};return op.entity=="note/"+note.id.uuidString+"/title"})
        let op=try JSONDecoder().decode(CausalOperation.self,from:wires[index].bytes)
        let changed=CausalOperation(id:op.id,transactionID:op.transactionID,libraryID:op.libraryID,accountFingerprint:op.accountFingerprint,entity:op.entity,bases:op.bases,baseValueHash:op.baseValueHash,deviceID:op.deviceID,sequence:op.sequence,createdAt:op.createdAt,value:op.value,valueHash:op.valueHash,revisions:op.revisions,assets:op.assets.union([String(repeating:"c",count:64)]))
        wires[index]=SyncWireRecord(id:wires[index].id,kind:.operation,bytes:try JSONEncoder().encode(changed))
        try await deliver(wires,to:receiver,scope:b)
        let notes=try await receiver.listNotes();XCTAssertTrue(notes.isEmpty)
        let ack=try await receiver.acknowledgedSystemFields(operationID:op.id,scope:b);XCTAssertNil(ack)
    }
}

extension NotebookStore {
    func renameNoteForTest(_ id:UUID,title:String) throws {
        try transaction {guard let index=library.notes.firstIndex(where:{$0.id==id}) else {throw NotebookError.notFound};library.notes[index].title=title}
    }
}

extension SyncTests {
    func testStructuralConflictHasBoundedWholeTransactionDiagnosticsAfterReopen() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base")
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await a.renameNoteForTest(note.id,title:"A");try await b.renameNoteForTest(note.id,title:"B")
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
        let reopened=try await NotebookStore.open(root:a.root),pending=try await reopened.pendingWireTransactions(scope:sa,limit:1)
        XCTAssertEqual(pending.count,1);XCTAssertEqual(pending.first?.reason,.conflict)
        XCTAssertEqual(pending.first?.affectedPageIDs,Set(note.pageIDs))
        XCTAssertTrue(pending.first?.entities.contains("note/"+note.id.uuidString+"/title") == true)
        let current=try await reopened.openNote(id:note.id);XCTAssertEqual(current.note.title,"A")
    }
}

extension SyncTests {
    func testStructuralResolutionChoicesCreateValidRecoverableResults() async throws {
        for choice in [SyncConflictChoice.a,.b,.both] {
            let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base")
            let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
            for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
            try await a.renameNoteForTest(note.id,title:"A");try await b.renameNoteForTest(note.id,title:"B")
            try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
            let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict})
            let token=try await a.syncGraphToken()
            let resolution=try await a.resolveWireConflict(transactionID:conflict.id,choice:choice,expectedToken:token,scope:sa)
            XCTAssertTrue(resolution.sourceTransactionIDs.contains(conflict.id))
            let notes=try await a.listNotes()
            XCTAssertEqual(notes.count,choice == .both ? 2 : 1)
            XCTAssertEqual(notes.first{$0.id==note.id}?.title,choice == .b ? "B" : "A")
            if choice == .both {
                let copy=try XCTUnwrap(notes.first{$0.id != note.id});XCTAssertEqual(copy.title,"B")
                XCTAssertTrue(Set(copy.pageIDs).isDisjoint(with:note.pageIDs))
                let page=try await a.openPage(id:copy.pageIDs[0]);XCTAssertEqual(page.noteID,copy.id)
            }
            let reopened=try await NotebookStore.open(root:a.root),remaining=try await reopened.pendingWireTransactions(scope:sa)
            XCTAssertFalse(remaining.contains{$0.id==conflict.id})
            let saved=try await reopened.syncResolutions();XCTAssertTrue(saved.contains{$0.id==resolution.id})
        }
    }
}

extension SyncTests {
    func testResolutionReverseIngressReplayAndReopen() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base")
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await a.renameNoteForTest(note.id,title:"Chosen A");try await b.renameNoteForTest(note.id,title:"Source B")
        try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
        let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict}),token=try await a.syncGraphToken()
        let resolution=try await a.resolveWireConflict(transactionID:conflict.id,choice:.a,expectedToken:token,scope:sa)
        let outgoing=try await a.prepareWireOutbox(scope:sa)
        for wire in outgoing.reversed() {try await b.stageWire(wire,scope:sb);_ = try await b.reconcileWire(scope:sb)}
        try await deliver(outgoing,to:b,scope:sb)
        let reopened=try await NotebookStore.open(root:b.root),actual=try await reopened.openNote(id:note.id),resolutions=try await reopened.syncResolutions()
        XCTAssertEqual(actual.note.title,"Chosen A");XCTAssertTrue(resolutions.contains{$0.id==resolution.id})
        let remaining=try await reopened.pendingWireTransactions(scope:sb);XCTAssertFalse(remaining.contains{$0.reason == .conflict})
    }
}

extension NotebookStore {
    func renameAndEditForTest(_ noteID:UUID,title:String,ink:String) throws {
        try transaction {
            guard let index=library.notes.firstIndex(where:{$0.id==noteID}) else {throw NotebookError.notFound}
            library.notes[index].title=title
            for id in library.notes[index].pageIDs {
                var page=try loadPage(id);let parent=page.currentRevisionID;page.content.style.ink=ink;page.currentRevisionID=UUID()
                _ = try persist(page,parents:[parent],reason:.edit)
            }
        }
    }
}

extension SyncTests {
    func testConsumedUnmaterializedRevisionPublishesExactClosure() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base")
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await a.renameAndEditForTest(note.id,title:"A",ink:"blue");try await b.renameAndEditForTest(note.id,title:"B",ink:"red")
        let source=try await b.openPage(id:note.pageIDs[0]),sourceBytes=try await b.fullRevisionPayload(id:source.currentRevisionID)
        try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
        let missing=try await a.record(source.currentRevisionID.uuidString);XCTAssertNil(missing)
        let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict}),token=try await a.syncGraphToken()
        _ = try await a.resolveWireConflict(transactionID:conflict.id,choice:.a,expectedToken:token,scope:sa)
        let outgoing=try await a.prepareWireOutbox(scope:sa)
        XCTAssertEqual(outgoing.first{$0.id=="revision-"+source.currentRevisionID.uuidString}?.bytes,sourceBytes)
        try await deliver(outgoing.reversed(),to:b,scope:sb)
        let actual=try await b.openNote(id:note.id);XCTAssertEqual(actual.note.title,"A");XCTAssertEqual(actual.pages[0].content.style.ink,"blue")
    }
    func testBothCopiesExactSourceWhenReceiverOtherPageDiffers() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore()
        let note=try await a.createNote(title:"Base",contents:[PageContent(),PageContent()])
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await a.renameAndEditForTest(note.note.id,title:"A",ink:"blue");try await b.renameAndEditForTest(note.note.id,title:"B",ink:"green")
        let sourceWires=try await b.prepareWireOutbox(scope:sb)
        for wire in sourceWires {try await a.stageWire(wire,scope:sa)}
        _ = try await a.reconcileWire(scope:sa)
        let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict}),token=try await a.syncGraphToken()
        let resolution=try await a.resolveWireConflict(transactionID:conflict.id,choice:.both,expectedToken:token,scope:sa),copyID=try XCTUnwrap(resolution.copiedNoteIDs.first)
        let copy=try await a.openNote(id:copyID),original=try await a.openNote(id:note.note.id)
        XCTAssertEqual(copy.pages.map(\.content.style.ink),["green","green"]);XCTAssertEqual(original.pages.map(\.content.style.ink),["blue","blue"])
        let outgoing=try await a.prepareWireOutbox(scope:sa);try await deliver(outgoing.reversed(),to:b,scope:sb)
        let peer=try await b.openNote(id:copyID);XCTAssertEqual(peer,copy)
    }
}

extension SyncTests {
    func testPageConflictResolutionChoicesReconcileOnPeer() async throws {
        for choice in [SyncConflictChoice.a,.b,.both] {
            let (a,sa,b,sb,conflict)=try await forkedStores(),token=try await a.syncGraphToken()
            let resolution=try await a.resolvePageConflict(id:conflict.id,choice:choice,expectedToken:token,scope:sa)
            let source=try await a.get(conflict.sourceRevisionIDs[choice == .b ? 1 : 0].uuidString,as:PageRevision.self)
            let originalID=try XCTUnwrap(UUID(uuidString:String(conflict.entity.split(separator:"/")[1])))
            let page=try await a.openPage(id:originalID);XCTAssertEqual(page.content,source.content)
            let pending=try await a.unresolvedPageConflicts();XCTAssertTrue(pending.isEmpty)
            let outgoing=try await a.prepareWireOutbox(scope:sa);try await deliver(outgoing.reversed(),to:b,scope:sb)
            let peer=try await b.openPage(id:originalID);XCTAssertEqual(peer.content,page.content)
            let peerPending=try await b.unresolvedPageConflicts();XCTAssertTrue(peerPending.isEmpty)
            let notes=try await b.listNotes();XCTAssertEqual(notes.count,choice == .both ? 2 : 1)
            let saved=try await b.syncResolutions();XCTAssertTrue(saved.contains{$0.id==resolution.id})
        }
    }
}

extension SyncTests {
    func deletedAndEditedStores(pageDeletion:Bool) async throws -> (NotebookStore,SyncScope,NotebookStore,SyncScope,NoteSnapshot,SyncConflict) {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Delete/edit",contents:[PageContent(),PageContent()])
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        if pageDeletion {try await a.deletePage(id:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID)} else {try await a.trash(noteID:note.note.id)}
        var content=note.pages[0].content;content.style.ink="red"
        _ = try await b.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:content))
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb.reversed(),to:a,scope:sa)
        let conflicts=try await a.syncConflicts(),peer=try await b.syncConflicts()
        XCTAssertEqual(conflicts,peer)
        let conflict=try XCTUnwrap(conflicts.first{$0.deletionOperationID != nil})
        return (a,sa,b,sb,note,conflict)
    }
    func testConcurrentNoteAndPageDeletionPreserveEditedRecoveryCopy() async throws {
        for pageDeletion in [false,true] {
            let (a,_,b,_,note,conflict)=try await deletedAndEditedStores(pageDeletion:pageDeletion)
            let copy=try await a.openPage(id:conflict.copyPageID),peer=try await b.openPage(id:conflict.copyPageID)
            XCTAssertEqual(copy.content.style.ink,"red");XCTAssertEqual(copy,peer)
            let notes=try await a.listNotes();XCTAssertEqual(notes.count,pageDeletion ? 2 : 1)
            if pageDeletion {let current=try await a.openNote(id:note.note.id);XCTAssertFalse(current.note.pageIDs.contains(note.pages[0].id))}
            else {XCTAssertFalse(notes.contains{$0.id==note.note.id})}
        }
    }
}

extension SyncTests {
    func testDeletionResolutionChoicesRestoreOnlyExplicitScope() async throws {
        for pageDeletion in [false,true] {for choice in [SyncConflictChoice.a,.b,.both] {
            let (a,sa,b,sb,note,conflict)=try await deletedAndEditedStores(pageDeletion:pageDeletion),token=try await a.syncGraphToken()
            _ = try await a.resolvePageConflict(id:conflict.id,choice:choice,expectedToken:token,scope:sa)
            let outgoing=try await a.prepareWireOutbox(scope:sa);try await deliver(outgoing.reversed(),to:b,scope:sb)
            let reopened=try await NotebookStore.open(root:b.root),notes=try await reopened.listNotes()
            XCTAssertEqual(notes.count,choice == .b ? 1 : ((pageDeletion ? 1 : 0)+(choice == .both ? 1 : 0)))
            if choice == .b {
                let restored=try await reopened.openNote(id:note.note.id);XCTAssertEqual(Set(restored.note.pageIDs),Set(note.note.pageIDs))
                XCTAssertEqual(restored.pages.first{$0.id==note.pages[0].id}?.content.style.ink,"red")
            } else if pageDeletion {let current=try await reopened.openNote(id:note.note.id);XCTAssertFalse(current.note.pageIDs.contains(note.pages[0].id))}
            else {XCTAssertFalse(notes.contains{$0.id==note.note.id})}
            let pending=try await reopened.unresolvedPageConflicts();XCTAssertTrue(pending.isEmpty)
        }}
    }
}

extension SyncTests {
    func testPageChoiceDoesNotAuthorOtherPageOrTitleFromSourceTransaction() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base",contents:[PageContent(),PageContent()])
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial,to:b,scope:sb)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        try await a.renameAndEditForTest(note.note.id,title:"Source title",ink:"blue")
        var red=note.pages[0].content;red.style.ink="red"
        _ = try await b.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:red))
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wa,to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
        let other=try await b.openPage(id:note.pages[1].id);var green=other.content;green.style.ink="green"
        _ = try await b.commit(.init(pageID:other.id,expectedRevisionID:other.currentRevisionID,content:green));try await b.renameNoteForTest(note.note.id,title:"Receiver title")
        let conflicts=try await a.unresolvedPageConflicts(),conflict=try XCTUnwrap(conflicts.first),token=try await a.syncGraphToken()
        let resolution=try await a.resolvePageConflict(id:conflict.id,choice:.a,expectedToken:token,scope:sa)
        XCTAssertNil(resolution.resultHashes["page/"+other.id.uuidString+"/head"])
        XCTAssertNil(resolution.resultHashes["note/"+note.note.id.uuidString+"/title"])
        let outgoing=try await a.prepareWireOutbox(scope:sa);try await deliver(outgoing.reversed(),to:b,scope:sb);try await deliver(outgoing,to:b,scope:sb)
        let actual=try await b.openNote(id:note.note.id),pending=try await b.unresolvedPageConflicts()
        XCTAssertEqual(actual.note.title,"Receiver title");XCTAssertEqual(actual.pages[1].content.style.ink,"green");XCTAssertTrue(pending.isEmpty)
    }
}

import SQLite3
extension SyncTests {
    func executeSyncFixtureSQL(_ statement:String,root:URL) throws {
        var database:OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("metadata.sqlite").path,&database)==SQLITE_OK else {throw NotebookError.invalidModel}
        defer{sqlite3_close(database)}
        guard sqlite3_exec(database,statement,nil,nil,nil)==SQLITE_OK else {throw NotebookError.invalidModel}
    }
    func testNewerCopyEditCannotBeArchivedByOldResolution() async throws {
        let (a,sa,_,_,conflict)=try await forkedStores(),old=try await a.syncGraphToken(),page=try await a.openPage(id:conflict.copyPageID)
        var content=page.content;content.style.ink="green"
        _ = try await a.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        for token in [old,try await a.syncGraphToken()] {
            do {_ = try await a.resolvePageConflict(id:conflict.id,choice:.a,expectedToken:token,scope:sa);XCTFail("newer copy silently archived")} catch {}
        }
        let current=try await a.openNote(id:conflict.copyNoteID);XCTAssertEqual(current.pages[0].content.style.ink,"green")
    }
    func testWholeNoteRestoreChecksSecondWindowDraftLease() async throws {
        let (a,sa,_,_,note,conflict)=try await deletedAndEditedStores(pageDeletion:false)
        var session:EditorSession?=EditorSession(store:a,snapshot:note),draft=note.pages[1].content;draft.style.ink="green"
        session!.setDraft(draft,pageID:note.pages[1].id)
        let token=try await a.syncGraphToken()
        do {_ = try await a.resolvePageConflict(id:conflict.id,choice:.b,expectedToken:token,scope:sa);XCTFail("whole note restore ignored another page draft")} catch {}
        let notes=try await a.listNotes();XCTAssertFalse(notes.contains{$0.id==note.note.id})
        withExtendedLifetime(session) {};session=nil
    }
    func testResolutionSaveFailureRollsBackPromotionAndHistory() async throws {
        let (a,sa,_,_,conflict)=try await forkedStores();_ = try await a.prepareWireOutbox(scope:sa)
        let before=try await a.snapshot(),token=try await a.syncGraphToken(),root=await a.root
        try executeSyncFixtureSQL("CREATE TRIGGER fail_resolution BEFORE INSERT ON ZRECORD WHEN NEW.ZKIND='causalOperation' BEGIN SELECT RAISE(FAIL, 'injected resolution failure'); END",root:root)
        do {_ = try await a.resolvePageConflict(id:conflict.id,choice:.both,expectedToken:token,scope:sa);XCTFail("failed save accepted")} catch {}
        try executeSyncFixtureSQL("DROP TRIGGER fail_resolution",root:root)
        let after=try await a.snapshot(),marker=try await a.get("derived-copy-"+conflict.copyPageID.uuidString,as:DerivedSyncCopy.self)
        XCTAssertEqual(before,after);XCTAssertFalse(marker.promoted)
        _ = try await a.resolvePageConflict(id:conflict.id,choice:.both,expectedToken:token,scope:sa)
        let reopened=try await NotebookStore.open(root:root),resolved=try await reopened.unresolvedPageConflicts();XCTAssertTrue(resolved.isEmpty)
    }
}

extension SyncTests {
    func testDeletionConflictRejectsUnrelatedHistoricalOwner() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore()
        let first=try await a.createNote(title:"Edited"),other=try await a.createNote(title:"Deleted")
        try await deliver(a.prepareWireOutbox(scope:sa),to:b,scope:sb)
        try await a.trash(noteID:other.id)
        let page=try await b.openPage(id:first.pageIDs[0]);var content=page.content;content.style.ink="red"
        _ = try await b.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        let aj=try await a.journal(),bj=try await b.journal()
        let deletion=try XCTUnwrap(aj.filter{$0.entity=="note/"+other.id.uuidString+"/deleted"}.max{$0.sequence<$1.sequence})
        let edit=try XCTUnwrap(bj.filter{$0.entity=="page/"+page.id.uuidString+"/head" && $0.libraryID==sb.libraryID}.max{$0.sequence<$1.sequence})
        let forged=try SyncConflict(deletion:deletion,edit:edit)
        let operations=Dictionary((aj+bj).map{($0.id,$0)},uniquingKeysWith:{$1})
        let ac=try await a.transactionContexts(),bc=try await b.transactionContexts()
        let contexts=Dictionary((ac+bc).map{($0.id,$0)},uniquingKeysWith:{$1})
        XCTAssertEqual(SyncTransactionContext.areConcurrent(deletion.transactionID,edit.transactionID,contexts:contexts),true)
        XCTAssertThrowsError(try forged.validateSources(operations:operations,contexts:contexts))
    }
}

extension SyncTests {
    func testConsumedSourceDescendantRemainsConcurrentWithResolution() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),note=try await a.createNote(title:"Base")
        try await deliver(a.prepareWireOutbox(scope:sa),to:b,scope:sb)
        try await a.renameAndEditForTest(note.id,title:"A",ink:"blue")
        try await b.renameAndEditForTest(note.id,title:"B",ink:"red")
        try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
        let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict})
        _ = try await a.resolveWireConflict(transactionID:conflict.id,choice:.a,expectedToken:a.syncGraphToken(),scope:sa)
        try await b.renameAndEditForTest(note.id,title:"B later",ink:"green")
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wb.reversed(),to:a,scope:sa);try await deliver(wa.reversed(),to:b,scope:sb)
        let local=try await a.openNote(id:note.id),peer=try await b.openNote(id:note.id)
        XCTAssertEqual(local.note.title,"A");XCTAssertEqual(local.pages[0].content.style.ink,"blue")
        XCTAssertEqual(peer.note.title,"B later");XCTAssertEqual(peer.pages[0].content.style.ink,"green")
        let pa=try await a.pendingWireTransactions(scope:sa),pb=try await b.pendingWireTransactions(scope:sb)
        XCTAssertTrue(pa.contains{$0.reason == .conflict});XCTAssertTrue(pb.contains{$0.reason == .conflict})
        try await deliver(wb,to:a,scope:sa)
        let reopened=try await NotebookStore.open(root:a.root),again=try await reopened.openNote(id:note.id);XCTAssertEqual(again,local)
    }
    func setGlyph(_ store:NotebookStore,_ project:UUID,_ code:UInt32,_ advance:Double) async throws {
        let staged=try await store.assets.stage(data:PKDrawing().dataRepresentation());_ = try await store.assets.finalize(staged)
        _ = try await store.saveFontGlyph(projectID:project,codePoint:code,expectedHash:nil,expectedMetrics:nil,hash:staged.hash,metrics:GlyphCaptureMetrics(baselineY:80,emSize:100,xHeight:50,capHeight:70,advanceWidth:advance,leftBearing:5))
    }
    func testDisjointGlyphsMergeAndSameGlyphChoicesConverge() async throws {
        for choice in [SyncConflictChoice.a,.b,.both] {
            let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),project=FontProject(name:"Glyphs")
            try await a.saveFontProject(project);try await deliver(a.prepareWireOutbox(scope:sa),to:b,scope:sb)
            try await setGlyph(a,project.id,65,60);try await setGlyph(b,project.id,66,70)
            let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
            try await deliver(wa,to:b,scope:sb);try await deliver(wb,to:a,scope:sa)
            let first=await a.fontProjects(),second=await b.fontProjects();XCTAssertEqual(first,second);XCTAssertEqual(first[0].glyphAssetHashes.count,2)
            try await setGlyph(a,project.id,67,80);try await setGlyph(b,project.id,67,90)
            try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
            let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict})
            let resolution=try await a.resolveWireConflict(transactionID:conflict.id,choice:choice,expectedToken:a.syncGraphToken(),scope:sa)
            try await deliver(a.prepareWireOutbox(scope:sa).reversed(),to:b,scope:sb)
            let local=await a.fontProjects(),peer=await b.fontProjects();XCTAssertEqual(local.sorted{$0.id.uuidString<$1.id.uuidString},peer.sorted{$0.id.uuidString<$1.id.uuidString})
            XCTAssertEqual(local.first{$0.id==project.id}?.glyphMetrics[67]?.advanceWidth,choice == .b ? 90 : 80)
            if choice == .both {let id=try XCTUnwrap(resolution.copiedProjectIDs.first);XCTAssertEqual(local.first{$0.id==id}?.glyphMetrics[67]?.advanceWidth,90)}
        }
    }
}

extension SyncTests {
    func publishFixture(_ store:NotebookStore,_ project:UUID) async throws -> FontVersion {
        let id=UUID(),name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(550,700),.init(550,0)]],advanceWidth:600)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map{($0,outline)});glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let asset=try await store.assets.stage(data:TrueTypeWriter.build(glyphs:glyphs,postScriptName:name));_ = try await store.assets.finalize(asset)
        let version=FontVersion(id:id,assetHash:asset.hash,postScriptName:name,metrics:FontMetrics())
        _ = try await store.publishFontVersion(projectID:project,version:version);return version
    }
    func testConcurrentFontPublicationsRetainImmutableMetadataForEveryChoice() async throws {
        for choice in [SyncConflictChoice.a,.b,.both] {
            let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),project=FontProject(name:"Published")
            try await a.saveFontProject(project);try await deliver(a.prepareWireOutbox(scope:sa),to:b,scope:sb)
            let va=try await publishFixture(a,project.id),vb=try await publishFixture(b,project.id)
            try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
            let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict})
            let resolution=try await a.resolveWireConflict(transactionID:conflict.id,choice:choice,expectedToken:a.syncGraphToken(),scope:sa)
            let outgoing=try await a.prepareWireOutbox(scope:sa);try await deliver(outgoing.reversed(),to:b,scope:sb)
            let reopened=try await NotebookStore.open(root:b.root),local=await a.fontProjects(),peer=await reopened.fontProjects()
            XCTAssertEqual(local.sorted{$0.id.uuidString<$1.id.uuidString},peer.sorted{$0.id.uuidString<$1.id.uuidString})
            let metadata=try await reopened.fontDependencyMetadata();XCTAssertTrue(metadata.contains{$0.font==va});XCTAssertTrue(metadata.contains{$0.font==vb})
            XCTAssertEqual(local.first{$0.id==project.id}?.publicationIDs,[choice == .b ? vb.id : va.id])
            if choice == .both {let copy=try XCTUnwrap(resolution.copiedProjectIDs.first);XCTAssertEqual(local.first{$0.id==copy}?.publicationIDs,[vb.id])}
        }
    }
}

extension SyncTests {
    func testRefetchObligationSurvivesCheckpointReopenAndClearsOnlyExactBody() async throws {
        let (store,scope)=try await boundStore(),bytes=Data("pending wire body".utf8),hash=AssetStore.hash(bytes)
        let wire=SyncWireRecord(id:"asset-"+hash,kind:.asset,bytes:bytes)
        try await store.stageWireRefetch(id:wire.id,kind:wire.kind,bodyHash:hash,systemFields:Data([7]),scope:scope)
        try await store.checkpointEngine(Data([9]),scope:scope)
        let reopened=try await NotebookStore.open(root:store.root),pending=try await reopened.pendingWireRefetches(scope:scope)
        XCTAssertEqual(pending.map(\.id),[wire.id]);let checkpoint=try await reopened.engineCheckpoint(scope:scope);XCTAssertEqual(checkpoint,Data([9]))
        do {try await reopened.stageWireRefetch(id:wire.id,kind:wire.kind,bodyHash:String(repeating:"b",count:64),scope:scope);XCTFail("obligation collision accepted")} catch {}
        try await reopened.stageWire(wire,systemFields:Data([7]),scope:scope)
        let cleared=try await reopened.pendingWireRefetches(scope:scope);XCTAssertTrue(cleared.isEmpty)
        _ = try await reopened.disableKeepingLocalData(expected:scope)
        do {try await reopened.stageWireRefetch(id:wire.id,kind:wire.kind,bodyHash:hash,scope:scope);XCTFail("stale scope accepted")} catch {}
    }
    func testDisableWhileWireAssetStageSuspendsCannotPublishLateInbox() async throws {
        let (store,scope)=try await boundStore(),bytes=Data("suspended body".utf8),hash=AssetStore.hash(bytes),release=DispatchSemaphore(value:0)
        let held=AsyncStream<Void>.makeStream(),suspended=AsyncStream<Void>.makeStream()
        let assets=await store.assets
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next()
        let wire=SyncWireRecord(id:"asset-"+hash,kind:.asset,bytes:bytes)
        let task=Task {try await store.stageSuspendedWireForTest(wire,scope:scope,started:suspended.continuation)}
        var si=suspended.stream.makeAsyncIterator();_ = await si.next()
        _ = try await store.disableKeepingLocalData(expected:scope)
        release.signal();await holder.value
        do {try await task.value;XCTFail("late inbox published")} catch {}
        let reopened=try await NotebookStore.open(root:store.root),rows=try await reopened.records("syncWire");XCTAssertTrue(rows.isEmpty)
    }
}
extension AssetStore {
    func holdForSyncTest(started:AsyncStream<Void>.Continuation,release:DispatchSemaphore) {started.yield();release.wait()}
}
extension NotebookStore {
    func stageSuspendedWireForTest(_ wire:SyncWireRecord,scope:SyncScope,started:AsyncStream<Void>.Continuation) async throws {
        Task {started.yield()}
        try await stageWire(wire,scope:scope)
    }
}

extension SyncTests {
    func testWireCacheRetirementPreservesExactClosureAndUnreceivedBodies() async throws {
        let (store,scope)=try await boundStore(),note=try await store.createNote(title:"Cache")
        let original=try await store.openPage(id:note.pageIDs[0])
        let wires=try await store.prepareWireOutbox(scope:scope)
        let before=try await store.retireWireCache(scope:scope);XCTAssertEqual(before,0)
        for wire in wires {try await store.acknowledgeWire(wire,scope:scope,systemFields:Data())}
        let count=try await store.retireWireCache(scope:scope);XCTAssertGreaterThan(count,0)
        let orphan=operation(),pending=SyncWireRecord(id:"operation-"+orphan.id.uuidString,kind:.operation,bytes:try JSONEncoder().encode(orphan))
        try await store.stageWire(pending,scope:scope)
        _ = try await store.retireWireCache(scope:scope)
        _ = try await store.collectRetention(now:Date().addingTimeInterval(100*86400))
        let reopened=try await NotebookStore.open(root:store.root),actual=try await reopened.wireRecords(scope:scope)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:actual.map{($0.record.id,$0.record.bytes)}),Dictionary(uniqueKeysWithValues:(wires+[pending]).map{($0.id,$0.bytes)}))
        let page=try await reopened.openPage(id:note.pageIDs[0]);XCTAssertEqual(page,original)
        let capture=try await reopened.captureBackup();XCTAssertNoThrow(try NotebookStore.validatePackageRecords(capture.files));await reopened.assets.releasePin(capture.pin)
        let pkg=NotebookPackage(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await pkg.create(store:reopened)
    }
}

extension SyncTests {
    func testOpenAndPackageRejectHashCorrectMalformedStagedWireBody() async throws {
        let (store,scope)=try await boundStore(),body=Data("{}".utf8)
        let staged=try await store.assets.stage(data:body);_ = try await store.assets.finalize(staged)
        let wire=StoredSyncWire(id:"operation-"+UUID().uuidString,kind:.operation,bodyHash:staged.hash,scope:scope,systemFields:Data())
        try await store.injectWireMetadataForTest(wire)
        do {_ = try await NotebookStore.open(root:store.root);XCTFail("malformed wire accepted on open")} catch {}
        let pkg=NotebookPackage(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do {_ = try await pkg.create(store:store);XCTFail("malformed wire accepted in package")} catch {}
    }
}
extension NotebookStore {
    func injectWireMetadataForTest(_ wire:StoredSyncWire) throws {try transaction(journalChanges:false) {try put(wire,key:"sync-wire-"+wire.id,kind:"syncWire")}}
}

extension SyncTests {
    func testNativeImageFontAndGlyphCorruptionCannotActivateOrAcknowledge() async throws {
        for kind in ["image","font","glyph"] {
            let (sender,a)=try await boundStore(),(receiver,b)=try await boundStore()
            let asset=try await sender.assets.stage(data:Data("invalid native bytes".utf8));_ = try await sender.assets.finalize(asset)
            if kind=="image" {
                var content=PageContent();content.version=2;content.images=[ImageElement(frame:.init(x:60,y:80,width:100,height:100),assetHash:asset.hash,altText:"Invalid")]
                _ = try await sender.createNote(title:"Invalid image",contents:[content])
            } else {
                let project=FontProject(name:"Invalid "+kind);try await sender.saveFontProject(project)
                try await deliver(sender.prepareWireOutbox(scope:a),to:receiver,scope:b)
                if kind=="font" {_ = try await sender.publishFontVersion(projectID:project.id,version:FontVersion(assetHash:asset.hash,postScriptName:"InvalidFont",metrics:FontMetrics()))}
                else {_ = try await sender.saveFontGlyph(projectID:project.id,codePoint:65,expectedHash:nil,expectedMetrics:nil,hash:asset.hash,metrics:GlyphCaptureMetrics(baselineY:80,emSize:100,xHeight:50,capHeight:70,advanceWidth:60,leftBearing:5))}
            }
            let wires=try await sender.prepareWireOutbox(scope:a)
            for wire in wires {try await receiver.stageWire(wire,scope:b)}
            do {_ = try await receiver.reconcileWire(scope:b);XCTFail("invalid "+kind+" activated")} catch {}
            let operations=try await sender.journal(),invalid=operations.filter{$0.assets.contains(asset.hash)}
            for operation in invalid {let ack=try await receiver.record("ack-"+operation.id.uuidString);XCTAssertNil(ack)}
            let notes=try await receiver.listNotes(),fonts=await receiver.fontProjects()
            XCTAssertTrue(notes.isEmpty);XCTAssertTrue(fonts.allSatisfy{$0.versions.isEmpty && $0.glyphAssetHashes.isEmpty})
        }
    }
    func testSimultaneousDifferentPageDecisionsRemainResolvable() async throws {
        let (a,sa,b,sb,conflict)=try await forkedStores()
        _ = try await a.resolvePageConflict(id:conflict.id,choice:.a,expectedToken:a.syncGraphToken(),scope:sa)
        _ = try await b.resolvePageConflict(id:conflict.id,choice:.b,expectedToken:b.syncGraphToken(),scope:sb)
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wb.reversed(),to:a,scope:sa);try await deliver(wa.reversed(),to:b,scope:sb)
        let ca=try await a.unresolvedPageConflicts(),cb=try await b.unresolvedPageConflicts()
        let pa=try await a.pendingWireTransactions(scope:sa),pb=try await b.pendingWireTransactions(scope:sb)
        XCTAssertTrue(!ca.isEmpty || pa.contains{$0.reason == .conflict})
        XCTAssertTrue(!cb.isEmpty || pb.contains{$0.reason == .conflict})
        XCTAssertEqual(ca,cb)
        try await deliver(wb,to:a,scope:sa)
        let reopened=try await NotebookStore.open(root:a.root),again=try await reopened.unresolvedPageConflicts();XCTAssertEqual(again,ca)
    }
}

extension SyncTests {
    func testStructuralNoteChoiceDoesNotReassignUnrelatedFontOwner() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore(),first=FontProject(name:"First"),second=FontProject(name:"Second")
        try await a.saveFontProject(first);try await a.saveFontProject(second)
        let font=try await publishFixture(a,first.id),note=try await a.createNote(title:"Base")
        try await deliver(a.prepareWireOutbox(scope:sa),to:b,scope:sb)
        try await a.renameAndEditForTest(note.id,title:"A",ink:"blue");try await b.renameAndEditForTest(note.id,title:"B",ink:"red")
        try await a.moveFontOwnerForTest(font.id,from:first.id,to:second.id)
        try await deliver(b.prepareWireOutbox(scope:sb),to:a,scope:sa)
        let pending=try await a.pendingWireTransactions(scope:sa),conflict=try XCTUnwrap(pending.first{$0.reason == .conflict})
        _ = try await a.resolveWireConflict(transactionID:conflict.id,choice:.b,expectedToken:a.syncGraphToken(),scope:sa)
        let metadata=try await a.fontDependencyMetadata();XCTAssertEqual(metadata.first{$0.font.id==font.id}?.ownerProjectID,second.id)
        try await deliver(a.prepareWireOutbox(scope:sa).reversed(),to:b,scope:sb)
        let peer=try await b.fontDependencyMetadata();XCTAssertEqual(peer.first{$0.font.id==font.id}?.ownerProjectID,second.id)
    }
}
extension NotebookStore {
    func moveFontOwnerForTest(_ id:UUID,from:UUID,to:UUID) throws {
        try transaction {
            guard let a=library.fonts.firstIndex(where:{$0.id==from}),let b=library.fonts.firstIndex(where:{$0.id==to}),let font=library.fonts[a].versions.first(where:{$0.id==id}) else {throw NotebookError.notFound}
            library.fonts[a].publishedVersionIDs=library.fonts[a].publicationIDs;library.fonts[a].formatVersion=3;library.fonts[a].versions.removeAll{$0.id==id}
            library.fonts[b].publishedVersionIDs=library.fonts[b].publicationIDs+[id];library.fonts[b].formatVersion=3;library.fonts[b].versions.append(font)
        }
    }
}

extension SyncTests {
    func testCausalMetadataRejectsUnboundedOrNoncanonicalValues() throws {
        let glyph=operation("font/"+UUID().uuidString+"/glyph/00065")
        XCTAssertThrowsError(try glyph.validate())
        let base=operation()
        let oversized=CausalOperation(id:base.id,transactionID:base.transactionID,libraryID:base.libraryID,accountFingerprint:base.accountFingerprint,entity:base.entity,bases:(0...100_000).map{_ in UUID()},baseValueHash:nil,deviceID:base.deviceID,sequence:1,createdAt:Date(),value:base.value,valueHash:base.valueHash,revisions:[],assets:[])
        XCTAssertThrowsError(try oversized.validate())
        let invalidDate=CausalOperation(id:base.id,transactionID:base.transactionID,libraryID:base.libraryID,accountFingerprint:base.accountFingerprint,entity:base.entity,bases:[],baseValueHash:nil,deviceID:base.deviceID,sequence:1,createdAt:Date(timeIntervalSince1970:.infinity),value:base.value,valueHash:base.valueHash,revisions:[],assets:[])
        XCTAssertThrowsError(try invalidDate.validate())
    }
}

extension SyncTests {
    func testOpenRejectsTypedStagedHeaderCollisionWithMaterializedRevision() async throws {
        let (store,scope)=try await boundStore(),note=try await store.createNote(title:"Immutable")
        let page=try await store.openPage(id:note.pageIDs[0]),revision=try await store.get(page.currentRevisionID.uuidString,as:PageRevision.self)
        var header=try JSONSerialization.jsonObject(with:JSONEncoder().encode(RevisionHeader(revision))) as! [String:Any]
        header["contentHash"]=String(repeating:"b",count:64)
        let wire=SyncWireRecord(id:"header-"+revision.id.uuidString,kind:.header,bytes:try JSONSerialization.data(withJSONObject:header,options:.sortedKeys))
        do {try await store.stageWire(wire,scope:scope);XCTFail("typed immutable collision staged")} catch {}
        let body=try await store.assets.stage(data:wire.bytes);_ = try await store.assets.finalize(body)
        try await store.injectWireMetadataForTest(StoredSyncWire(id:wire.id,kind:wire.kind,bodyHash:body.hash,scope:scope,systemFields:Data()))
        do {_ = try await NotebookStore.open(root:store.root);XCTFail("typed immutable header collision accepted")} catch {}
    }
}

extension SyncTests {
    func testInspectionBindingCreatesNoOutgoingBaselineAndRejectsContent() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let journal=try await store.journal()
        XCTAssertTrue(journal.isEmpty)
        XCTAssertEqual(scope.accountFingerprint,String(repeating:"a",count:64))
        let other=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await other.createNote(title:"Keep local")
        do { _ = try await other.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:other.syncScope(),engineID:UUID());XCTFail("Nonempty content adopted") } catch {}
    }
}


extension SyncTests {
    func testNativeCodecOwnsBodyAndRejectsWrongSystemIdentity() throws {
        let bytes=Data("source bytes".utf8),hash=AssetStore.hash(bytes)
        let wire=SyncWireRecord(id:"asset-"+hash,kind:.asset,bytes:bytes)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codec=CloudKitRecordCodec()
        let outgoing=try codec.encode(wire,systemFields:Data(),directory:folder)
        XCTAssertEqual(try codec.decode(outgoing.record),wire)
        let archive=try codec.systemFields(outgoing.record)
        let restored=try codec.encode(wire,systemFields:archive,directory:folder)
        XCTAssertEqual(try codec.decode(restored.record),wire)
        let wrongRecords=[
            CKRecord(recordType:"Wrong",recordID:outgoing.record.recordID),
            CKRecord(recordType:CloudKitRecordCodec.recordType,recordID:CKRecord.ID(recordName:"different",zoneID:CloudKitRecordCodec.zoneID)),
            CKRecord(recordType:CloudKitRecordCodec.recordType,recordID:CKRecord.ID(recordName:wire.id,zoneID:CKRecordZone.ID(zoneName:"wrong zone",ownerName:CKCurrentUserDefaultName)))
        ]
        for wrong in wrongRecords {XCTAssertThrowsError(try codec.encode(wire,systemFields:codec.systemFields(wrong),directory:folder))}
        XCTAssertThrowsError(try codec.encode(wire,systemFields:Data("not an archive".utf8),directory:folder))
        outgoing.record["body"]=CKAsset(fileURL:folder.appendingPathComponent("missing"))
        XCTAssertThrowsError(try codec.decode(outgoing.record))
    }
    func testNativeCodecNilAssetRetainsExactRefetchIdentity() throws {
        let bytes=Data("body".utf8),wire=SyncWireRecord(id:"asset-"+AssetStore.hash(bytes),kind:.asset,bytes:bytes)
        let codec=CloudKitRecordCodec()
        let value=try codec.encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        value.record["body"]=nil
        XCTAssertNil(try codec.decode(value.record))
        XCTAssertEqual(try codec.metadata(value.record).hash,AssetStore.hash(bytes))
        value.record["body"]="wrong field type" as CKRecordValue
        XCTAssertThrowsError(try codec.decode(value.record))
        value.record["hash"]=String(repeating:"b",count:64) as CKRecordValue
        XCTAssertThrowsError(try codec.metadata(value.record))
    }
}

extension SyncTests {
    func testInspectionReopenRejectsSendAndAuthoringUntilPromotion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let scope=try await store.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let reopened=try await NotebookStore.open(root:root)
        let actual=try await reopened.syncScope();XCTAssertEqual(actual,scope)
        do {_ = try await reopened.prepareWireOutbox(scope:scope);XCTFail("Inspection published")} catch {}
        do {_ = try await reopened.createNote(title:"Forbidden");XCTFail("Inspection authored")} catch {}
        let promoted=try await reopened.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:scope,engineID:UUID())
        let before=try await reopened.journal();XCTAssertTrue(before.isEmpty)
        _ = try await reopened.createNote(title:"Chosen after consent")
        let after=try await reopened.prepareWireOutbox(scope:promoted);XCTAssertFalse(after.isEmpty)
    }
    func testAdapterStagesNilAssetBeforeCheckpointAndRejectsLateDelivery() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let service=CloudKitSyncService(store:store,scope:scope)
        let bytes=Data("remote".utf8),wire=SyncWireRecord(id:"asset-"+AssetStore.hash(bytes),kind:.asset,bytes:bytes)
        let codec=CloudKitRecordCodec(),record=try codec.encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).record
        record["body"]=nil
        try await service.receive([record])
        try await service.checkpoint(Data("cursor".utf8))
        let obligations=try await store.pendingWireRefetches(scope:scope);XCTAssertEqual(obligations.map(\.id),[wire.id])
        let cursor=try await store.engineCheckpoint(scope:scope);XCTAssertEqual(cursor,Data("cursor".utf8))
        try await service.disable()
        do {try await service.receive([record]);XCTFail("Late event applied")} catch {}
    }
    func testAdapterProviderKeepsSkippedAndUnacknowledgedIntent() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await store.createNote(title:"Exact success")
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let service=CloudKitSyncService(store:store,scope:scope)
        let wires=try await service.prepareOutgoing()
        let ids=wires.map{CKRecord.ID(recordName:$0.id,zoneID:CloudKitRecordCodec.zoneID)}
        let batch=try await service.provide(pending:ids.map{.saveRecord($0)},filter:.recordIDs([ids[0]]))
        XCTAssertEqual(batch?.recordsToSave.count,1)
        let before=try await store.pendingOperations(scope:scope);XCTAssertFalse(before.isEmpty)
        try await service.saved(try XCTUnwrap(batch).recordsToSave)
        let after=try await store.pendingOperations(scope:scope);XCTAssertFalse(after.isEmpty)
        let rest=try await service.provide(pending:ids.dropFirst().map{.saveRecord($0)},filter:.all)
        try await service.saved(try XCTUnwrap(rest).recordsToSave)
        let complete=try await store.pendingOperations(scope:scope);XCTAssertTrue(complete.isEmpty)
    }
    func testAdapterInspectionProviderNilEvenForHostilePendingRecords() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindForCloudInspection(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let service=CloudKitSyncService(store:store,scope:scope)
        let batch=try await service.provide(pending:[.saveRecord(CKRecord.ID(recordName:"hostile",zoneID:CloudKitRecordCodec.zoneID))],filter:.all)
        XCTAssertNil(batch)
    }
}

extension SyncTests {
    func testAdapterLimitExceededShrinksThenBlocksIdenticalSingleRetryDurably() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        _ = try await store.createNote(title:"Keep intent")
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        let service=CloudKitSyncService(store:store,scope:scope)
        let wires=try await service.prepareOutgoing(),id=CKRecord.ID(recordName:try XCTUnwrap(wires.first).id,zoneID:CloudKitRecordCodec.zoneID)
        let batch=try await service.provide(pending:[.saveRecord(id)],filter:.all)
        let record=try XCTUnwrap(batch?.recordsToSave.first)
        try await service.failed(record,error:CKError(.limitExceeded))
        let retry=try await service.provide(pending:[.saveRecord(id)],filter:.all);XCTAssertNil(retry)
        let reopened=try await NotebookStore.open(root:root)
        let state=try await reopened.transportState(scope:scope);XCTAssertEqual(state.issues[id.recordName]?.code,.oversize)
        try await service.retryTransportIssue(id.recordName)
        let explicit=try await service.provide(pending:[.saveRecord(id)],filter:.all);XCTAssertEqual(explicit?.recordsToSave.count,1)
        let pending=try await reopened.pendingOperations(scope:scope);XCTAssertFalse(pending.isEmpty)
    }
}

extension SyncTests {
    func testDiscoveryRejectsAccountSwitchBetweenAwaitedResults() async throws {
        let discovery=CloudKitAccountDiscovery(),ids=AccountIDsForTest()
        let config=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        do {_ = try await discovery.discover(configuration:config,status:{.available},userID:{await ids.next()});XCTFail("Mixed account discovery accepted")} catch {}
    }
    func testDiscoveryDisableInvalidatesSuspendedCompletion() async throws {
        let discovery=CloudKitAccountDiscovery(),gate=AccountGateForTest()
        let config=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        let task=Task {try await discovery.discover(configuration:config,status:{.available},userID:{await gate.wait()})}
        await gate.started()
        discovery.invalidate()
        await gate.release()
        do {_ = try await task.value;XCTFail("Disabled discovery completed")} catch {}
    }
    func testMissingOrMismatchedCloudConfigurationFailsClosed() throws {
        XCTAssertThrowsError(try CloudKitConfiguration(container:nil,environment:nil))
        XCTAssertThrowsError(try CloudKitConfiguration(container:"iCloud.other",environment:"production"))
        XCTAssertThrowsError(try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"DEBUG"))
    }
}
actor AccountIDsForTest {
    var count=0
    func next() -> CKRecord.ID {count+=1;return CKRecord.ID(recordName:count==1 ? "A" : "B")}
}
actor AccountGateForTest {
    var continuation:CheckedContinuation<CKRecord.ID,Never>?
    var startedContinuation:CheckedContinuation<Void,Never>?
    func wait() async -> CKRecord.ID {
        await withCheckedContinuation {continuation=$0;startedContinuation?.resume();startedContinuation=nil}
    }
    func started() async {if continuation==nil {await withCheckedContinuation{startedContinuation=$0}}}
    func release() {continuation?.resume(returning:CKRecord.ID(recordName:"A"));continuation=nil}
}

extension SyncTests {
    func testNativeCollisionObligationSurvivesReopenAndOnlyVerifiedBytesAcknowledge() async throws {
        let (store,scope)=try await boundStore()
        _ = try await store.createNote(title:"Immutable")
        let service=CloudKitSyncService(store:store,scope:scope),wires=try await service.prepareOutgoing()
        let wire=try XCTUnwrap(wires.first),id=CKRecord.ID(recordName:wire.id,zoneID:CloudKitRecordCodec.zoneID)
        let batch=try await service.provide(pending:[.saveRecord(id)],filter:.all)
        let record=try XCTUnwrap(batch?.recordsToSave.first)
        let server=CKRecord(recordType:CloudKitRecordCodec.recordType,recordID:id)
        server["version"]=1 as CKRecordValue;server["kind"]=wire.kind.rawValue as CKRecordValue;server["hash"]=AssetStore.hash(wire.bytes) as CKRecordValue
        try await service.failed(record,error:CKError(.serverRecordChanged,userInfo:[CKRecordChangedErrorServerRecordKey:server]))
        try await service.receive([server])
        do {try await service.retryTransportIssue(wire.id);XCTFail("Verification removed by ordinary retry")} catch {}
        let reopen=try await NotebookStore.open(root:store.root)
        let state=try await reopen.transportState(scope:scope)
        XCTAssertEqual(state.issues[wire.id]?.verification?.hash,AssetStore.hash(wire.bytes))
        let absent=try await reopen.record("sync-delivered-"+wire.id);XCTAssertNil(absent)
        let resumed=CloudKitSyncService(store:reopen,scope:scope)
        let complete=try CloudKitRecordCodec().encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).record
        try await resumed.receive([complete])
        let delivered=try await reopen.record("sync-delivered-"+wire.id);XCTAssertNotNil(delivered)
        let cleared=try await reopen.transportState(scope:scope);XCTAssertNil(cleared.issues[wire.id])
        let capture=try await reopen.captureBackup();XCTAssertNoThrow(try NotebookStore.validatePackageRecords(capture.files));await reopen.assets.releasePin(capture.pin)
    }
    func testFailedReceiveNeverPublishesCheckpoint() async throws {
        let (store,scope)=try await boundStore(),service=CloudKitSyncService(store:store,scope:scope)
        let bytes=Data("corrupt".utf8),wire=SyncWireRecord(id:"asset-"+AssetStore.hash(bytes),kind:.asset,bytes:bytes)
        let record=try CloudKitRecordCodec().encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).record
        record["body"]=nil
        try executeSyncFixtureSQL("CREATE TRIGGER fail_refetch BEFORE INSERT ON ZRECORD WHEN NEW.ZKIND='syncRefetch' BEGIN SELECT RAISE(FAIL, 'injected refetch failure'); END",root:await store.root)
        do {try await service.receive([record]);XCTFail("Failed persistence accepted")} catch {}
        do {try await service.checkpoint(Data([9]));XCTFail("Checkpoint bypassed failed staging")} catch {}
        let cursor=try await store.engineCheckpoint(scope:scope);XCTAssertNil(cursor)
        try executeSyncFixtureSQL("DROP TRIGGER fail_refetch",root:await store.root)
    }
    func testCheckpointCannotOvertakeSuspendedAssetStaging() async throws {
        let (store,scope)=try await boundStore(),service=CloudKitSyncService(store:store,scope:scope)
        let release=DispatchSemaphore(value:0),held=AsyncStream<Void>.makeStream(),started=AsyncStream<Void>.makeStream()
        let assets=await store.assets
        let holder=Task.detached {await assets.holdForSyncTest(started:held.continuation,release:release)}
        var hi=held.stream.makeAsyncIterator();_ = await hi.next()
        let bytes=Data("ordered receive".utf8),wire=SyncWireRecord(id:"asset-"+AssetStore.hash(bytes),kind:.asset,bytes:bytes)
        let record=try CloudKitRecordCodec().encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).record
        let receive=Task {try await service.receiveForTest(record,started:started.continuation)}
        var si=started.stream.makeAsyncIterator();_ = await si.next()
        let checkpoint=Task {try await service.checkpoint(Data([8]))}
        let before=try await store.engineCheckpoint(scope:scope);XCTAssertNil(before)
        release.signal();await holder.value
        try await receive.value;try await checkpoint.value
        let bodies=try await store.wireRecords(scope:scope);XCTAssertTrue(bodies.contains{$0.record==wire})
        let after=try await store.engineCheckpoint(scope:scope);XCTAssertEqual(after,Data([8]))
    }
}
extension CloudKitSyncService {
    func receiveForTest(_ record:CKRecord,started:AsyncStream<Void>.Continuation) async throws {
        Task {started.yield()}
        try await receive([record])
    }
}

extension SyncTests {
    func testNativeProviderCapsBatchReducesLimitAndRetainsQuotaIntent() async throws {
        let (store,scope)=try await boundStore()
        for i in 0..<25 {_ = try await store.createNote(title:"N\(i)")}
        let service=CloudKitSyncService(store:store,scope:scope),wires=try await service.prepareOutgoing()
        XCTAssertGreaterThan(wires.count,250)
        let pending=wires.map{CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName:$0.id,zoneID:CloudKitRecordCodec.zoneID))}
        let provided=try await service.provide(pending:pending,filter:.all)
        let batch=try XCTUnwrap(provided)
        XCTAssertEqual(batch.recordsToSave.count,250);XCTAssertTrue(batch.recordIDsToDelete.isEmpty)
        let first=try XCTUnwrap(batch.recordsToSave.first)
        try await service.failed(first,error:CKError(.limitExceeded))
        let state=try await store.transportState(scope:scope);XCTAssertEqual(state.batchLimit,125)
        let second=batch.recordsToSave[1]
        try await service.failed(second,error:CKError(.quotaExceeded))
        let saved=try await store.transportState(scope:scope);XCTAssertEqual(saved.issues[second.recordID.recordName]?.code,.quota)
        let retry=try await service.provide(pending:[.saveRecord(second.recordID)],filter:.all);XCTAssertNil(retry)
        let operations=try await store.pendingOperations(scope:scope);XCTAssertFalse(operations.isEmpty)
        try await service.retryTransportIssue(second.recordID.recordName)
        let offlineBatch=try await service.provide(pending:[.saveRecord(second.recordID)],filter:.all)
        let offlineRecord=try XCTUnwrap(offlineBatch?.recordsToSave.first)
        try await service.failed(offlineRecord,error:CKError(.networkUnavailable))
        let offline=try await store.transportState(scope:scope);XCTAssertEqual(offline.issues[second.recordID.recordName]?.code,.offline)
        XCTAssertGreaterThan(try XCTUnwrap(offline.issues[second.recordID.recordName]?.retryAfter),Date())
        try await service.disable()
    }
    func testNativeCollisionMatchingMetadataWithWrongBytesNeverAcknowledges() async throws {
        let (store,scope)=try await boundStore();_ = try await store.createNote(title:"Preserve")
        let service=CloudKitSyncService(store:store,scope:scope),wires=try await service.prepareOutgoing(),wire=try XCTUnwrap(wires.first)
        let id=CKRecord.ID(recordName:wire.id,zoneID:CloudKitRecordCodec.zoneID)
        let batch=try await service.provide(pending:[.saveRecord(id)],filter:.all),record=try XCTUnwrap(batch?.recordsToSave.first)
        try await service.failed(record,error:CKError(.serverRecordChanged))
        let corrupt=try CloudKitRecordCodec().encode(wire,systemFields:Data(),directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try Data("different bytes".utf8).write(to:corrupt.file)
        do {try await service.receive([corrupt.record]);XCTFail("Unverified bytes acknowledged")} catch {}
        let receipt=try await store.record("sync-delivered-"+wire.id);XCTAssertNil(receipt)
        let state=try await store.transportState(scope:scope);XCTAssertNotNil(state.issues[wire.id]?.verification)
        let restarted=try await NotebookStore.open(root:store.root);_ = try await restarted.transportState(scope:scope)
    }
}

extension SyncTests {
    func testInspectionFactoryOwnsCandidateWithoutActivatingOriginalRoot() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery=ColdRecoveryService(baseRoot:base)
        let configuration=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        let candidate=try await recovery.createCloudInspectionCandidate(configuration:configuration,fingerprint:String(repeating:"a",count:64))
        let scope=try await candidate.store.syncScope();XCTAssertEqual(scope.receiveOnly,true)
        let selected=try await recovery.selectedRoot();XCTAssertEqual(selected,base)
        let owned=try await recovery.ownedRootIDs();XCTAssertTrue(owned.contains(candidate.rootID))
        var forged=scope;forged.version=1;XCTAssertThrowsError(try forged.validate())
        let journal=try await candidate.store.journal();XCTAssertTrue(journal.isEmpty)
        let disabled=try await candidate.store.disableKeepingLocalData(expected:scope)
        let resumed=try await candidate.store.resumeCloudInspection(expected:disabled,engineID:UUID())
        XCTAssertEqual(resumed.receiveOnly,true);XCTAssertGreaterThan(resumed.generation,disabled.generation)
        do {_ = try await candidate.store.prepareWireOutbox(scope:resumed);XCTFail("Inspection resume granted upload")} catch {}
    }
}

extension SyncTests {
    func testApplicationBudgetFailureIsDistinctAndRetainsPendingLocalSource() async throws {
        let (store,scope)=try await boundStore()
        let bytes=Data(repeating:7,count:SyncWireRecord.assetBudget+1)
        let asset=try await store.assets.stage(data:bytes);_ = try await store.assets.finalize(asset)
        var content=PageContent();content.drawingAssetHash=asset.hash
        let note=try await store.createNote(title:"Budget fixture",contents:[content])
        let service=CloudKitSyncService(store:store,scope:scope)
        do {_ = try await service.prepareOutgoing();XCTFail("Oversize accepted")}
        catch let error as SyncWireRecord.BudgetExceeded {XCTAssertEqual(error.id,"asset-"+asset.hash)}
        let state=try await store.transportState(scope:scope);XCTAssertEqual(state.issues["asset-"+asset.hash]?.code,.oversize)
        let pending=try await store.pendingOperations(scope:scope);XCTAssertFalse(pending.isEmpty)
        let page=try await store.openPage(id:note.pages[0].id);XCTAssertEqual(page.content.drawingAssetHash,asset.hash)
        let retained=try await store.assets.read(hash:asset.hash);XCTAssertEqual(retained,bytes)
        do {try SyncWireRecord(id:"revision-"+UUID().uuidString,kind:.revision,bytes:Data("bad".utf8)).validate();XCTFail("Invalid body accepted")}
        catch is SyncWireRecord.BudgetExceeded {XCTFail("Malformed body mislabeled oversize")} catch {}
    }
}

extension SyncTests {
    func testNativeAccountEventsAllowVerifiedInitialSignInButInvalidateSwitch() async throws {
        let config=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development"),user=CKRecord.ID(recordName:"A")
        let fingerprint=try await CloudKitAccountDiscovery().discover(configuration:config,status:{.available},userID:{user})
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scope=try await store.bindAccountAfterConsent(fingerprint:fingerprint,container:config.container,environment:config.environment,expected:store.syncScope(),engineID:UUID())
        let service=CloudKitSyncService(store:store,scope:scope)
        try await service.accountChanged(.signIn(currentUser:user))
        let same=try await store.syncScope();XCTAssertEqual(same,scope)
        try await service.accountChanged(.switchAccounts(previousUser:user,currentUser:CKRecord.ID(recordName:"B")))
        let changed=try await store.syncScope();XCTAssertFalse(changed.enabled);XCTAssertEqual(changed.accountFingerprint,fingerprint)
        do {try await service.checkpoint(Data([1]));XCTFail("Old engine published after switch")} catch {}
    }
}

extension SyncTests {
    func testUnrelatedNativeZoneDeletionDoesNotBlockCheckpoint() async throws {
        let (store,scope)=try await boundStore(),service=CloudKitSyncService(store:store,scope:scope)
        try await service.deletedZones([CKRecordZone.ID(zoneName:"OtherFeature",ownerName:CKCurrentUserDefaultName)])
        try await service.checkpoint(Data([1]))
        let before=try await store.transportState(scope:scope);XCTAssertNil(before.issues["transport"])
        try await service.deletedZones([CloudKitRecordCodec.zoneID])
        do {try await service.checkpoint(Data([2]));XCTFail("Our deleted zone checkpointed")} catch {}
        let after=try await store.engineCheckpoint(scope:scope);XCTAssertEqual(after,Data([1]))
        let state=try await store.transportState(scope:scope);XCTAssertEqual(state.issues["transport"]?.code,.remoteDeletion)
    }
}

extension SyncTests {
    func testAccountAvailabilityPreservesStatusWithoutIdentityLookup() async throws {
        let config=try CloudKitConfiguration(container:"iCloud.de.meetingbook.app",environment:"development")
        for status:CKAccountStatus in [.noAccount,.restricted,.couldNotDetermine,.temporarilyUnavailable] {
            do {
                _ = try await CloudKitAccountDiscovery().discover(configuration:config,status:{status},userID:{throw NotebookError.invalidModel})
                XCTFail("Unavailable account accepted")
            } catch let error as CloudKitAccountDiscovery.AccountUnavailable {XCTAssertEqual(error.status,status)}
        }
    }
}

extension SyncTests {
    func testProviderFailureRollsBackOnlyUnsubmittedCapturesAndCanRetry() async throws {
        let (store,scope)=try await boundStore();_ = try await store.createNote(title:"Atomic provider")
        let service=CloudKitSyncService(store:store,scope:scope),wires=try await service.prepareOutgoing()
        XCTAssertGreaterThanOrEqual(wires.count,3)
        let ids=wires.prefix(3).map{CKRecord.ID(recordName:$0.id,zoneID:CloudKitRecordCodec.zoneID)}
        let initialPins=store.protection.snapshot.hashes
        let existingBatch=try await service.provide(pending:[.saveRecord(ids[2])],filter:.all)
        let existing=try XCTUnwrap(existingBatch?.recordsToSave.first)
        let existingFile=try XCTUnwrap((existing["body"] as? CKAsset)?.fileURL)
        let directory=existingFile.deletingLastPathComponent()
        let inFlightPins=store.protection.snapshot.hashes
        let originalFields=try await store.replaceWireFieldsForProviderTest(id:wires[1].id,fields:Data("malformed native archive".utf8),scope:scope)
        do {_ = try await service.provide(pending:[.saveRecord(ids[0]),.saveRecord(ids[1])],filter:.all);XCTFail("Malformed later record accepted")} catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[existingFile.lastPathComponent])
        XCTAssertEqual(store.protection.snapshot.hashes,inFlightPins,"Never-submitted capture kept its lease")
        XCTAssertTrue(FileManager.default.fileExists(atPath:existingFile.path))
        let stillSending=try await service.provide(pending:[.saveRecord(ids[2])],filter:.all);XCTAssertNil(stillSending)
        _ = try await store.replaceWireFieldsForProviderTest(id:wires[1].id,fields:originalFields,scope:scope)
        let retry=try await service.provide(pending:[.saveRecord(ids[0]),.saveRecord(ids[1])],filter:.all)
        let records=try XCTUnwrap(retry).recordsToSave
        XCTAssertEqual(Set(records.map(\.recordID)),Set(ids.prefix(2)),"First record stranded after failed proposal")
        try await service.saved([existing]+records)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty)
        XCTAssertEqual(store.protection.snapshot.hashes,initialPins)
    }
}
extension NotebookStore {
    func replaceWireFieldsForProviderTest(id:String,fields:Data,scope:SyncScope) throws -> Data {
        try requireScope(scope)
        let old=try get("sync-wire-"+id,as:StoredSyncWire.self)
        let replacement=StoredSyncWire(version:old.version,backingRecordKey:old.backingRecordKey,id:old.id,kind:old.kind,bodyHash:old.bodyHash,scope:old.scope,systemFields:fields)
        try transaction(journalChanges:false) {try put(replacement,key:"sync-wire-"+id,kind:"syncWire")}
        return old.systemFields
    }
}

extension SyncTests {
    func testTransportRetryDeadlineCannotBeShortenedAfterReopen() async throws {
        let (store,scope)=try await boundStore()
        let long=Date(timeIntervalSince1970:4_102_452_000),short=Date(timeIntervalSince1970:4_102_444_860)
        try await store.setTransportIssue("transport",issue:.init(code:.rateLimited,retryAfter:long),scope:scope)
        try await store.setTransportIssue("transport",issue:.init(code:.offline,retryAfter:short),scope:scope)
        let reopened=try await NotebookStore.open(root:store.root)
        let state=try await reopened.transportState(scope:scope)
        XCTAssertEqual(state.issues["transport"]?.retryAfter,long)
    }
}

extension SyncTests {
    func testDirectRefetchFailuresHonorServerRetryAfterAndKeepObligations() async throws {
        let (store,scope)=try await boundStore(),service=CloudKitSyncService(store:store,scope:scope)
        let now=Date(timeIntervalSince1970:4_102_444_800),bytes=Data("still requires a server body".utf8),hash=AssetStore.hash(bytes),id="asset-"+hash
        try await store.stageWireRefetch(id:id,kind:.asset,bodyHash:hash,scope:scope)
        let rateLimited=CKError(.requestRateLimited,userInfo:[CKErrorRetryAfterKey:NSNumber(value:3600)])
        XCTAssertEqual(rateLimited.retryAfterSeconds,3600)
        try await service.transportFailed(rateLimited,now:now)
        let first=try await store.transportState(scope:scope)
        XCTAssertEqual(first.issues["transport"]?.retryAfter,Date(timeIntervalSince1970:4_102_448_400))
        XCTAssertEqual(first.issues["transport"]?.code,.rateLimited)
        let unavailable=CKError(.serviceUnavailable,userInfo:[CKErrorRetryAfterKey:NSNumber(value:7200)])
        XCTAssertEqual(unavailable.retryAfterSeconds,7200)
        try await service.transportFailed(unavailable,now:now.addingTimeInterval(5))
        try await service.transportFailed(CKError(.networkFailure),now:now.addingTimeInterval(10))
        try await service.transportFailed(CKError(.quotaExceeded,userInfo:[CKErrorRetryAfterKey:NSNumber(value:10)]),id:id,now:now)
        let reopened=try await NotebookStore.open(root:store.root),state=try await reopened.transportState(scope:scope)
        XCTAssertEqual(state.issues["transport"]?.retryAfter,Date(timeIntervalSince1970:4_102_452_005))
        XCTAssertEqual(state.issues[id]?.retryAfter,Date(timeIntervalSince1970:4_102_444_860))
        XCTAssertEqual(state.issues[id]?.code,.quota)
        let pending=try await reopened.pendingWireRefetches(scope:scope);XCTAssertEqual(pending.map(\.id),[id])
    }
}


extension SyncTests {
    func testTimestampOperationHasTypedVersionedCompleteValue() throws {
        let value=Data(#"{"createdAt":null,"modifiedAt":-100}"#.utf8)
        let op=CausalOperation(version:2,id:UUID(),transactionID:UUID(),libraryID:UUID(),accountFingerprint:nil,entity:"note/"+UUID().uuidString+"/timestamps",bases:[],baseValueHash:nil,deviceID:UUID(),sequence:1,createdAt:Date(),value:value,valueHash:AssetStore.hash(value),revisions:[],assets:[])
        XCTAssertNoThrow(try op.validate())
        XCTAssertNoThrow(try op.validateWireValue())
    }
}


extension SyncTests {
    func timestampOperation(id:UUID=UUID(),bases:[UUID]=[],created:Date?=Date(timeIntervalSince1970:10),modified:Date?) throws -> CausalOperation {
        let bytes=try JSONEncoder().encode(NoteTimestampMetadata(createdAt:created,modifiedAt:modified))
        return CausalOperation(version:2,id:id,transactionID:UUID(),libraryID:UUID(),accountFingerprint:nil,entity:"note/00000000-0000-0000-0000-000000000001/timestamps",bases:bases,baseValueHash:nil,deviceID:UUID(),sequence:1,createdAt:Date(),value:bytes,valueHash:AssetStore.hash(bytes),revisions:[],assets:[])
    }
    func testTimestampProjectionUsesCausalMaximaThenUUIDAndRejectsConflictingCreation() throws {
        let base=try timestampOperation(modified:Date(timeIntervalSince1970:1000))
        let low=try timestampOperation(id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,bases:[base.id],modified:Date(timeIntervalSince1970:9999))
        let high=try timestampOperation(id:UUID(uuidString:"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,bases:[base.id],modified:Date(timeIntervalSince1970:-9999))
        let selected=try NoteTimestampMetadata.project([high,base,low])
        XCTAssertEqual(selected.modifiedAt,Date(timeIntervalSince1970:-9999))
        XCTAssertEqual(selected,try NoteTimestampMetadata.project([low,base,high]))
        let later=try timestampOperation(bases:[low.id,high.id],modified:Date(timeIntervalSince1970:-20000))
        XCTAssertEqual(try NoteTimestampMetadata.project([base,low,high,later]).modifiedAt,Date(timeIntervalSince1970:-20000))
        let contradiction=try timestampOperation(bases:[later.id],created:Date(timeIntervalSince1970:11),modified:nil)
        XCTAssertThrowsError(try NoteTimestampMetadata.project([base,low,high,later,contradiction]))
        XCTAssertThrowsError(try JSONDecoder().decode(NoteTimestampMetadata.self,from:Data(#"{"createdAt":null}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(NoteTimestampMetadata.self,from:Data(#"{"modifiedAt":null}"#.utf8)))
    }
    func forgedPriorHash(_ bytes:Data) throws -> Data {
        var json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        let operation=try JSONDecoder().decode(CausalOperation.self,from:bytes)
        guard operation.version==2 && operation.entity.hasPrefix("note/") else {return bytes}
        XCTAssertTrue(operation.bases.isEmpty)
        json["baseValueHash"]=String(repeating:"a",count:64)
        return try JSONSerialization.data(withJSONObject:json,options:.sortedKeys)
    }
    func testVersionedNewNoteCannotOmitTimestampMember() async throws {
        let (sender,scope)=try await boundStore()
        let bootstrap=try await sender.prepareWireOutbox(scope:scope)
        _ = try await sender.createNote(title:"Complete")
        let bootstrapIDs=Set(bootstrap.map(\.id))
        let wires=try removingTimestampMembers(await sender.prepareWireOutbox(scope:scope),legacy:false).filter{!bootstrapIDs.contains($0.id)}
        for forgeHash in [false,true] {
            let (receiver,receivedScope)=try await boundStore()
            try await deliver(bootstrap,to:receiver,scope:receivedScope)
            let originalNotes=try await receiver.listNotes(),originalHistory=try await receiver.journal()
            let incoming=try wires.map {wire in
                guard forgeHash,wire.kind == .operation else {return wire}
                return SyncWireRecord(id:wire.id,kind:wire.kind,bytes:try forgedPriorHash(wire.bytes))
            }
            do {try await deliver(incoming,to:receiver,scope:receivedScope);XCTFail("missing timestamp accepted; forged hash: \(forgeHash)")} catch {XCTAssertEqual(error as? NotebookError,.invalidModel)}
            let notes=try await receiver.listNotes(),history=try await receiver.journal()
            XCTAssertEqual(notes,originalNotes);XCTAssertEqual(history,originalHistory)
        }
    }
    func testStoredAndPackagedNewNoteRejectForgedPriorHashWithoutTimestamp() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        _ = try await store.createNote(title:"Forged package")
        let capture=try await store.captureBackup()
        let rows=try NotebookStore.importedRows(capture.files)
        let forged=try rows.compactMap {row -> NotebookStore.RecordRow? in
            guard row.kind=="causalOperation" else {return row}
            let operation=try JSONDecoder().decode(CausalOperation.self,from:row.payload)
            if operation.entity.hasSuffix("/timestamps") {return nil}
            return .init(key:row.key,kind:row.kind,payload:try forgedPriorHash(row.payload))
        }
        XCTAssertThrowsError(try NotebookStore.validateGraph(forged)) {XCTAssertEqual($0 as? NotebookError,.invalidModel)}
        var files=capture.files,envelope=try JSONSerialization.jsonObject(with:files["library.json"]!) as! [String:Any]
        envelope["technical"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(forged.filter{!["library","page","revision"].contains($0.kind)}))
        files["library.json"]=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
        XCTAssertThrowsError(try NotebookStore.validatePackageRecords(files)) {XCTAssertEqual($0 as? NotebookError,.invalidModel)}
        let destination=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let before=try await destination.snapshot()
        do {try await destination.activateRestore(files:files,expectedGeneration:AssetStore.hash(before),policy:.replace);XCTFail("forged package accepted")} catch {XCTAssertEqual(error as? NotebookError,.invalidModel)}
        let after=try await destination.snapshot();XCTAssertEqual(after,before)
        await store.assets.releasePin(capture.pin)
    }
    func testDelayedIndependentEditsPreserveDatesAndImmutableBytes() async throws {
        let (a,sa)=try await boundStore(),(b,sb)=try await boundStore()
        let note=try await a.createNote(title:"Two pages",contents:[PageContent(),PageContent()],now:Date(timeIntervalSince1970:200))
        let initial=try await a.prepareWireOutbox(scope:sa);try await deliver(initial.reversed(),to:b,scope:sb)
        let originalOperations=try await a.journal(),originalBytes=try await a.fullRevisionPayload(id:note.pages[0].currentRevisionID)
        for wire in initial {try await a.acknowledgeWire(wire,scope:sa,systemFields:Data())}
        var left=note.pages[0].content;left.style.ink="red"
        var right=note.pages[1].content;right.style.ink="blue"
        _ = try await a.commit(.init(pageID:note.pages[0].id,expectedRevisionID:note.pages[0].currentRevisionID,content:left),now:Date(timeIntervalSince1970:-300))
        _ = try await b.commit(.init(pageID:note.pages[1].id,expectedRevisionID:note.pages[1].currentRevisionID,content:right),now:Date(timeIntervalSince1970:9000))
        let wa=try await a.prepareWireOutbox(scope:sa),wb=try await b.prepareWireOutbox(scope:sb)
        try await deliver(wb.reversed(),to:a,scope:sa);try await deliver(wa.reversed(),to:b,scope:sb)
        let na=try await a.openNote(id:note.note.id),nb=try await b.openNote(id:note.note.id)
        XCTAssertEqual(na.note,nb.note);XCTAssertEqual(na.note.createdAt,note.note.createdAt)
        XCTAssertEqual(na.pages.map(\.content),[left,right]);XCTAssertEqual(nb.pages.map(\.content),[left,right])
        let history=try await a.journal();XCTAssertTrue(originalOperations.allSatisfy{history.contains($0)})
        let preserved=try await a.fullRevisionPayload(id:note.pages[0].currentRevisionID);XCTAssertEqual(preserved,originalBytes)
        let conflicts=try await a.syncConflicts();XCTAssertTrue(conflicts.isEmpty)
        let reopened=try await NotebookStore.open(root:a.root),durable=try await reopened.openNote(id:note.note.id);XCTAssertEqual(durable.note,na.note)
    }
}


extension SyncTests {
    func removingTimestampMembers(_ wires:[SyncWireRecord],legacy:Bool) throws -> [SyncWireRecord] {
        let decoder=JSONDecoder(),encoder=JSONEncoder()
        let removed=Set(try wires.filter{$0.kind == .operation}.map{try decoder.decode(CausalOperation.self,from:$0.bytes)}.filter{$0.entity.hasSuffix("/timestamps")}.map(\.id))
        return try wires.compactMap {wire in
            if wire.kind == .operation {
                var operation=try decoder.decode(CausalOperation.self,from:wire.bytes)
                if removed.contains(operation.id) {return nil}
                if legacy {operation.version=1}
                return SyncWireRecord(id:wire.id,kind:wire.kind,bytes:try encoder.encode(operation))
            }
            if wire.kind == .transaction {
                let manifest=try decoder.decode(SyncTransactionManifest.self,from:wire.bytes)
                return SyncWireRecord(id:wire.id,kind:wire.kind,bytes:try encoder.encode(SyncTransactionManifest(id:manifest.id,members:manifest.members.filter{!removed.contains($0)},context:manifest.context)))
            }
            return wire
        }
    }
    func testLegacyV1WireProjectionRemainsUnknownAndUnchanged() async throws {
        let (sender,scope)=try await boundStore(),(receiver,receivedScope)=try await boundStore()
        let note=try await sender.createNote(title:"Legacy wire")
        let wires=try removingTimestampMembers(await sender.prepareWireOutbox(scope:scope),legacy:true)
        try await deliver(wires.reversed(),to:receiver,scope:receivedScope)
        let restored=try await receiver.openNote(id:note.id);XCTAssertNil(restored.note.createdAt);XCTAssertNil(restored.note.modifiedAt)
        let journal=try await receiver.journal()
        for wire in wires where wire.kind == .operation {XCTAssertTrue(journal.contains(try JSONDecoder().decode(CausalOperation.self,from:wire.bytes)))}
        let reopened=try await NotebookStore.open(root:receiver.root),durable=try await reopened.openNote(id:note.id)
        XCTAssertEqual(durable.note,restored.note)
    }
    func testRepeatedAuthorDateStillPublishesCausallyLaterEvent() async throws {
        let (store,_)=try await boundStore(),date=Date(timeIntervalSince1970:100)
        let note=try await store.createNote(title:"Repeated clock",now:date),page=try await store.openPage(id:note.pageIDs[0])
        var content=page.content;content.style.ink="red"
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content),now:date)
        let events=try await store.journal().filter{$0.entity=="note/"+note.id.uuidString+"/timestamps"}
        XCTAssertEqual(events.count,2);XCTAssertEqual(events.last?.bases,[events[0].id]);XCTAssertEqual(events.last?.baseValueHash,events[0].valueHash)
    }
}
