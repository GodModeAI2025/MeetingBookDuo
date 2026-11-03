import Foundation
import MeetingBookCore

struct SyncConflict: Codable, Sendable, Equatable, Identifiable {
    var version=1
    var deletionOperationID:UUID? = nil
    var recoveredRevisionID:UUID? = nil
    var copySourceRevisionID:UUID {recoveredRevisionID ?? sourceRevisionIDs[1]}
    let id: UUID
    let accountFingerprint: String
    let entity: String
    let operationIDs: [UUID]
    let sourceRevisionIDs: [UUID]
    let copyNoteID: UUID
    let copyPageID: UUID
    let copyRevisionID: UUID
    init(_ a: CausalOperation,_ b: CausalOperation) throws {
        guard a.entity==b.entity,a.entity.hasSuffix("/head"),let fingerprint=a.accountFingerprint,fingerprint==b.accountFingerprint else {throw NotebookError.invalidModel}
        let ordered=[a,b].sorted{$0.id.uuidString<$1.id.uuidString}
        id=RevisionConflictResolver.copyID(entity:a.entity,operations:ordered.map(\.id));accountFingerprint=fingerprint;entity=a.entity;operationIDs=ordered.map(\.id)
        sourceRevisionIDs=try ordered.map{guard let value=$0.value else {throw NotebookError.invalidModel};return try JSONDecoder().decode(UUID.self,from:value)}
        copyNoteID=RevisionConflictResolver.copyID(entity:"note/"+id.uuidString,operations:[])
        copyPageID=RevisionConflictResolver.copyID(entity:"page/"+id.uuidString,operations:[])
        copyRevisionID=RevisionConflictResolver.copyID(entity:"revision/"+id.uuidString,operations:[])
    }
    init(deletion:CausalOperation,edit:CausalOperation) throws {
        guard deletion.accountFingerprint==edit.accountFingerprint,let fingerprint=edit.accountFingerprint,edit.entity.hasPrefix("page/"),edit.entity.hasSuffix("/head"),deletion.entity.hasSuffix("/deleted"),let deletionValue=deletion.value,try JSONDecoder().decode(Date?.self,from:deletionValue) != nil,let value=edit.value else {throw NotebookError.invalidModel}
        let revisionID=try JSONDecoder().decode(UUID.self,from:value)
        version=2;deletionOperationID=deletion.id;recoveredRevisionID=revisionID
        accountFingerprint=fingerprint;entity=edit.entity;operationIDs=[deletion.id,edit.id].sorted{$0.uuidString<$1.uuidString};sourceRevisionIDs=[revisionID]
        id=RevisionConflictResolver.copyID(entity:"delete-edit/"+entity,operations:operationIDs)
        copyNoteID=RevisionConflictResolver.copyID(entity:"note/"+id.uuidString,operations:[])
        copyPageID=RevisionConflictResolver.copyID(entity:"page/"+id.uuidString,operations:[])
        copyRevisionID=RevisionConflictResolver.copyID(entity:"revision/"+id.uuidString,operations:[])
    }
    func validate() throws {
        guard PageContent.isHash(accountFingerprint),operationIDs.count==2,Set(operationIDs).count==2,operationIDs==operationIDs.sorted(by:{$0.uuidString<$1.uuidString}),
              copyNoteID==RevisionConflictResolver.copyID(entity:"note/"+id.uuidString,operations:[]),copyPageID==RevisionConflictResolver.copyID(entity:"page/"+id.uuidString,operations:[]),copyRevisionID==RevisionConflictResolver.copyID(entity:"revision/"+id.uuidString,operations:[]) else {throw NotebookError.invalidModel}
        switch version {
        case 1: guard deletionOperationID==nil,recoveredRevisionID==nil,sourceRevisionIDs.count==2,id==RevisionConflictResolver.copyID(entity:entity,operations:operationIDs) else {throw NotebookError.invalidModel}
        case 2: guard let deletionOperationID,operationIDs.contains(deletionOperationID),let recoveredRevisionID,sourceRevisionIDs==[recoveredRevisionID],id==RevisionConflictResolver.copyID(entity:"delete-edit/"+entity,operations:operationIDs) else {throw NotebookError.invalidModel}
        default: throw NotebookError.unsupportedVersion
        }
    }
    func validateSources(operations:[UUID:CausalOperation],contexts:[UUID:SyncTransactionContext]) throws {
        guard let a=operations[operationIDs[0]],let b=operations[operationIDs[1]] else {throw NotebookError.invalidModel}
        if let deletionOperationID {
            let deletion=a.id==deletionOperationID ? a : b,edit=a.id==deletionOperationID ? b : a
            guard try SyncConflict(deletion:deletion,edit:edit)==self,SyncTransactionContext.areConcurrent(deletion.transactionID,edit.transactionID,contexts:contexts)==true else {throw NotebookError.invalidModel}
            let deleted=deletion.entity.split(separator:"/"),edited=edit.entity.split(separator:"/")
            guard deleted.count==3,edited.count==3 else {throw NotebookError.invalidModel}
            if deleted[0]=="page" {
                guard deleted[1]==edited[1] else {throw NotebookError.invalidModel}
            } else {
                guard deleted[0]=="note" else {throw NotebookError.invalidModel}
                // Ownership is evidence from the edit's causal snapshot, never receiver-local state.
                var pending=[edit.transactionID],observed=Set<UUID>()
                while let id=pending.popLast() {
                    guard observed.insert(id).inserted else {continue}
                    guard let context=contexts[id],context.accountFingerprint==accountFingerprint else {throw NotebookError.invalidModel}
                    pending+=context.dependencies
                }
                let owners=operations.values.filter{$0.entity=="page/"+edited[1]+"/owner" && $0.accountFingerprint==accountFingerprint && observed.contains($0.transactionID)}
                let superseded=Set(owners.flatMap(\.bases)),tips=owners.filter{!superseded.contains($0.id)}
                guard !tips.isEmpty else {throw NotebookError.invalidModel}
                for owner in tips {
                    guard let value=owner.value,try JSONDecoder().decode(UUID.self,from:value).uuidString==deleted[1] else {throw NotebookError.invalidModel}
                }
            }
        } else {guard try SyncConflict(a,b)==self,try RevisionConflictResolver.classify(local:a,incoming:b,operations:Array(operations.values)) == .concurrent else {throw NotebookError.invalidModel}}
    }

}
struct DerivedSyncCopy: Codable, Sendable {
    var version=1
    let conflictID: UUID
    let noteID: UUID
    let pageID: UUID
    let revisionID: UUID
    var promoted=false
    var requested=false
}

