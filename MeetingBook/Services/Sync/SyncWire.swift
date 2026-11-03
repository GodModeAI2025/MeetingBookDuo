import Foundation
import MeetingBookCore

struct SyncTransactionManifest: Codable, Sendable, Equatable {
    var version=2
    let id: UUID
    let members: [UUID]
    let context: SyncTransactionContext
    func validate() throws {
        try context.validate()
        guard version==2,context.id==id,members.count>0,members.count<=100_000,Set(members).count==members.count,members==members.sorted(by:{$0.uuidString<$1.uuidString}) else {throw NotebookError.invalidModel}
    }
}
struct SyncWireRecord: Sendable, Equatable {
    struct BudgetExceeded: Error, Sendable {let id:String}
    enum Kind: String, Codable, Sendable { case operation, transaction, revision, header, font, asset, conflict }
    var version=1
    let id: String
    let kind: Kind
    let bytes: Data
    // Application budget, not a claimed CloudKit native limit. Local saves/exports retain larger assets.
    static let assetBudget=50_000_000
    func validate() throws {
        guard version==1 else {throw NotebookError.unsupportedVersion}
        guard id.utf8.count<=128,id.hasPrefix(kind.rawValue+"-") else {throw NotebookError.invalidModel}
        let suffix=String(id.dropFirst(kind.rawValue.count+1)),decoder=JSONDecoder()
        guard kind == .asset ? PageContent.isHash(suffix) : UUID(uuidString:suffix)?.uuidString==suffix else {throw NotebookError.invalidModel}
        guard bytes.count<=Self.assetBudget else {throw BudgetExceeded(id:id)}
        if kind == .asset {guard PageContent.isHash(suffix),AssetStore.hash(bytes)==suffix else {throw NotebookError.hashMismatch};return}
        guard let uuid=UUID(uuidString:suffix),uuid.uuidString==suffix else {throw NotebookError.invalidModel}
        try ImportValidation.validateJSON(bytes)
        switch kind {
        case .conflict: let value=try decoder.decode(SyncConflict.self,from:bytes);try value.validate();guard value.id==uuid else {throw NotebookError.invalidModel}
        case .operation: let value=try decoder.decode(CausalOperation.self,from:bytes);try value.validate();try value.validateWireValue();guard value.id==uuid else {throw NotebookError.invalidModel}
        case .transaction: let value=try decoder.decode(SyncTransactionManifest.self,from:bytes);try value.validate();guard value.id==uuid else {throw NotebookError.invalidModel}
        case .revision:
            let value=try decoder.decode(PageRevision.self,from:bytes),encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            try value.content.validate();guard value.id==uuid,value.sequence>0,Set(value.parentRevisionIDs).count==value.parentRevisionIDs.count,!value.parentRevisionIDs.contains(uuid),AssetStore.hash(try encoder.encode(value.content))==value.contentHash else {throw NotebookError.invalidModel}
        case .header:
            let value=try decoder.decode(RevisionHeader.self,from:bytes)
            guard value.id==uuid,value.sequence>0,PageContent.isHash(value.contentHash),Set(value.parentRevisionIDs).count==value.parentRevisionIDs.count,!value.parentRevisionIDs.contains(uuid) else {throw NotebookError.invalidModel}
        case .font:
            let value=try decoder.decode(FontVersion.self,from:bytes)
            guard value.id==uuid,PageContent.isHash(value.assetHash),!value.postScriptName.isEmpty else {throw NotebookError.invalidModel};try value.metrics?.validate()
        case .asset: break
        }
    }
}
struct StoredSyncWire: Codable, Sendable {
    var version=1
    var backingRecordKey:String? = nil
    let id: String
    let kind: SyncWireRecord.Kind
    let bodyHash: String
    let scope: SyncScope
    let systemFields: Data
    func validate() throws {
        guard ((version==1 && backingRecordKey==nil) || (version==2 && backingRecordKey != nil)),PageContent.isHash(bodyHash),id.utf8.count<=128,id.hasPrefix(kind.rawValue+"-"),systemFields.count<=1_000_000 else {throw NotebookError.invalidModel}
        try scope.validate()
        let suffix=String(id.dropFirst(kind.rawValue.count+1))
        if kind == .asset {guard PageContent.isHash(suffix),suffix==bodyHash else {throw NotebookError.invalidModel}}
        else {guard let uuid=UUID(uuidString:suffix),uuid.uuidString==suffix else {throw NotebookError.invalidModel}}
        if let backingRecordKey {
            let expected:String
            switch kind {
            case .operation: expected="operation-"+suffix
            case .revision: expected=suffix
            case .conflict: expected="sync-conflict-"+suffix
            default: throw NotebookError.invalidModel
            }
            guard backingRecordKey==expected else {throw NotebookError.invalidModel}
        }
    }
}
struct SyncWireRefetch:Codable,Sendable,Equatable {
    var version=1
    let id:String
    let kind:SyncWireRecord.Kind
    let bodyHash:String
    let scope:SyncScope
    let systemFields:Data
    func validate() throws {
        guard version==1 else {throw NotebookError.unsupportedVersion}
        try StoredSyncWire(id:id,kind:kind,bodyHash:bodyHash,scope:scope,systemFields:systemFields).validate()
    }
}
struct ReceivedSyncWire: Sendable { let record: SyncWireRecord;let systemFields: Data }
struct SyncWireReceipt: Codable, Sendable {
    var version=1
    let id: String
    let bodyHash: String
    let scope: SyncScope
    let systemFields: Data
}

