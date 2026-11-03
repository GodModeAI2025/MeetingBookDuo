import Foundation
import MeetingBookCore

enum RevisionConflictResolver {
    enum Relation: Equatable { case same, local, incoming, concurrent, incomplete }
    static func classify(local: CausalOperation,incoming: CausalOperation,operations: [CausalOperation]) throws -> Relation {
        guard local.entity==incoming.entity,local.accountFingerprint==incoming.accountFingerprint else {throw NotebookError.invalidModel}
        var graph:[UUID:CausalOperation]=[:]
        for operation in operations {
            try operation.validate()
            if let old=graph[operation.id],old != operation {throw NotebookError.invalidModel}
            graph[operation.id]=operation
        }
        func ancestors(_ value: CausalOperation) throws -> Set<UUID>? {
            var result=Set<UUID>(),pending=value.bases
            while let id=pending.popLast() {
                guard id != value.id else {throw NotebookError.invalidModel}
                guard result.insert(id).inserted else {continue}
                guard let base=graph[id] else {return nil}
                guard base.entity==value.entity,base.accountFingerprint==value.accountFingerprint else {throw NotebookError.invalidModel}
                pending+=base.bases
            }
            // A cycle anywhere in the closure is invalid even when it excludes the selected tip.
            var counts=Dictionary(uniqueKeysWithValues:result.map{($0,graph[$0]!.bases.count)})
            var children:[UUID:[UUID]]=[:]
            for id in result {for base in graph[id]!.bases {children[base,default:[]].append(id)}}
            var ready=counts.filter{$0.value==0}.map(\.key),visited=0
            while let id=ready.popLast() { visited+=1;for child in children[id] ?? [] {counts[child]!-=1;if counts[child]==0 {ready.append(child)}} }
            guard visited==result.count else {throw NotebookError.invalidModel}
            return result
        }
        guard let left=try ancestors(local),let right=try ancestors(incoming) else {return .incomplete}
        if local.id==incoming.id {guard local==incoming else {throw NotebookError.invalidModel};return .same}
        if left.contains(incoming.id) {return .local}
        if right.contains(local.id) {return .incoming}
        return .concurrent
    }
    static func copyID(entity: String,operations: [UUID]) -> UUID {
        let input="MeetingBook.SyncConflict.v1/"+entity+"/"+operations.map(\.uuidString).sorted().joined(separator:"/")
        let hex=Array(AssetStore.hash(Data(input.utf8)).prefix(32))
        let text=String(hex[0..<8])+"-"+String(hex[8..<12])+"-5"+String(hex[13..<16])+"-a"+String(hex[17..<20])+"-"+String(hex[20..<32])
        return UUID(uuidString:text)!
    }
}


extension RevisionConflictResolver {
    /// Only an unchanged shared prefix followed by additions qualifies as append, never a reorder.
    static func concurrentAppends(_ tips:[CausalOperation],operations:[CausalOperation]) throws -> [UUID]? {
        guard let first=tips.first,tips.allSatisfy({$0.entity==first.entity}) else {return nil}
        let byID=Dictionary(uniqueKeysWithValues:operations.map{($0.id,$0)}),decoder=JSONDecoder()
        func list(_ operation:CausalOperation) throws -> [UUID]? {try operation.value.map{try decoder.decode([UUID].self,from:$0)}}
        func ancestors(_ operation:CausalOperation) -> Set<UUID> {
            var pending=operation.bases,seen=Set<UUID>()
            while let id=pending.popLast() {if seen.insert(id).inserted,let value=byID[id] {pending+=value.bases}}
            return seen
        }
        var common=ancestors(first)
        for tip in tips.dropFirst() {common.formIntersection(ancestors(tip))}
        let lists=try tips.map{try list($0) ?? []}
        let candidates=try common.compactMap {id -> (UUID,[UUID])? in guard let operation=byID[id],let value=try list(operation) else {return nil};return (id,value)}.sorted{$0.1.count==$1.1.count ? $0.0.uuidString<$1.0.uuidString : $0.1.count>$1.1.count}
        guard let base=candidates.first?.1,lists.allSatisfy({$0.count>base.count && Array($0.prefix(base.count))==base}) else {return nil}
        var ranks:[UUID:Int]=[:]
        for list in lists {for (index,id) in list.enumerated() where index>=base.count {ranks[id]=min(ranks[id] ?? index,index)}}
        return base+ranks.keys.sorted {ranks[$0]==ranks[$1] ? $0.uuidString<$1.uuidString : ranks[$0]!<ranks[$1]!}
    }
}