extension NotebookStore {
    func conflictSourceRevisions(_ conflict:SyncConflict) throws -> [PageRevision] {
        guard try unresolvedPageConflicts().contains(conflict) else {throw NotebookError.revisionConflict}
        return try conflict.sourceRevisionIDs.map{try get($0.uuidString,as:PageRevision.self)}
    }
    func conflictAffectedEntity(_ conflict:SyncConflict) throws -> String {
        if let deletion=conflict.deletionOperationID {return try get("operation-"+deletion.uuidString,as:CausalOperation.self).entity}
        return conflict.entity
    }
    func syncConflicts() throws -> [SyncConflict] {try records("syncConflict").map{try decoder.decode(SyncConflict.self,from:$0)}.sorted{$0.id.uuidString<$1.id.uuidString}}
    func projectConflict(_ conflict: SyncConflict,scope: SyncScope,wires: [String:SyncWireRecord] = [:]) throws {
        try conflict.validate();guard conflict.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        let key="sync-conflict-"+conflict.id.uuidString
        if let bytes=try record(key) {guard try decoder.decode(SyncConflict.self,from:bytes)==conflict else {throw NotebookError.invalidModel};return}
        let source=try get(conflict.copySourceRevisionID.uuidString,as:PageRevision.self)
        guard try record(conflict.copyPageID.uuidString)==nil,try record(conflict.copyRevisionID.uuidString)==nil,!library.notes.contains(where:{$0.id==conflict.copyNoteID}) else {throw NotebookError.invalidModel}
        let copy=PageSnapshot(id:conflict.copyPageID,noteID:conflict.copyNoteID,orderKey:0,currentRevisionID:conflict.copyRevisionID,content:source.content)
        let revision=PageRevision(id:copy.currentRevisionID,pageID:copy.id,parentRevisionIDs:[],deviceID:source.deviceID,sequence:source.sequence,createdAt:source.createdAt,contentHash:AssetStore.hash(try encoder.encode(source.content)),content:source.content,reason:.conflict)
        let operations=try journal()+wires.values.filter{$0.kind == .operation}.map{try decoder.decode(CausalOperation.self,from:$0.bytes)}
        let sourceTransactions=Set(operations.filter{$0.entity==conflict.entity && $0.value.flatMap{try? decoder.decode(UUID.self,from:$0)}==source.id}.map(\.transactionID))
        let owners=Set(operations.filter{$0.entity=="page/"+source.pageID.uuidString+"/owner"}.compactMap{$0.value.flatMap{try? decoder.decode(UUID.self,from:$0)}})
        guard owners.count<=1 else {throw NotebookError.invalidModel}
        let sourceMetadata=operations.filter{sourceTransactions.contains($0.transactionID) && $0.entity==owners.first.map{"note/"+$0.uuidString+"/timestamps"}}.sorted{$0.id.uuidString<$1.id.uuidString}.first
        let timestamps=try sourceMetadata?.value.map{try decoder.decode(NoteTimestampMetadata.self,from:$0)}
        library.version=4
        library.notes.append(Note(id:conflict.copyNoteID,title:"Conflict",orderKey:0,pageIDs:[copy.id],createdAt:timestamps?.createdAt,modifiedAt:timestamps?.modifiedAt))
        try put(copy,key:copy.id.uuidString,kind:"page");try put(revision,key:revision.id.uuidString,kind:"revision")
        try put(conflict,key:key,kind:"syncConflict")
        try put(DerivedSyncCopy(conflictID:conflict.id,noteID:copy.noteID,pageID:copy.id,revisionID:revision.id),key:"derived-copy-"+copy.id.uuidString,kind:"derivedSyncCopy")
    }
    /// Called inside the shared authoring transaction; rollback includes the promotion marker.
    func promotionBaseline(before: [String:Data],after: [String:Data]) throws -> [String:Data] {
        var baseline=before
        for bytes in try records("derivedSyncCopy") {
            var copy=try decoder.decode(DerivedSyncCopy.self,from:bytes)
            guard !copy.promoted else {continue}
            let prefixes=["note/"+copy.noteID.uuidString+"/","page/"+copy.pageID.uuidString+"/"]
            let keys=Set(before.keys).union(after.keys).filter{key in prefixes.contains(where:key.hasPrefix)}
            guard copy.requested || keys.contains(where:{before[$0] != after[$0]}) else {continue}
            for key in keys {baseline.removeValue(forKey:key)}
            baseline.removeValue(forKey:"revision/"+copy.revisionID.uuidString)
            copy.promoted=true;copy.requested=false
            try put(copy,key:"derived-copy-"+copy.pageID.uuidString,kind:"derivedSyncCopy")
        }
        return baseline
    }
}