extension NotebookStore {
    func stageWire(_ wire: SyncWireRecord,systemFields: Data=Data(),scope: SyncScope) async throws {
        try requireScope(scope);guard scope.enabled else {throw NotebookError.revisionConflict};try wire.validate()
        if wire.kind == .operation {
            let operation=try decoder.decode(CausalOperation.self,from:wire.bytes)
            guard operation.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        }
        if wire.kind == .transaction {
            guard try decoder.decode(SyncTransactionManifest.self,from:wire.bytes).context.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        }
        if wire.kind == .conflict {
            guard try decoder.decode(SyncConflict.self,from:wire.bytes).accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        }
        try Self.validateMaterializedWireIdentity(wire,fonts:fontVersions(),readRecord:{try record($0)})
        let value=StoredSyncWire(id:wire.id,kind:wire.kind,bodyHash:AssetStore.hash(wire.bytes),scope:scope,systemFields:systemFields)
        try value.validate()
        let key="sync-wire-"+wire.id
        if let existing=try record(key) {
            let old=try decoder.decode(StoredSyncWire.self,from:existing)
            guard old.bodyHash==value.bodyHash,old.kind==value.kind else {throw NotebookError.invalidModel}
            try clearWireRefetch(value);return
        }
        let lease=protection.retain(hashes:[value.bodyHash]);defer{withExtendedLifetime(lease){}}
        let staged=try await assets.stage(data:wire.bytes,expectedHash:value.bodyHash);try requireScope(scope)
        _ = try await assets.finalize(staged);try requireScope(scope)
        try transaction(journalChanges:false) {
            try Self.validateMaterializedWireIdentity(wire,fonts:fontVersions(),readRecord:{try record($0)})
            if let existing=try record(key) {guard try decoder.decode(StoredSyncWire.self,from:existing).bodyHash==value.bodyHash else {throw NotebookError.invalidModel}}
            else {try put(value,key:key,kind:"syncWire")}
            try removeMatchingRefetch(value)
            if wire.kind == .transaction {
                let manifests=try records("syncWire").compactMap { data -> SyncTransactionManifest? in
                    let stored=try decoder.decode(StoredSyncWire.self,from:data)
                    guard stored.kind == .transaction else {return nil}
                    return try decoder.decode(SyncTransactionManifest.self,from:AssetStore.verifiedData(hash:stored.bodyHash,root:root.appendingPathComponent("assets")))
                }
                try Self.validateStagedManifestGraph(manifests,contexts:transactionContexts(),operations:journal(),account:scope.accountFingerprint)
            }
        }
    }
    private func removeMatchingRefetch(_ wire:StoredSyncWire) throws {
        let key="sync-refetch-"+wire.id
        if let bytes=try record(key) {
            let pending=try decoder.decode(SyncWireRefetch.self,from:bytes)
            guard pending.kind==wire.kind,pending.bodyHash==wire.bodyHash else {throw NotebookError.invalidModel}
            try removeRecord(key)
        }
    }
    private func clearWireRefetch(_ wire:StoredSyncWire) throws {
        if try record("sync-refetch-"+wire.id) != nil {try transaction(journalChanges:false) {try removeMatchingRefetch(wire)}}
    }
    /// Persist before checkpointing an event whose asset URL/body is unavailable.
    func stageWireRefetch(id:String,kind:SyncWireRecord.Kind,bodyHash:String,systemFields:Data=Data(),scope:SyncScope) throws {
        try requireScope(scope);guard scope.enabled else {throw NotebookError.revisionConflict}
        let value=SyncWireRefetch(id:id,kind:kind,bodyHash:bodyHash,scope:scope,systemFields:systemFields);try value.validate()
        if let bytes=try record("sync-wire-"+id) {
            let stored=try decoder.decode(StoredSyncWire.self,from:bytes)
            guard stored.bodyHash==bodyHash,stored.kind==kind else {throw NotebookError.invalidModel};return
        }
        let key="sync-refetch-"+id
        try transaction(journalChanges:false) {
            if let bytes=try record(key) {
                let old=try decoder.decode(SyncWireRefetch.self,from:bytes)
                guard old.bodyHash==bodyHash,old.kind==kind else {throw NotebookError.invalidModel}
            }
            try put(value,key:key,kind:"syncRefetch")
        }
    }
    func pendingWireRefetches(scope:SyncScope,limit:Int=250) throws -> [SyncWireRefetch] {
        try requireScope(scope);guard (1...250).contains(limit) else {throw NotebookError.invalidModel}
        return Array(try records("syncRefetch").map{try decoder.decode(SyncWireRefetch.self,from:$0)}.sorted{$0.id<$1.id}.prefix(limit))
    }
    func wireRecords(scope: SyncScope) throws -> [ReceivedSyncWire] {
        try requireScope(scope)
        return try records("syncWire").map { bytes in
            let value=try decoder.decode(StoredSyncWire.self,from:bytes);try value.validate()
            guard value.scope.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
            let body:Data
            if let key=value.backingRecordKey {guard let bytes=try record(key),AssetStore.hash(bytes)==value.bodyHash else {throw NotebookError.hashMismatch};body=bytes}
            else {body=try AssetStore.verifiedData(hash:value.bodyHash,root:root.appendingPathComponent("assets"))}
            let wire=SyncWireRecord(id:value.id,kind:value.kind,bytes:body)
            try wire.validate();return ReceivedSyncWire(record:wire,systemFields:value.systemFields)
        }
    }
}


