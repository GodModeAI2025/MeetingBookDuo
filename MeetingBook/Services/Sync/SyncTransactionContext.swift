import Foundation
import MeetingBookCore

struct SyncTransactionContext: Codable, Sendable, Equatable {
    var version=1
    let id: UUID
    let libraryID: UUID
    let deviceID: UUID
    let accountFingerprint: String
    let dependencies: [UUID]
    func validate() throws {
        guard version==1,PageContent.isHash(accountFingerprint),dependencies.count<=100_000,Set(dependencies).count==dependencies.count,!dependencies.contains(id),dependencies==dependencies.sorted(by:{$0.uuidString<$1.uuidString}) else {throw NotebookError.invalidModel}
    }
}

extension NotebookStore {
    func transactionContexts() throws -> [SyncTransactionContext] {try records("syncContext").map{try decoder.decode(SyncTransactionContext.self,from:$0)}}
    /// Pre-7B could not receive remote transactions. Derive only its own authored predecessor chain.
    func legacyTransactionContext(_ id: UUID,journal: [CausalOperation]) throws -> SyncTransactionContext {
        let members=journal.filter{$0.transactionID==id}
        guard let first=members.first,first.libraryID==library.ownership?.libraryID,first.deviceID==library.deviceID,let account=first.accountFingerprint else {throw NotebookError.invalidModel}
        let start=members.map(\.sequence).min()!
        let preceding=journal.filter{$0.libraryID==first.libraryID && $0.deviceID==first.deviceID && $0.accountFingerprint==account && $0.sequence<start}.max{$0.sequence<$1.sequence}
        return SyncTransactionContext(id:id,libraryID:first.libraryID,deviceID:first.deviceID,accountFingerprint:account,dependencies:preceding.map{[$0.transactionID]} ?? [])
    }
    func authorTransactionContext(id: UUID) throws {
        let operations=try journal(),members=operations.filter{$0.transactionID==id}
        guard let first=members.first,let account=first.accountFingerprint else {return}
        var contexts=try transactionContexts().filter{$0.accountFingerprint==account}
        for transactionID in Set(operations.filter{$0.accountFingerprint==account}.map(\.transactionID)) where transactionID != id && !contexts.contains(where:{$0.id==transactionID}) {
            let context=try legacyTransactionContext(transactionID,journal:operations)
            try context.validate();try put(context,key:"sync-context-"+context.id.uuidString,kind:"syncContext");contexts.append(context)
        }
        let superseded=Set(contexts.flatMap(\.dependencies)),frontier=contexts.map(\.id).filter{!superseded.contains($0)}.sorted{$0.uuidString<$1.uuidString}
        let context=SyncTransactionContext(id:id,libraryID:first.libraryID,deviceID:first.deviceID,accountFingerprint:account,dependencies:frontier)
        try context.validate();try put(context,key:"sync-context-"+id.uuidString,kind:"syncContext")
    }
    func contextForPublication(_ id: UUID,journal: [CausalOperation]) throws -> SyncTransactionContext {
        if let bytes=try record("sync-context-"+id.uuidString) {return try decoder.decode(SyncTransactionContext.self,from:bytes)}
        return try legacyTransactionContext(id,journal:journal)
    }
}


extension SyncTransactionContext {
    /// Missing external dependencies remain pending, but cycles in received evidence are corrupt.
    static func validatePartialGraph(_ contexts:[SyncTransactionContext],account:String?) throws {
        var byID:[UUID:SyncTransactionContext]=[:]
        for context in contexts {
            try context.validate()
            guard context.accountFingerprint==account else {throw NotebookError.invalidModel}
            if let old=byID[context.id],old != context {throw NotebookError.invalidModel}
            byID[context.id]=context
        }
        var counts=byID.mapValues{$0.dependencies.filter{byID[$0] != nil}.count},children:[UUID:[UUID]]=[:]
        for context in byID.values {for dependency in context.dependencies where byID[dependency] != nil {children[dependency,default:[]].append(context.id)}}
        var ready=counts.filter{$0.value==0}.map(\.key),visited=0
        while let id=ready.popLast() {visited+=1;for child in children[id] ?? [] {counts[child]!-=1;if counts[child]==0 {ready.append(child)}}}
        guard visited==byID.count else {throw NotebookError.invalidModel}
    }
}


extension SyncTransactionContext {
    static func areConcurrent(_ a:UUID,_ b:UUID,contexts:[UUID:SyncTransactionContext]) -> Bool? {
        guard contexts[a] != nil,contexts[b] != nil else {return nil}
        if a==b {return false}
        func precedes(_ source:UUID,_ target:UUID) -> Bool? {
            var queue=contexts[target]!.dependencies,seen=Set<UUID>()
            while let id=queue.popLast() {
                if id==source {return true}
                guard seen.insert(id).inserted else {continue}
                guard let context=contexts[id] else {return nil};queue+=context.dependencies
            }
            return false
        }
        guard let ab=precedes(a,b),let ba=precedes(b,a) else {return nil}
        return !ab && !ba
    }
}