/// A is the captured current scope, B the exact incoming transaction branch; Both authors real copies.
enum SyncConflictChoice:String,Codable,Sendable {case a,b,both}
struct SyncResolution:Codable,Sendable,Equatable,Identifiable {
    var version=1
    var pageConflictID:UUID? = nil
    let id:UUID
    let authorLibraryID:UUID
    let accountFingerprint:String
    let sourceTransactionIDs:[UUID]
    let choice:SyncConflictChoice
    let resultHashes:[String:String]
    let priorRevisionIDs:Set<UUID>
    let priorAssetHashes:Set<String>
    let copiedNoteIDs:Set<UUID>
    let copiedProjectIDs:Set<UUID>
    func validate() throws {
        guard version==1,PageContent.isHash(accountFingerprint),!sourceTransactionIDs.isEmpty,sourceTransactionIDs.count<=250,Set(sourceTransactionIDs).count==sourceTransactionIDs.count,
              !resultHashes.isEmpty,resultHashes.count<=100_000,resultHashes.allSatisfy({$0.key.utf8.count<=512 && !$0.key.hasPrefix("resolution/") && PageContent.isHash($0.value)}),priorRevisionIDs.count<=100_000,priorAssetHashes.count<=100_000,priorAssetHashes.allSatisfy(PageContent.isHash),
              choice == .both || (copiedNoteIDs.isEmpty && copiedProjectIDs.isEmpty) else {throw NotebookError.invalidModel}
    }
}
struct ConsumedSyncTransaction:Codable,Sendable {
    var version=1
    let id:UUID
    let scope:SyncScope
    var resolutionIDs:Set<UUID>
}

