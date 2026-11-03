import Foundation
import CloudKit
import MeetingBookCore

struct CloudKitConfiguration: Sendable {
    let container:String
    let environment:String
    /// Build/signing configuration; release QA must compare it to actual signed entitlements.
    init(container:String?,environment:String?) throws {
        guard container=="iCloud.de.meetingbook.app",let environment,["development","production"].contains(environment) else {throw NotebookError.invalidModel}
        self.container=container!;self.environment=environment
    }
    func validate(_ scope:SyncScope) throws {
        try scope.validate()
        guard scope.container==container,scope.environment==environment,scope.enabled,scope.engineID != nil else {throw NotebookError.revisionConflict}
    }
}

/// Codes only, never payloads or native error descriptions in persistent diagnostics.
struct SyncTransportState: Codable, Sendable {
    enum Code:String,Codable,Sendable {case offline,quota,rateLimited,oversize,serverVerification,collision,service,invalidDelivery,missingProvider,remoteDeletion}
    struct Verification:Codable,Sendable {
        let id:String;let kind:SyncWireRecord.Kind;let hash:String;let systemFields:Data
    }
    struct Issue:Codable,Sendable {
        let code:Code;let retryAfter:Date?
        var verification:Verification? = nil
    }
    var version=1
    let scope:SyncScope
    var batchLimit=250
    var issues:[String:Issue]=[:]
    func validate() throws {
        try scope.validate()
        guard version==1,(1...250).contains(batchLimit),issues.count<=100_000,
              issues.allSatisfy({$0.key.utf8.count<=128 && ($0.value.retryAfter?.timeIntervalSince1970.isFinite ?? true)}) else {throw NotebookError.invalidModel}
        for (id,issue) in issues {
            guard (issue.code == .serverVerification)==(issue.verification != nil) else {throw NotebookError.invalidModel}
            if let value=issue.verification {
                guard id==value.id else {throw NotebookError.invalidModel}
                try StoredSyncWire(id:value.id,kind:value.kind,bodyHash:value.hash,scope:scope,systemFields:value.systemFields).validate()
            }
        }
    }
}

extension NotebookStore {
    func transportState(scope:SyncScope) throws -> SyncTransportState {
        try requireScope(scope)
        guard let bytes=try record("sync-transport") else {return SyncTransportState(scope:scope)}
        let old=try decoder.decode(SyncTransportState.self,from:bytes);try old.validate()
        guard old.scope.libraryID==scope.libraryID,old.scope.accountFingerprint==scope.accountFingerprint,old.scope.container==scope.container,old.scope.environment==scope.environment else {throw NotebookError.invalidModel}
        var state=SyncTransportState(scope:scope);state.batchLimit=old.batchLimit;state.issues=old.issues;return state
    }
    func saveTransportState(_ state:SyncTransportState) throws {
        try requireScope(state.scope);try state.validate()
        try transaction(journalChanges:false) {try put(state,key:"sync-transport",kind:"syncTransport")}
    }
    func setTransportIssue(_ id:String,issue:SyncTransportState.Issue?,scope:SyncScope) throws {
        var state=try transportState(scope:scope),next=issue
        if let proposed=issue,let deadline=proposed.retryAfter,let outstanding=state.issues[id]?.retryAfter,outstanding>deadline {
            next = .init(code:proposed.code,retryAfter:outstanding,verification:proposed.verification)
        }
        state.issues[id]=next;try saveTransportState(state)
    }
    func reduceTransportBatch(count:Int,scope:SyncScope) throws {
        var state=try transportState(scope:scope)
        state.batchLimit=max(1,min(state.batchLimit/2,count/2));try saveTransportState(state)
    }
}

