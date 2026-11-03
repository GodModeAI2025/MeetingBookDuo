import Foundation
import CoreData
import PencilKit
import MeetingBookCore

enum SyncActivationError: Error { case incomplete, leased, concurrent }

extension NotebookStore {
    /// Only a complete transaction reaches the existing graph validator and SQLite save.
    func reconcileWire(scope: SyncScope) throws -> Int {
        try requireScope(scope);guard scope.enabled else {throw NotebookError.revisionConflict}
        let wires=try wireRecords(scope:scope),byID=Dictionary(uniqueKeysWithValues:wires.map{($0.record.id,$0.record)})
        let manifests=try wires.filter{$0.record.kind == .transaction}.map{try decoder.decode(SyncTransactionManifest.self,from:$0.record.bytes)}
        try SyncTransactionContext.validatePartialGraph(manifests.map(\.context)+transactionContexts(),account:scope.accountFingerprint)
        var count=0,progress=true
        while progress {
            progress=false
            for manifest in manifests {
                if try record("sync-applied-"+manifest.id.uuidString) != nil || record("sync-consumed-"+manifest.id.uuidString) != nil {continue}
                do {
                    let preliminary=try readWireOperations(manifest,wires:byID,scope:scope)
                    if preliminary.contains(where:{$0.entity.hasPrefix("resolution/")}) {
                        try activateResolutionTransaction(manifest,operations:preliminary,wires:byID,scope:scope)
                        count+=1;progress=true;continue
                    }
                    for dependency in manifest.context.dependencies {
                        guard try record("sync-context-"+dependency.uuidString) != nil else {throw SyncActivationError.incomplete}
                    }
                    let operations=try readWireOperations(manifest,wires:byID,scope:scope)
                    try validateTransactionReferences(operations,wires:byID)
                    let plan=try makeWirePlan(operations,scope:scope)
                    let values=plan.values,conflicts=plan.conflicts,affected=plan.affectedPages,affectedFonts=plan.affectedFonts
                    let oldByID=Dictionary(uniqueKeysWithValues:try journal().map{($0.id,$0)})
                    try protection.locked {
                        try requireScope(scope)
                        guard !affected.contains(where:isPageLeasedForRemoteActivation),affectedFonts.isDisjoint(with:protection.snapshot.remoteFonts) else {throw SyncActivationError.leased}
                        try transaction(journalChanges:false) {
                            try projectRemote(values:values,wires:byID,scope:scope)
                            for conflict in conflicts {try projectConflict(conflict,scope:scope,wires:byID)}
                            for op in operations {
                                if let existing=oldByID[op.id] {guard existing==op else {throw NotebookError.invalidModel};continue}
                                try put(op,key:"operation-"+op.id.uuidString,kind:"causalOperation")
                                try put(ScopedAcknowledgement(operationID:op.id,valueHash:op.valueHash,scope:scope,received:true),key:"ack-"+op.id.uuidString,kind:"operationAck")
                            }
                            try put(manifest.context,key:"sync-context-"+manifest.id.uuidString,kind:"syncContext")
                            try consumeConflictEvidence(wires:byID)
                            try put(AppliedSyncTransaction(id:manifest.id,scope:scope),key:"sync-applied-"+manifest.id.uuidString,kind:"syncApplied")
                        }
                    }
                    count+=1;progress=true
                } catch SyncActivationError.incomplete {continue}
                catch SyncActivationError.leased {continue}
                catch SyncActivationError.concurrent {continue}
            }
        }
        return count
    }
    func readWireOperations(_ manifest:SyncTransactionManifest,wires:[String:SyncWireRecord],scope:SyncScope) throws -> [CausalOperation] {
        let operations=try manifest.members.map {id -> CausalOperation in
            guard let wire=wires["operation-"+id.uuidString] else {throw SyncActivationError.incomplete}
            let operation=try decoder.decode(CausalOperation.self,from:wire.bytes)
            guard operation.transactionID==manifest.id,operation.accountFingerprint==scope.accountFingerprint,operation.libraryID==manifest.context.libraryID,operation.deviceID==manifest.context.deviceID,operation.accountFingerprint==manifest.context.accountFingerprint else {throw NotebookError.invalidModel};return operation
        }
        return operations
    }
    func makeWirePlan(_ operations:[CausalOperation],scope:SyncScope,history:[CausalOperation]? = nil) throws -> SyncActivationPlan {
        let old=try history ?? journal(),oldByID=Dictionary(uniqueKeysWithValues:old.map{($0.id,$0)})
        for op in operations {for base in op.bases where oldByID[base]==nil && !operations.contains(where:{$0.id==base}) {throw SyncActivationError.incomplete}}
        var values=try entityValues(),changed=Set<String>(),conflicts:[SyncConflict]=[],appendMerges:[String:[UUID]]=[:]
        for op in operations {
            if op.entity.hasPrefix("note/"),op.entity.hasSuffix("/timestamps") {continue}
            if let original=oldByID[op.id] {guard original==op else {throw NotebookError.invalidModel};continue}
            let same=old.filter{$0.entity==op.entity && $0.accountFingerprint==scope.accountFingerprint}
            let superseded=Set(same.flatMap(\.bases)),tips=same.filter{!superseded.contains($0.id)}
            var apply=true
            for tip in tips {
                switch try RevisionConflictResolver.classify(local:tip,incoming:op,operations:old+operations) {
                case .same,.local: apply=false
                case .incoming: break
                case .incomplete: throw SyncActivationError.incomplete
                case .concurrent:
                    if tip.valueHash != op.valueHash {
                        if op.entity=="bookmarkOrder" || op.entity=="preference/textDefaults" || op.entity.hasSuffix("/bookmark") {
                            // Source permits LWW only for bookmark/display settings; UUID breaks equal clocks.
                            if tip.createdAt>op.createdAt || (tip.createdAt==op.createdAt && tip.id.uuidString>op.id.uuidString) {apply=false}
                            continue
                        }
                        if op.entity.hasPrefix("note/"),op.entity.hasSuffix("/pages"),let merged=try RevisionConflictResolver.concurrentAppends(tips+[op],operations:old+operations) {
                            appendMerges[op.entity]=merged;continue
                        }
                        guard op.entity.hasPrefix("page/"),op.entity.hasSuffix("/head") else {throw SyncActivationError.concurrent}
                        conflicts.append(try SyncConflict(tip,op))
                        if tip.id.uuidString<op.id.uuidString {apply=false}
                    }
                }
            }
            if apply {values[op.entity]=op.value;changed.insert(op.entity)}
        }
        let timestampEntities=Set(operations.filter{$0.entity.hasPrefix("note/") && $0.entity.hasSuffix("/timestamps")}.map(\.entity))
        for entity in timestampEntities {
            let all=Dictionary((old+operations).filter{$0.entity==entity && $0.accountFingerprint==scope.accountFingerprint}.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
            let bytes=try encoder.encode(NoteTimestampMetadata.project(Array(all.values)))
            if values[entity] != bytes {values[entity]=bytes;changed.insert(entity)}
        }
        for (entity,pages) in appendMerges {
            values[entity]=try encoder.encode(pages);changed.insert(entity)
            for (index,page) in pages.enumerated() {let key="page/"+page.uuidString+"/order";values[key]=try encoder.encode(Int64(index));changed.insert(key)}
        }
        conflicts+=try deletionEditConflicts(incoming:operations,history:old,values:values,scope:scope)
        let affected=try affectedRemotePages(changed:changed,values:values),affectedFonts=try affectedRemoteFonts(changed:changed,values:values)
        return SyncActivationPlan(values:values,changed:changed,conflicts:conflicts,affectedPages:affected,affectedFonts:affectedFonts)
    }
    /// Read-only bounded diagnostics; sources are the already durable exact manifests and wire bodies.
    func pendingWireTransactions(scope:SyncScope,limit:Int=250) throws -> [SyncPendingTransaction] {
        try requireScope(scope);guard limit>0,limit<=250 else {throw NotebookError.invalidModel}
        let wires=Dictionary(uniqueKeysWithValues:try wireRecords(scope:scope).map{($0.record.id,$0.record)})
        let manifests=try wires.values.filter{$0.kind == .transaction}.map{try decoder.decode(SyncTransactionManifest.self,from:$0.bytes)}.sorted{$0.id.uuidString<$1.id.uuidString}
        try SyncTransactionContext.validatePartialGraph(manifests.map(\.context)+transactionContexts(),account:scope.accountFingerprint)
        var result:[SyncPendingTransaction]=[]
        for manifest in manifests {
            if try record("sync-applied-"+manifest.id.uuidString) != nil || record("sync-consumed-"+manifest.id.uuidString) != nil {continue}
            var operations:[CausalOperation]=[],reason=SyncPendingReason.ready
            do {
                operations=try readWireOperations(manifest,wires:wires,scope:scope)
                for dependency in manifest.context.dependencies {guard try record("sync-context-"+dependency.uuidString) != nil else {throw SyncActivationError.incomplete}}
                try validateTransactionReferences(operations,wires:wires)
                let plan=try makeWirePlan(operations,scope:scope)
                if !plan.affectedPages.isDisjoint(with:protection.snapshot.remotePages) || !plan.affectedFonts.isDisjoint(with:protection.snapshot.remoteFonts) {reason = .leased}
            } catch SyncActivationError.incomplete {reason = .incomplete}
            catch SyncActivationError.concurrent {reason = .conflict}
            var values=try entityValues();for operation in operations {values[operation.entity]=operation.value}
            let entities=Set(operations.map(\.entity))
            result.append(SyncPendingTransaction(id:manifest.id,reason:reason,entities:entities,affectedPageIDs:try affectedRemotePages(changed:entities,values:values),affectedFontIDs:try affectedRemoteFonts(changed:entities,values:values)))
            if result.count==limit {break}
        }
        return result
    }
    func projectRemote(values: [String:Data],wires: [String:SyncWireRecord],scope: SyncScope) throws {
        func read<T:Decodable>(_ key: String,_ type: T.Type) throws -> T {guard let bytes=values[key] else {throw SyncActivationError.incomplete};return try decoder.decode(type,from:bytes)}
        func ids(_ prefix: String) -> Set<UUID> {Set(values.keys.filter{$0.hasPrefix(prefix+"/")}.compactMap{UUID(uuidString:String($0.split(separator:"/")[1]))})}
        for wire in wires.values where (wire.kind == .revision || wire.kind == .header) && values["revision/"+String(wire.id.dropFirst(wire.kind.rawValue.count+1))] != nil {
            let id=String(wire.id.dropFirst(wire.kind.rawValue.count+1))
            let incoming=wire.kind == .revision ? RevisionHeader(try decoder.decode(PageRevision.self,from:wire.bytes)) : try decoder.decode(RevisionHeader.self,from:wire.bytes)
            guard let intent=values["revision/"+id],try decoder.decode(RevisionHeader.self,from:intent)==incoming else {throw NotebookError.invalidModel}
            if let current=try record(id) {
                let existing=try (try? decoder.decode(PageRevision.self,from:current)).map(RevisionHeader.init) ?? decoder.decode(RevisionHeader.self,from:current)
                let next=wire.kind == .revision ? RevisionHeader(try decoder.decode(PageRevision.self,from:wire.bytes)) : try decoder.decode(RevisionHeader.self,from:wire.bytes)
                guard existing==next else {throw NotebookError.invalidModel}
                if wire.kind == .header {continue}
                if let revision=try? decoder.decode(PageRevision.self,from:current) {guard revision == (try decoder.decode(PageRevision.self,from:wire.bytes)) else {throw NotebookError.invalidModel};continue}
            }
            try putRemoteBytes(wire.bytes,key:id,kind:wire.kind == .revision ? "revision" : "revisionHeader")
        }
        let fontIDs=ids("fontVersion")
        var versions:[UUID:FontVersion]=[:]
        for id in fontIDs {
            let font:FontVersion=try read("fontVersion/"+id.uuidString,FontVersion.self)
            guard font.id==id else {throw NotebookError.invalidModel}
            if let old=(try fontVersions()).first(where:{$0.id==id}) {guard old==font else {throw NotebookError.invalidModel}}
            versions[id]=font
        }
        var projects:[FontProject]=[]
        struct Glyph: Decodable {let hash: String?;let metrics: GlyphCaptureMetrics?}
        for id in ids("font") {
            let prefix="font/"+id.uuidString+"/",publications:[UUID]=try read(prefix+"publications",[UUID].self)
            var project=FontProject(id:id,name:try read(prefix+"name",String.self));project.formatVersion=3;project.publishedVersionIDs=publications
            for key in values.keys where key.hasPrefix(prefix+"glyph/") {
                guard let code=UInt32(key.split(separator:"/").last!) else {throw NotebookError.invalidModel}
                let glyph:Glyph=try read(key,Glyph.self);project.glyphAssetHashes[code]=glyph.hash;project.glyphMetrics[code]=glyph.metrics
            }
            for versionID in publications {
                guard let version=versions[versionID] else {throw SyncActivationError.incomplete}
                let owner:UUID=try read("fontVersion/"+versionID.uuidString+"/owner",UUID.self)
                if owner==id {project.versions.append(version)}
            }
            try project.validateMetadata();projects.append(project)
        }
        for version in versions.values {
            let owner:UUID=try read("fontVersion/"+version.id.uuidString+"/owner",UUID.self),key="retained-font-"+version.id.uuidString
            if projects.contains(where:{$0.versions.contains(where:{$0.id==version.id})}) {try removeRecord(key)}
            else {
                let old=try record(key).map{try decoder.decode(RetainedFontVersion.self,from:$0)}
                let source=try wires.values.filter{$0.kind == .operation}.map{try decoder.decode(CausalOperation.self,from:$0.bytes)}.first{$0.entity=="fontVersion/"+version.id.uuidString}
                guard let origin=old?.originLibraryID ?? source?.libraryID else {throw SyncActivationError.incomplete}
                try put(RetainedFontVersion(font:version,ownerProjectID:owner,originLibraryID:origin),key:key,kind:"retainedFontVersion");library.version=max(3,library.version)
            }
        }
        library.fonts=projects
        for id in ids("resolution") {
            let resolution:SyncResolution=try read("resolution/"+id.uuidString,SyncResolution.self);try resolution.validate()
            try put(resolution,key:"sync-resolution-"+id.uuidString,kind:"syncResolution")
        }
        var notes:[Note]=[]
        for id in ids("note") {
            let prefix="note/"+id.uuidString+"/"
            var note=Note(id:id,title:try read(prefix+"title",String.self),orderKey:try read(prefix+"order",Int64.self),pageIDs:try read(prefix+"pages",[UUID].self))
            note.deletedAt=try read(prefix+"deleted",Date?.self)
            if let bytes=values[prefix+"timestamps"] {
                let timestamps=try decoder.decode(NoteTimestampMetadata.self,from:bytes)
                note.createdAt=timestamps.createdAt;note.modifiedAt=timestamps.modifiedAt;library.version=4
            }
            if note.pageIDs.allSatisfy({values["page/"+$0.uuidString+"/retired"] != nil}) {try put(note,key:"expired-note-"+id.uuidString,kind:"expiredNote")}
            else {notes.append(note);try removeRecord("expired-note-"+id.uuidString)}
        }
        library.notes=notes
        for id in ids("page") {
            let prefix="page/"+id.uuidString+"/"
            if let retired=values[prefix+"retired"] {try putRemoteBytes(retired,key:id.uuidString,kind:"expiredPage");continue}
            let revisionID:UUID=try read(prefix+"head",UUID.self)
            guard let bytes=try record(revisionID.uuidString),let revision=try? decoder.decode(PageRevision.self,from:bytes) else {throw SyncActivationError.incomplete}
            guard revision.pageID==id else {throw NotebookError.invalidModel}
            let page=PageSnapshot(id:id,noteID:try read(prefix+"owner",UUID.self),orderKey:try read(prefix+"order",Int64.self),currentRevisionID:revisionID,bookmark:try read(prefix+"bookmark",Bool.self),content:revision.content)
            try put(page,key:id.uuidString,kind:"page")
            let deleted:Date?=try read(prefix+"deleted",Date?.self)
            if let deleted {try put(deleted,key:"deleted-page-"+id.uuidString,kind:"pageTombstone")} else {try removeRecord("deleted-page-"+id.uuidString)}
        }
        library.preferences.textDefaults=try read("preference/textDefaults",TextDefaults?.self)
        library.bookmarkOrder=try read("bookmarkOrder",[UUID].self)
        try put(library,key:"library",kind:"library")
        let context=self.context,rows=try context.performAndWait{try Self.rows(context:context)}
        // Missing assets/parents are pending; the final validator still rejects malformed complete graphs.
        for wire in wires.values where wire.kind == .revision && values["revision/"+String(wire.id.dropFirst("revision-".count))] != nil {
            let revision=try decoder.decode(PageRevision.self,from:wire.bytes)
            for parent in revision.parentRevisionIDs where try record(parent.uuidString)==nil {throw SyncActivationError.incomplete}

        }
        // The outer atomic save validates the complete graph after journal/context/resolution rows exist.
        for font in try fontVersions() {try PersonalFontService.validateForImport(version:font,data:syncAsset(font.assetHash))}
        for row in rows where row.kind=="revision" {
            let revision=try decoder.decode(PageRevision.self,from:row.payload)
            if let hash=revision.content.drawingAssetHash {_ = try PKDrawing(data:syncAsset(hash))}
            for image in revision.content.images {
                for hash in Set([image.assetHash,image.previewAssetHash].compactMap({$0})) {
                    var item=ImageElement(frame:image.frame,assetHash:hash,altText:image.altText)
                    if hash==image.previewAssetHash {item.previewAssetHash=hash}
                    var isolated=PageContent();isolated.version=2;isolated.images=[item]
                    try PageClipboard(content:isolated,assets:[hash:syncAsset(hash)],fonts:[]).validate()
                }
            }
        }
        for project in library.fonts {for hash in project.glyphAssetHashes.values {
            let bytes=try syncAsset(hash);guard bytes.count<=2_000_000 else {throw NotebookError.invalidAsset};_ = try PKDrawing(data:bytes)
        }}
    }
    func validateTransactionReferences(_ operations:[CausalOperation],wires:[String:SyncWireRecord]) throws {
        try CausalOperation.validateNoteMetadataCompleteness(operations)
        var revisions:[UUID:PageRevision]=[:],fonts=Dictionary(uniqueKeysWithValues:try fontVersions().map{($0.id,$0)})
        for wire in wires.values where wire.kind == .font {
            let font=try decoder.decode(FontVersion.self,from:wire.bytes)
            if let old=fonts[font.id],old != font {throw NotebookError.invalidModel};fonts[font.id]=font
        }
        for operation in operations {
            try operation.validateWireValue()
            for hash in operation.assets {_ = try syncAsset(hash)}
            for id in operation.revisions where revisions[id]==nil {
                let bytes:Data
                if let wire=wires["revision-"+id.uuidString] {bytes=wire.bytes}
                else if let local=try record(id.uuidString), (try? decoder.decode(PageRevision.self,from:local)) != nil {bytes=local}
                else {throw SyncActivationError.incomplete}
                let revision=try decoder.decode(PageRevision.self,from:bytes)
                guard revision.id==id else {throw NotebookError.invalidModel}
                if let header=wires["header-"+id.uuidString] {guard try decoder.decode(RevisionHeader.self,from:header.bytes)==RevisionHeader(revision) else {throw NotebookError.invalidModel}}
                else if try record(id.uuidString)==nil {throw SyncActivationError.incomplete}
                if let hash=revision.content.drawingAssetHash {_ = try PKDrawing(data:syncAsset(hash))}
                for image in revision.content.images {for hash in Set([image.assetHash,image.previewAssetHash].compactMap({$0})) {
                    var item=ImageElement(frame:image.frame,assetHash:hash,altText:image.altText);if hash==image.previewAssetHash {item.previewAssetHash=hash}
                    var isolated=PageContent();isolated.version=2;isolated.images=[item]
                    try PageClipboard(content:isolated,assets:[hash:syncAsset(hash)],fonts:[]).validate()
                }}
                for fontID in revision.content.textBlocks.compactMap(\.fontVersionID) {
                    guard let font=fonts[fontID] else {throw SyncActivationError.incomplete}
                    try PersonalFontService.validateForImport(version:font,data:syncAsset(font.assetHash))
                }
                revisions[id]=revision
            }
            let parts=operation.entity.split(separator:"/").map(String.init)
            if parts.first=="page",parts.last=="head",let value=operation.value {
                let id=try decoder.decode(UUID.self,from:value)
                guard operation.revisions.contains(id),revisions[id]?.pageID.uuidString==parts[1] else {throw NotebookError.invalidModel}
            }
            if parts.first=="font",parts.count==4,let value=operation.value {
                struct Glyph:Decodable {let hash:String?}
                if let hash=try decoder.decode(Glyph.self,from:value).hash {let bytes=try syncAsset(hash);guard bytes.count<=2_000_000 else {throw NotebookError.invalidAsset};_ = try PKDrawing(data:bytes)}
            }
            if parts.first=="fontVersion",parts.count==2,let value=operation.value {
                let font=try decoder.decode(FontVersion.self,from:value)
                guard let declared=fonts[font.id] else {throw SyncActivationError.incomplete};guard declared==font else {throw NotebookError.invalidModel}
                try PersonalFontService.validateForImport(version:font,data:syncAsset(font.assetHash))
            }
        }
    }
    private func syncAsset(_ hash:String) throws -> Data {
        do {return try AssetStore.verifiedData(hash:hash,root:root.appendingPathComponent("assets"))}
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {throw SyncActivationError.incomplete}
    }
    func affectedRemoteFonts(changed:Set<String>,values:[String:Data]) throws -> Set<UUID> {
        var result=Set<UUID>()
        for key in changed {
            let parts=key.split(separator:"/").map(String.init)
            guard parts.count>1,let id=UUID(uuidString:parts[1]) else {continue}
            if parts[0]=="font" {result.insert(id)}
            if parts[0]=="fontVersion" {
                result.formUnion(library.fonts.filter{$0.publicationIDs.contains(id)}.map(\.id))
                if let owner=try fontDependencyMetadata().first(where:{$0.font.id==id})?.ownerProjectID {result.insert(owner)}
                if let bytes=values["fontVersion/"+id.uuidString+"/owner"] {result.insert(try decoder.decode(UUID.self,from:bytes))}
            }
        }
        return result
    }
    func affectedRemotePages(changed:Set<String>,values:[String:Data]) throws -> Set<UUID> {
        var result=Set<UUID>()
        for key in changed {
            let parts=key.split(separator:"/").map(String.init)
            guard parts.count>1,let id=UUID(uuidString:parts[1]) else {continue}
            if parts[0]=="page" {result.insert(id)}
            if parts[0]=="note" {
                result.formUnion(library.notes.first(where:{$0.id==id})?.pageIDs ?? [])
                if let bytes=values["note/"+id.uuidString+"/pages"] {result.formUnion(try decoder.decode([UUID].self,from:bytes))}
            }
        }
        return result
    }
    func putRemoteBytes(_ bytes: Data,key: String,kind: String) throws {
        let context=self.context
        try context.performAndWait {
            try Self.setRecord(bytes,key:key,kind:kind,context:context)
        }
    }
}
struct AppliedSyncTransaction: Codable, Sendable {var version=1;let id: UUID;let scope: SyncScope}


struct SyncActivationPlan {
    let values:[String:Data]
    let changed:Set<String>
    let conflicts:[SyncConflict]
    let affectedPages:Set<UUID>
    let affectedFonts:Set<UUID>
}
enum SyncPendingReason: String,Sendable {case ready,incomplete,leased,conflict}
struct SyncPendingTransaction: Sendable,Identifiable {
    let id:UUID
    let reason:SyncPendingReason
    let entities:Set<String>
    let affectedPageIDs:Set<UUID>
    let affectedFontIDs:Set<UUID>
}

extension NotebookStore {
    /// Missing conflict ancestors are incorporated only together with their complete causal resolution.
    func activateResolutionTransaction(_ manifest:SyncTransactionManifest,operations:[CausalOperation],wires:[String:SyncWireRecord],scope:SyncScope) throws {
        let resolutions=try operations.filter{$0.entity.hasPrefix("resolution/")}.map{operation -> SyncResolution in
            guard let value=operation.value else {throw NotebookError.invalidModel}
            let resolution=try decoder.decode(SyncResolution.self,from:value);try resolution.validate()
            guard resolution.resultHashes.allSatisfy({entity,hash in operations.contains{$0.entity==entity && $0.valueHash==hash}}) else {throw NotebookError.invalidModel}
            return resolution
        }
        for resolution in resolutions {
            if let id=resolution.pageConflictID,try record("sync-conflict-"+id.uuidString)==nil,wires["conflict-"+id.uuidString]==nil {throw SyncActivationError.incomplete}
        }
        let authorized=Set(resolutions.flatMap(\.sourceTransactionIDs))
        var missing:[UUID:SyncTransactionManifest]=[:],members:[UUID:[CausalOperation]]=[manifest.id:operations],queue=manifest.context.dependencies
        while let id=queue.popLast() {
            if try record("sync-context-"+id.uuidString) != nil || missing[id] != nil {continue}
            guard let bytes=wires["transaction-"+id.uuidString]?.bytes else {throw SyncActivationError.incomplete}
            let source=try decoder.decode(SyncTransactionManifest.self,from:bytes),ops=try readWireOperations(source,wires:wires,scope:scope)
            try validateTransactionReferences(ops,wires:wires);missing[id]=source;members[id]=ops;queue+=source.context.dependencies
        }
        try validateTransactionReferences(operations,wires:wires)
        // Every declared source must be causal history, never an unrelated transaction to discard.
        var ancestors=Set<UUID>(),ancestry=manifest.context.dependencies
        let existing=Dictionary(uniqueKeysWithValues:try transactionContexts().map{($0.id,$0)})
        while let id=ancestry.popLast() {guard ancestors.insert(id).inserted else {continue};guard let context=missing[id]?.context ?? existing[id] else {throw SyncActivationError.incomplete};ancestry+=context.dependencies}
        guard authorized.isSubset(of:ancestors) else {throw NotebookError.invalidModel}
        let allOperations=operations+members.filter{$0.key != manifest.id}.flatMap(\.value),entities=Set(allOperations.map(\.entity))
        var candidate=try entityValues();for operation in allOperations {candidate[operation.entity]=operation.value}
        let affected=try affectedRemotePages(changed:entities,values:candidate),fonts=try affectedRemoteFonts(changed:entities,values:candidate)
        try protection.locked {
            try requireScope(scope);guard affected.isDisjoint(with:protection.snapshot.remotePages),fonts.isDisjoint(with:protection.snapshot.remoteFonts) else {throw SyncActivationError.leased}
            try transaction(journalChanges:false) {
                var remaining=missing,consumedIDs=Set<UUID>()
                while !remaining.isEmpty {
                    guard let source=try remaining.values.sorted(by:{$0.id.uuidString<$1.id.uuidString}).first(where:{source in try source.context.dependencies.allSatisfy{try record("sync-context-"+$0.uuidString) != nil}}) else {throw SyncActivationError.incomplete}
                    let ops=members[source.id]!
                    do {
                        let plan=try makeWirePlan(ops,scope:scope)
                        try projectRemote(values:plan.values,wires:wires,scope:scope)
                        for conflict in plan.conflicts {try projectConflict(conflict,scope:scope,wires:wires)}
                        try put(AppliedSyncTransaction(id:source.id,scope:scope),key:"sync-applied-"+source.id.uuidString,kind:"syncApplied")
                    } catch SyncActivationError.concurrent {
                        guard authorized.contains(source.id),resolutions.contains(where:{$0.sourceTransactionIDs.contains(source.id) && $0.coversMutableEntities(ops)}) else {throw SyncActivationError.concurrent}
                        consumedIDs.insert(source.id)
                    }
                    try receiveWireHistory(source,operations:ops,scope:scope)
                    remaining.removeValue(forKey:source.id)
                }
                let plan=try makeWirePlan(operations,scope:scope)
                try projectRemote(values:plan.values,wires:wires,scope:scope)
                for conflict in plan.conflicts {try projectConflict(conflict,scope:scope,wires:wires)}
                try receiveWireHistory(manifest,operations:operations,scope:scope)
                try consumeConflictEvidence(wires:wires)
                for id in consumedIDs {
                    let key="sync-consumed-"+id.uuidString
                    var ids=try record(key).map{try decoder.decode(ConsumedSyncTransaction.self,from:$0).resolutionIDs} ?? []
                    ids.formUnion(resolutions.filter{$0.sourceTransactionIDs.contains(id)}.map(\.id))
                    try put(ConsumedSyncTransaction(id:id,scope:scope,resolutionIDs:ids),key:key,kind:"syncConsumed")
                }
                try put(AppliedSyncTransaction(id:manifest.id,scope:scope),key:"sync-applied-"+manifest.id.uuidString,kind:"syncApplied")
            }
        }
    }
    func receiveWireHistory(_ manifest:SyncTransactionManifest,operations:[CausalOperation],scope:SyncScope) throws {
        for operation in operations {
            if let bytes=try record("operation-"+operation.id.uuidString) {guard try decoder.decode(CausalOperation.self,from:bytes)==operation else {throw NotebookError.invalidModel}}
            else {
                try put(operation,key:"operation-"+operation.id.uuidString,kind:"causalOperation")
                try put(ScopedAcknowledgement(operationID:operation.id,valueHash:operation.valueHash,scope:scope,received:true),key:"ack-"+operation.id.uuidString,kind:"operationAck")
            }
        }
        try put(manifest.context,key:"sync-context-"+manifest.id.uuidString,kind:"syncContext")
    }
}


extension NotebookStore {
    func deletionEditConflicts(incoming:[CausalOperation],history:[CausalOperation],values:[String:Data],scope:SyncScope) throws -> [SyncConflict] {
        var all=Dictionary(uniqueKeysWithValues:history.map{($0.id,$0)})
        for operation in incoming {all[operation.id]=operation}
        let scoped=all.values.filter{$0.accountFingerprint==scope.accountFingerprint},superseded=Set(scoped.flatMap(\.bases)),tips=scoped.filter{!superseded.contains($0.id)},incomingIDs=Set(incoming.map(\.id))
        let heads=tips.filter{$0.entity.hasPrefix("page/") && $0.entity.hasSuffix("/head")}
        let deletions=try tips.filter{operation in guard operation.entity.hasSuffix("/deleted"),let value=operation.value else {return false};return try decoder.decode(Date?.self,from:value) != nil}
        guard !deletions.isEmpty else {return []}
        var contexts=Dictionary(uniqueKeysWithValues:try transactionContexts().map{($0.id,$0)})
        for bytes in try records("syncWire") {
            let stored=try decoder.decode(StoredSyncWire.self,from:bytes);guard stored.kind == .transaction else {continue}
            let body=try AssetStore.verifiedData(hash:stored.bodyHash,root:root.appendingPathComponent("assets")),manifest=try decoder.decode(SyncTransactionManifest.self,from:body)
            if let old=contexts[manifest.id],old != manifest.context {throw NotebookError.invalidModel};contexts[manifest.id]=manifest.context
        }
        var result:[SyncConflict]=[]
        for deletion in deletions {for head in heads where incomingIDs.contains(deletion.id) || incomingIDs.contains(head.id) {
            let page=String(head.entity.split(separator:"/")[1]),parts=deletion.entity.split(separator:"/").map(String.init)
            let matches:Bool
            if parts[0]=="page" {matches=parts[1]==page}
            else if let owner=values["page/"+page+"/owner"] {matches=try decoder.decode(UUID.self,from:owner).uuidString==parts[1]}
            else {matches=false}
            guard matches else {continue}
            guard let concurrent=SyncTransactionContext.areConcurrent(deletion.transactionID,head.transactionID,contexts:contexts) else {throw SyncActivationError.incomplete}
            if concurrent {result.append(try SyncConflict(deletion:deletion,edit:head))}
        }}
        return result
    }
}