extension NotebookStore {
    func syncResolutions() throws -> [SyncResolution] {try records("syncResolution").map{try decoder.decode(SyncResolution.self,from:$0)}.sorted{$0.id.uuidString<$1.id.uuidString}}
    func syncGraphToken() throws -> String {
        struct Token:Encodable {let scope:SyncScope;let values:[String:Data];let operations:[UUID]}
        return AssetStore.hash(try encoder.encode(Token(scope:syncScope(),values:entityValues(),operations:journal().map(\.id).sorted{$0.uuidString<$1.uuidString})))
    }
    /// Reconstruct only verified source history. Receiver-local pages or names never enter a source copy.
    func sourceWireValues(transactionID:UUID,wires:[String:SyncWireRecord],scope:SyncScope) throws -> [String:Data] {
        var all=Dictionary(uniqueKeysWithValues:try journal().map{($0.id,$0)}),contexts=Dictionary(uniqueKeysWithValues:try transactionContexts().map{($0.id,$0)}),manifests:[UUID:SyncTransactionManifest]=[:]
        for wire in wires.values where wire.kind == .operation {
            let operation=try decoder.decode(CausalOperation.self,from:wire.bytes)
            if let old=all[operation.id],old != operation {throw NotebookError.invalidModel};all[operation.id]=operation
        }
        for wire in wires.values where wire.kind == .transaction {
            let manifest=try decoder.decode(SyncTransactionManifest.self,from:wire.bytes)
            if let old=contexts[manifest.id],old != manifest.context {throw NotebookError.invalidModel}
            contexts[manifest.id]=manifest.context;manifests[manifest.id]=manifest
        }
        try SyncTransactionContext.validatePartialGraph(Array(contexts.values),account:scope.accountFingerprint)
        var queue=[transactionID],seen=Set<UUID>(),selected:[CausalOperation]=[]
        while let id=queue.popLast() {
            guard seen.insert(id).inserted else {continue}
            guard let context=contexts[id] else {throw SyncActivationError.incomplete}
            let members:[CausalOperation]
            if let manifest=manifests[id] {members=try readWireOperations(manifest,wires:wires,scope:scope)}
            else {
                guard context.libraryID==scope.libraryID,context.deviceID==library.deviceID else {throw SyncActivationError.incomplete}
                members=all.values.filter{$0.transactionID==id};guard !members.isEmpty else {throw SyncActivationError.incomplete}
            }
            selected+=members;queue+=context.dependencies
        }
        var result:[String:Data]=[:]
        for (entity,operations) in Dictionary(grouping:selected,by:\.entity) {
            if entity.hasPrefix("note/"),entity.hasSuffix("/timestamps") {
                result[entity]=try encoder.encode(NoteTimestampMetadata.project(operations));continue
            }
            let superseded=Set(operations.flatMap(\.bases)),tips=operations.filter{!superseded.contains($0.id)}
            guard var tip=tips.sorted(by:{$0.id.uuidString<$1.id.uuidString}).first else {throw NotebookError.invalidModel}
            if Set(tips.map(\.valueHash)).count>1 {
                if entity=="bookmarkOrder" || entity=="preference/textDefaults" || entity.hasSuffix("/bookmark") {tip=tips.max{$0.createdAt==$1.createdAt ? $0.id.uuidString<$1.id.uuidString : $0.createdAt<$1.createdAt}!}
                else if entity.hasPrefix("note/"),entity.hasSuffix("/pages"),let merged=try RevisionConflictResolver.concurrentAppends(tips,operations:selected) {result[entity]=try encoder.encode(merged);continue}
                else if !(entity.hasPrefix("page/") && entity.hasSuffix("/head")) {throw SyncActivationError.concurrent}
            }
            result[entity]=tip.value
        }
        // Concurrent append derives dense materialized ordering from the same immutable membership evidence.
        for (key,data) in result where key.hasPrefix("note/") && key.hasSuffix("/pages") {
            for (index,id) in try decoder.decode([UUID].self,from:data).enumerated() {result["page/"+id.uuidString+"/order"]=try encoder.encode(Int64(index))}
        }
        return result
    }
    func resolveWireConflict(transactionID:UUID,choice:SyncConflictChoice,expectedToken:String,scope:SyncScope) async throws -> SyncResolution {
        try requireScope(scope);guard scope.enabled,try syncGraphToken()==expectedToken else {throw NotebookError.revisionConflict}
        _ = try await prepareWireOutbox(scope:scope)
        try requireScope(scope);guard try syncGraphToken()==expectedToken else {throw NotebookError.revisionConflict}
        let wires=Dictionary(uniqueKeysWithValues:try wireRecords(scope:scope).map{($0.record.id,$0.record)})
        guard let wire=wires["transaction-"+transactionID.uuidString] else {throw SyncActivationError.incomplete}
        let manifest=try decoder.decode(SyncTransactionManifest.self,from:wire.bytes),operations=try readWireOperations(manifest,wires:wires,scope:scope)
        for dependency in manifest.context.dependencies {guard try record("sync-context-"+dependency.uuidString) != nil else {throw SyncActivationError.incomplete}}
        try validateTransactionReferences(operations,wires:wires)
        do {_ = try makeWirePlan(operations,scope:scope);throw NotebookError.revisionConflict} catch SyncActivationError.concurrent {}
        let source=try sourceWireValues(transactionID:transactionID,wires:wires,scope:scope),before=try entityValues()
        let history=try journal()
        var sourceIDs:Set<UUID>=[manifest.id]
        for operation in operations {
            let same=history.filter{$0.entity==operation.entity && $0.accountFingerprint==scope.accountFingerprint},superseded=Set(same.flatMap(\.bases))
            for tip in same where !superseded.contains(tip.id) && tip.valueHash != operation.valueHash {
                if try RevisionConflictResolver.classify(local:tip,incoming:operation,operations:history+operations) == .concurrent {sourceIDs.insert(tip.transactionID)}
            }
        }
        var sourceOperations=operations
        for id in sourceIDs where id != manifest.id {
            guard let bytes=wires["transaction-"+id.uuidString]?.bytes else {throw SyncActivationError.incomplete}
            sourceOperations+=try readWireOperations(decoder.decode(SyncTransactionManifest.self,from:bytes),wires:wires,scope:scope)
        }
        let entities=Set(sourceOperations.map(\.entity)),pages=try affectedRemotePages(changed:entities,values:source),fonts=try affectedRemoteFonts(changed:entities,values:source)
        var notes=Set<UUID>()
        for key in entities {let parts=key.split(separator:"/").map(String.init);if parts.first=="note",parts.count>1,let id=UUID(uuidString:parts[1]) {notes.insert(id)}}
        for page in pages {for values in [before,source] {if let bytes=values["page/"+page.uuidString+"/owner"] {notes.insert(try decoder.decode(UUID.self,from:bytes))}}}
        let affectedPages=pages.union(library.notes.filter{notes.contains($0.id)}.flatMap(\.pageIDs))
        return try protection.locked {
            try requireScope(scope);guard try syncGraphToken()==expectedToken,affectedPages.isDisjoint(with:protection.snapshot.remotePages),fonts.isDisjoint(with:protection.snapshot.remoteFonts) else {throw NotebookError.revisionConflict}
            return try transaction(journalChanges:false) {
                var priorRevisions=Set<UUID>(),priorAssets=Set<String>()
                for page in affectedPages {if let bytes=before["page/"+page.uuidString+"/head"] {let id=try decoder.decode(UUID.self,from:bytes);priorRevisions.insert(id);if let revision=try record(id.uuidString) {priorAssets.formUnion(try decoder.decode(PageRevision.self,from:revision).content.assetHashes)}}}
                for project in library.fonts where fonts.contains(project.id) {priorAssets.formUnion(project.glyphAssetHashes.values);priorAssets.formUnion(project.versions.map(\.assetHash))}
                var selected=before
                // A rejected publication still owns immutable font metadata needed by references
                // and source replay. Preserve its source owner independently of publication choice.
                for operation in operations where operation.entity.hasPrefix("fontVersion/") && operation.entity.split(separator:"/").count==2 {
                    let key=operation.entity
                    if selected[key]==nil {
                        guard let body=source[key],let owner=source[key+"/owner"] else {throw SyncActivationError.incomplete}
                        selected[key]=body;selected[key+"/owner"]=owner
                    }
                }
                if choice == .b {
                    for note in notes {
                        let prefix="note/"+note.uuidString+"/"
                        for (key,value) in source where key.hasPrefix(prefix) {selected[key]=value}
                        let sourcePages=try source[prefix+"pages"].map{try decoder.decode([UUID].self,from:$0)} ?? []
                        for page in sourcePages {for (key,value) in source where key.hasPrefix("page/"+page.uuidString+"/") {selected[key]=value}}
                        for page in library.notes.first(where:{$0.id==note})?.pageIDs ?? [] where !sourcePages.contains(page) {selected["page/"+page.uuidString+"/deleted"]=try encoder.encode(Date())}
                    }
                    for font in fonts {
                        let prefix="font/"+font.uuidString+"/"
                        for key in Array(selected.keys) where key.hasPrefix(prefix) {selected.removeValue(forKey:key)}
                        for (key,value) in source where key.hasPrefix(prefix) {selected[key]=value}
                    }
                    for (key,value) in source where key.hasPrefix("revision/") {
                        let header=try decoder.decode(RevisionHeader.self,from:value)
                        if affectedPages.contains(header.pageID) {selected[key]=value}
                    }
                    var neededFonts=Set<UUID>()
                    for font in fonts {
                        if let bytes=selected["font/"+font.uuidString+"/publications"] {neededFonts.formUnion(try decoder.decode([UUID].self,from:bytes))}
                    }
                    for page in affectedPages {
                        if let bytes=selected["page/"+page.uuidString+"/head"] {
                            let id=try decoder.decode(UUID.self,from:bytes)
                            if let body=wires["revision-"+id.uuidString]?.bytes {neededFonts.formUnion(try decoder.decode(PageRevision.self,from:body).content.textBlocks.compactMap(\.fontVersionID))}
                        }
                    }
                    for (key,value) in source where key.hasPrefix("fontVersion/") {
                        let parts=key.split(separator:"/")
                        guard let id=UUID(uuidString:String(parts[1])) else {throw NotebookError.invalidModel}
                        if entities.contains(key) || (neededFonts.contains(id) && selected[key]==nil) {selected[key]=value}
                    }
                }
                if selected != before {try projectRemote(values:selected,wires:wires,scope:scope)}
                var copiedNotes=Set<UUID>(),copiedProjects=Set<UUID>()
                if choice == .both {
                    for note in notes.sorted(by:{$0.uuidString<$1.uuidString}) {copiedNotes.insert(try copySourceNote(note,values:source,wires:wires))}
                    for font in fonts.sorted(by:{$0.uuidString<$1.uuidString}) {copiedProjects.insert(try copySourceProject(font,values:source,origin:manifest.context.libraryID))}
                }
                let authoredAt=Date()
                for note in notes where library.notes.contains(where:{$0.id==note}) {
                    let prefix="note/"+note.uuidString+"/"
                    if selected.contains(where:{$0.key.hasPrefix(prefix) && before[$0.key] != $0.value}) || pages.contains(where:{id in library.notes.first(where:{$0.id==note})?.pageIDs.contains(id)==true && selected["page/"+id.uuidString+"/head"] != before["page/"+id.uuidString+"/head"]}) {try markNoteModified(note,at:authoredAt)}
                }
                for operation in operations {
                    if let bytes=try record("operation-"+operation.id.uuidString) {guard try decoder.decode(CausalOperation.self,from:bytes)==operation else {throw NotebookError.invalidModel}}
                    else {try put(operation,key:"operation-"+operation.id.uuidString,kind:"causalOperation")}
                    try put(ScopedAcknowledgement(operationID:operation.id,valueHash:operation.valueHash,scope:scope,received:true),key:"ack-"+operation.id.uuidString,kind:"operationAck")
                }
                try put(manifest.context,key:"sync-context-"+manifest.id.uuidString,kind:"syncContext")
                let after=try entityValues()
                var forced=before,authoredKeys=Set<String>()
                for key in Set(before.keys).union(after.keys).union(entities) where !key.hasPrefix("resolution/") {
                    if (key.hasPrefix("revision/") || (key.hasPrefix("fontVersion/") && key.split(separator:"/").count==2)) && after[key]==nil {continue}
                    if before[key] != after[key] || entities.contains(key) {
                        authoredKeys.insert(key)
                        if after[key] != nil {forced.removeValue(forKey:key)} else {forced[key]=before[key] ?? Data("null".utf8)}
                    }
                }
                let resolution=SyncResolution(id:UUID(),authorLibraryID:scope.libraryID,accountFingerprint:scope.accountFingerprint!,sourceTransactionIDs:sourceIDs.sorted{$0.uuidString<$1.uuidString},choice:choice,resultHashes:Dictionary(uniqueKeysWithValues:authoredKeys.map{($0,AssetStore.hash(after[$0] ?? Data()))}),priorRevisionIDs:priorRevisions,priorAssetHashes:priorAssets,copiedNoteIDs:copiedNotes,copiedProjectIDs:copiedProjects)
                try resolution.validate();try put(resolution,key:"sync-resolution-"+resolution.id.uuidString,kind:"syncResolution")
                try put(ConsumedSyncTransaction(id:manifest.id,scope:scope,resolutionIDs:[resolution.id]),key:"sync-consumed-"+manifest.id.uuidString,kind:"syncConsumed")
                try appendOperations(before:forced)
                return resolution
            }
        }
    }
    private func copySourceNote(_ id:UUID,values:[String:Data],wires:[String:SyncWireRecord]) throws -> UUID {
        func read<T:Decodable>(_ key:String,_ type:T.Type) throws -> T {guard let bytes=values[key] else {throw SyncActivationError.incomplete};return try decoder.decode(type,from:bytes)}
        let prefix="note/"+id.uuidString+"/",pageIDs:[UUID]=try read(prefix+"pages",[UUID].self),copyID=UUID()
        var copies:[UUID]=[]
        for (index,pageID) in pageIDs.enumerated() {
            let revisionID:UUID=try read("page/"+pageID.uuidString+"/head",UUID.self)
            guard let bytes=try wires["revision-"+revisionID.uuidString]?.bytes ?? record(revisionID.uuidString) else {throw SyncActivationError.incomplete}
            let source=try decoder.decode(PageRevision.self,from:bytes)
            guard source.pageID==pageID else {throw NotebookError.invalidModel}
            let page=PageSnapshot(noteID:copyID,orderKey:Int64(index),content:source.content)
            _ = try persist(page,parents:[],reason:.conflict);copies.append(page.id)
        }
        let timestamps=try values[prefix+"timestamps"].map{try decoder.decode(NoteTimestampMetadata.self,from:$0)}
        library.version=4
        library.notes.append(Note(id:copyID,title:try read(prefix+"title",String.self),orderKey:Int64(library.notes.count),pageIDs:copies,createdAt:timestamps?.createdAt,modifiedAt:timestamps?.modifiedAt));return copyID
    }
    private func copySourceProject(_ id:UUID,values:[String:Data],origin:UUID) throws -> UUID {
        func read<T:Decodable>(_ key:String,_ type:T.Type) throws -> T {guard let bytes=values[key] else {throw SyncActivationError.incomplete};return try decoder.decode(type,from:bytes)}
        let prefix="font/"+id.uuidString+"/"
        var project=FontProject(name:try read(prefix+"name",String.self));project.formatVersion=3;project.publishedVersionIDs=try read(prefix+"publications",[UUID].self)
        struct Glyph:Decodable {let hash:String?;let metrics:GlyphCaptureMetrics?}
        for (key,bytes) in values where key.hasPrefix(prefix+"glyph/") {guard let code=UInt32(key.split(separator:"/").last!) else {throw NotebookError.invalidModel};let glyph=try decoder.decode(Glyph.self,from:bytes);project.glyphAssetHashes[code]=glyph.hash;project.glyphMetrics[code]=glyph.metrics}
        for versionID in project.publicationIDs where try !fontVersions().contains(where:{$0.id==versionID}) {
            let font:FontVersion=try read("fontVersion/"+versionID.uuidString,FontVersion.self),owner:UUID=try read("fontVersion/"+versionID.uuidString+"/owner",UUID.self)
            try put(RetainedFontVersion(font:font,ownerProjectID:owner,originLibraryID:origin),key:"retained-font-"+versionID.uuidString,kind:"retainedFontVersion");library.version=max(3,library.version)
        }
        try project.validateMetadata();library.fonts.append(project);return project.id
    }
}