/// Constructing the service performs no account requests and creates no engine.
/// Each instance owns exactly one scope/generation; account changes permanently invalidate it.
actor CloudKitSyncService: CKSyncEngineDelegate {
    let store:NotebookStore
    let scope:SyncScope
    private let codec=CloudKitRecordCodec()
    private let accountEpoch=CloudKitAccountEpoch()
    private var accountToken:UUID?
    private var engine:CKSyncEngine?
    private var database:CKDatabase?
    private var active=true
    private var checkpointBlocked=false
    private var requesting=false
    private var connecting=false
    private var eventBusy=false
    private var eventWaiters:[CheckedContinuation<Void,Never>]=[]
    private struct Sending {let wire:SyncWireRecord;let file:URL;let lease:StorageLease;var batchCount:Int}
    private var sending:[String:Sending]=[:]
    private var outgoing:[String:SyncWireRecord]=[:]
    var requiresRestart:Bool {checkpointBlocked}
    var isConnected:Bool {active && engine != nil}
    init(store:NotebookStore,scope:SyncScope) {self.store=store;self.scope=scope}
    private func check() async throws {
        guard active,accountToken.map({$0==accountEpoch.read()}) ?? true else {throw NotebookError.revisionConflict}
        try await store.requireScope(scope)
        guard active,accountToken.map({$0==accountEpoch.read()}) ?? true else {throw NotebookError.revisionConflict}
    }
    private func enterEvent() async {
        if eventBusy {await withCheckedContinuation {eventWaiters.append($0)}} else {eventBusy=true}
    }
    private func leaveEvent() {
        if eventWaiters.isEmpty {eventBusy=false} else {eventWaiters.removeFirst().resume()}
    }
    /// Explicitly authorized connection only. Inspection always discards serialized send state.
    func connect(configuration:CloudKitConfiguration,accountFingerprint:String) async throws {
        try configuration.validate(scope)
        guard scope.accountFingerprint==accountFingerprint,engine==nil,!connecting else {throw NotebookError.revisionConflict}
        connecting=true;defer{connecting=false}
        try await check()
        accountToken=accountEpoch.read()
        let discovered=try await CloudKitAccountDiscovery().discover(configuration:configuration);try await check()
        guard discovered==accountFingerprint else {throw NotebookError.revisionConflict}
        let bytes = scope.receiveOnly==true ? nil : try await store.engineCheckpoint(scope:scope)
        try await check()
        let serialization=try bytes.map {try JSONDecoder().decode(CKSyncEngine.State.Serialization.self,from:$0)}
        let db=CKContainer(identifier:configuration.container).privateCloudDatabase
        var config=CKSyncEngine.Configuration(database:db,stateSerialization:serialization,delegate:self)
        config.automaticallySync=false
        let native=CKSyncEngine(config)
        // Durable producer intent is authoritative. Never replay deletes or another zone from a cursor.
        native.state.remove(pendingRecordZoneChanges:native.state.pendingRecordZoneChanges)
        native.state.remove(pendingDatabaseChanges:native.state.pendingDatabaseChanges)
        database=db;engine=native
    }
    /// Never invoked inside a delegate handler; refetch obligations survive process death.
    func requestSync() async throws {
        try await check()
        guard let engine,let database,!requesting,!checkpointBlocked else {throw NotebookError.revisionConflict}
        requesting=true;defer{requesting=false}
        let stateBeforeRequest=try await store.transportState(scope:scope);try await check()
        if let until=stateBeforeRequest.issues["transport"]?.retryAfter,until>Date() {throw CKError(.requestRateLimited)}
        if stateBeforeRequest.issues["transport"]?.code == .oversize {throw CKError(.limitExceeded)}
        var refetchBatchCount=0
        do {
            // Create the fixed private zone only after upload consent, including first enable.
            if scope.receiveOnly != true {
                engine.state.add(pendingDatabaseChanges:[.saveZone(CKRecordZone(zoneID:CloudKitRecordCodec.zoneID))])
                try await engine.sendChanges(.init(scope:.zoneIDs([CloudKitRecordCodec.zoneID])));try await check()
            }
            try await engine.fetchChanges(.init(scope:.zoneIDs([CloudKitRecordCodec.zoneID])));try await check()
            let refetches=try await store.pendingWireRefetches(scope:scope);try await check()
            let state=try await store.transportState(scope:scope);try await check()
            let verification=state.issues.filter{$0.value.code == .serverVerification}.map(\.key)
            let ids=Array(Set(refetches.map(\.id)+verification)).sorted().prefix(state.batchLimit)
            if !ids.isEmpty {
                refetchBatchCount=ids.count
                let values=try await database.records(for:ids.map{CKRecord.ID(recordName:$0,zoneID:CloudKitRecordCodec.zoneID)})
                try await check();refetchBatchCount=0
                for id in ids {
                    guard let result=values[CKRecord.ID(recordName:id,zoneID:CloudKitRecordCodec.zoneID)] else {continue}
                    switch result {
                    case .success(let record): try await receive([record]);try await check()
                    case .failure(let error): try await transportFailed(error);try await check()
                    }
                }
            }
            _ = try await store.reconcileWire(scope:scope);try await check()
            if scope.receiveOnly != true {
                let records=try await prepareOutgoing();try await check()
                engine.state.add(pendingRecordZoneChanges:records.map{.saveRecord(CKRecord.ID(recordName:$0.id,zoneID:CloudKitRecordCodec.zoneID))})
                try await engine.sendChanges(.init(scope:.zoneIDs([CloudKitRecordCodec.zoneID])));try await check()
            }
        } catch {
            if active {
                if let budget=error as? SyncWireRecord.BudgetExceeded {try? await issue(budget.id,code:.oversize)}
                else if (error as? CKError)?.code == .limitExceeded,refetchBatchCount>0 {
                    if refetchBatchCount>1 {try? await store.reduceTransportBatch(count:refetchBatchCount,scope:scope)}
                    else {try? await issue("transport",code:.oversize)}
                } else {try? await transportFailed(error)}
            }
            throw error
        }
    }
    func retryTransportIssue(_ id:String) async throws {
        try await check();let state=try await store.transportState(scope:scope);try await check()
        guard let value=state.issues[id],[.offline,.quota,.rateLimited,.oversize,.service,.missingProvider].contains(value.code) else {throw NotebookError.invalidModel}
        try await clearIssue(id)
    }
    /// Consent coordinator only: stop this adapter while preserving the inspected graph/scope CAS.
    func disconnect() async {
        active=false
        let native=engine;engine=nil;database=nil
        await native?.cancelOperations();releaseAll()
    }
    func disable() async throws {
        guard active else {return}
        active=false
        let native=engine;engine=nil;database=nil
        do {_ = try await store.disableKeepingLocalData(expected:scope)}
        catch {await native?.cancelOperations();releaseAll();throw error}
        await native?.cancelOperations();releaseAll()
    }
    private func releaseAll() {
        for item in sending.values {try? FileManager.default.removeItem(at:item.file)}
        sending.removeAll();outgoing.removeAll()
    }
    func prepareOutgoing() async throws -> [SyncWireRecord] {
        try await check();guard scope.receiveOnly != true else {throw NotebookError.revisionConflict}
        let prior=try await store.transportState(scope:scope);try await check()
        if let blocked=prior.issues.first(where:{$0.value.code == .oversize}) {throw SyncWireRecord.BudgetExceeded(id:blocked.key)}
        let wires:[SyncWireRecord]
        do {wires=try await store.prepareWireOutbox(scope:scope);try await check()}
        catch let error as SyncWireRecord.BudgetExceeded {try await issue(error.id,code:.oversize);throw error}
        outgoing=Dictionary(uniqueKeysWithValues:wires.map{($0.id,$0)})
        let state=try await store.transportState(scope:scope);try await check()
        for wire in wires where state.issues[wire.id]?.code == .missingProvider {try await clearIssue(wire.id);try await check()}
        return wires
    }
    func provide(pending:[CKSyncEngine.PendingRecordZoneChange],filter:CKSyncEngine.SendChangesOptions.Scope) async throws -> CKSyncEngine.RecordZoneChangeBatch? {
        try await check();guard scope.receiveOnly != true else {return nil}
        let state=try await store.transportState(scope:scope);try await check()
        let cache=try await store.wireRecords(scope:scope);try await check()
        let fields=Dictionary(uniqueKeysWithValues:cache.map{($0.record.id,$0.systemFields)})
        let directory=store.root.appendingPathComponent("transfers/cloudkit-"+(scope.engineID?.uuidString ?? UUID().uuidString));try await check()
        var records:[CKRecord]=[],proposed:[String:Sending]=[:],published=false
        defer {if !published {for capture in proposed.values {try? FileManager.default.removeItem(at:capture.file)}}}
        let eligible=pending.filter{change in
            guard filter.contains(change),case .saveRecord(let id)=change,id.zoneID==CloudKitRecordCodec.zoneID else {return false}
            if let issue=state.issues[id.recordName] {return issue.retryAfter.map{$0<=Date()} ?? false}
            return true
        }.prefix(state.batchLimit)
        // Complete awaited diagnostics before staging any candidate; publication below cannot suspend.
        for change in eligible {
            if case .saveRecord(let id)=change,outgoing[id.recordName]==nil {try await issue(id.recordName,code:.missingProvider);try await check()}
        }
        for change in eligible {
            guard case .saveRecord(let id)=change,let wire=outgoing[id.recordName] else {continue}
            guard sending[wire.id]==nil,proposed[wire.id]==nil else {continue}
            let lease=store.protection.retain(hashes:[AssetStore.hash(wire.bytes)])
            let encoded=try codec.encode(wire,systemFields:fields[wire.id] ?? Data(),directory:directory)
            records.append(encoded.record)
            proposed[wire.id]=Sending(wire:wire,file:encoded.file,lease:lease,batchCount:eligible.count)
        }
        guard !records.isEmpty else {return nil}
        for (id,candidate) in proposed {var capture=candidate;capture.batchCount=records.count;sending[id]=capture}
        published=true
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave:records,recordIDsToDelete:[],atomicByZone:false)
    }
    func receive(_ records:[CKRecord]) async throws {
        await enterEvent();defer{leaveEvent()}
        do {
            try await check()
            for record in records {
                let info=try codec.metadata(record),fields=try codec.systemFields(record)
                let state=try await store.transportState(scope:scope);try await check()
                let verification=state.issues[info.id]?.verification
                if let wire=try codec.decode(record) {
                    if let verification {
                        guard verification.kind==wire.kind,verification.hash==AssetStore.hash(wire.bytes) else {try await issue(info.id,code:.collision);throw NotebookError.hashMismatch}
                        let stored=try await store.wireRecords(scope:scope);try await check()
                        guard let local=stored.first(where:{$0.record.id==wire.id})?.record,local==wire else {
                            try await issue(info.id,code:.collision);throw NotebookError.hashMismatch
                        }
                        try await store.acknowledgeWire(local,scope:scope,systemFields:fields);try await check()
                        try await clearIssue(info.id);try await check()
                    } else {try await store.stageWire(wire,systemFields:fields,scope:scope);try await check()}
                } else {
                    if verification==nil {try await store.stageWireRefetch(id:info.id,kind:info.kind,bodyHash:info.hash,systemFields:fields,scope:scope);try await check()}
                }
            }
        } catch {checkpointBlocked=true;throw error}
    }
    func checkpoint(_ bytes:Data) async throws {
        await enterEvent();defer{leaveEvent()}
        try await check();guard !checkpointBlocked else {throw NotebookError.invalidModel}
        do {try await store.checkpointEngine(bytes,scope:scope);try await check()} catch {checkpointBlocked=true;throw error}
    }
    func saved(_ records:[CKRecord]) async throws {
        await enterEvent();defer{leaveEvent()}
        try await check();guard scope.receiveOnly != true else {throw NotebookError.revisionConflict}
        for record in records {
            let info=try codec.metadata(record)
            guard let captured=sending[info.id],AssetStore.hash(captured.wire.bytes)==info.hash else {throw NotebookError.invalidModel}
            try await store.acknowledgeWire(captured.wire,scope:scope,systemFields:codec.systemFields(record));try await check()
            try await clearIssue(info.id);try await check()
            sending.removeValue(forKey:info.id);outgoing.removeValue(forKey:info.id)
            try? FileManager.default.removeItem(at:captured.file)
        }
    }
    func failed(_ record:CKRecord,error:CKError) async throws {
        try await check();guard scope.receiveOnly != true else {throw NotebookError.revisionConflict}
        let info=try codec.metadata(record),id=info.id
        guard let capture=sending[id],AssetStore.hash(capture.wire.bytes)==info.hash else {throw NotebookError.invalidModel}
        if error.code == .limitExceeded {
            let count=capture.batchCount
            if count>1 {try await store.reduceTransportBatch(count:count,scope:scope);try await check()}
            else {try await issue(id,code:.oversize)}
        } else if error.code == .serverRecordChanged {
            // Server error assets may be nil. Metadata equality is never delivery evidence.
            let server=error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            if let server {guard server.recordID==record.recordID,server.recordType==CloudKitRecordCodec.recordType else {throw NotebookError.invalidModel}}
            let obligation=SyncTransportState.Verification(id:id,kind:capture.wire.kind,hash:AssetStore.hash(capture.wire.bytes),systemFields:try server.map(codec.systemFields) ?? Data())
            try await store.setTransportIssue(id,issue:.init(code:.serverVerification,retryAfter:nil,verification:obligation),scope:scope);try await check()
        } else {
            try await transportFailed(error,id:id)
        }
        if let captured=sending.removeValue(forKey:id) {try? FileManager.default.removeItem(at:captured.file)}
    }
    /// Shared by direct per-record fetch failures and native events. The store preserves the longest deadline atomically.
    func transportFailed(_ error:Error,id:String="transport",now:Date=Date()) async throws {
        let requested=(error as? CKError)?.retryAfterSeconds ?? 60
        let delay=requested.isFinite ? max(60,requested) : 60
        try await issue(id,code:Self.errorCode(error),retryAfter:now.addingTimeInterval(delay))
    }
    private static func errorCode(_ error:Error) -> SyncTransportState.Code {
        guard let error=error as? CKError else {return .service}
        switch error.code {
        case .networkUnavailable,.networkFailure: return .offline
        case .quotaExceeded: return .quota
        case .requestRateLimited,.serviceUnavailable,.zoneBusy: return .rateLimited
        default: return .service
        }
    }
    private func issue(_ id:String,code:SyncTransportState.Code,retryAfter:Date?=nil) async throws {
        try await check()
        try await store.setTransportIssue(id,issue:.init(code:code,retryAfter:retryAfter),scope:scope);try await check()
    }
    private func clearIssue(_ id:String) async throws {
        try await store.setTransportIssue(id,issue:nil,scope:scope);try await check()
    }
    func deletedZones(_ ids:[CKRecordZone.ID]) async throws {
        await enterEvent();defer{leaveEvent()}
        try await check();guard ids.contains(CloudKitRecordCodec.zoneID) else {return}
        checkpointBlocked=true;try await issue("transport",code:.remoteDeletion)
    }
    func accountChanged(_ change:CKSyncEngine.Event.AccountChange.ChangeType) async throws {
        guard active else {return}
        if case .signIn(let user)=change,accountToken.map({$0==accountEpoch.read()}) ?? true {
            let config=try CloudKitConfiguration(container:scope.container,environment:scope.environment)
            if try CloudKitAccountDiscovery.fingerprint(user:user,configuration:config)==scope.accountFingerprint {try await check();return}
        }
        active=false;let native=engine;engine=nil;database=nil
        defer {Task {await native?.cancelOperations();self.releaseAll()}}
        _ = try await store.disableKeepingLocalData(expected:scope)
    }
    func handleEvent(_ event:CKSyncEngine.Event,syncEngine:CKSyncEngine) async {
        guard active,engine===syncEngine else {return}
        do {
            switch event {
            case .stateUpdate(let update): try await checkpoint(JSONEncoder().encode(update.stateSerialization))
            case .accountChange(let change): try await accountChanged(change.changeType)
            case .fetchedRecordZoneChanges(let changes):
                try await receive(changes.modifications.map(\.record))
                try await deletedZones(changes.deletions.map{ $0.recordID.zoneID })
            case .sentRecordZoneChanges(let changes):
                try await saved(changes.savedRecords)
                for failure in changes.failedRecordSaves {try await failed(failure.record,error:failure.error)}
            case .fetchedDatabaseChanges(let changes):
                try await deletedZones(changes.deletions.map(\.zoneID))
            case .sentDatabaseChanges(let changes):
                for failure in changes.failedZoneSaves {try await transportFailed(failure.error)}
            case .didFetchRecordZoneChanges(let changes):
                if let error=changes.error {try await transportFailed(error)}
            default: break
            }
        } catch {
            checkpointBlocked=true
            if active {try? await issue("transport",code:.invalidDelivery)}
        }
    }
    func nextRecordZoneChangeBatch(_ context:CKSyncEngine.SendChangesContext,syncEngine:CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard active,engine===syncEngine,scope.receiveOnly != true else {return nil}
        do {return try await provide(pending:syncEngine.state.pendingRecordZoneChanges,filter:context.options.scope)}
        catch {if active {try? await transportFailed(error)};return nil}
    }
    func nextFetchChangesOptions(_ context:CKSyncEngine.FetchChangesContext,syncEngine:CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope:.zoneIDs(active && engine===syncEngine ? [CloudKitRecordCodec.zoneID] : []))
    }
}


extension ColdRecoveryService {
    /// Creates and binds a fresh owned candidate; does not activate it or construct a native engine.
    func createCloudInspectionCandidate(configuration:CloudKitConfiguration,fingerprint:String) async throws -> OwnedLibrary {
        let candidate=try await createOwnedLibrary()
        _ = try await candidate.store.bindForCloudInspection(fingerprint:fingerprint,container:configuration.container,environment:configuration.environment,expected:candidate.store.syncScope(),engineID:UUID())
        return candidate
    }
}
