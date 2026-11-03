import Foundation
import MeetingBookCore

extension NotebookStore {
    /// Explicit foreground maintenance. All eligibility, database pruning and guarded unlink are
    /// serialized with publication; interruption after commit may leave extra immutable files.
    func collectRetention(now: Date = Date(),assetGrace: TimeInterval = 86400) async throws -> RetentionResult {
        guard assetGrace>=86400,now.timeIntervalSince1970.isFinite else {throw NotebookError.invalidModel}
        try ensureCacheEpoch()
        let context=self.context
        guard !context.performAndWait({context.hasChanges}) else {throw NotebookError.revisionConflict}
        let startingEpoch=protection.currentCommitEpoch
        let startingRetentionEpoch=protection.currentRetentionEpoch
        var result=RetentionResult()
        let pins=protection.snapshot
        if pins.blocksCollection {result.deferred=true;return result}
        let scope=try syncScope(),snapshotLibrary=library,snapshotRoot=root
        if scope.archived==true {result.deferred=true;return result}
        #if DEBUG
        let captureStart=ContinuousClock.now
        #endif
        let rows=try context.performAndWait {try Self.rows(context:context)}
        #if DEBUG
        let captureDuration=captureStart.duration(to:.now).components
        lastRetentionCaptureMS=Double(captureDuration.seconds)*1000+Double(captureDuration.attoseconds)/1e15
        #endif
        guard protection.currentCommitEpoch==startingEpoch else {result.deferred=true;return result}
        let worker=Task.detached {try Self.retentionPlan(rows:rows,library:snapshotLibrary,root:snapshotRoot,pins:pins,now:now)}
        let planned=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        try Task.checkCancellation()
        guard let plan=planned else {result.deferred=true;return result}
        #if DEBUG
        try retentionPlanReady?()
        #endif
        let full=plan.full,pages=plan.pages,historyByPage=plan.historyByPage,assetPins=plan.assetPins
        var expired=plan.expired,retained=plan.retained
        return try protection.locked {
            let latestPins=protection.snapshot
            guard protection.currentCommitEpoch==startingEpoch,protection.currentRetentionEpoch==startingRetentionEpoch,!latestPins.blocksCollection else {result.deferred=true;return result}
            try Task.checkCancellation();try requireScope(scope)
            for page in pages where (historyByPage[page.id] ?? []).contains(where:{latestPins.revisions.contains($0.id)}) {expired.remove(page.id)}
            for note in library.notes where note.deletedAt != nil && !note.pageIDs.allSatisfy(expired.contains) {expired.subtract(note.pageIDs)}
            retained.formUnion(pages.filter{!expired.contains($0.id)}.map(\.currentRevisionID))
            let candidates=full.filter{!retained.contains($0.id) && !latestPins.revisions.contains($0.id) && now.timeIntervalSince($0.createdAt)>30*86400}
            if !candidates.isEmpty || !expired.isEmpty {try transaction(journalChanges:false) {
                for revision in candidates {
                    try put(RevisionHeader(revision),key:revision.id.uuidString,kind:"revisionHeader")
                    // Unassigned legacy intent is superseded by explicit current-state bootstrap on opt-in.
                    for data in try records("outbox") {
                        let entry=try decoder.decode(OutboxEntry.self,from:data)
                        if entry.revisionID==revision.id {try removeRecord(entry.id.uuidString)}
                    }
                }
                for page in pages where expired.contains(page.id) {try put(page,key:page.id.uuidString,kind:"expiredPage")}
                for data in try records("outbox") {
                    let entry=try decoder.decode(OutboxEntry.self,from:data)
                    if expired.contains(entry.pageID) {try removeRecord(entry.id.uuidString)}
                }
                for note in library.notes where note.deletedAt != nil && note.pageIDs.allSatisfy(expired.contains) {try put(note,key:"expired-note-"+note.id.uuidString,kind:"expiredNote")}
                library.notes.removeAll { note in note.deletedAt != nil && note.pageIDs.allSatisfy(expired.contains) }
                // An expired individual page is already outside note membership.
                library.bookmarkOrder?.removeAll(where:expired.contains)
                if let id=library.preferences.lastPageID,expired.contains(id) {library.preferences.lastPageID=nil}
                try requireScope(scope)
            }}
            result.prunedRevisions=candidates.count;result.expiredPages=expired.count
            let keep=validatedAssetHashes.union(assetPins).union(protection.snapshot.hashes)
            let assetRoot=root.appendingPathComponent("assets")
            for directory in try FileManager.default.contentsOfDirectory(at:assetRoot,includingPropertiesForKeys:[.isDirectoryKey]).sorted(by:{$0.path<$1.path}) where directory.lastPathComponent.count==2 {
                let attributes=try FileManager.default.attributesOfItem(atPath:directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw NotebookError.invalidAsset}
                for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
                    let name=file.lastPathComponent
                    guard name.hasSuffix(".blob") else {continue}
                    let hash=String(name.dropLast(5))
                    guard PageContent.isHash(hash),String(hash.prefix(2))==directory.lastPathComponent else {throw NotebookError.invalidAsset}
                    let metadata=try FileManager.default.attributesOfItem(atPath:file.path)
                    guard metadata[.type] as? FileAttributeType == .typeRegular,let modified=metadata[.modificationDate] as? Date else {throw NotebookError.invalidAsset}
                    if !keep.contains(hash),now.timeIntervalSince(modified)>assetGrace {
                        try requireScope(scope)
                        try FileManager.default.removeItem(at:file)
                        try AssetStore.synchronize(directory,true)
                        result.removedAssets+=1
                    }
                }
            }
            return result
        }
    }
    private struct RetentionPlan:Sendable {
        let full:[PageRevision]
        let pages:[PageSnapshot]
        let historyByPage:[UUID:[PageRevision]]
        let retained:Set<UUID>
        let assetPins:Set<String>
        let expired:Set<UUID>
    }
    private static func retentionPlan(rows:[RecordRow],library:Library,root:URL,pins:StorageProtection.Pin,now:Date) throws -> RetentionPlan? {
        let decoder=JSONDecoder(),byKind=Dictionary(grouping:rows,by: \.kind)
        var byKey:[String:Data]=[:]
        for row in rows {guard byKey.updateValue(row.payload,forKey:row.key)==nil else {throw NotebookError.invalidModel}}
        func records(_ kind:String) -> [Data] {(byKind[kind] ?? []).map(\.payload)}
        func record(_ key:String) -> Data? {byKey[key]}
        let full=try records("revision").map{data in try autoreleasepool{try Task.checkCancellation();return try decoder.decode(PageRevision.self,from:data)}}
        let headers=full.map(RevisionHeader.init)+(try records("revisionHeader").map{try decoder.decode(RevisionHeader.self,from:$0)})
        let pages=try records("page").map{try decoder.decode(PageSnapshot.self,from:$0)}
        var retained=pins.revisions,assetPins=pins.hashes
        // Account-bound obligations remain pinned even when sync is disabled/offline.
        for operation in try records("causalOperation").map({try decoder.decode(CausalOperation.self,from:$0)}) where operation.accountFingerprint != nil {
            if record("ack-"+operation.id.uuidString)==nil {retained.formUnion(operation.revisions);assetPins.formUnion(operation.assets)}
        }
        for data in records("incomingOperation") {
            let incoming=try decoder.decode(IncomingOperation.self,from:data)
            retained.formUnion(incoming.operation.revisions);assetPins.formUnion(incoming.operation.assets)
        }
        for data in records("syncWire") {
            let wire=try decoder.decode(StoredSyncWire.self,from:data)
            if let key=wire.backingRecordKey,wire.kind == .revision,let id=UUID(uuidString:key) {retained.insert(id)}
            else if wire.backingRecordKey==nil {assetPins.insert(wire.bodyHash)}
        }
        for conflict in try records("syncConflict").map({try decoder.decode(SyncConflict.self,from:$0)}) {retained.formUnion(conflict.sourceRevisionIDs);retained.insert(conflict.copyRevisionID)}
        for resolution in try records("syncResolution").map({try decoder.decode(SyncResolution.self,from:$0)}) {retained.formUnion(resolution.priorRevisionIDs);assetPins.formUnion(resolution.priorAssetHashes)}
        // Legacy migration JSON owns the asset closure of its original full snapshot.
        let recovery=root.appendingPathComponent("recovery")
        if FileManager.default.fileExists(atPath:recovery.path) {
            for url in try FileManager.default.contentsOfDirectory(at:recovery,includingPropertiesForKeys:nil) where ["json","recovery","staging"].contains(url.pathExtension) {
                if url.pathExtension=="staging" {return nil}
                let rows=try Self.readMigrationEnvelope(at:url)
                assetPins.formUnion(try Self.validateGraph(rows).assetHashes)
            }
        }
        let externallyPinned=retained
        retained.formUnion(RevisionHeader.protectedRecoveryParents(headers))
        let historyByPage=Dictionary(grouping:full,by:\.pageID)
        var expired=Set<UUID>()
        for page in pages {
            try Task.checkCancellation()
            let deletedNote=library.notes.first(where:{$0.id==page.noteID})?.deletedAt
            let deletedPage=try record("deleted-page-"+page.id.uuidString).map{try decoder.decode(Date.self,from:$0)}
            let deletion=deletedNote ?? deletedPage
            let history=(historyByPage[page.id] ?? []).sorted{$0.sequence>$1.sequence}
            if let deletion,now.timeIntervalSince(deletion)>30*86400,!history.contains(where:{externallyPinned.contains($0.id)}) {
                expired.insert(page.id)
            } else {retained.insert(page.currentRevisionID)}
            retained.formUnion(history.filter{$0.id != page.currentRevisionID && now.timeIntervalSince($0.createdAt)<=30*86400}.prefix(20).map(\.id))
        }
        for note in library.notes where note.deletedAt != nil && !note.pageIDs.allSatisfy(expired.contains) {
            expired.subtract(note.pageIDs)
            for page in pages where note.pageIDs.contains(page.id) {retained.insert(page.currentRevisionID)}
        }

        try Task.checkCancellation()
        return RetentionPlan(full:full,pages:pages,historyByPage:historyByPage,retained:retained,assetPins:assetPins,expired:expired)
    }
    static func readMigrationEnvelope(at url: URL) throws -> [RecordRow] {
        if url.pathExtension=="recovery" {return try readChunkedRecovery(at:url)}
        let file=try PackageIO.openRegular(url);defer{try? file.close()}
        guard try file.seekToEnd()<=100_000_000 else {throw NotebookError.invalidAsset};try file.seek(toOffset:0)
        guard let data=try file.readToEnd() else {throw NotebookError.invalidModel}
        return try envelopeRows(data)
    }
    static func envelopeRows(_ data: Data) throws -> [RecordRow] {
        guard data.count<=100_000_000,let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              [1,2,3,4].contains(envelope["version"] as? Int ?? 0),let rows=envelope["records"] as? [[String:String]],rows.count<=100_000 else {throw NotebookError.unsupportedVersion}
        return try rows.map { row in guard let key=row["key"],let kind=row["kind"],let encoded=row["payload"],let payload=Data(base64Encoded:encoded) else {throw NotebookError.invalidModel};return RecordRow(key:key,kind:kind,payload:payload) }
    }
    /// Explicit retirement of one local migration checkpoint; never retires safety packages implicitly.
    func retireMigrationBackup(at url: URL) throws {
        try protection.locked {
            guard url.path==url.standardizedFileURL.path,url.standardizedFileURL.deletingLastPathComponent()==root.appendingPathComponent("recovery").standardizedFileURL,["json","recovery"].contains(url.pathExtension) else {throw NotebookError.invalidModel}
            _ = try Self.validateGraph(Self.readMigrationEnvelope(at:url))
            try FileManager.default.removeItem(at:url);try AssetStore.synchronize(url.deletingLastPathComponent(),true)
        }
    }
}

