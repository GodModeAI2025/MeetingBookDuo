import Foundation
import MeetingBookCore

extension NotebookStore {
    func prepareWireOutbox(scope: SyncScope) async throws -> [SyncWireRecord] {
        let capture=try capturePending(scope:scope)
        defer {withExtendedLifetime(capture){}}
        let all=try journal().filter{$0.accountFingerprint==scope.accountFingerprint}
        let byID=Dictionary(uniqueKeysWithValues:all.map{($0.id,$0)})
        var selected=Set<UUID>(),queue=capture.operations.map(\.id)
        while let id=queue.popLast() {
            guard selected.insert(id).inserted else {continue}
            guard let value=byID[id] else {throw NotebookError.invalidModel}
            queue+=value.bases
            queue+=all.filter{$0.transactionID==value.transactionID}.map(\.id)
            let context=try contextForPublication(value.transactionID,journal:all)
            for dependency in context.dependencies {queue+=all.filter{$0.transactionID==dependency}.map(\.id)}
        }
        let selectedOperations=all.filter{selected.contains($0.id)}
        let pin=protection.retain(hashes:selectedOperations.reduce(into:Set<String>()){$0.formUnion($1.assets)},revisions:selectedOperations.reduce(into:Set<UUID>()){$0.formUnion($1.revisions)})
        defer {withExtendedLifetime(pin){}}
        let staged=Dictionary(uniqueKeysWithValues:try wireRecords(scope:scope).map{($0.record.id,$0.record)})
        var result:[String:SyncWireRecord]=[:]
        func add<T:Codable & Equatable>(_ kind: SyncWireRecord.Kind,_ id: UUID,_ value: T) throws {
            let key=kind.rawValue+"-"+id.uuidString
            if let original=staged[key] {guard try decoder.decode(T.self,from:original.bytes)==value else {throw NotebookError.invalidModel};result[key]=original}
            else {let record=SyncWireRecord(id:key,kind:kind,bytes:try encoder.encode(value));try record.validate();result[record.id]=record}
        }
        for operation in selectedOperations {try add(.operation,operation.id,operation)}
        for conflict in try syncConflicts() {try add(.conflict,conflict.id,conflict)}
        for id in Set(selectedOperations.map(\.transactionID)) {
            let context=try contextForPublication(id,journal:all)
            if context.libraryID != scope.libraryID || context.deviceID != library.deviceID {
                let stored=try get("sync-wire-transaction-"+id.uuidString,as:StoredSyncWire.self)
                let wire=SyncWireRecord(id:"transaction-"+id.uuidString,kind:.transaction,bytes:try AssetStore.verifiedData(hash:stored.bodyHash,root:root.appendingPathComponent("assets")))
                let manifest=try decoder.decode(SyncTransactionManifest.self,from:wire.bytes)
                guard manifest.context==context,Set(manifest.members)==Set(all.filter{$0.transactionID==id}.map(\.id)) else {throw NotebookError.invalidModel}
                result[wire.id]=wire
            } else {try add(.transaction,id,SyncTransactionManifest(id:id,members:all.filter{$0.transactionID==id}.map(\.id).sorted{$0.uuidString<$1.uuidString},context:context))}
        }
        let byRevision=try publicationHeaders(staged:staged)
        var revisionIDs=Set<UUID>(),pending=selectedOperations.flatMap{$0.revisions}
        while let id=pending.popLast() {guard revisionIDs.insert(id).inserted else {continue};guard let header=byRevision[id] else {throw NotebookError.invalidModel};pending+=header.parentRevisionIDs}
        var hashes=selectedOperations.reduce(into:Set<String>()){$0.formUnion($1.assets)}
        for id in revisionIDs {
            try add(.header,id,byRevision[id]!)
            let local=try record(id.uuidString),payload=try local.flatMap{_ in try fullRevisionPayload(id:id)} ?? staged["revision-"+id.uuidString]?.bytes
            if let bytes=payload {
                let record=SyncWireRecord(id:"revision-"+id.uuidString,kind:.revision,bytes:bytes);try record.validate();result[record.id]=record
                hashes.formUnion(try decoder.decode(PageRevision.self,from:bytes).content.assetHashes)
            }
        }
        for font in try fontDependencyMetadata() where hashes.contains(font.font.assetHash) {try add(.font,font.font.id,font.font)}
        for wire in staged.values where wire.kind == .font {
            let font=try decoder.decode(FontVersion.self,from:wire.bytes)
            if hashes.contains(font.assetHash) {try add(.font,font.id,font)}
        }
        for hash in hashes {
            let record=SyncWireRecord(id:"asset-"+hash,kind:.asset,bytes:try await assets.read(hash:hash));try requireScope(scope);try record.validate();result[record.id]=record
        }
        var pendingRecords:[SyncWireRecord]=[]
        for wire in result.values.sorted(by:{$0.id<$1.id}) {
            try requireScope(scope)
            if let bytes=try record("sync-delivered-"+wire.id) {
                let receipt=try decoder.decode(SyncWireReceipt.self,from:bytes)
                guard receipt.bodyHash==AssetStore.hash(wire.bytes) else {throw NotebookError.invalidModel}
            } else {try await stageWire(wire,scope:scope);try requireScope(scope);pendingRecords.append(wire)}
        }
        return pendingRecords
    }
    func acknowledgeWire(_ wire: SyncWireRecord,scope: SyncScope,systemFields: Data) throws {
        try requireScope(scope);try wire.validate();guard scope.enabled,scope.receiveOnly != true,systemFields.count<=1_000_000 else {throw NotebookError.invalidModel}
        let stored=try get("sync-wire-"+wire.id,as:StoredSyncWire.self)
        guard stored.bodyHash==AssetStore.hash(wire.bytes) else {throw NotebookError.invalidModel}
        try transaction(journalChanges:false) {
            try put(SyncWireReceipt(id:wire.id,bodyHash:stored.bodyHash,scope:scope,systemFields:systemFields),key:"sync-delivered-"+wire.id,kind:"syncDelivery")
            for operation in try pendingOperations(scope:scope) {
                let required=try requiredPublicationRecords(operation)
                guard try required.allSatisfy({try record("sync-delivered-"+$0) != nil}) else {continue}
                guard operation.libraryID==scope.libraryID else {throw NotebookError.invalidModel}
                let operationReceipt=try get("sync-delivered-operation-"+operation.id.uuidString,as:SyncWireReceipt.self)
                try put(ScopedAcknowledgement(operationID:operation.id,valueHash:operation.valueHash,scope:scope,systemFields:operationReceipt.systemFields),key:"ack-"+operation.id.uuidString,kind:"operationAck")
            }
        }
    }
    private func requiredPublicationRecords(_ operation: CausalOperation) throws -> Set<String> {
        let all=try journal(),byID=Dictionary(uniqueKeysWithValues:all.map{($0.id,$0)})
        var visited=Set<UUID>(),queue=[operation.id],required=Set<String>(),hashes=Set<String>(),revisionIDs=Set<UUID>()
        while let id=queue.popLast() {
            guard visited.insert(id).inserted else {continue}
            guard let value=byID[id] else {throw NotebookError.invalidModel}
            required.insert("operation-"+id.uuidString);required.insert("transaction-"+value.transactionID.uuidString)
            queue+=value.bases;queue+=all.filter{$0.transactionID==value.transactionID}.map(\.id)
            for dependency in try contextForPublication(value.transactionID,journal:all).dependencies {queue+=all.filter{$0.transactionID==dependency}.map(\.id)}
            hashes.formUnion(value.assets);revisionIDs.formUnion(value.revisions)
            if value.entity.hasPrefix("resolution/"),let bytes=value.value,let id=try decoder.decode(SyncResolution.self,from:bytes).pageConflictID {required.insert("conflict-"+id.uuidString)}
        }
        for id in revisionIDs {required.insert("revision-"+id.uuidString)}
        let staged=Dictionary(uniqueKeysWithValues:try wireRecords(scope:syncScope()).map{($0.record.id,$0.record)}),headers=try publicationHeaders(staged:staged)
        var parents=Array(revisionIDs),seen=Set<UUID>()
        while let id=parents.popLast() {
            guard seen.insert(id).inserted else {continue}
            guard let header=headers[id] else {throw NotebookError.invalidModel}
            required.insert("header-"+id.uuidString);parents+=header.parentRevisionIDs
        }
        required.formUnion(hashes.map{"asset-"+$0})
        for font in try fontDependencyMetadata() where hashes.contains(font.font.assetHash) {required.insert("font-"+font.font.id.uuidString)}
        for wire in staged.values where wire.kind == .font {let font=try decoder.decode(FontVersion.self,from:wire.bytes);if hashes.contains(font.assetHash) {required.insert(wire.id)}}
        return required
    }

}


extension NotebookStore {
    func publicationHeaders(staged:[String:SyncWireRecord]) throws -> [UUID:RevisionHeader] {
        var result=Dictionary(uniqueKeysWithValues:try revisionHeaders().map{($0.id,$0)})
        for wire in staged.values where wire.kind == .header {
            let header=try decoder.decode(RevisionHeader.self,from:wire.bytes)
            if let old=result[header.id],old != header {throw NotebookError.invalidModel};result[header.id]=header
        }
        return result
    }
}