extension NotebookStore {
    func unresolvedPageConflicts() throws -> [SyncConflict] {
        let resolved=Set(try syncResolutions().compactMap(\.pageConflictID))
        return try syncConflicts().filter{!resolved.contains($0.id)}
    }
    func resolvePageConflict(id:UUID,choice:SyncConflictChoice,expectedToken:String,scope:SyncScope) async throws -> SyncResolution {
        try requireScope(scope);guard scope.enabled,try syncGraphToken()==expectedToken else {throw NotebookError.revisionConflict}
        _ = try await prepareWireOutbox(scope:scope)
        try requireScope(scope);guard try syncGraphToken()==expectedToken else {throw NotebookError.revisionConflict}
        guard let conflict=try unresolvedPageConflicts().first(where:{$0.id==id}),let pageID=UUID(uuidString:String(conflict.entity.split(separator:"/")[1])) else {throw NotebookError.notFound}
        let original=try loadPage(pageID),copy=try loadPage(conflict.copyPageID)
        guard conflict.sourceRevisionIDs.contains(original.currentRevisionID),copy.currentRevisionID==conflict.copyRevisionID else {throw NotebookError.revisionConflict}
        let deletion=try conflict.deletionOperationID.map{try get("operation-"+$0.uuidString,as:CausalOperation.self)}
        if let deletion {
            let same=try journal().filter{$0.entity==deletion.entity && $0.accountFingerprint==scope.accountFingerprint},superseded=Set(same.flatMap(\.bases))
            guard !superseded.contains(deletion.id),beforeDeletionValue(deletion,original:original) else {throw NotebookError.revisionConflict}
        }
        let selectedRevision=deletion==nil ? conflict.sourceRevisionIDs[choice == .b ? 1 : 0] : conflict.copySourceRevisionID
        let source=try get(selectedRevision.uuidString,as:PageRevision.self)
        let operations=try conflict.operationIDs.map{try get("operation-"+$0.uuidString,as:CausalOperation.self)},sourceIDs=Set(operations.map(\.transactionID))
        let before=try entityValues()
        var affectedPages:Set<UUID>=[pageID,copy.id]
        if deletion != nil,choice == .b {
            affectedPages.formUnion(library.notes.first(where:{$0.id==original.noteID})?.pageIDs ?? [])
        }
        return try protection.locked {
            try requireScope(scope);guard try syncGraphToken()==expectedToken,affectedPages.isDisjoint(with:protection.snapshot.remotePages) else {throw NotebookError.revisionConflict}
            return try transaction(journalChanges:false) {
                if deletion==nil || choice == .b {
                    var page=original;page.currentRevisionID=UUID();page.content=source.content
                    _ = try persist(page,parents:Array(Set(conflict.sourceRevisionIDs+[original.currentRevisionID])).sorted{$0.uuidString<$1.uuidString},reason:.conflict)
                }
                if let deletion,choice == .b {
                    let parts=deletion.entity.split(separator:"/").map(String.init)
                    guard let index=library.notes.firstIndex(where:{$0.id==original.noteID}) else {throw NotebookError.revisionConflict}
                    if parts[0]=="note" {guard library.notes[index].id.uuidString==parts[1] else {throw NotebookError.revisionConflict};library.notes[index].deletedAt=nil}
                    else {
                        guard library.notes[index].deletedAt==nil,!library.notes[index].pageIDs.contains(pageID),try record("deleted-page-"+pageID.uuidString) != nil else {throw NotebookError.revisionConflict}
                        library.notes[index].pageIDs.insert(pageID,at:min(Int(original.orderKey),library.notes[index].pageIDs.count))
                        try removeRecord("deleted-page-"+pageID.uuidString);try renumber(index)
                    }
                }
                if choice == .both {
                    var marker=try get("derived-copy-"+copy.id.uuidString,as:DerivedSyncCopy.self);marker.requested=true
                    try put(marker,key:"derived-copy-"+copy.id.uuidString,kind:"derivedSyncCopy")
                } else {
                    guard let index=library.notes.firstIndex(where:{$0.id==copy.noteID}) else {throw NotebookError.invalidModel}
                    library.notes[index].deletedAt=Date()
                }
                let authoredAt=Date()
                if deletion==nil || choice == .b {try markNoteModified(original.noteID,at:authoredAt)}
                try markNoteModified(copy.noteID,at:authoredAt)
                let after=try entityValues()
                var sourceEntities:Set<String>=[conflict.entity]
                sourceEntities.formUnion(conflict.sourceRevisionIDs.map{"revision/"+$0.uuidString})
                if let deletion {
                    sourceEntities.insert(deletion.entity)
                    if deletion.entity.hasPrefix("page/") {
                        sourceEntities.insert("note/"+original.noteID.uuidString+"/pages")
                        for id in library.notes.first(where:{$0.id==original.noteID})?.pageIDs ?? [] {sourceEntities.insert("page/"+id.uuidString+"/order")}
                    }
                }
                var forced=before,keys=Set<String>()
                for key in Set(before.keys).union(after.keys) where !key.hasPrefix("resolution/") {
                    let promotesCopy=choice == .both && (key.hasPrefix("note/"+copy.noteID.uuidString+"/") || key.hasPrefix("page/"+copy.id.uuidString+"/") || key=="revision/"+copy.currentRevisionID.uuidString)
                    if before[key] != after[key] || sourceEntities.contains(key) || promotesCopy {
                        keys.insert(key);if after[key] != nil {forced.removeValue(forKey:key)} else {forced[key]=before[key] ?? Data("null".utf8)}
                    }
                }
                let protected=Set(conflict.sourceRevisionIDs+[copy.currentRevisionID,original.currentRevisionID]),assets=try protected.reduce(into:Set<String>()){result,id in result.formUnion(try get(id.uuidString,as:PageRevision.self).content.assetHashes)}
                let resolution=SyncResolution(pageConflictID:conflict.id,id:UUID(),authorLibraryID:scope.libraryID,accountFingerprint:scope.accountFingerprint!,sourceTransactionIDs:sourceIDs.sorted{$0.uuidString<$1.uuidString},choice:choice,resultHashes:Dictionary(uniqueKeysWithValues:keys.map{($0,AssetStore.hash(after[$0] ?? Data()))}),priorRevisionIDs:protected,priorAssetHashes:assets,copiedNoteIDs:choice == .both ? [copy.noteID] : [],copiedProjectIDs:[])
                try resolution.validate();try put(resolution,key:"sync-resolution-"+resolution.id.uuidString,kind:"syncResolution")
                try appendOperations(before:forced);return resolution
            }
        }
    }
    private func beforeDeletionValue(_ operation:CausalOperation,original:PageSnapshot) -> Bool {
        guard let current=try? entityValues()[operation.entity] else {return false}
        return current==operation.value
    }
    /// Received evidence may arrive after genuine authored copy entities. Preserve their current state.
    func consumeConflictEvidence(wires:[String:SyncWireRecord]) throws {
        let operations=Dictionary(uniqueKeysWithValues:try journal().map{($0.id,$0)})
        for wire in wires.values where wire.kind == .conflict {
            let conflict=try decoder.decode(SyncConflict.self,from:wire.bytes);try conflict.validate()
            guard let a=operations[conflict.operationIDs[0]],let b=operations[conflict.operationIDs[1]] else {continue}
            _ = a;_ = b
            try conflict.validateSources(operations:operations,contexts:Dictionary(uniqueKeysWithValues:try transactionContexts().map{($0.id,$0)}))
            guard let sourceBytes=try record(conflict.copySourceRevisionID.uuidString),let source=try? decoder.decode(PageRevision.self,from:sourceBytes),try record(conflict.sourceRevisionIDs[0].uuidString) != nil else {continue}
            let key="sync-conflict-"+conflict.id.uuidString
            if let bytes=try record(key) {guard try decoder.decode(SyncConflict.self,from:bytes)==conflict else {throw NotebookError.invalidModel};continue}
            if let copyBytes=try record(conflict.copyRevisionID.uuidString) {
                let copy=try decoder.decode(PageRevision.self,from:copyBytes)
                let expected=PageRevision(id:conflict.copyRevisionID,pageID:conflict.copyPageID,parentRevisionIDs:[],deviceID:source.deviceID,sequence:source.sequence,createdAt:source.createdAt,contentHash:AssetStore.hash(try encoder.encode(source.content)),content:source.content,reason:.conflict)
                guard copy==expected,try loadPage(copy.pageID).noteID==conflict.copyNoteID else {throw NotebookError.invalidModel}
                try put(conflict,key:key,kind:"syncConflict")
                try put(DerivedSyncCopy(conflictID:conflict.id,noteID:conflict.copyNoteID,pageID:copy.pageID,revisionID:copy.id,promoted:true),key:"derived-copy-"+copy.pageID.uuidString,kind:"derivedSyncCopy")
            } else {try projectConflict(conflict,scope:syncScope(),wires:wires)}
        }
    }
}


extension SyncResolution {
    func coversMutableEntities(_ operations:[CausalOperation]) -> Bool {operations.filter(\.isMutableSyncEntity).allSatisfy{resultHashes[$0.entity] != nil}}
}