extension NotebookStore {
    /// Deduplicate acknowledged wire bodies only against byte-identical immutable local records.
    /// The ordinary collector owns blob deletion and its grace period; no source history is removed.
    func retireWireCache(scope:SyncScope,limit:Int=250) throws -> Int {
        try requireScope(scope);guard (1...250).contains(limit) else {throw NotebookError.invalidModel}
        let history=try journal(),wires=try records("syncWire").map{try decoder.decode(StoredSyncWire.self,from:$0)}.sorted{$0.id<$1.id}
        return try transaction(journalChanges:false) {
            var count=0
            for var wire in wires where wire.backingRecordKey==nil && count<limit {
                let suffix=String(wire.id.dropFirst(wire.kind.rawValue.count+1)),key:String
                let received:Bool
                switch wire.kind {
                case .operation:
                    key="operation-"+suffix;received=try record("ack-"+suffix) != nil
                case .revision:
                    key=suffix
                    received = try record("sync-delivered-"+wire.id) != nil || history.contains { operation in
                        guard operation.revisions.contains(where:{$0.uuidString==suffix}) else {return false}
                        return try record("ack-"+operation.id.uuidString) != nil
                    }
                case .conflict:
                    key="sync-conflict-"+suffix
                    if let bytes=try record(key) {received=try decoder.decode(SyncConflict.self,from:bytes).operationIDs.allSatisfy{try record("ack-"+$0.uuidString) != nil}}
                    else {received=false}
                default: continue
                }
                guard received,let bytes=try record(key),AssetStore.hash(bytes)==wire.bodyHash else {continue}
                try SyncWireRecord(id:wire.id,kind:wire.kind,bytes:bytes).validate()
                wire.version=2;wire.backingRecordKey=key;try wire.validate()
                try put(wire,key:"sync-wire-"+wire.id,kind:"syncWire");count+=1
            }
            return count
        }
    }
}

