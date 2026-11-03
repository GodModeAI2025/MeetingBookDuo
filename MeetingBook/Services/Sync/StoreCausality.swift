import Foundation
import MeetingBookCore

extension NotebookStore {
    /// Granular materialized entities. Glyph values pair source hash and metrics atomically.
    func entityValues() throws -> [String:Data] {
        var result:[String:Data]=[:]
        func add<T:Encodable>(_ key: String,_ value: T) throws { result[key]=try encoder.encode(value) }
        for note in library.notes+(try records("expiredNote").map{try decoder.decode(Note.self,from:$0)}) {
            let key="note/"+note.id.uuidString+"/"
            try add(key+"title",note.title);try add(key+"order",note.orderKey)
            try add(key+"pages",note.pageIDs);try add(key+"deleted",note.deletedAt)
            if library.version>=4 {try add(key+"timestamps",NoteTimestampMetadata(createdAt:note.createdAt,modifiedAt:note.modifiedAt))}
        }
        for data in try records("page") {
            let page=try decoder.decode(PageSnapshot.self,from:data),key="page/"+page.id.uuidString+"/"
            try add(key+"head",page.currentRevisionID);try add(key+"owner",page.noteID)
            try add(key+"order",page.orderKey);try add(key+"bookmark",page.bookmark)
            let deleted=try record("deleted-page-"+page.id.uuidString).map { try decoder.decode(Date.self,from:$0) }
            try add(key+"deleted",deleted)
        }
        for data in try records("expiredPage") {
            let page=try decoder.decode(PageSnapshot.self,from:data)
            try add("page/"+page.id.uuidString+"/retired",page)
        }
        for data in try records("revision") {
            let revision=try decoder.decode(PageRevision.self,from:data)
            try add("revision/"+revision.id.uuidString,RevisionHeader(revision))
        }
        // Headers remain the same entity after payload retention; pruning is not a remote deletion.
        for data in try records("revisionHeader") {
            let header=try decoder.decode(RevisionHeader.self,from:data);try add("revision/"+header.id.uuidString,header)
        }
        struct Glyph: Codable { let hash: String?;let metrics: GlyphCaptureMetrics? }
        for project in library.fonts {
            let key="font/"+project.id.uuidString+"/"
            try add(key+"name",project.name);try add(key+"publications",project.publicationIDs)
            for code in Set(project.glyphAssetHashes.keys).union(project.glyphMetrics.keys) {
                try add(key+"glyph/"+String(code),Glyph(hash:project.glyphAssetHashes[code],metrics:project.glyphMetrics[code]))
            }
            for version in project.versions { try add("fontVersion/"+version.id.uuidString,version);try add("fontVersion/"+version.id.uuidString+"/owner",project.id) }
        }
        for retained in try retainedFontVersions() {
            try add("fontVersion/"+retained.font.id.uuidString,retained.font)
            try add("fontVersion/"+retained.font.id.uuidString+"/owner",retained.ownerProjectID)
        }
        for resolution in try syncResolutions() {try add("resolution/"+resolution.id.uuidString,resolution)}
        try add("preference/textDefaults",library.preferences.textDefaults)
        try add("bookmarkOrder",library.bookmarkOrder ?? [])
        return result
    }
    func journal() throws -> [CausalOperation] {
        try records("causalOperation").map { try decoder.decode(CausalOperation.self,from:$0) }.sorted { $0.sequence<$1.sequence }
    }
    @discardableResult func appendOperations(before: [String:Data],afterValues:[String:Data]? = nil,priorOperations:[CausalOperation]? = nil,contextDependencies:Set<UUID>? = nil) throws -> [CausalOperation] {
        guard let scope=library.ownership else { return [] }
        guard scope.receiveOnly != true else {throw NotebookError.revisionConflict}
        library.version=4
        let after=try afterValues ?? entityValues(),old=try priorOperations ?? journal(),transactionID=UUID()
        var authored:[CausalOperation]=[]
        let before=try promotionBaseline(before:before,after:after)
        var timestampEvents=Set<String>()
        for entity in after.keys where entity.hasPrefix("note/") && before[entity]==nil {
            let prefix=entity.split(separator:"/").prefix(2).joined(separator:"/")+"/"
            timestampEvents.insert(prefix+"timestamps")
        }
        // An authored event is causal evidence even when the clock repeats the same Date.
        for entity in after.keys where before[entity] != after[entity] {
            let parts=entity.split(separator:"/").map(String.init)
            if parts.count==3,parts[0]=="note",["title","pages","deleted"].contains(parts[2]) {
                timestampEvents.insert("note/"+parts[1]+"/timestamps")
            } else if parts.count==3,parts[0]=="page",parts[2]=="head",let bytes=after["page/"+parts[1]+"/owner"] {
                let owner=try decoder.decode(UUID.self,from:bytes)
                timestampEvents.insert("note/"+owner.uuidString+"/timestamps")
            }
        }
        var latest:[String:Set<UUID>]=[:]
        let sameScope=old.filter{$0.accountFingerprint==scope.accountFingerprint}
        for operation in sameScope {latest[operation.entity,default:[]].insert(operation.id)}
        for operation in sameScope {latest[operation.entity,default:[]].subtract(operation.bases)}
        for entity in Set(before.keys).union(after.keys).sorted() where before[entity] != after[entity] || timestampEvents.contains(entity) {
            guard library.sequence<Int64.max-1 else { throw NotebookError.invalidModel }
            library.sequence+=1
            let dependencies=try entityDependencies(entity)
            let operation=CausalOperation(version:entity.hasPrefix("note/") ? 2 : 1,id:UUID(),transactionID:transactionID,libraryID:scope.libraryID,accountFingerprint:scope.accountFingerprint,
                entity:entity,bases:(latest[entity] ?? []).sorted{$0.uuidString<$1.uuidString},baseValueHash:before[entity].map(AssetStore.hash),deviceID:library.deviceID,sequence:library.sequence,createdAt:Date(),
                value:after[entity],valueHash:AssetStore.hash(after[entity] ?? Data()),revisions:dependencies.0,assets:dependencies.1)
            try operation.validate();try operation.validateWireValue();authored.append(operation);try put(operation,key:"operation-"+operation.id.uuidString,kind:"causalOperation")
        }
        if let contextDependencies {
            if let first=authored.first,let account=scope.accountFingerprint {
                let context=SyncTransactionContext(id:transactionID,libraryID:scope.libraryID,deviceID:first.deviceID,accountFingerprint:account,dependencies:contextDependencies.sorted{$0.uuidString<$1.uuidString})
                try context.validate();try put(context,key:"sync-context-"+transactionID.uuidString,kind:"syncContext")
            }
        } else {try authorTransactionContext(id:transactionID)}
        return authored
    }
    func entityDependencies(_ entity: String) throws -> (Set<UUID>,Set<String>) {
        let pieces=entity.split(separator:"/").map(String.init)
        var revisions=Set<UUID>(),hashes=Set<String>(),fontIDs=Set<UUID>()
        if pieces.count>1,let id=UUID(uuidString:pieces[1]) {
            switch pieces[0] {
            case "resolution":
                let resolution=try get("sync-resolution-"+id.uuidString,as:SyncResolution.self);revisions.formUnion(resolution.priorRevisionIDs);hashes.formUnion(resolution.priorAssetHashes)
            case "revision": if let bytes=try record(id.uuidString),(try? decoder.decode(PageRevision.self,from:bytes)) != nil { revisions.insert(id) }
            case "page": if pieces.last != "retired",let bytes=try record(id.uuidString),let page=try? decoder.decode(PageSnapshot.self,from:bytes) { revisions.insert(page.currentRevisionID) }
            case "note": if let note=library.notes.first(where:{$0.id==id}) { for pageID in note.pageIDs { revisions.insert(try loadPage(pageID).currentRevisionID) } }
            case "font": if let project=library.fonts.first(where:{$0.id==id}) {
                if pieces.count==4,pieces[2]=="glyph",let code=UInt32(pieces[3]),let hash=project.glyphAssetHashes[code] { hashes.insert(hash) }
                else {fontIDs.formUnion(project.publicationIDs)}
            }
            case "fontVersion":fontIDs.insert(id)
            default: break
            }
        }
        if entity=="preference/textDefaults",let id=library.preferences.textDefaults?.fontVersionID {fontIDs.insert(id)}
        for id in revisions {
            if let data=try record(id.uuidString),let revision=try? decoder.decode(PageRevision.self,from:data) {
                hashes.formUnion(revision.content.assetHashes)
                fontIDs.formUnion(revision.content.textBlocks.compactMap(\.fontVersionID))
            }
        }
        for id in fontIDs {if let font=try fontVersion(id:id) {hashes.insert(font.assetHash)}}
        return (revisions,hashes)
    }
    func syncScope() throws -> SyncScope { try ensureCacheEpoch();guard let scope=library.ownership else {throw NotebookError.invalidModel};return scope }
    func requireScope(_ expected: SyncScope) throws { try ensureCacheEpoch();guard library.ownership==expected else {throw NotebookError.revisionConflict} }
    /// Caller supplies explicit consent/merge decision; this method never discovers an account or sends data.
    func bindAccountAfterConsent(fingerprint: String,container: String,environment: String,expected: SyncScope,engineID: UUID) throws -> SyncScope {
        try requireScope(expected)
        guard expected.accountFingerprint == nil || (expected.accountFingerprint==fingerprint && expected.container==container && expected.environment==environment) else {throw NotebookError.revisionConflict}
        return try transaction(journalChanges:false) {
            var scope=expected;scope.accountFingerprint=fingerprint;scope.container=container;scope.environment=environment
            scope.generation+=1;scope.engineID=engineID;scope.enabled=true;scope.receiveOnly = expected.version==2 ? false : nil;scope.archived=false;try scope.validate();library.ownership=scope
            // Local-only intent is not reassigned. Bootstrap the current graph with new scoped operations.
            if expected.accountFingerprint == nil { try appendOperations(before:[:]) }
            return scope
        }
    }
    func disableKeepingLocalData(expected: SyncScope) throws -> SyncScope {
        try requireScope(expected)
        return try transaction(journalChanges:false) { var scope=expected;scope.generation+=1;scope.enabled=false;scope.engineID=nil;try scope.validate();library.ownership=scope;return scope }
    }
    func pendingOperations(scope: SyncScope,limit: Int=200) throws -> [CausalOperation] {
        try requireScope(scope);guard scope.enabled,scope.receiveOnly != true,limit>0,limit<=250 else {throw NotebookError.invalidModel}
        return try journal().filter { operation in guard operation.accountFingerprint==scope.accountFingerprint else { return false };return try record("ack-"+operation.id.uuidString) == nil }.prefix(limit).map{$0}
    }
    func acknowledge(_ operation: CausalOperation,scope: SyncScope,systemFields: Data = Data()) throws {
        guard systemFields.count<=1_000_000 else {throw NotebookError.invalidModel}
        try requireScope(scope);guard scope.enabled,scope.receiveOnly != true else {throw NotebookError.revisionConflict}
        let stored=try get("operation-"+operation.id.uuidString,as:CausalOperation.self)
        guard stored==operation,operation.libraryID==scope.libraryID,operation.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        try transaction(journalChanges:false) { try put(ScopedAcknowledgement(operationID:operation.id,valueHash:operation.valueHash,scope:scope,systemFields:systemFields),key:"ack-"+operation.id.uuidString,kind:"operationAck") }
    }
    /// Inbox is durable before a caller checkpoints the engine cursor. Activation belongs to Task7B.
    func stageIncoming(_ operation: CausalOperation,systemFields: Data,scope: SyncScope) throws {
        try requireScope(scope);try operation.validate()
        guard scope.enabled,operation.accountFingerprint==scope.accountFingerprint,systemFields.count<=1_000_000 else {throw NotebookError.invalidModel}
        let key="inbox-"+operation.id.uuidString
        if let bytes=try record(key) { guard try decoder.decode(IncomingOperation.self,from:bytes).operation==operation else {throw NotebookError.invalidModel};return }
        try transaction(journalChanges:false) { try put(IncomingOperation(operation:operation,scope:scope,systemFields:systemFields),key:key,kind:"incomingOperation") }
    }
    func stagedIncoming(scope: SyncScope) throws -> [IncomingOperation] { try requireScope(scope);return try records("incomingOperation").map{try decoder.decode(IncomingOperation.self,from:$0)} }
    func checkpointEngine(_ bytes: Data,scope: SyncScope) throws {
        try requireScope(scope);guard scope.enabled,bytes.count<=8_000_000 else {throw NotebookError.invalidModel}
        try transaction(journalChanges:false) { try put(EngineCheckpoint(scope:scope,bytes:bytes),key:"engine-checkpoint",kind:"engineCheckpoint") }
    }
    func engineCheckpoint(scope: SyncScope) throws -> Data? {
        try requireScope(scope);guard let data=try record("engine-checkpoint") else {return nil}
        let checkpoint=try decoder.decode(EngineCheckpoint.self,from:data)
        // Generation changes invalidate the engine but an explicitly resumed binding may reuse its cursor.
        guard checkpoint.scope.libraryID==scope.libraryID,checkpoint.scope.accountFingerprint==scope.accountFingerprint,checkpoint.scope.container==scope.container,checkpoint.scope.environment==scope.environment else {throw NotebookError.invalidModel}
        return checkpoint.bytes
    }
}