private struct RecoveryManifest:Codable {
    struct Chunk:Codable {let path:String;let size:Int;let sha256:String;let rowCount:Int}
    let version:Int
    let libraryVersion:Int
    let rowCount:Int
    let rawMetadataBytes:Int
    let encodedMetadataBytes:Int
    let chunks:[Chunk]
}
extension NotebookStore {
    func writeChunkedRecovery(rows:[RecordRow],directory:URL) throws -> URL {try Self.writeChunkedRecovery(rows:rows,directory:directory,libraryVersion:library.version,protection:protection)}
    static func writeChunkedRecovery(rows:[RecordRow],directory:URL,libraryVersion:Int,protection:StorageProtection) throws -> URL {
        let destination=directory.appendingPathComponent(UUID().uuidString+".recovery")
        let staging=directory.appendingPathComponent("."+UUID().uuidString+".staging")
        do {
            try FileManager.default.createDirectory(at:staging.appendingPathComponent("records"),withIntermediateDirectories:true,attributes:AssetStore.protection)
            var protected=staging;var values=URLResourceValues();values.isExcludedFromBackup=true;try protected.setResourceValues(values)
            let files=try RecordChunks.encode(rows)
            var chunks:[RecoveryManifest.Chunk]=[]
            for path in files.keys.sorted() {
                try Task.checkCancellation();let bytes=files[path]!
                try PackageIO.write(bytes,to:staging.appendingPathComponent(path))
                let count=try JSONDecoder().decode([RecordRow].self,from:bytes).count
                chunks.append(.init(path:path,size:bytes.count,sha256:AssetStore.hash(bytes),rowCount:count))
            }
            let manifest=RecoveryManifest(version:5,libraryVersion:libraryVersion,rowCount:rows.count,rawMetadataBytes:try rows.reduce(0){try $0+RecordChunks.rawSize($1)},encodedMetadataBytes:files.values.reduce(0){$0+$1.count},chunks:chunks)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let bytes=try encoder.encode(manifest)
            guard bytes.count<=16_000_000,bytes.count<=768_000_000-manifest.encodedMetadataBytes else {throw NotebookError.invalidAsset}
            try PackageIO.write(bytes,to:staging.appendingPathComponent("manifest.json"))
            try AssetStore.synchronize(staging.appendingPathComponent("records"),true);try AssetStore.synchronize(staging,true)
            try Task.checkCancellation();try publishRecovery(staging:staging,destination:destination,protection:protection);return destination
        } catch {try? FileManager.default.removeItem(at:staging);throw error}
    }
    static func writeLocalRecovery(rows:[RecordRow],version:Int,directory:URL,protection:StorageProtection,prefix:String = "") throws -> URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:AssetStore.protection)
        guard try FileManager.default.attributesOfItem(atPath:directory.path)[.type] as? FileAttributeType == .typeDirectory else {throw NotebookError.invalidAsset}
        var owned=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try owned.setResourceValues(values)
        let estimate=rows.reduce(64){$0+($1.payload.count+2)/3*8+$1.key.utf8.count*6+$1.kind.utf8.count*6+64}
        if rows.count>100_000 || estimate>100_000_000 {return try writeChunkedRecovery(rows:rows,directory:directory,libraryVersion:version,protection:protection)}
        let records=rows.map{["key":$0.key,"kind":$0.kind,"payload":$0.payload.base64EncodedString()]}
        let bytes=try JSONSerialization.data(withJSONObject:["version":version,"records":records],options:.sortedKeys)
        guard bytes.count<=100_000_000 else {throw NotebookError.invalidAsset}
        let destination=directory.appendingPathComponent(prefix+UUID().uuidString+".json"),staging=directory.appendingPathComponent("."+UUID().uuidString+".staging")
        do {
            try Task.checkCancellation();try PackageIO.write(bytes,to:staging);try Task.checkCancellation()
            try publishRecovery(staging:staging,destination:destination,protection:protection);return destination
        } catch {try? FileManager.default.removeItem(at:staging);throw error}
    }
    static func publishRecovery(staging:URL,destination:URL,protection:StorageProtection,synchronize:@Sendable (URL,Bool) throws -> Void = AssetStore.synchronize) throws {
        let lease=protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        try protection.locked {
            try FileManager.default.moveItem(at:staging,to:destination)
            protection.recoveryPublished()
        }
        try synchronize(destination.deletingLastPathComponent(),true)
    }
    static func readChunkedRecovery(at url:URL) throws -> [RecordRow] {
        guard UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil else {throw NotebookError.invalidModel}
        func directory(_ url:URL) throws {
            guard try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType == .typeDirectory else {throw NotebookError.invalidAsset}
        }
        try directory(url.deletingLastPathComponent());try directory(url);try directory(url.appendingPathComponent("records"))
        let manifestURL=url.appendingPathComponent("manifest.json")
        let file=try PackageIO.openRegular(manifestURL);defer {try? file.close()}
        guard try file.seekToEnd()<=16_000_000 else {throw NotebookError.invalidAsset};try file.seek(toOffset:0)
        guard let bytes=try file.readToEnd() else {throw NotebookError.invalidAsset}
        try ImportValidation.validateJSON(bytes)
        let manifest=try JSONDecoder().decode(RecoveryManifest.self,from:bytes)
        guard manifest.version==5,[1,2,3,4].contains(manifest.libraryVersion),(1...1_000_000).contains(manifest.rowCount),(1...4096).contains(manifest.chunks.count),
              (0...576_000_000).contains(manifest.rawMetadataBytes),(0...768_000_000-bytes.count).contains(manifest.encodedMetadataBytes),
              manifest.chunks.map(\.path)==(0..<manifest.chunks.count).map(RecordChunks.path) else {throw NotebookError.invalidModel}
        guard Set(try FileManager.default.contentsOfDirectory(atPath:url.path))==["manifest.json","records"],
              Set(try FileManager.default.contentsOfDirectory(atPath:url.appendingPathComponent("records").path))==Set(manifest.chunks.map{URL(fileURLWithPath:$0.path).lastPathComponent}) else {throw NotebookError.invalidModel}
        var encoded=0,count=0
        for chunk in manifest.chunks {
            guard (1...24_000_000).contains(chunk.size),(1...256).contains(chunk.rowCount),PageContent.isHash(chunk.sha256),chunk.size<=manifest.encodedMetadataBytes-encoded,chunk.rowCount<=manifest.rowCount-count else {throw NotebookError.invalidAsset}
            encoded+=chunk.size;count+=chunk.rowCount
        }
        guard encoded==manifest.encodedMetadataBytes,count==manifest.rowCount else {throw NotebookError.invalidModel}
        let rows=try RecordChunks.decode(count:manifest.chunks.count,expectedRows:manifest.chunks.map(\.rowCount)) { index in
            let chunk=manifest.chunks[index]
            try Task.checkCancellation();let file=try PackageIO.openRegular(url.appendingPathComponent(chunk.path));defer {try? file.close()}
            guard try file.seekToEnd()==UInt64(chunk.size) else {throw NotebookError.invalidAsset};try file.seek(toOffset:0)
            guard let data=try file.readToEnd(),AssetStore.hash(data)==chunk.sha256 else {throw NotebookError.hashMismatch}
            return data
        }
        guard try rows.reduce(0,{try $0+RecordChunks.rawSize($1)})==manifest.rawMetadataBytes else {throw NotebookError.invalidModel}
        let graph=try validateGraph(rows);guard graph.library.version==manifest.libraryVersion else {throw NotebookError.invalidModel};return rows
    }
}