extension NotebookStore {
    /// Disk/package trust boundary. Incomplete staged closure is allowed; malformed evidence is not.
    static func validateStoredWireBodies(_ rows:[RecordRow],fonts:[FontVersion],readAsset:(String)throws->Data) throws {
        let decoder=JSONDecoder(),byKey=Dictionary(uniqueKeysWithValues:rows.map{($0.key,$0)})
        let contexts=try rows.filter{$0.kind=="syncContext"}.map{try decoder.decode(SyncTransactionContext.self,from:$0.payload)}
        let operations=try rows.filter{$0.kind=="causalOperation"}.map{try decoder.decode(CausalOperation.self,from:$0.payload)}
        let operationsByID=Dictionary(uniqueKeysWithValues:operations.map{($0.id,$0)})
        var manifests:[SyncTransactionManifest]=[]
        var account:String?
        for row in rows where row.kind=="syncWire" {
            let value=try decoder.decode(StoredSyncWire.self,from:row.payload);try value.validate()
            let bytes:Data
            if let key=value.backingRecordKey {guard let backing=byKey[key] else {throw NotebookError.invalidModel};bytes=backing.payload}
            else {bytes=try readAsset(value.bodyHash)}
            guard AssetStore.hash(bytes)==value.bodyHash else {throw NotebookError.hashMismatch}
            let wire=SyncWireRecord(id:value.id,kind:value.kind,bytes:bytes)
            try wire.validate()
            try validateMaterializedWireIdentity(wire,fonts:fonts,readRecord:{byKey[$0]?.payload})
            account=value.scope.accountFingerprint
            switch value.kind {
            case .operation:
                let operation=try decoder.decode(CausalOperation.self,from:bytes)
                guard operation.accountFingerprint==account else {throw NotebookError.invalidModel}
                if let existing=operationsByID[operation.id] {guard existing==operation else {throw NotebookError.invalidModel}}
            case .transaction:
                let manifest=try decoder.decode(SyncTransactionManifest.self,from:bytes)
                guard manifest.context.accountFingerprint==account else {throw NotebookError.invalidModel}
                manifests.append(manifest)
            case .conflict:
                guard try decoder.decode(SyncConflict.self,from:bytes).accountFingerprint==account else {throw NotebookError.invalidModel}
            default: break
            }
        }
        try validateStagedManifestGraph(manifests,contexts:contexts,operations:operations,account:account ?? contexts.first?.accountFingerprint)
    }
    /// Shared by accepted-inbox publication and disk/package validation; missing ancestry is allowed.
    static func validateStagedManifestGraph(_ manifests:[SyncTransactionManifest],contexts:[SyncTransactionContext],operations:[CausalOperation],account:String?) throws {
        for manifest in manifests {
            try manifest.validate()
            if let context=contexts.first(where:{$0.id==manifest.id}) {
                guard context==manifest.context,Set(manifest.members)==Set(operations.filter{$0.transactionID==manifest.id}.map(\.id)) else {throw NotebookError.invalidModel}
            }
        }
        try SyncTransactionContext.validatePartialGraph(contexts+manifests.map(\.context),account:account)
    }
}


extension NotebookStore {
    static func validateMaterializedWireIdentity(_ wire:SyncWireRecord,fonts:[FontVersion],readRecord:(String)throws->Data?) throws {
        let decoder=JSONDecoder(),suffix=String(wire.id.dropFirst(wire.kind.rawValue.count+1))
        switch wire.kind {
        case .revision,.header:
            let incoming=wire.kind == .revision ? RevisionHeader(try decoder.decode(PageRevision.self,from:wire.bytes)) : try decoder.decode(RevisionHeader.self,from:wire.bytes)
            if let bytes=try readRecord(suffix) {
                if let revision=try? decoder.decode(PageRevision.self,from:bytes) {
                    guard RevisionHeader(revision)==incoming else {throw NotebookError.invalidModel}
                    if wire.kind == .revision {guard try decoder.decode(PageRevision.self,from:wire.bytes)==revision else {throw NotebookError.invalidModel}}
                } else {guard try decoder.decode(RevisionHeader.self,from:bytes)==incoming else {throw NotebookError.invalidModel}}
            }
        case .font:
            let incoming=try decoder.decode(FontVersion.self,from:wire.bytes)
            if let existing=fonts.first(where:{$0.id==incoming.id}) {guard existing==incoming else {throw NotebookError.invalidModel}}
        case .conflict:
            if let bytes=try readRecord("sync-conflict-"+suffix) {guard try decoder.decode(SyncConflict.self,from:bytes)==decoder.decode(SyncConflict.self,from:wire.bytes) else {throw NotebookError.invalidModel}}
        case .operation:
            if let bytes=try readRecord("operation-"+suffix) {guard try decoder.decode(CausalOperation.self,from:bytes)==decoder.decode(CausalOperation.self,from:wire.bytes) else {throw NotebookError.invalidModel}}
        default: break
        }
    }
}