extension NotebookStore {
    /// Consumer may release only after activation/quarantine resolution; active graph references still pin content.
    func retireIncoming(_ operation: CausalOperation,scope: SyncScope) throws {
        try requireScope(scope)
        let key="inbox-"+operation.id.uuidString,value=try get(key,as:IncomingOperation.self)
        guard value.operation==operation,value.scope.libraryID==scope.libraryID,value.scope.accountFingerprint==scope.accountFingerprint else {throw NotebookError.invalidModel}
        try transaction(journalChanges:false) {try removeRecord(key)}
    }
    func stageIncomingAsset(_ bytes: Data,hash: String,operationID: UUID,scope: SyncScope) async throws {
        try requireScope(scope)
        let incoming=try get("inbox-"+operationID.uuidString,as:IncomingOperation.self)
        guard scope.enabled,incoming.operation.assets.contains(hash),incoming.scope.libraryID==scope.libraryID else {throw NotebookError.invalidModel}
        let lease=protection.retain(hashes:[hash]);defer{withExtendedLifetime(lease){}}
        let staged=try await assets.stage(data:bytes,expectedHash:hash);try requireScope(scope)
        _ = try await assets.finalize(staged);try requireScope(scope)
        try transaction(journalChanges:false) {
            var current=try get("inbox-"+operationID.uuidString,as:IncomingOperation.self)
            guard current.operation==incoming.operation else {throw NotebookError.revisionConflict}
            var available=current.availableAssets ?? [];available.insert(hash);current.availableAssets=available
            try put(current,key:"inbox-"+operationID.uuidString,kind:"incomingOperation")
        }
        // Durable inbox now records verified available bytes before any engine cursor checkpoint.
        protection.committed([hash])
    }
}

extension NotebookStore {
    func revisionHeaders() throws -> [RevisionHeader] {
        try records("revision").map{RevisionHeader(try decoder.decode(PageRevision.self,from:$0))}+records("revisionHeader").map{try decoder.decode(RevisionHeader.self,from:$0)}
    }
    func fullRevisionPayload(id: UUID) throws -> Data? {
        guard let data=try record(id.uuidString) else {throw NotebookError.notFound}
        if let revision=try? decoder.decode(PageRevision.self,from:data) {guard revision.id==id else {throw NotebookError.invalidModel};return data}
        let header=try decoder.decode(RevisionHeader.self,from:data)
        guard header.id==id else {throw NotebookError.invalidModel};return nil
    }
    func capturePending(scope: SyncScope,limit: Int=200) throws -> OutgoingCapture {
        try protection.locked {
            let operations=try pendingOperations(scope:scope,limit:limit)
            let revisions=operations.reduce(into:Set<UUID>()){$0.formUnion($1.revisions)}
            var payloads:[UUID:Data]=[:]
            for id in revisions {guard let payload=try fullRevisionPayload(id:id) else {throw NotebookError.invalidModel};payloads[id]=payload}
            let hashes=operations.reduce(into:Set<String>()){$0.formUnion($1.assets)}
            return OutgoingCapture(scope:scope,operations:operations,revisionPayloads:payloads,fontDependencies:try fontDependencyMetadata().filter{hashes.contains($0.font.assetHash)},lease:protection.retain(hashes:hashes,revisions:revisions))
        }
    }
    func acknowledgedSystemFields(operationID: UUID,scope: SyncScope) throws -> Data? {
        try requireScope(scope);guard let bytes=try record("ack-"+operationID.uuidString) else {return nil}
        return try decoder.decode(ScopedAcknowledgement.self,from:bytes).systemFields
    }
}

extension NotebookStore {
    func isPageLeasedForRemoteActivation(_ pageID: UUID) -> Bool { protection.snapshot.remotePages.contains(pageID) }
}

extension NotebookStore {
    func captureNote(id: UUID) throws -> (snapshot: NoteSnapshot,lease: StorageLease) {
        try protection.locked {
            let snapshot=try loadNote(id)
            let hashes=snapshot.pages.reduce(into:Set<String>()){$0.formUnion($1.content.assetHashes)}.union((try fontVersions()).map(\.assetHash))
            return (snapshot,protection.retain(hashes:hashes,revisions:Set(snapshot.pages.map(\.currentRevisionID))))
        }
    }
}

extension NotebookStore {
    func archiveScope(expected: SyncScope) throws -> SyncScope {
        try requireScope(expected)
        return try transaction(journalChanges:false) {
            var scope=expected;scope.generation+=1;scope.enabled=false;scope.engineID=nil;scope.archived=true
            try scope.validate();library.ownership=scope;return scope
        }
    }
}

extension NotebookStore {
    func fontDependencyMetadata() throws -> [RetainedFontVersion] {
        let scope=try syncScope()
        return library.fonts.flatMap {project in project.versions.map{RetainedFontVersion(font:$0,ownerProjectID:project.id,originLibraryID:scope.libraryID)}}+(try retainedFontVersions())
    }
}


extension NotebookStore {
    /// Only the newly created owned candidate may be inspected. No baseline or local authoring.
    func bindForCloudInspection(fingerprint:String,container:String,environment:String,expected:SyncScope,engineID:UUID) throws -> SyncScope {
        try requireScope(expected)
        guard expected.accountFingerprint==nil,expected.generation==0,library.sequence==0,
              library.notes.isEmpty,library.fonts.isEmpty,
              try context.performAndWait({try Self.rows(context:context).allSatisfy({$0.kind=="library"})}) else {throw NotebookError.revisionConflict}
        return try transaction(journalChanges:false) {
            var scope=expected;scope.version=2;scope.receiveOnly=true
            scope.accountFingerprint=fingerprint;scope.container=container;scope.environment=environment
            scope.generation+=1;scope.engineID=engineID;scope.enabled=true;scope.archived=false
            try scope.validate();library.ownership=scope;return scope
        }
    }
}


extension NotebookStore {
    func resumeCloudInspection(expected:SyncScope,engineID:UUID) throws -> SyncScope {
        try requireScope(expected)
        guard expected.receiveOnly==true,expected.accountFingerprint != nil else {throw NotebookError.revisionConflict}
        return try transaction(journalChanges:false) {
            var scope=expected;scope.generation+=1;scope.engineID=engineID;scope.enabled=true;scope.archived=false
            try scope.validate();library.ownership=scope;return scope
        }
    }
}
