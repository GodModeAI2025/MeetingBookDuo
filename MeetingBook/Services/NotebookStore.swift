import Foundation
import CoreData
import CryptoKit
import MeetingBookCore

/// Exists only during a full transaction and is accessed only on its Core Data queue.
private final class TransactionRecordIndex {
    static let contextKey="MeetingBook.transactionRecords"
    var objects:[String:NSManagedObject]=[:]
    var kinds:[String:Set<String>]=[:]
    var kindByKey:[String:String]=[:]
    init(_ records:[NSManagedObject]) throws {
        for object in records {
            guard let key=object.value(forKey:"key") as? String,let kind=object.value(forKey:"kind") as? String else {throw NotebookError.invalidModel}
            try set(object,key:key,kind:kind)
        }
    }
    func set(_ object:NSManagedObject,key:String,kind:String) throws {
        if let old=objects[key],old !== object {throw NotebookError.invalidModel}
        if let old=kindByKey[key] {kinds[old]?.remove(key)}
        objects[key]=object;kindByKey[key]=kind;kinds[kind,default:[]].insert(key)
    }
    func remove(_ key:String) {
        objects.removeValue(forKey:key)
        if let kind=kindByKey.removeValue(forKey:key) {kinds[kind]?.remove(key)}
    }
    func removeAll() {objects.removeAll();kinds.removeAll();kindByKey.removeAll()}
}

/// Actor-owned values and encoding; managed objects never leave the private context queue.
actor NotebookStore {
    private let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext
    nonisolated let protection: StorageProtection
    nonisolated let identity: UUID
    let assets: AssetStore
    let encoder: JSONEncoder = { let e=JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    let decoder=JSONDecoder()
    let root: URL
    struct Library: Codable, Sendable {
        var version = 4
        var ownership: SyncScope?
        var deviceID=UUID()
        var sequence: Int64 = 0
        var notes: [Note] = []
        var preferences=LibraryPreferences()
        var fonts: [FontProject] = []
        var bookmarkOrder: [UUID]?
    }
    #if DEBUG
    var performancePhases:[String:Double]?
    var lastRetentionCaptureMS:Double?
    var retentionPlanReady:(@Sendable () throws -> Void)?
    #endif
    var validatedAssetHashes=Set<String>()
    private var generationCache:(epoch:UUID,value:String)?
    var cacheEpoch:UUID?
    var causalProjection:CausalProjection?
    var transactionInProgress=false
    struct CausalProjection:Sendable {
        var frontiers:[String:Set<UUID>]
        var contexts:Set<UUID>
    }
    var searchDocuments:[UUID:SearchDocument]?
    struct SearchDocument:Sendable {let bookmark:Bool;let text:String}
    var library: Library
    private init(root: URL) throws {
        assert(!Thread.isMainThread, "SQLite startup must run off the main thread")
        self.root=root
        protection=StorageProtection.forRoot(root.appendingPathComponent("assets"))
        let openingLease=protection.retain(blocksCollection:true);defer{withExtendedLifetime(openingLease){}}
        let openingEpoch=protection.currentCommitEpoch
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:AssetStore.protection)
        let model=NSManagedObjectModel()
        let entity=NSEntityDescription(); entity.name="Record"; entity.managedObjectClassName="NSManagedObject"
        entity.properties=[("key",NSAttributeType.stringAttributeType),("kind",.stringAttributeType),("payload",.binaryDataAttributeType)].map { name,type in let a=NSAttributeDescription();a.name=name;a.attributeType=type;a.isOptional=false;return a }
        entity.uniquenessConstraints=[["key"]];model.entities=[entity]
        coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
        var options: [AnyHashable:Any] = [NSMigratePersistentStoresAutomaticallyOption:false, NSInferMappingModelAutomaticallyOption:false, NSSQLitePragmasOption:["journal_mode":"WAL","synchronous":"FULL","fullfsync":"ON","checkpoint_fullfsync":"ON"]]
        #if os(iOS)
        options[NSPersistentStoreFileProtectionKey]=FileProtectionType.complete
        #endif
        let database=root.appendingPathComponent("metadata.sqlite")
        let existed=FileManager.default.fileExists(atPath:database.path)
        if existed { options[NSReadOnlyPersistentStoreOption]=true }
        let persistent=try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:database,options:options)
        let privateContext=NSManagedObjectContext(concurrencyType:.privateQueueConcurrencyType)
        privateContext.persistentStoreCoordinator=coordinator
        let stored=try privateContext.performAndWait { try Self.rows(context:privateContext) }
        let graph: ValidatedGraph
        if existed {
            // Never repair a missing root or activate an inconsistent graph while opening.
            graph=try Self.validateGraph(stored)
        } else {
            guard stored.isEmpty else { throw NotebookError.invalidModel }
            var value=Library();value.ownership=SyncScope(libraryID:UUID());value.preferences.version=2;value.preferences.textDefaults=TextDefaults(fontCatalogID:"bundled.caveat");let payload=try JSONEncoder().encode(value)
            graph=try Self.validateGraph([RecordRow(key:"library",kind:"library",payload:payload)])
            try privateContext.performAndWait {
                let object=NSEntityDescription.insertNewObject(forEntityName:"Record",into:privateContext)
                object.setValue("library",forKey:"key");object.setValue("library",forKey:"kind");object.setValue(payload,forKey:"payload");try privateContext.save()
            }
        }
        let assetRoot=root.appendingPathComponent("assets")
        for hash in graph.assetHashes { _ = try AssetStore.verifiedData(hash:hash,root:assetRoot) }
        try Self.validateStoredWireBodies(stored,fonts:graph.fonts) {try AssetStore.verifiedData(hash:$0,root:assetRoot)}
        if existed {
            privateContext.performAndWait { privateContext.reset() }
            try coordinator.remove(persistent)
            options.removeValue(forKey:NSReadOnlyPersistentStoreOption)
            try coordinator.addPersistentStore(ofType:NSSQLiteStoreType,configurationName:nil,at:database,options:options)
        }
        context=privateContext;library=graph.library;searchDocuments=graph.searchDocuments;causalProjection=graph.causalProjection;validatedAssetHashes=graph.assetHashes
        cacheEpoch=protection.currentCommitEpoch==openingEpoch ? openingEpoch : nil
        let ownership=graph.library.ownership ?? SyncScope(libraryID:UUID());identity=ownership.libraryID
        assets=try AssetStore(root:assetRoot,protection:protection)
        if graph.library.version==1 || graph.library.ownership == nil {
            _ = try Self.writeLocalRecovery(rows:stored,version:graph.library.version,directory:root.appendingPathComponent("recovery"),protection:protection,prefix:"schema1-")
            library.version=max(2,library.version);library.ownership=ownership
            let bytes=try JSONEncoder().encode(library),migrationProtection=protection
            cacheEpoch=try migrationProtection.locked {
                guard migrationProtection.currentCommitEpoch==openingEpoch else {throw NotebookError.revisionConflict}
                try privateContext.performAndWait { try Self.object("library",context:privateContext)?.setValue(bytes,forKey:"payload");try privateContext.save() }
                migrationProtection.committed(graph.assetHashes);return migrationProtection.currentCommitEpoch
            }
        }
    }
    /// Open the SQLite coordinator away from the caller's actor, including SwiftUI startup.
    static func open(root: URL) async throws -> NotebookStore {
        try await Task.detached { try NotebookStore(root:root) }.value
    }
    static func object(_ key: String, context: NSManagedObjectContext) throws -> NSManagedObject? {
        if let index=context.userInfo[TransactionRecordIndex.contextKey] as? TransactionRecordIndex {return index.objects[key]}
        let request=NSFetchRequest<NSManagedObject>(entityName:"Record")
        request.predicate=NSPredicate(format:"key == %@",key);request.fetchLimit=1
        return try context.fetch(request).first
    }
    static func setRecord(_ payload:Data,key:String,kind:String,context:NSManagedObjectContext) throws {
        let object=try Self.object(key,context:context) ?? NSEntityDescription.insertNewObject(forEntityName:"Record",into:context)
        try (context.userInfo[TransactionRecordIndex.contextKey] as? TransactionRecordIndex)?.set(object,key:key,kind:kind)
        object.setValue(key,forKey:"key");object.setValue(kind,forKey:"kind");object.setValue(payload,forKey:"payload")
    }
    func record(_ key: String) throws -> Data? {
        let context=self.context
        return try context.performAndWait { try Self.object(key,context:context)?.value(forKey:"payload") as? Data }
    }
    func records(_ kind: String) throws -> [Data] {
        let context=self.context
        return try context.performAndWait {
            if let index=context.userInfo[TransactionRecordIndex.contextKey] as? TransactionRecordIndex {
                return try (index.kinds[kind] ?? []).map {key in
                    guard let bytes=index.objects[key]?.value(forKey:"payload") as? Data else {throw NotebookError.invalidModel};return bytes
                }
            }
            let request=NSFetchRequest<NSManagedObject>(entityName:"Record");request.predicate=NSPredicate(format:"kind == %@",kind)
            return try context.fetch(request).map { $0.value(forKey:"payload") as! Data }
        }
    }
    func get<T:Decodable>(_ key: String, as: T.Type) throws -> T {
        guard let data=try record(key) else { throw NotebookError.notFound }
        return try decoder.decode(T.self,from:data)
    }
    func put<T:Encodable>(_ value: T, key: String, kind: String) throws {
        if !transactionInProgress {causalProjection=nil;searchDocuments=nil}
        let payload=try encoder.encode(value)
        let context=self.context
        try context.performAndWait {
            try Self.setRecord(payload,key:key,kind:kind,context:context)
        }
    }
    func removeRecord(_ key: String) throws {
        if !transactionInProgress {causalProjection=nil;searchDocuments=nil}
        let context=self.context
        try context.performAndWait { if let object=try Self.object(key,context:context) {
            (context.userInfo[TransactionRecordIndex.contextKey] as? TransactionRecordIndex)?.remove(key);context.delete(object)
        } }
    }
    func transaction<T>(journalChanges: Bool = true,_ operation: () throws -> T) throws -> T {
        try ensureCacheEpoch()
        return try protection.locked {
            try ensureCacheEpoch()
            let context=self.context
            let ownsIndex=try context.performAndWait { () throws -> Bool in
                guard context.userInfo[TransactionRecordIndex.contextKey]==nil else {return false}
                context.userInfo[TransactionRecordIndex.contextKey]=try TransactionRecordIndex(context.fetch(NSFetchRequest<NSManagedObject>(entityName:"Record")))
                return true
            }
            defer {if ownsIndex {context.performAndWait {context.userInfo.removeObject(forKey:TransactionRecordIndex.contextKey)}}}
            transactionInProgress=true;defer{transactionInProgress=false}
            let previous=library
            let before=try journalChanges ? entityValues() : [:]
            do {
                let result=try operation()
                if journalChanges { try appendOperations(before:before) }
                try put(library,key:"library",kind:"library")
                let context=self.context
                let graph=try Self.validateGraph(context.performAndWait { try Self.rows(context:context) })
                for hash in graph.assetHashes { _ = try AssetStore.verifiedData(hash:hash,root:root.appendingPathComponent("assets")) }
                try context.performAndWait { try context.save() }
                searchDocuments=graph.searchDocuments;causalProjection=graph.causalProjection;validatedAssetHashes=graph.assetHashes;protection.committed(graph.assetHashes);cacheEpoch=protection.currentCommitEpoch;return result
            } catch {
                let context=self.context;context.performAndWait { context.rollback() };library=previous;throw error
            }
        }
    }
    func revision(_ page: PageSnapshot, parents: [UUID], reason: RevisionReason) throws -> PageRevision {
        guard library.sequence < Int64.max-1 else { throw NotebookError.invalidModel }
        library.sequence += 1
        return PageRevision(id:page.currentRevisionID,pageID:page.id,parentRevisionIDs:parents,deviceID:library.deviceID,sequence:library.sequence,createdAt:Date(),contentHash:AssetStore.hash(try encoder.encode(page.content)),content:page.content,reason:reason)
    }
    func persist(_ page: PageSnapshot, parents: [UUID], reason: RevisionReason) throws -> PageRevision {
        let revision=try revision(page,parents:parents,reason:reason)
        // Keep content separate from mutable head metadata.
        var head=page;head.content=PageContent()
        try put(head,key:page.id.uuidString,kind:"page")
        try put(revision,key:revision.id.uuidString,kind:"revision")
        let outbox=OutboxEntry(pageID:page.id,revisionID:revision.id,createdAt:revision.createdAt)
        try put(outbox,key:outbox.id.uuidString,kind:"outbox")
        return revision
    }
    func createNote(title: String, now: Date = Date()) async throws -> Note {
        guard title.utf8.count <= 10000 else { throw NotebookError.invalidModel }
        return try transaction {
            guard (library.notes.map(\.orderKey).max() ?? -1) < Int64.max-1 else { throw NotebookError.invalidModel }
            let id=UUID();let page=PageSnapshot(noteID:id,orderKey:0)
            let note=Note(id:id,title:title,orderKey:(library.notes.map(\.orderKey).max() ?? -1)+1,pageIDs:[page.id],createdAt:now,modifiedAt:now)
            library.version=4;library.notes.append(note);_ = try persist(page,parents:[],reason:.edit);return note
        }
    }
    func listNotes(includeDeleted: Bool = false) async throws -> [Note] { try ensureCacheEpoch();return LibraryRules.orderedNotes(library.notes,includeDeleted:includeDeleted) }
    func loadPage(_ id: UUID) throws -> PageSnapshot {
        try ensureCacheEpoch()
        var page=try get(id.uuidString,as:PageSnapshot.self)
        let revision=try get(page.currentRevisionID.uuidString,as:PageRevision.self)
        guard revision.pageID == id, AssetStore.hash(try encoder.encode(revision.content)) == revision.contentHash else { throw NotebookError.invalidModel }
        page.content=revision.content;try page.content.validate();return page
    }
    func openPage(id: UUID) async throws -> PageSnapshot { try loadPage(id) }
    func commit(_ edit: PageEditTransaction, now: Date = Date()) async throws -> CommitReceipt {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        try edit.content.validate()
        for fontID in edit.content.textBlocks.compactMap(\.fontVersionID) {
            guard let version=try fontVersion(id:fontID) else { throw NotebookError.invalidModel }
            try await assets.ensureDurable(hash:version.assetHash)
        }
        // Asset actor suspension happens before rereading the head and entering the transaction.
        for hash in edit.content.assetHashes { try await assets.ensureDurable(hash:hash) }
        return try authoredPageTransaction(pageIDs:[edit.pageID]) {
            var page=try loadPage(edit.pageID)
            guard page.currentRevisionID == edit.expectedRevisionID else { throw NotebookError.revisionConflict }
            guard library.notes.contains(where: { $0.id == page.noteID && $0.deletedAt == nil && $0.pageIDs.contains(page.id) }) else { throw NotebookError.notFound }
            // String equality folds canonical Unicode; a no-op must preserve exact saved bytes.
            guard try encoder.encode(page.content) != encoder.encode(edit.content) else {return CommitReceipt(pageID:page.id,revision:try get(page.currentRevisionID.uuidString,as:PageRevision.self),savedAt:now,confirmedAssetHashes:edit.content.assetHashes)}
            try markNoteModified(page.noteID,at:now)
            page.content=edit.content;page.currentRevisionID=UUID()
            let revision=try persist(page,parents:[edit.expectedRevisionID],reason:edit.reason)
            return CommitReceipt(pageID:page.id,revision:revision,savedAt:Date(),confirmedAssetHashes:edit.content.assetHashes)
        }
    }
    func validateAssets(_ contents: [PageContent], importedFonts: [FontVersion] = []) async throws -> Set<String> {
        var hashes=Set<String>()
        for content in contents {
            try content.validate();hashes.formUnion(content.assetHashes)
            for id in content.textBlocks.compactMap(\.fontVersionID) {
                guard let font=try fontVersion(id:id) ?? importedFonts.first(where:{$0.id==id}) else { throw NotebookError.invalidModel }
                hashes.insert(font.assetHash)
            }
        }
        for hash in hashes { try await assets.ensureDurable(hash:hash) }
        return hashes
    }
    func loadNote(_ id: UUID) throws -> NoteSnapshot {
        guard let note=library.notes.first(where: { $0.id == id && $0.deletedAt == nil }) else { throw NotebookError.notFound }
        return NoteSnapshot(note:note,pages:try note.pageIDs.map(loadPage))
    }
    func openNote(id: UUID) async throws -> NoteSnapshot { try loadNote(id) }
    func createNote(title: String, contents: [PageContent], now: Date = Date()) async throws -> NoteSnapshot {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        guard title.utf8.count <= 10000, !contents.isEmpty, contents.count <= 5000 else { throw NotebookError.invalidModel }
        _ = try await validateAssets(contents)
        return try transaction {
            guard (library.notes.map(\.orderKey).max() ?? -1) < Int64.max-1 else { throw NotebookError.invalidModel }
            let id=UUID()
            let pages=contents.enumerated().map { PageSnapshot(noteID:id,orderKey:Int64($0.offset),content:$0.element) }
            let note=Note(id:id,title:title,orderKey:(library.notes.map(\.orderKey).max() ?? -1)+1,pageIDs:pages.map(\.id),createdAt:now,modifiedAt:now)
            library.version=4;library.notes.append(note)
            for page in pages { _ = try persist(page,parents:[],reason:.edit) }
            return try loadNote(id)
        }
    }
    func createNote(title: String, templates: [TemplateInstance]) async throws -> NoteSnapshot {
        try await createNote(title:title,contents:templates.map { var c=PageContent();c.template=$0;return c })
    }
    func commit(_ edit: NoteEditTransaction, now: Date = Date()) async throws -> NoteCommitReceipt {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        guard !edit.changes.isEmpty, edit.changes.count <= 10000,
              Set(edit.changes.map(\.pageID)).count == edit.changes.count,
              Set(edit.expectedPageIDs).count == edit.expectedPageIDs.count else { throw NotebookError.invalidModel }
        guard edit.importedFonts.count<=100,Set(edit.importedFonts.map(\.id)).count == edit.importedFonts.count else { throw NotebookError.invalidModel }
        for font in edit.importedFonts {
            try font.metrics?.validate()
            guard font.postScriptName == "MeetingBook-"+font.id.uuidString.replacingOccurrences(of:"-",with:"") else { throw NotebookError.invalidModel }
            try await PersonalFontService(assets:assets).register(version:font)
            try await assets.ensureDurable(hash:font.assetHash)
        }
        #if DEBUG
        let assetStart=ContinuousClock.now
        #endif
        let hashes=try await validateAssets(edit.changes.compactMap(\.content),importedFonts:edit.importedFonts)
        #if DEBUG
        if performancePhases != nil {let d=assetStart.duration(to:.now).components;performancePhases?["assetValidationMS"]=Double(d.seconds)*1000+Double(d.attoseconds)/1e15}
        #endif
        // All comparisons occur after asset awaits, inside the one rollback/save boundary.
        let updatesOnly=edit.importedFonts.isEmpty && edit.changes.allSatisfy {if case .update = $0 {return true};return false}
        return try authoredPageTransaction(pageIDs:updatesOnly ? Set(edit.changes.map(\.pageID)) : nil) {
            guard let index=library.notes.firstIndex(where: { $0.id == edit.noteID && $0.deletedAt == nil }) else { throw NotebookError.notFound }
            guard library.notes[index].pageIDs == edit.expectedPageIDs else { throw NotebookError.revisionConflict }
            for (id,revision) in edit.expectedRevisionIDs {
                let page=try loadPage(id)
                guard page.noteID == edit.noteID else { throw NotebookError.invalidModel }
                guard page.currentRevisionID == revision else { throw NotebookError.revisionConflict }
            }
            let existing=try edit.importedFonts.isEmpty ? [] : fontVersions()
            for font in edit.importedFonts {
                if let previous=existing.first(where: { $0.id == font.id }),previous != font { throw NotebookError.invalidModel }
            }
            let additions=edit.importedFonts.filter { !existing.contains($0) }
            if !additions.isEmpty { library.fonts.append(FontProject(name:String(localized:"Imported handwriting"),versions:additions)) }
            var removed: [UUID]=[]
            var changed=false
            for change in edit.changes {
                let id=change.pageID
                switch change {
                case .update(_,let content,let reason):
                    guard library.notes[index].pageIDs.contains(id), let expected=edit.expectedRevisionIDs[id] else { throw NotebookError.invalidModel }
                    var page=try loadPage(id)
                    guard try encoder.encode(page.content) != encoder.encode(content) else {continue}
                    changed=true;page.content=content;page.currentRevisionID=UUID()
                    _ = try persist(page,parents:[expected],reason:reason)
                case .insert(_,let content,let anchor):
                    changed=true
                    guard try record(id.uuidString) == nil else { throw NotebookError.invalidModel }
                    let position=try insertionPosition(anchor,in:library.notes[index].pageIDs)
                    let page=PageSnapshot(id:id,noteID:edit.noteID,orderKey:Int64(position),content:content)
                    library.notes[index].pageIDs.insert(id,at:position);_ = try persist(page,parents:[],reason:.edit)
                case .remove:
                    changed=true
                    guard library.notes[index].pageIDs.contains(id),edit.expectedRevisionIDs[id] != nil else { throw NotebookError.invalidModel }
                    try put(Date(),key:"deleted-page-"+id.uuidString,kind:"pageTombstone")
                    library.notes[index].pageIDs.removeAll { $0 == id };removed.append(id)
                case .restore(_,let anchor):
                    changed=true
                    guard !library.notes[index].pageIDs.contains(id),edit.expectedRevisionIDs[id] != nil else { throw NotebookError.invalidModel }
                    let page=try loadPage(id);guard page.noteID == edit.noteID else { throw NotebookError.invalidModel }
                    let date=try get("deleted-page-"+id.uuidString,as:Date.self)
                    guard Date().timeIntervalSince(date) <= 30*86400 else { throw NotebookError.expiredTrash }
                    let position=try insertionPosition(anchor,in:library.notes[index].pageIDs)
                    library.notes[index].pageIDs.insert(id,at:position);try removeRecord("deleted-page-"+id.uuidString)
                }
            }
            guard !library.notes[index].pageIDs.isEmpty else { throw NotebookError.lastPage }
            guard library.notes[index].pageIDs.count <= 10000 else { throw NotebookError.invalidModel }
            if !updatesOnly {try renumber(index)}
            if changed {try markNoteModified(edit.noteID,at:now)}
            return NoteCommitReceipt(snapshot:try loadNote(edit.noteID),removedPageIDs:removed,savedAt:Date(),confirmedAssetHashes:hashes)
        }
    }
    func markNoteModified(_ id: UUID,at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite,let index=library.notes.firstIndex(where:{$0.id==id}) else {throw NotebookError.invalidModel}
        library.version=4;library.notes[index].modifiedAt=date
    }
    func insertionPosition(_ anchor: UUID?, in ids: [UUID]) throws -> Int {
        guard let anchor else { return 0 }
        guard let index=ids.firstIndex(of:anchor) else { throw NotebookError.invalidModel }
        return index+1
    }
    func recoverPrevious(pageID: UUID) async throws -> PageSnapshot {
        let page=try loadPage(pageID)
        let current=try get(page.currentRevisionID.uuidString,as:PageRevision.self)
        guard let parent=current.parentRevisionIDs.first else { throw NotebookError.notFound }
        let previous=try get(parent.uuidString,as:PageRevision.self)
        _ = try await commit(.init(pageID:pageID,expectedRevisionID:page.currentRevisionID,content:previous.content,reason:.recovery))
        return try loadPage(pageID)
    }
    func insertPage(noteID: UUID, after pageID: UUID?, now: Date = Date()) async throws -> PageSnapshot {
        try transaction {
            guard let index=library.notes.firstIndex(where: { $0.id == noteID && $0.deletedAt == nil }) else { throw NotebookError.notFound }
            let position: Int
            if let pageID { guard let p=library.notes[index].pageIDs.firstIndex(of:pageID) else { throw NotebookError.notFound };position=p+1 } else { position=0 }
            let page=PageSnapshot(noteID:noteID,orderKey:Int64(position))
            library.notes[index].pageIDs.insert(page.id,at:position)
            _ = try persist(page,parents:[],reason:.edit)
            try renumber(index);try markNoteModified(noteID,at:now);return try loadPage(page.id)
        }
    }
    func renumber(_ noteIndex: Int) throws {
        for (number,id) in library.notes[noteIndex].pageIDs.enumerated() {
            var head=try get(id.uuidString,as:PageSnapshot.self);head.orderKey=Int64(number);try put(head,key:id.uuidString,kind:"page")
        }
    }
    func deletePage(id: UUID, expectedRevisionID: UUID, now: Date = Date()) async throws {
        try transaction {
            let page=try loadPage(id)
            guard page.currentRevisionID == expectedRevisionID else { throw NotebookError.revisionConflict }
            guard let index=library.notes.firstIndex(where: { $0.id == page.noteID && $0.deletedAt == nil }) else { throw NotebookError.notFound }
            guard library.notes[index].pageIDs.contains(id) else {return}
            guard library.notes[index].pageIDs.count > 1 else { throw NotebookError.lastPage }
            // A tombstone keeps its original immutable content available to recovery/export.
            try put(Date(),key:"deleted-page-"+id.uuidString,kind:"pageTombstone")
            library.notes[index].pageIDs.removeAll { $0 == id };try renumber(index);try markNoteModified(page.noteID,at:now)
        }
    }
    func restoreDeletedPage(id: UUID, now: Date = Date()) async throws -> PageSnapshot {
        try transaction {
            guard let tombstone=try record("deleted-page-"+id.uuidString) else { throw NotebookError.notFound }
            let deletedAt=try decoder.decode(Date.self,from:tombstone)
            guard Date().timeIntervalSince(deletedAt) <= 30*86400 else { throw NotebookError.expiredTrash }
            let page=try loadPage(id)
            guard let i=library.notes.firstIndex(where: { $0.id == page.noteID && $0.deletedAt == nil }),!library.notes[i].pageIDs.contains(id) else { throw NotebookError.invalidModel }
            library.notes[i].pageIDs.insert(id,at:min(Int(page.orderKey),library.notes[i].pageIDs.count))
            try removeRecord("deleted-page-"+id.uuidString);try renumber(i);try markNoteModified(page.noteID,at:now);return try loadPage(id)
        }
    }
    func setBookmark(pageID: UUID, value: Bool) async throws {
        try transaction { var page=try get(pageID.uuidString,as:PageSnapshot.self);page.bookmark=value;try put(page,key:pageID.uuidString,kind:"page");var order=library.bookmarkOrder ?? [];order.removeAll{$0==pageID};if value {order.append(pageID)};library.bookmarkOrder=order }
    }
    func bookmarkedPageIDs() async throws -> [UUID] { try bookmarkedIDs() }
    func bookmarkedIDs() throws -> [UUID] {
        try ensureCacheEpoch()
        return try LibraryRules.orderedNotes(library.notes).flatMap(\.pageIDs).filter {if let value=searchDocuments?[$0] {return value.bookmark};return try loadPage($0).bookmark }
    }
    func latestBookmarkedPageID() async throws -> UUID? {
        let ids=try bookmarkedIDs(),valid=Set(ids)
        return library.bookmarkOrder?.last(where:{valid.contains($0)}) ?? ids.last
    }
    func trash(noteID: UUID, now: Date = Date()) async throws {
        try transaction { guard let i=library.notes.firstIndex(where: { $0.id == noteID }) else { throw NotebookError.notFound }; if library.notes[i].deletedAt == nil { library.notes[i].deletedAt=now;try markNoteModified(noteID,at:now) } }
    }
    func restore(noteID: UUID, now: Date = Date()) async throws {
        try transaction { guard let i=library.notes.firstIndex(where: { $0.id == noteID }) else { throw NotebookError.notFound };if let date=library.notes[i].deletedAt, Date().timeIntervalSince(date) > 30*86400 { throw NotebookError.expiredTrash };if library.notes[i].deletedAt != nil {library.notes[i].deletedAt=nil;try markNoteModified(noteID,at:now)} }
    }
    func preferences() async -> LibraryPreferences { library.preferences }
    func savePreferences(_ preferences: LibraryPreferences) async throws {
        try ensureCacheEpoch()
        try preferences.validate()
        if let fontID=preferences.textDefaults?.fontVersionID { guard try fontVersions().contains(where: { $0.id == fontID }) else { throw NotebookError.invalidModel } }
        if let pageID=preferences.lastPageID { _ = try loadPage(pageID) }
        let context=self.context
        if preferences.textDefaults==library.preferences.textDefaults,causalProjection != nil,
           library.ownership?.receiveOnly != true,!context.performAndWait({context.hasChanges}) {
            try protection.locked {
                try ensureCacheEpoch()
                // Another actor may have changed defaults while this writer waited for the root lock.
                guard preferences.textDefaults==library.preferences.textDefaults,causalProjection != nil,library.ownership?.receiveOnly != true else {
                    return try transaction {library.preferences=preferences}
                }
                if let pageID=preferences.lastPageID {_ = try loadPage(pageID)}
                let previous=library.preferences
                transactionInProgress=true;defer{transactionInProgress=false}
                do {library.preferences=preferences;try put(library,key:"library",kind:"library");try context.performAndWait{try context.save()};protection.committed([]);cacheEpoch=protection.currentCommitEpoch}
                catch {context.performAndWait{context.rollback()};library.preferences=previous;throw error}
            }
        } else {try transaction { library.preferences=preferences }}
    }
    func fontProjects() async -> [FontProject] { library.fonts }
    func retainedFontVersions() throws -> [RetainedFontVersion] {
        try records("retainedFontVersion").map{try decoder.decode(RetainedFontVersion.self,from:$0)}.sorted{$0.font.id.uuidString<$1.font.id.uuidString}
    }
    func fontVersions() throws -> [FontVersion] {library.fonts.flatMap(\.versions)+(try retainedFontVersions().map(\.font))}
    func fontVersion(id:UUID) throws -> FontVersion? {
        try ensureCacheEpoch()
        if let current=library.fonts.lazy.flatMap(\.versions).first(where:{$0.id==id}) {return current}
        guard let bytes=try record("retained-font-"+id.uuidString) else {return nil}
        let retained=try decoder.decode(RetainedFontVersion.self,from:bytes)
        guard retained.version==1,retained.font.id==id else {throw NotebookError.invalidModel}
        return retained.font
    }

    func saveFontProject(_ project: FontProject) async throws {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        try project.validateMetadata()
        for (codepoint,hash) in project.glyphAssetHashes { guard Unicode.Scalar(codepoint) != nil else { throw NotebookError.invalidModel };try await assets.ensureDurable(hash:hash) }
        for version in project.versions { try await assets.ensureDurable(hash:version.assetHash) }
        try transaction {
            let retained=try retainedFontVersions()
            guard project.versions.allSatisfy({v in !retained.contains(where:{$0.font.id==v.id})}) else {throw NotebookError.invalidModel}
            let versionIDs=library.fonts.filter { $0.id != project.id }.flatMap(\.versions).map(\.id)+project.versions.map(\.id)
            guard Set(versionIDs).count == versionIDs.count,project.publicationIDs.allSatisfy({Set(versionIDs+retained.map{$0.font.id}).contains($0)}),project.versions.allSatisfy({ !$0.postScriptName.isEmpty }) else { throw NotebookError.invalidModel }
            if let i=library.fonts.firstIndex(where: { $0.id == project.id }) {
                let old=library.fonts[i]
                guard old.versions.allSatisfy({ project.versions.contains($0) }) else { throw NotebookError.invalidModel }
                guard old == project else { throw NotebookError.revisionConflict }
                library.fonts[i]=project
            } else { library.fonts.append(project) }
        }
    }
    /// Compare only the edited glyph after asset suspension; unrelated glyphs/versions merge atomically.
    func saveFontGlyph(projectID: UUID,codePoint: UInt32,expectedHash: String?,expectedMetrics: GlyphCaptureMetrics?,hash: String?,metrics: GlyphCaptureMetrics?) async throws -> FontProject {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        guard Unicode.Scalar(codePoint) != nil,(hash == nil) == (metrics == nil) else {throw NotebookError.invalidModel}
        if let hash { try await assets.ensureDurable(hash:hash) }
        return try transaction {
            guard let i=library.fonts.firstIndex(where:{$0.id==projectID}) else {throw NotebookError.notFound}
            var current=library.fonts[i]
            guard current.glyphAssetHashes[codePoint]==expectedHash,current.glyphMetrics[codePoint]==expectedMetrics else {throw NotebookError.revisionConflict}
            current.glyphAssetHashes[codePoint]=hash;current.glyphMetrics[codePoint]=metrics
            try current.validateMetadata();library.fonts[i]=current;return current
        }
    }
    func publishFontVersion(projectID: UUID,version: FontVersion) async throws -> FontProject {
        let publication=protection.retain(blocksCollection:true);defer{withExtendedLifetime(publication){}}
        try await assets.ensureDurable(hash:version.assetHash)
        guard !version.postScriptName.isEmpty else {throw NotebookError.invalidModel}
        return try transaction {
            guard let i=library.fonts.firstIndex(where:{$0.id==projectID}) else {throw NotebookError.notFound}
            guard try !fontVersions().contains(where:{$0.id==version.id}) else {throw NotebookError.invalidModel}
            var current=library.fonts[i];current.versions.append(version)
            if current.publishedVersionIDs != nil { current.publishedVersionIDs?.append(version.id) }
            try current.validateMetadata();library.fonts[i]=current;return current
        }
    }
    func outbox() async throws -> [OutboxEntry] { try records("outbox").map { try decoder.decode(OutboxEntry.self,from:$0) } }
    /// Logical, consistent snapshot, including every retained revision; never copies live SQLite sidecars.
    func publicationGuard(expectedScope:SyncScope,expectedGeneration:String) throws -> StorePublicationGuard {
        try protection.locked {
            try requireScope(expectedScope)
            guard try snapshotGeneration()==expectedGeneration,protection.snapshot.draftPages.isEmpty,protection.snapshot.remoteFonts.isEmpty else {throw NotebookError.revisionConflict}
            return protection.publicationGuard()
        }
    }
    func snapshot() throws -> Data {
        let context=self.context
        let records=try context.performAndWait {
            let request=NSFetchRequest<NSManagedObject>(entityName:"Record");request.sortDescriptors=[NSSortDescriptor(key:"key",ascending:true)]
            return try context.fetch(request).map { ["key":$0.value(forKey:"key") as! String,"kind":$0.value(forKey:"kind") as! String,"payload":($0.value(forKey:"payload") as! Data).base64EncodedString()] }
        }
        return try JSONSerialization.data(withJSONObject:["version":library.version,"records":records],options:[.sortedKeys])
    }
    /// Byte-equivalent to snapshot(), without constructing its base64 envelope.
    func snapshotGeneration() throws -> String {
        try ensureCacheEpoch()
        let context=self.context,version=library.version,epoch=protection.currentCommitEpoch
        let clean=context.performAndWait {!context.hasChanges}
        if clean,let cached=generationCache,cached.epoch==epoch {return cached.value}
        let value=try context.performAndWait {
            let request=NSFetchRequest<NSManagedObject>(entityName:"Record")
            request.sortDescriptors=[NSSortDescriptor(key:"key",ascending:true)];request.fetchBatchSize=256
            var digest=SHA256();digest.update(data:Data("{\"records\":[".utf8))
            var first=true
            for object in try context.fetch(request) {
              try autoreleasepool {
                if !first {digest.update(data:Data([44]))};first=false
                let row=["key":object.value(forKey:"key") as! String,"kind":object.value(forKey:"kind") as! String,"payload":(object.value(forKey:"payload") as! Data).base64EncodedString()]
                digest.update(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]))
              }
            }
            digest.update(data:Data("],\"version\":\(version)}".utf8))
            return digest.finalize().map{String(format:"%02x",$0)}.joined()
        }
        if clean,protection.currentCommitEpoch==epoch {generationCache=(epoch,value)}
        return value
    }
    func migrationBackup() async throws -> URL {
        let lease=protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        let context=self.context
        let capture=try protection.locked { () throws -> (rows:[RecordRow],version:Int) in
            try ensureCacheEpoch()
            guard !context.performAndWait({context.hasChanges}) else {throw NotebookError.revisionConflict}
            return (try context.performAndWait {try Self.rows(context:context)},library.version)
        }
        return try Self.writeLocalRecovery(rows:capture.rows,version:capture.version,directory:root.appendingPathComponent("recovery"),protection:protection)
    }
    /// User-visible checkpoints are bounded; unacknowledged transport revisions stay intact.
    func checkpoints(pageID: UUID, now: Date = Date()) async throws -> [PageRevision] {
        let head=try loadPage(pageID)
        let history=try records("revision").map { try decoder.decode(PageRevision.self,from:$0) }
            .filter { $0.pageID == pageID }.sorted { $0.sequence > $1.sequence }
        var selected=Array(history.filter { $0.id != head.currentRevisionID && now.timeIntervalSince($0.createdAt) <= 30*86400 }.prefix(20))
        let headers=history.map(RevisionHeader.init)+(try records("revisionHeader").map{try decoder.decode(RevisionHeader.self,from:$0)}).filter{$0.pageID==pageID}
        for parent in RevisionHeader.protectedRecoveryParents(headers).sorted(by:{$0.uuidString<$1.uuidString}) {
            if !selected.contains(where:{$0.id==parent}),let protected=history.first(where:{$0.id==parent}) {selected.append(protected)}
        }
        return selected
    }
    /// Restores only a locally generated migration checkpoint, within one Core Data transaction.
    func rollbackMigrationBackup(at url: URL) async throws {
        let directory=root.appendingPathComponent("recovery").standardizedFileURL
        guard url.path==url.standardizedFileURL.path,url.deletingLastPathComponent().standardizedFileURL == directory, ["json","recovery"].contains(url.pathExtension) else { throw NotebookError.invalidModel }
        let lease=protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        let generation=try snapshotGeneration()
        var incoming=try Self.readMigrationEnvelope(at:url)
        var recovered=try Self.validateGraph(incoming).library
        recovered.deviceID=library.deviceID;recovered.sequence=max(library.sequence,recovered.sequence)
        recovered.version=max(2,recovered.version);recovered.ownership=library.ownership;recovered.ownership?.enabled=false;recovered.ownership?.engineID=nil
        if let generation=recovered.ownership?.generation {recovered.ownership?.generation=generation+1}
        recovered.preferences.syncEnabled=false
        incoming=try preservingDestinationLineage(incoming,recovered:&recovered)
        let graph=try Self.validateGraph(incoming)
        var verifiedAssets:[String:URL]=[:]
        for hash in graph.assetHashes {
            try Task.checkCancellation();try await assets.ensureDurable(hash:hash)
            verifiedAssets[hash]=try await assets.verifiedURL(hash:hash)
            guard try snapshotGeneration()==generation else {throw NotebookError.revisionConflict}
        }
        let reader=NotebookPackage(root:directory)
        try await reader.validateNativeAssets(InspectedPackage(rows:incoming,records:[:],assets:verifiedAssets,fonts:graph.fonts,notes:0,unsaved:false,pages:0))
        try Task.checkCancellation()
        try transaction {
            guard try snapshotGeneration()==generation else {throw NotebookError.revisionConflict}
            try replaceRows(incoming);library=recovered
        }

    }

    struct RecordRow: Codable, Sendable { let key: String; let kind: String; let payload: Data }
    struct ValidatedGraph: Sendable { let library: Library; let assetHashes: Set<String>;let fonts: [FontVersion];let searchDocuments:[UUID:SearchDocument]?;let causalProjection:CausalProjection? }
    static func rows(context: NSManagedObjectContext) throws -> [RecordRow] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName:"Record")).map { object in
            guard let key=object.value(forKey:"key") as? String,let kind=object.value(forKey:"kind") as? String,let payload=object.value(forKey:"payload") as? Data else { throw NotebookError.invalidModel }
            return RecordRow(key:key,kind:kind,payload:payload)
        }
    }
    /// Same typed activation boundary for existing stores and local migration rollback.
    static func validateGraph(_ rows: [RecordRow]) throws -> ValidatedGraph {
        let decoder=JSONDecoder();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var keys=Set<String>();var library: Library?;var pages: [UUID:PageSnapshot]=[:];var revisions: [UUID:PageRevision]=[:]
        var outbox: [OutboxEntry]=[];var tombstones=Set<UUID>();var hashes=Set<String>()
        var inbox:[IncomingOperation]=[],engineCheckpoints:[EngineCheckpoint]=[]
        var retainedFonts:[RetainedFontVersion]=[]
        var wireInbox:[StoredSyncWire]=[],refetches:[SyncWireRefetch]=[]
        var syncContexts:[UUID:SyncTransactionContext]=[:]
        var resolutions:[UUID:SyncResolution]=[:],consumed:[ConsumedSyncTransaction]=[]
        var syncApplied:[AppliedSyncTransaction]=[],syncDeliveries:[SyncWireReceipt]=[],syncConflicts:[SyncConflict]=[],derivedCopies:[DerivedSyncCopy]=[]
        var headers:[UUID:RevisionHeader]=[:],expiredPages:[UUID:PageSnapshot]=[:],expiredNotes:[UUID:Note]=[:],operations:[UUID:CausalOperation]=[:],acks:[UUID:ScopedAcknowledgement]=[:]
        for row in rows {
          try autoreleasepool {
            if keys.count%256==0 {try Task.checkCancellation()}
            guard keys.insert(row.key).inserted else { throw NotebookError.invalidModel }
            switch row.kind {
            case "library":
                guard row.key == "library",library == nil else { throw NotebookError.invalidModel }
                let value=try decoder.decode(Library.self,from:row.payload)
                guard [1,2,3,4].contains(value.version) else { throw NotebookError.unsupportedVersion };try value.preferences.validate();try value.ownership?.validate();library=value
            case "page":
                let value=try decoder.decode(PageSnapshot.self,from:row.payload)
                guard value.id.uuidString == row.key else { throw NotebookError.invalidModel }
                try value.content.validate();pages[value.id]=value
            case "revision":
                let value=try decoder.decode(PageRevision.self,from:row.payload);try value.content.validate()
                guard value.id.uuidString == row.key,value.sequence > 0,AssetStore.hash(try encoder.encode(value.content)) == value.contentHash else { throw NotebookError.invalidModel }
                revisions[value.id]=value;headers[value.id]=RevisionHeader(value);hashes.formUnion(value.content.assetHashes)
            case "outbox":
                let value=try decoder.decode(OutboxEntry.self,from:row.payload)
                guard value.id.uuidString == row.key else { throw NotebookError.invalidModel };outbox.append(value)
            case "revisionHeader":
                let value=try decoder.decode(RevisionHeader.self,from:row.payload)
                guard value.id.uuidString==row.key,value.sequence>0,PageContent.isHash(value.contentHash) else {throw NotebookError.invalidModel}
                headers[value.id]=value
            case "expiredPage":
                let value=try decoder.decode(PageSnapshot.self,from:row.payload)
                guard value.id.uuidString==row.key,value.content.textBlocks.isEmpty,value.content.images.isEmpty,value.content.drawingAssetHash==nil else {throw NotebookError.invalidModel}
                expiredPages[value.id]=value
            case "expiredNote":
                let value=try decoder.decode(Note.self,from:row.payload)
                guard row.key=="expired-note-"+value.id.uuidString,value.deletedAt != nil,!value.pageIDs.isEmpty else {throw NotebookError.invalidModel}
                expiredNotes[value.id]=value
            case "retainedFontVersion":
                let value=try decoder.decode(RetainedFontVersion.self,from:row.payload)
                guard value.version==1,row.key=="retained-font-"+value.font.id.uuidString else {throw NotebookError.unsupportedVersion}
                retainedFonts.append(value)
            case "causalOperation":
                let value=try decoder.decode(CausalOperation.self,from:row.payload);try value.validate();try value.validateWireValue()
                guard row.key=="operation-"+value.id.uuidString else {throw NotebookError.invalidModel};operations[value.id]=value
            case "operationAck":
                let value=try decoder.decode(ScopedAcknowledgement.self,from:row.payload);try value.scope.validate()
                guard row.key=="ack-"+value.operationID.uuidString else {throw NotebookError.invalidModel};acks[value.operationID]=value
            case "incomingOperation":
                let value=try decoder.decode(IncomingOperation.self,from:row.payload);try value.operation.validate();try value.scope.validate()
                guard row.key=="inbox-"+value.operation.id.uuidString,value.systemFields.count<=1_000_000 else {throw NotebookError.invalidModel};inbox.append(value)
            case "syncResolution":
                let value=try decoder.decode(SyncResolution.self,from:row.payload);try value.validate()
                guard row.key=="sync-resolution-"+value.id.uuidString else {throw NotebookError.invalidModel};resolutions[value.id]=value;hashes.formUnion(value.priorAssetHashes)
            case "syncConsumed":
                let value=try decoder.decode(ConsumedSyncTransaction.self,from:row.payload);try value.scope.validate()
                guard value.version==1,row.key=="sync-consumed-"+value.id.uuidString,!value.resolutionIDs.isEmpty,value.resolutionIDs.count<=100_000 else {throw NotebookError.invalidModel};consumed.append(value)
            case "syncContext":
                let value=try decoder.decode(SyncTransactionContext.self,from:row.payload);try value.validate()
                guard row.key=="sync-context-"+value.id.uuidString else {throw NotebookError.invalidModel};syncContexts[value.id]=value
            case "syncConflict":
                let value=try decoder.decode(SyncConflict.self,from:row.payload);try value.validate()
                guard row.key=="sync-conflict-"+value.id.uuidString else {throw NotebookError.invalidModel};syncConflicts.append(value)
            case "derivedSyncCopy":
                let value=try decoder.decode(DerivedSyncCopy.self,from:row.payload)
                guard value.version==1,row.key=="derived-copy-"+value.pageID.uuidString else {throw NotebookError.invalidModel};derivedCopies.append(value)
            case "syncApplied":
                let value=try decoder.decode(AppliedSyncTransaction.self,from:row.payload);try value.scope.validate()
                guard value.version==1,row.key=="sync-applied-"+value.id.uuidString else {throw NotebookError.invalidModel};syncApplied.append(value)
            case "syncDelivery":
                let value=try decoder.decode(SyncWireReceipt.self,from:row.payload);try value.scope.validate()
                guard value.version==1,row.key=="sync-delivered-"+value.id,value.id.utf8.count<=128,PageContent.isHash(value.bodyHash),value.systemFields.count<=1_000_000 else {throw NotebookError.invalidModel};syncDeliveries.append(value)
            case "syncTransport":
                let value=try decoder.decode(SyncTransportState.self,from:row.payload);try value.validate()
                guard row.key=="sync-transport" else {throw NotebookError.invalidModel}
            case "syncRefetch":
                let value=try decoder.decode(SyncWireRefetch.self,from:row.payload);try value.validate()
                guard row.key=="sync-refetch-"+value.id else {throw NotebookError.invalidModel};refetches.append(value)
            case "syncWire":
                let value=try decoder.decode(StoredSyncWire.self,from:row.payload);try value.validate()
                guard row.key=="sync-wire-"+value.id else {throw NotebookError.invalidModel}
                if let key=value.backingRecordKey {
                    guard let backing=rows.first(where:{$0.key==key}),backing.kind==(value.kind == .operation ? "causalOperation" : value.kind == .revision ? "revision" : "syncConflict"),AssetStore.hash(backing.payload)==value.bodyHash else {throw NotebookError.invalidModel}
                    try SyncWireRecord(id:value.id,kind:value.kind,bytes:backing.payload).validate()
                } else {hashes.insert(value.bodyHash)}
                wireInbox.append(value)
            case "engineCheckpoint":
                let value=try decoder.decode(EngineCheckpoint.self,from:row.payload);try value.scope.validate()
                guard row.key=="engine-checkpoint",value.bytes.count<=8_000_000 else {throw NotebookError.invalidModel};engineCheckpoints.append(value)
            case "pageTombstone":
                guard row.key.hasPrefix("deleted-page-"),let id=UUID(uuidString:String(row.key.dropFirst("deleted-page-".count))),row.key == "deleted-page-"+id.uuidString,tombstones.insert(id).inserted else { throw NotebookError.invalidModel }
                _ = try decoder.decode(Date.self,from:row.payload)
            default: throw NotebookError.unsupportedVersion
            }
          }
        }
        guard let library,library.sequence >= 0,library.sequence < Int64.max,Set(library.notes.map(\.id)).count == library.notes.count,Set(library.fonts.map(\.id)).count == library.fonts.count else { throw NotebookError.invalidModel }
        for note in library.notes+Array(expiredNotes.values) {
            try note.validateAuthorDates()
            guard library.version>=4 || (note.createdAt==nil && note.modifiedAt==nil) else {throw NotebookError.unsupportedVersion}
        }
        var fontIDs=Set<UUID>()
        for project in library.fonts {
            try project.validateMetadata()
            for (codepoint,hash) in project.glyphAssetHashes { guard Unicode.Scalar(codepoint) != nil,PageContent.isHash(hash) else { throw NotebookError.invalidModel };hashes.insert(hash) }
            for version in project.versions { guard fontIDs.insert(version.id).inserted,PageContent.isHash(version.assetHash),!version.postScriptName.isEmpty else { throw NotebookError.invalidModel };hashes.insert(version.assetHash) }
        }
        guard retainedFonts.isEmpty || library.version>=3 else {throw NotebookError.unsupportedVersion}
        for retained in retainedFonts {
            let version=retained.font
            guard fontIDs.insert(version.id).inserted,PageContent.isHash(version.assetHash),!version.postScriptName.isEmpty else {throw NotebookError.invalidModel}
            try version.metrics?.validate();hashes.insert(version.assetHash)
        }
        guard library.fonts.allSatisfy({$0.publicationIDs.allSatisfy(fontIDs.contains)}) else { throw NotebookError.invalidModel }
        if let fontID=library.preferences.textDefaults?.fontVersionID { guard fontIDs.contains(fontID) else { throw NotebookError.invalidModel } }
        var memberships=Set<UUID>()
        for note in library.notes {
            guard !note.pageIDs.isEmpty,note.orderKey >= 0,note.orderKey < Int64.max,note.title.utf8.count <= 10000 else { throw NotebookError.invalidModel }
            for (order,id) in note.pageIDs.enumerated() {
                guard memberships.insert(id).inserted,let page=pages[id],page.noteID == note.id,page.orderKey == Int64(order),!tombstones.contains(id) else { throw NotebookError.invalidModel }
            }
        }
        for page in pages.values {
            guard page.orderKey >= 0,library.notes.contains(where: { $0.id == page.noteID }),memberships.contains(page.id) || tombstones.contains(page.id),revisions[page.currentRevisionID]?.pageID == page.id else { throw NotebookError.invalidModel }
        }
        guard tombstones.allSatisfy({ pages[$0] != nil || expiredPages[$0] != nil }),library.preferences.lastPageID.map({ pages[$0] != nil }) ?? true else { throw NotebookError.invalidModel }
        if let order=library.bookmarkOrder { guard Set(order).count==order.count,order.allSatisfy({pages[$0] != nil}) else { throw NotebookError.invalidModel } }
        for revision in headers.values {
            guard pages[revision.pageID] != nil || expiredPages[revision.pageID] != nil else {throw NotebookError.invalidModel}
            guard revision.deviceID != library.deviceID || revision.sequence <= library.sequence,Set(revision.parentRevisionIDs).count == revision.parentRevisionIDs.count else { throw NotebookError.invalidModel }
            for id in revision.parentRevisionIDs {
                guard let parent=headers[id],parent.pageID == revision.pageID,parent.id != revision.id,parent.deviceID != revision.deviceID || parent.sequence < revision.sequence else { throw NotebookError.invalidModel }
            }

        }
        // The newest destructive recovery parent remains full even if its action payload was pruned.
        guard RevisionHeader.protectedRecoveryParents(Array(headers.values)).allSatisfy({revisions[$0] != nil}) else {throw NotebookError.invalidModel}
        // Iterative topological check also rejects cross-device cycles without recursion.
        var pending=headers.mapValues { $0.parentRevisionIDs.count };var children: [UUID:[UUID]]=[:]
        for revision in headers.values { for parent in revision.parentRevisionIDs { children[parent,default:[]].append(revision.id) } }
        var ready=pending.filter { $0.value == 0 }.map(\.key);var checked=0
        while let id=ready.popLast() { checked += 1;for child in children[id] ?? [] { pending[child]! -= 1;if pending[child] == 0 { ready.append(child) } } }
        guard checked == headers.count else { throw NotebookError.invalidModel }
        guard outbox.allSatisfy({ pages[$0.pageID] != nil && revisions[$0.revisionID]?.pageID == $0.pageID }) else { throw NotebookError.invalidModel }
        guard library.version>=2 || (headers.count==revisions.count && expiredPages.isEmpty && expiredNotes.isEmpty && operations.isEmpty && acks.isEmpty) else {throw NotebookError.unsupportedVersion}
        guard library.version>=4 || operations.values.allSatisfy({$0.version==1}) else {throw NotebookError.unsupportedVersion}
        if library.version>=2 { guard library.ownership != nil else {throw NotebookError.invalidModel} }
        else {guard rows.allSatisfy({["library","page","revision","outbox","pageTombstone"].contains($0.kind)}) else {throw NotebookError.unsupportedVersion}}
        for value in syncContexts.values {
            guard value.accountFingerprint==library.ownership?.accountFingerprint,value.dependencies.allSatisfy({syncContexts[$0]?.accountFingerprint==value.accountFingerprint}) else {throw NotebookError.invalidModel}
            let members=operations.values.filter{$0.transactionID==value.id}
            guard !members.isEmpty,members.allSatisfy({$0.libraryID==value.libraryID && $0.deviceID==value.deviceID && $0.accountFingerprint==value.accountFingerprint}) else {throw NotebookError.invalidModel}
        }
        var contextCounts=syncContexts.mapValues{$0.dependencies.count},contextChildren:[UUID:[UUID]]=[:]
        for value in syncContexts.values {for dependency in value.dependencies {contextChildren[dependency,default:[]].append(value.id)}}
        var contextReady=contextCounts.filter{$0.value==0}.map(\.key),contextCount=0
        while let id=contextReady.popLast() {contextCount+=1;for child in contextChildren[id] ?? [] {contextCounts[child]!-=1;if contextCounts[child]==0 {contextReady.append(child)}}}
        guard contextCount==syncContexts.count else {throw NotebookError.invalidModel}
        for wire in wireInbox {
            guard wire.scope.libraryID==library.ownership?.libraryID,wire.scope.accountFingerprint==library.ownership?.accountFingerprint,wire.scope.container==library.ownership?.container,wire.scope.environment==library.ownership?.environment else {throw NotebookError.invalidModel}
        }
        func sameBinding(_ scope:SyncScope) -> Bool {
            scope.libraryID==library.ownership?.libraryID && scope.accountFingerprint==library.ownership?.accountFingerprint && scope.container==library.ownership?.container && scope.environment==library.ownership?.environment
        }
        for row in rows where row.kind=="syncTransport" {
            let state=try decoder.decode(SyncTransportState.self,from:row.payload)
            guard sameBinding(state.scope) else {throw NotebookError.invalidModel}
            for issue in state.issues.values {
                if let verification=issue.verification {
                    guard wireInbox.contains(where:{$0.id==verification.id && $0.kind==verification.kind && $0.bodyHash==verification.hash}) else {throw NotebookError.invalidModel}
                }
            }
        }
        let wireByID=Dictionary(uniqueKeysWithValues:wireInbox.map{($0.id,$0)})
        for refetch in refetches {guard sameBinding(refetch.scope),wireByID[refetch.id]==nil else {throw NotebookError.invalidModel}}
        for applied in syncApplied {guard sameBinding(applied.scope),syncContexts[applied.id] != nil,wireByID["transaction-"+applied.id.uuidString]?.kind == .transaction else {throw NotebookError.invalidModel}}
        for marker in consumed {
            guard sameBinding(marker.scope),syncContexts[marker.id] != nil,wireByID["transaction-"+marker.id.uuidString]?.kind == .transaction,
                  marker.resolutionIDs.allSatisfy({id in guard let resolution=resolutions[id] else {return false};return resolution.sourceTransactionIDs.contains(marker.id) && resolution.coversMutableEntities(operations.values.filter{$0.transactionID==marker.id})}) else {throw NotebookError.invalidModel}
        }
        for resolution in resolutions.values {
            guard resolution.accountFingerprint==library.ownership?.accountFingerprint,
                  let authored=operations.values.first(where:{$0.entity=="resolution/"+resolution.id.uuidString}),authored.libraryID==resolution.authorLibraryID,
                  let value=authored.value,try decoder.decode(SyncResolution.self,from:value)==resolution,
                  resolution.sourceTransactionIDs.allSatisfy({syncContexts[$0] != nil && wireByID["transaction-"+$0.uuidString]?.kind == .transaction}),
                  resolution.priorRevisionIDs.allSatisfy({revisions[$0] != nil || wireByID["revision-"+$0.uuidString]?.kind == .revision}) else {throw NotebookError.invalidModel}
            if let id=resolution.pageConflictID {guard let conflict=syncConflicts.first(where:{$0.id==id}),conflict.operationIDs.allSatisfy({id in operations[id].map{resolution.sourceTransactionIDs.contains($0.transactionID)} ?? false}),resolution.resultHashes[conflict.entity] != nil else {throw NotebookError.invalidModel}}
            var ancestry=syncContexts[authored.transactionID]?.dependencies ?? [],ancestors=Set<UUID>()
            while let id=ancestry.popLast() {if ancestors.insert(id).inserted {ancestry+=syncContexts[id]?.dependencies ?? []}}
            guard Set(resolution.sourceTransactionIDs).isSubset(of:ancestors) else {throw NotebookError.invalidModel}
            let members=operations.values.filter{$0.transactionID==authored.transactionID}
            guard resolution.resultHashes.allSatisfy({entity,hash in members.contains{$0.entity==entity && $0.valueHash==hash}}),
                  resolution.copiedNoteIDs.allSatisfy({resolution.resultHashes["note/"+$0.uuidString+"/title"] != nil}),
                  resolution.copiedProjectIDs.allSatisfy({resolution.resultHashes["font/"+$0.uuidString+"/name"] != nil}) else {throw NotebookError.invalidModel}
        }
        for receipt in syncDeliveries {guard sameBinding(receipt.scope),let wire=wireByID[receipt.id],wire.bodyHash==receipt.bodyHash else {throw NotebookError.invalidModel}}
        for conflict in syncConflicts {
            try conflict.validateSources(operations:operations,contexts:syncContexts)
            guard conflict.accountFingerprint==library.ownership?.accountFingerprint,
                  conflict.sourceRevisionIDs.allSatisfy({revisions[$0] != nil}),let copy=revisions[conflict.copyRevisionID],copy.pageID==conflict.copyPageID,
                  copy.content==revisions[conflict.copySourceRevisionID]?.content,pages[conflict.copyPageID]?.noteID==conflict.copyNoteID else {throw NotebookError.invalidModel}
        }
        for copy in derivedCopies {
            guard let conflict=syncConflicts.first(where:{$0.id==copy.conflictID}),copy.noteID==conflict.copyNoteID,copy.pageID==conflict.copyPageID,copy.revisionID==conflict.copyRevisionID else {throw NotebookError.invalidModel}
        }
        for incoming in inbox {
            guard incoming.scope.libraryID==library.ownership?.libraryID,incoming.scope.accountFingerprint==library.ownership?.accountFingerprint,
                  incoming.scope.container==library.ownership?.container,incoming.scope.environment==library.ownership?.environment,
                  incoming.operation.accountFingerprint==incoming.scope.accountFingerprint,
                  (incoming.availableAssets ?? []).isSubset(of:incoming.operation.assets) else {throw NotebookError.invalidModel}
            hashes.formUnion(incoming.availableAssets ?? [])
        }
        for checkpoint in engineCheckpoints {
            guard checkpoint.scope.libraryID==library.ownership?.libraryID,checkpoint.scope.accountFingerprint==library.ownership?.accountFingerprint,
                  checkpoint.scope.container==library.ownership?.container,checkpoint.scope.environment==library.ownership?.environment else {throw NotebookError.invalidModel}
        }
        for revision in revisions.values { guard revision.content.textBlocks.compactMap(\.fontVersionID).allSatisfy(fontIDs.contains) else {throw NotebookError.invalidModel} }
        for page in expiredPages.values {
            guard headers[page.currentRevisionID]?.pageID==page.id,
                  library.notes.contains(where:{$0.id==page.noteID}) || expiredNotes[page.noteID] != nil else {throw NotebookError.invalidModel}
        }
        for note in expiredNotes.values {guard !library.notes.contains(where:{$0.id==note.id}),note.pageIDs.allSatisfy({expiredPages[$0]?.noteID==note.id}) else {throw NotebookError.invalidModel}}
        for operation in operations.values {
            guard (operation.libraryID==library.ownership?.libraryID || (operation.accountFingerprint != nil && operation.accountFingerprint==library.ownership?.accountFingerprint)),operation.deviceID != library.deviceID || operation.sequence<=library.sequence else {throw NotebookError.invalidModel}
            for base in operation.bases { guard let prior=operations[base],prior.entity==operation.entity,(prior.deviceID != operation.deviceID || prior.sequence<operation.sequence),prior.accountFingerprint==operation.accountFingerprint else {throw NotebookError.invalidModel} }
            if operation.accountFingerprint != nil && acks[operation.id]==nil {
                guard operation.accountFingerprint==library.ownership?.accountFingerprint,operation.revisions.allSatisfy({revisions[$0] != nil}) else {throw NotebookError.invalidModel}
                hashes.formUnion(operation.assets)
            }
        }
        try CausalOperation.validateNoteMetadataCompleteness(Array(operations.values))
        for (entity,events) in Dictionary(grouping:operations.values.filter{$0.entity.hasPrefix("note/") && $0.entity.hasSuffix("/timestamps")},by:\.entity) {
            let metadata=try NoteTimestampMetadata.project(events)
            let id=UUID(uuidString:String(entity.split(separator:"/")[1]))!
            if let known=(library.notes.first(where:{$0.id==id}) ?? expiredNotes[id])?.createdAt,let authored=metadata.createdAt {
                guard known==authored else {throw NotebookError.invalidModel}
            }
        }
        var operationPending=operations.mapValues{$0.bases.count},operationChildren:[UUID:[UUID]]=[:]
        for operation in operations.values {for base in operation.bases {operationChildren[base,default:[]].append(operation.id)}}
        var operationReady=operationPending.filter{$0.value==0}.map(\.key),operationCount=0
        while let id=operationReady.popLast() {operationCount+=1;for child in operationChildren[id] ?? [] {operationPending[child]!-=1;if operationPending[child]==0 {operationReady.append(child)}}}
        guard operationCount==operations.count else {throw NotebookError.invalidModel}
        for ack in acks.values { guard (ack.systemFields?.count ?? 0)<=1_000_000,let operation=operations[ack.operationID],ack.valueHash==operation.valueHash,(ack.scope.libraryID==operation.libraryID || (ack.received==true && ack.scope.libraryID==library.ownership?.libraryID)),ack.scope.accountFingerprint==operation.accountFingerprint else {throw NotebookError.invalidModel} }
        var documents:[UUID:SearchDocument]=[:],textBytes=0
        for page in pages.values {
            guard let revision=revisions[page.currentRevisionID] else {throw NotebookError.invalidModel}
            let text=revision.content.textBlocks.map(\.text).joined(separator:"\n")
            textBytes+=text.utf8.count
            if textBytes>32_000_000 {documents.removeAll();break}
            documents[page.id]=SearchDocument(bookmark:page.bookmark,text:text)
        }
        let scoped=operations.values.filter{$0.accountFingerprint==library.ownership?.accountFingerprint}
        var frontiers:[String:Set<UUID>]=[:]
        for op in scoped where !op.entity.hasPrefix("revision/") {frontiers[op.entity,default:[]].insert(op.id)}
        for op in scoped where !op.entity.hasPrefix("revision/") {frontiers[op.entity,default:[]].subtract(op.bases)}
        let contexts=Set(syncContexts.keys).subtracting(syncContexts.values.flatMap(\.dependencies))
        let completeContexts=library.ownership?.accountFingerprint==nil || Set(scoped.map(\.transactionID)).isSubset(of:Set(syncContexts.keys))
        return ValidatedGraph(library:library,assetHashes:hashes,fonts:library.fonts.flatMap(\.versions)+retainedFonts.map(\.font),searchDocuments:textBytes<=32_000_000 ? documents : nil,causalProjection:completeContexts ? CausalProjection(frontiers:frontiers,contexts:contexts) : nil)
    }

}

struct UnsavedGlyph: Sendable { let projectID: UUID;let codePoint: UInt32;let bytes: Data?;let metrics: GlyphCaptureMetrics? }

struct BackupCapture: Sendable {
    var memoryAssets: [String:Data]=[:]
    var unsaved=false
    var pin=UUID()
    let files: [String:Data]
    let assetHashes: Set<String>
    let fonts: [FontVersion]
    let generation: String
}

extension NotebookStore {
    /// Keep raw immutable payloads: decoding/re-encoding can change legacy revision hashes.
    func captureBackup(drafts: [EditorSession.DraftLease] = [],glyph: UnsavedGlyph? = nil) async throws -> BackupCapture {
        let lease=protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        let context=self.context
        let generation=try snapshotGeneration()
        var records=try context.performAndWait { try Self.rows(context:context) }
        var memoryAssets:[String:Data]=[:]
        if !drafts.isEmpty || glyph != nil {
            guard let index=records.firstIndex(where:{$0.kind=="library"}) else { throw NotebookError.invalidModel }
            var recovered=try decoder.decode(Library.self,from:records[index].payload)
            guard Set(drafts.map(\.pageID)).count==drafts.count else { throw NotebookError.invalidModel }
            let capturedAt=Date()
            for draft in drafts {
                try draft.content.validate()
                guard let pageIndex=records.firstIndex(where:{$0.kind=="page" && $0.key==draft.pageID.uuidString}),
                      let base=records.first(where:{$0.kind=="revision" && $0.key==draft.baseRevisionID.uuidString}),
                      try decoder.decode(PageRevision.self,from:base.payload).pageID==draft.pageID,
                      recovered.sequence<Int64.max-1 else { throw NotebookError.invalidModel }
                var page=try decoder.decode(PageSnapshot.self,from:records[pageIndex].payload)
                guard let current=records.first(where:{$0.kind=="revision" && $0.key==page.currentRevisionID.uuidString}) else {throw NotebookError.invalidModel}
                guard try encoder.encode(decoder.decode(PageRevision.self,from:current.payload).content) != encoder.encode(draft.content) else {continue}
                guard let noteIndex=recovered.notes.firstIndex(where:{$0.id==page.noteID}) else {throw NotebookError.invalidModel}
                recovered.version=4;recovered.notes[noteIndex].modifiedAt=capturedAt
                page.currentRevisionID=UUID();recovered.sequence+=1
                let revision=PageRevision(id:page.currentRevisionID,pageID:page.id,parentRevisionIDs:[draft.baseRevisionID],deviceID:recovered.deviceID,sequence:recovered.sequence,createdAt:Date(),contentHash:AssetStore.hash(try encoder.encode(draft.content)),content:draft.content,reason:.importData)
                records[pageIndex]=RecordRow(key:page.id.uuidString,kind:"page",payload:try encoder.encode(page))
                records.append(RecordRow(key:revision.id.uuidString,kind:"revision",payload:try encoder.encode(revision)))
            }
            if let glyph {
                guard Unicode.Scalar(glyph.codePoint) != nil,(glyph.bytes == nil)==(glyph.metrics == nil),let i=recovered.fonts.firstIndex(where:{$0.id==glyph.projectID}) else { throw NotebookError.invalidModel }
                try glyph.metrics?.validate()
                if let bytes=glyph.bytes {
                    guard bytes.count<=2_000_000 else { throw NotebookError.invalidAsset }
                    let hash=AssetStore.hash(bytes);memoryAssets[hash]=bytes;recovered.fonts[i].glyphAssetHashes[glyph.codePoint]=hash
                } else { recovered.fonts[i].glyphAssetHashes.removeValue(forKey:glyph.codePoint) }
                recovered.fonts[i].glyphMetrics[glyph.codePoint]=glyph.metrics
            }
            records[index]=RecordRow(key:"library",kind:"library",payload:try encoder.encode(recovered))
        }
        let graph=try Self.validateGraph(records)
        var files:[String:Data]=[:]
        if records.count>19_000 || records.reduce(0,{$0+$1.payload.count})>48_000_000 {
            files=try RecordChunks.encode(records)
            let pin=try await assets.acquirePin(graph.assetHashes)
            return BackupCapture(memoryAssets:memoryAssets,unsaved:!drafts.isEmpty || glyph != nil,pin:pin,files:files,assetHashes:graph.assetHashes,fonts:graph.fonts,generation:generation)
        }
        let rootRow=records.first { $0.kind=="library" }!
        var metadata=try JSONSerialization.jsonObject(with:rootRow.payload) as! [String:Any]
        for (key,directory) in [("notes","notes"),("fonts","font-projects")] {
            let values=metadata.removeValue(forKey:key) as? [[String:Any]] ?? []
            metadata[key]=try values.map { value -> String in
                guard let id=value["id"] as? String,let uuid=UUID(uuidString:id) else { throw NotebookError.invalidModel }
                let path=directory+"/"+uuid.uuidString.lowercased()+".json"
                files[path]=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys);return path
            }
        }
        let technical=records.filter { !["library","page","revision"].contains($0.kind) }
        let technicalData=try encoder.encode(technical)
        files["library.json"]=try JSONSerialization.data(withJSONObject:["version":graph.library.version,"library":metadata,"technical":try JSONSerialization.jsonObject(with:technicalData)],options:.sortedKeys)
        for row in records where row.kind=="page" || row.kind=="revision" {
            files[(row.kind=="page" ? "pages/" : "revisions/")+row.key.lowercased()+".json"]=row.payload
        }
        if files.count+graph.assetHashes.count+graph.fonts.count+5>20_000 || files.values.contains(where:{$0.count>16_000_000}) || files.values.reduce(0,{$0+$1.count})>56_000_000 {files=try RecordChunks.encode(records)}
        let pin=try await assets.acquirePin(graph.assetHashes)
        return BackupCapture(memoryAssets:memoryAssets,unsaved:!drafts.isEmpty || glyph != nil,pin:pin,files:files,assetHashes:graph.assetHashes,fonts:graph.fonts,generation:generation)
    }
    static func validatedPackageRows(_ files:[String:Data]) throws -> (rows:[RecordRow],graph:ValidatedGraph) {
        let rows=try decodePackageRows(files);return (rows,try validateGraph(rows))
    }
    static func importedRows(_ files:[String:Data]) throws -> [RecordRow] {try validatedPackageRows(files).rows}
    private static func decodePackageRows(_ files: [String:Data]) throws -> [RecordRow] {
        if files.keys.contains(where:{$0.hasPrefix("records/")}) {
            return try RecordChunks.decode(files)
        }
        guard let data=files["library.json"],let envelope=try JSONSerialization.jsonObject(with:data) as? [String:Any],[1,2,3,4].contains(envelope["version"] as? Int ?? 0),
              var library=envelope["library"] as? [String:Any],let technical=envelope["technical"] else { throw NotebookError.unsupportedVersion }
        var used:Set<String>=["library.json"]
        for (key,directory) in [("notes","notes"),("fonts","font-projects")] {
            guard let paths=library[key] as? [String],paths.count<=20_000 else { throw NotebookError.invalidModel }
            library[key]=try paths.map { path -> [String:Any] in
                guard path.hasPrefix(directory+"/"),ImportValidation.validPath(path),used.insert(path).inserted,
                      let data=files[path],let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      let id=value["id"] as? String,let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()+".json" == path.split(separator:"/").last.map(String.init) else { throw NotebookError.invalidModel }
                return value
            }
        }
        var rows=try JSONDecoder().decode([RecordRow].self,from:JSONSerialization.data(withJSONObject:technical))
        guard rows.allSatisfy({ ["outbox","pageTombstone","causalOperation","operationAck","incomingOperation","engineCheckpoint","revisionHeader","expiredPage","expiredNote","retainedFontVersion","syncWire","syncDelivery","syncApplied","syncConflict","derivedSyncCopy","syncContext","syncResolution","syncConsumed","syncRefetch","syncTransport"].contains($0.kind) }) else { throw NotebookError.invalidModel }
        for row in rows { try ImportValidation.validateJSON(row.payload) }
        rows.append(RecordRow(key:"library",kind:"library",payload:try JSONSerialization.data(withJSONObject:library,options:.sortedKeys)))
        for (path,data) in files where path.hasPrefix("pages/") || path.hasPrefix("revisions/") {
            guard ImportValidation.validPath(path),let id=UUID(uuidString:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent) else { throw NotebookError.invalidModel }
            used.insert(path);rows.append(RecordRow(key:id.uuidString,kind:path.hasPrefix("pages/") ? "page" : "revision",payload:data))
        }
        guard Set(files.keys)==used else { throw NotebookError.invalidModel }
        return rows
    }
    static func validatePackageRecords(_ files: [String:Data]) throws -> (hashes: Set<String>,fonts: [FontVersion],notes: Int,pages: Int) {
        let (rows,graph)=try validatedPackageRows(files)
        return (graph.assetHashes,graph.fonts,graph.library.notes.count,rows.filter{$0.kind=="page"}.count)
    }
    /// Imported transport state never replaces local delivery intent. Preserve immutable history
    /// and omitted identities so the destination journal remains a valid dependency closure.
    func preservingDestinationLineage(_ incoming: [RecordRow],recovered: inout Library) throws -> [RecordRow] {
        let transport:Set<String>=["causalOperation","operationAck","incomingOperation","engineCheckpoint","syncWire","syncDelivery","syncApplied","syncConflict","derivedSyncCopy","syncContext","syncResolution","syncConsumed","syncRefetch","syncTransport"]
        let context=self.context,existing=try context.performAndWait {try Self.rows(context:context)}
        var rows=Dictionary(uniqueKeysWithValues:incoming.filter{!transport.contains($0.kind) && $0.kind != "library" && $0.kind != "outbox"}.map{($0.key,$0)})
        for row in existing where transport.contains(row.kind) {rows[row.key]=row}
        func header(_ row: RecordRow) throws -> RevisionHeader {
            if row.kind=="revision" {return RevisionHeader(try decoder.decode(PageRevision.self,from:row.payload))}
            return try decoder.decode(RevisionHeader.self,from:row.payload)
        }
        for row in existing where row.kind=="revision" || row.kind=="revisionHeader" {
            if let imported=rows[row.key] {
                guard ["revision","revisionHeader"].contains(imported.kind),try header(imported)==header(row) else {throw NotebookError.invalidModel}
                if row.kind=="revision",imported.kind=="revision" {
                    guard try decoder.decode(PageRevision.self,from:row.payload)==decoder.decode(PageRevision.self,from:imported.payload) else {throw NotebookError.invalidModel}
                }
                if row.kind=="revision" {rows[row.key]=row} // Original bytes win over equivalent encoding/header.
            } else {rows[row.key]=row}
        }
        for row in existing where row.kind=="page" || row.kind=="expiredPage" {
            if rows[row.key]==nil {
                var page=try decoder.decode(PageSnapshot.self,from:row.payload);page.content=PageContent()
                rows[row.key]=RecordRow(key:row.key,kind:"expiredPage",payload:try encoder.encode(page))
            }
        }
        let oldNotes=library.notes+(try existing.filter{$0.kind=="expiredNote"}.map{try decoder.decode(Note.self,from:$0.payload)})
        for var note in oldNotes where !recovered.notes.contains(where:{$0.id==note.id}) {
            let key="expired-note-"+note.id.uuidString
            if rows[key]==nil {note.deletedAt=note.deletedAt ?? Date();rows[key]=RecordRow(key:key,kind:"expiredNote",payload:try encoder.encode(note))}
        }
        let importedFonts=recovered.fonts.flatMap(\.versions)
        var dependencies=try existing.filter{$0.kind=="retainedFontVersion"}.map{try decoder.decode(RetainedFontVersion.self,from:$0.payload)}
        guard let origin=library.ownership?.libraryID else {throw NotebookError.invalidModel}
        dependencies += library.fonts.flatMap {project in project.versions.map{RetainedFontVersion(font:$0,ownerProjectID:project.id,originLibraryID:origin)}}
        for dependency in dependencies {
            let key="retained-font-"+dependency.font.id.uuidString
            if let live=importedFonts.first(where:{$0.id==dependency.font.id}) {
                guard live==dependency.font else {throw NotebookError.invalidModel}
                rows.removeValue(forKey:key)
            } else if let imported=rows[key] {
                let value=try decoder.decode(RetainedFontVersion.self,from:imported.payload)
                guard value.font==dependency.font else {throw NotebookError.invalidModel}
                rows[key]=try existing.first{$0.key==key} ?? RecordRow(key:key,kind:"retainedFontVersion",payload:try encoder.encode(dependency))
            } else {rows[key]=try existing.first{$0.key==key} ?? RecordRow(key:key,kind:"retainedFontVersion",payload:try encoder.encode(dependency))}
        }
        if rows.values.contains(where:{$0.kind=="retainedFontVersion"}) {recovered.version=max(3,recovered.version)}
        rows["library"]=RecordRow(key:"library",kind:"library",payload:try encoder.encode(recovered))
        return rows.values.sorted{$0.key<$1.key}
    }
    func replaceRows(_ rows: [RecordRow]) throws {
        causalProjection=nil;searchDocuments=nil
        let context=self.context
        try context.performAndWait {
            for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName:"Record")) {context.delete(object)}
            context.processPendingChanges()
            (context.userInfo[TransactionRecordIndex.contextKey] as? TransactionRecordIndex)?.removeAll()
            var keys=Set<String>()
            for row in rows {
                guard keys.insert(row.key).inserted else {throw NotebookError.invalidModel}
                try Self.setRecord(row.payload,key:row.key,kind:row.kind,context:context)
            }
        }
    }
    /// Explicit selected-library import after consent; transport remains detached until root publication.
    func importChosenLocalLibrary(files: [String:Data],expectedScope: SyncScope,expectedGeneration: String,expectedGraphToken: String) async throws {
        try requireScope(expectedScope)
        guard expectedScope.enabled,expectedScope.receiveOnly != true,expectedScope.accountFingerprint != nil,
              try syncGraphToken()==expectedGraphToken else { throw NotebookError.revisionConflict }
        try await applyRestore(files:files,expectedGeneration:expectedGeneration,policy:.merge,cloudScope:expectedScope)
    }
    /// Every reference is durable before the one synchronous replacement transaction.
    func activateRestore(files: [String:Data],expectedGeneration: String,policy: RestorePolicy) async throws {
        try await applyRestore(files:files,expectedGeneration:expectedGeneration,policy:policy,cloudScope:nil)
    }
    private func applyRestore(files: [String:Data],expectedGeneration: String,policy: RestorePolicy,cloudScope: SyncScope?) async throws {
        let lease=protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        var incoming=try Self.importedRows(files)
        var recovered=try Self.validateGraph(incoming).library
        incoming.removeAll{["causalOperation","operationAck","incomingOperation","engineCheckpoint","syncWire","syncDelivery","syncApplied","syncConflict","derivedSyncCopy","syncContext","syncResolution","syncConsumed","syncRefetch","syncTransport"].contains($0.kind)}
        if policy == .merge {
            let existing=try fontVersions()
            for version in (recovered.fonts.flatMap(\.versions)+(try incoming.filter{$0.kind=="retainedFontVersion"}.map{try decoder.decode(RetainedFontVersion.self,from:$0.payload).font})) {
                if let old=existing.first(where:{$0.id==version.id}),old != version { throw NotebookError.invalidModel }
            }
            // Content identities may change; immutable font UUIDs bind their actual PostScript names.
            var ids:[String:String]=[:]
            func collect(_ value: Any,fonts: Bool = false) {
                if let object=value as? [String:Any] {
                    if !fonts,let id=object["id"] as? String,let uuid=UUID(uuidString:id) { ids[uuid.uuidString]=UUID().uuidString }
                    for (key,child) in object where key != "deviceID" { collect(child,fonts:key=="versions") }
                } else if let array=value as? [Any] { for item in array { collect(item,fonts:fonts) } }
            }
            for row in incoming where row.kind != "outbox" && row.kind != "retainedFontVersion" { collect(try JSONSerialization.jsonObject(with:row.payload,options:.fragmentsAllowed)) }
            func remap(_ value: Any,key: String = "") -> Any {
                if key=="versions" { return value }
                if let string=value as? String {
                    return ["id","pageID","noteID","currentRevisionID","parentRevisionIDs","pageIDs","lastPageID","writingRegionID","bookmarkOrder"].contains(key) ? (ids[string] ?? string) : string
                }
                if let object=value as? [String:Any] { return object.mapValues { $0 }.reduce(into:[String:Any]()) { $0[$1.key]=remap($1.value,key:$1.key) } }
                if let array=value as? [Any] { return array.map { remap($0,key:key) } }
                return value
            }
            incoming=try incoming.filter{$0.kind != "outbox"}.map { row in
                if row.kind=="retainedFontVersion" {return row}
                var object=remap(try JSONSerialization.jsonObject(with:row.payload,options:.fragmentsAllowed))
                if row.kind=="revision",var revision=object as? [String:Any],let content=revision["content"] {
                    let decoded=try decoder.decode(PageContent.self,from:JSONSerialization.data(withJSONObject:content))
                    revision["contentHash"]=AssetStore.hash(try encoder.encode(decoded));object=revision
                }
                let key=row.kind=="pageTombstone" ? "deleted-page-"+(ids[String(row.key.dropFirst(13))] ?? "") : row.kind=="expiredNote" ? "expired-note-"+(ids[String(row.key.dropFirst(13))] ?? "") : (ids[row.key] ?? row.key)
                return RecordRow(key:key,kind:row.kind,payload:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.fragmentsAllowed]))
            }
            recovered=try Self.validateGraph(incoming).library
            incoming=try incoming.filter {row in
                guard row.kind=="retainedFontVersion" else {return true}
                let value=try decoder.decode(RetainedFontVersion.self,from:row.payload)
                return !existing.contains(where:{$0.id==value.font.id})
            }
            let next=(library.notes.map(\.orderKey).max() ?? -1)+1
            guard next<=Int64.max-Int64(recovered.notes.count)-1 else { throw NotebookError.invalidModel }
            for i in recovered.notes.indices { recovered.notes[i].orderKey=next+Int64(i) }
            for i in recovered.fonts.indices {
                let order=recovered.fonts[i].publicationIDs
                let hadShared=recovered.fonts[i].versions.contains { version in existing.contains(where:{$0.id==version.id}) }
                recovered.fonts[i].versions.removeAll { version in existing.contains(where:{$0.id==version.id}) }
                if hadShared { recovered.fonts[i].formatVersion=3;recovered.fonts[i].publishedVersionIDs=order }
            }
            var combined=library;combined.notes+=recovered.notes;combined.fonts+=recovered.fonts;combined.sequence=max(combined.sequence,recovered.sequence);combined.version=max(combined.version,recovered.version)
            combined.bookmarkOrder=(library.bookmarkOrder ?? [])+(recovered.bookmarkOrder ?? [])
            let context=self.context
            incoming=try context.performAndWait { try Self.rows(context:context) }.filter{$0.kind != "library"}+incoming.filter{$0.kind != "library"}
            recovered=combined
        } else { incoming.removeAll{$0.kind=="outbox"} }
        recovered.deviceID=library.deviceID;recovered.sequence=max(library.sequence,recovered.sequence);recovered.preferences.syncEnabled=cloudScope == nil ? false : library.preferences.syncEnabled
        recovered.version=max(2,recovered.version);recovered.ownership=library.ownership
        if cloudScope == nil {
            recovered.ownership?.enabled=false;recovered.ownership?.engineID=nil
            if let generation=recovered.ownership?.generation {recovered.ownership?.generation=generation+1}
        } else { try requireScope(cloudScope!) }
        if policy == .replace {incoming=try preservingDestinationLineage(incoming,recovered:&recovered)}
        incoming.removeAll{$0.kind=="library"};incoming.append(RecordRow(key:"library",kind:"library",payload:try encoder.encode(recovered)))
        let graph=try Self.validateGraph(incoming)
        guard try snapshotGeneration()==expectedGeneration else { throw NotebookError.revisionConflict }
        for hash in graph.assetHashes {
            try Task.checkCancellation();try await assets.ensureDurable(hash:hash)
            guard try snapshotGeneration()==expectedGeneration else { throw NotebookError.revisionConflict }
        }
        try Task.checkCancellation()
        if let cloudScope { try requireScope(cloudScope) }
        try transaction {
            guard try snapshotGeneration()==expectedGeneration else {throw NotebookError.revisionConflict}
            try replaceRows(incoming);library=recovered
        }
    }
}

extension NotebookStore {
    enum ExportSelection: Sendable { case page(UUID),note(UUID),library }
    func captureExport(selection: ExportSelection,format: ExportRequest.Format) throws -> ExportRequest {
        let ids:[UUID]
        switch selection {
        case .page(let id): ids=[id]
        case .note(let id): ids=try loadNote(id).note.pageIDs
        case .library: ids=LibraryRules.orderedNotes(library.notes).flatMap(\.pageIDs)
        }
        let pages=try ids.map(loadPage),fonts=try fontVersions()
        let hashes=pages.reduce(into:Set<String>()){$0.formUnion($1.content.assetHashes)}.union(fonts.map(\.assetHash))
        return ExportRequest(format:format,pages:pages,fonts:fonts,unsaved:false,lease:protection.retain(hashes:hashes,revisions:Set(pages.map(\.currentRevisionID))))
    }
    func prepareTransferDirectories() throws -> (temporary: URL,safety: URL) {
        let temporary=root.appendingPathComponent("Transfers/Temporary"),safety=root.appendingPathComponent("RecoveryPackages")
        if FileManager.default.fileExists(atPath:temporary.path) { try FileManager.default.removeItem(at:temporary) }
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true,attributes:AssetStore.protection)
        try FileManager.default.createDirectory(at:safety,withIntermediateDirectories:true,attributes:AssetStore.protection)
        return (temporary,safety)
    }
    func emergencyExportDirectory() throws -> URL {
        let directory=root.appendingPathComponent("Transfers/Temporary/Emergency")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:AssetStore.protection);return directory
    }
}

extension NotebookStore {
    func safetyPackages() throws -> [SavedPackage] { try NotebookPackage.saved(in:root.appendingPathComponent("RecoveryPackages")) }
}


extension NotebookStore {
    /// Derived current-text projection only; exact source content remains in immutable revisions.
    func search(query:String,scope:String) throws -> [SearchHit] {
        try ensureCacheEpoch()
        var result:[SearchHit]=[]
        for note in LibraryRules.orderedNotes(library.notes,includeDeleted:true) where (scope=="trash") == (note.deletedAt != nil) {
            for id in note.pageIDs {
                try Task.checkCancellation()
                let document:SearchDocument
                if let indexed=searchDocuments?[id] {document=indexed}
                else {let page=try loadPage(id);document=SearchDocument(bookmark:page.bookmark,text:page.content.textBlocks.map(\.text).joined(separator:"\n"))}
                if scope=="bookmarks" && !document.bookmark {continue}
                if let snippet=NotebookSearch.snippet(title:note.title,body:document.text,query:query) {
                    result.append(SearchHit(note:note,pageID:id,snippet:snippet))
                    if query.isEmpty && scope != "bookmarks" {break}
                }
            }
        }
        return result
    }
}


extension NotebookStore {
    /// Only existing-page updates use the validated delta path; structural and external changes retain full graph validation.
    func authoredPageTransaction<T>(pageIDs:Set<UUID>?,_ operation:() throws -> T) throws -> T {
        try ensureCacheEpoch()
        let context=self.context
        guard let pageIDs,!pageIDs.isEmpty,var projection=causalProjection,
              !context.performAndWait({context.hasChanges}),
              try pageIDs.allSatisfy({try record("derived-copy-"+$0.uuidString)==nil}) else {return try transaction(operation)}
        return try protection.locked {
            try ensureCacheEpoch()
            guard let currentProjection=causalProjection,try pageIDs.allSatisfy({try record("derived-copy-"+$0.uuidString)==nil}) else {return try transaction(operation)}
            projection=currentProjection
            transactionInProgress=true;defer{transactionInProgress=false}
            let previous=library,previousDocuments=searchDocuments
            #if DEBUG
            var measuredAt=ContinuousClock.now
            func mark(_ phase:String) {
                guard performancePhases != nil else {return}
                let c=measuredAt.duration(to:.now).components
                performancePhases?[phase]=Double(c.seconds)*1000+Double(c.attoseconds)/1e15;measuredAt = .now
            }
            #endif
            do {
                let oldPages=try Dictionary(uniqueKeysWithValues:pageIDs.map{($0,try loadPage($0))})
                let noteIDs=Set(oldPages.values.map(\.noteID))
                let before=try pageEntityValues(pages:Array(oldPages.values),noteIDs:noteIDs)
                #if DEBUG
                mark("before")
                #endif
                let result=try operation()
                #if DEBUG
                mark("operation")
                #endif
                var afterPages:[PageSnapshot]=[],newRevisions:[PageRevision]=[]
                for (id,old) in oldPages {
                    let page=try loadPage(id)
                    guard page.noteID==old.noteID,page.orderKey==old.orderKey,page.bookmark==old.bookmark,
                          let note=library.notes.first(where:{$0.id==page.noteID}),note.deletedAt==nil,note.pageIDs.contains(id) else {throw NotebookError.invalidModel}
                    afterPages.append(page)
                    if page.currentRevisionID != old.currentRevisionID {
                        let revision=try get(page.currentRevisionID.uuidString,as:PageRevision.self)
                        guard revision.parentRevisionIDs==[old.currentRevisionID],revision.pageID==id,revision.deviceID==library.deviceID,
                              revision.sequence>previous.sequence,revision.sequence<=library.sequence else {throw NotebookError.invalidModel}
                        newRevisions.append(revision)
                    }
                }
                var permitted=previous;permitted.version=library.version;permitted.sequence=library.sequence
                for i in permitted.notes.indices where noteIDs.contains(permitted.notes[i].id) {
                    guard let updated=library.notes.first(where:{$0.id==permitted.notes[i].id}) else {throw NotebookError.invalidModel}
                    try updated.validateAuthorDates();permitted.notes[i].modifiedAt=updated.modifiedAt
                }
                guard try encoder.encode(permitted)==encoder.encode(library) else {throw NotebookError.invalidModel}
                var after=try pageEntityValues(pages:afterPages,noteIDs:noteIDs)
                for revision in newRevisions {after["revision/"+revision.id.uuidString]=try encoder.encode(RevisionHeader(revision))}
                let prior=try Set(before.keys.flatMap{projection.frontiers[$0] ?? []}).map {id -> CausalOperation in
                    let value=try get("operation-"+id.uuidString,as:CausalOperation.self)
                    try value.validate();try value.validateWireValue()
                    guard value.id==id,value.accountFingerprint==library.ownership?.accountFingerprint,
                          projection.frontiers[value.entity]?.contains(id)==true else {throw NotebookError.invalidModel}
                    return value
                }
                #if DEBUG
                mark("deltaValidation")
                #endif
                let authored=try appendOperations(before:before,afterValues:after,priorOperations:prior,contextDependencies:projection.contexts)
                #if DEBUG
                mark("journal")
                #endif
                try CausalOperation.validateNoteMetadataCompleteness(authored)
                for op in authored {
                    guard op.sequence>previous.sequence,op.accountFingerprint==library.ownership?.accountFingerprint else {throw NotebookError.invalidModel}
                    for base in op.bases {
                        guard let old=prior.first(where:{$0.id==base}),old.entity==op.entity,old.sequence<op.sequence || old.deviceID != op.deviceID else {throw NotebookError.invalidModel}
                    }
                    if !op.entity.hasPrefix("revision/") {projection.frontiers[op.entity]=[op.id]}
                }
                if let transaction=authored.first?.transactionID,library.ownership?.accountFingerprint != nil {projection.contexts=[transaction]}
                try put(library,key:"library",kind:"library")
                #if DEBUG
                mark("libraryEncode")
                #endif
                let newRevisionIDs=Set(newRevisions.map(\.id))
                try context.performAndWait {
                    guard context.deletedObjects.isEmpty else {throw NotebookError.invalidModel}
                    for object in context.insertedObjects.union(context.updatedObjects) {
                        guard let kind=object.value(forKey:"kind") as? String,let key=object.value(forKey:"key") as? String else {throw NotebookError.invalidModel}
                        switch kind {
                        case "library":guard key=="library" else {throw NotebookError.invalidModel}
                        case "page":guard UUID(uuidString:key).map(pageIDs.contains)==true else {throw NotebookError.invalidModel}
                        case "revision":guard object.isInserted,UUID(uuidString:key).map(newRevisionIDs.contains)==true else {throw NotebookError.invalidModel}
                        case "outbox","causalOperation","syncContext":guard object.isInserted else {throw NotebookError.invalidModel}
                        default:throw NotebookError.invalidModel
                        }
                    }
                    try context.save()
                }
                #if DEBUG
                mark("save")
                #endif
                if var documents=searchDocuments {
                    for page in afterPages {documents[page.id]=SearchDocument(bookmark:page.bookmark,text:page.content.textBlocks.map(\.text).joined(separator:"\n"))}
                    searchDocuments=documents.values.reduce(0,{$0+$1.text.utf8.count})<=32_000_000 ? documents : nil
                }
                causalProjection=projection;validatedAssetHashes.formUnion(newRevisions.flatMap(\.content.assetHashes))
                protection.committed(Set(newRevisions.flatMap(\.content.assetHashes)));cacheEpoch=protection.currentCommitEpoch
                #if DEBUG
                mark("publication")
                #endif
                return result
            } catch {
                context.performAndWait{context.rollback()};library=previous;searchDocuments=previousDocuments;throw error
            }
        }
    }
    private func pageEntityValues(pages:[PageSnapshot],noteIDs:Set<UUID>) throws -> [String:Data] {
        var values:[String:Data]=[:]
        for note in library.notes where noteIDs.contains(note.id) {
            let key="note/"+note.id.uuidString+"/"
            values[key+"title"]=try encoder.encode(note.title);values[key+"order"]=try encoder.encode(note.orderKey)
            values[key+"pages"]=try encoder.encode(note.pageIDs);values[key+"deleted"]=try encoder.encode(note.deletedAt)
            if library.version>=4 {values[key+"timestamps"]=try encoder.encode(NoteTimestampMetadata(createdAt:note.createdAt,modifiedAt:note.modifiedAt))}
        }
        for page in pages {
            let key="page/"+page.id.uuidString+"/"
            values[key+"head"]=try encoder.encode(page.currentRevisionID);values[key+"owner"]=try encoder.encode(page.noteID)
            values[key+"order"]=try encoder.encode(page.orderKey);values[key+"bookmark"]=try encoder.encode(page.bookmark)
            values[key+"deleted"]=try encoder.encode(Optional<Date>.none)
        }
        return values
    }
}


extension NotebookStore {
    /// A second actor for the same physical root invalidates every derived projection.
    func ensureCacheEpoch() throws {
        guard cacheEpoch != protection.currentCommitEpoch else {return}
        try protection.locked {
            guard cacheEpoch != protection.currentCommitEpoch else {return}
            let context=self.context
            guard !context.performAndWait({context.hasChanges}) else {throw NotebookError.revisionConflict}
            let rows=try context.performAndWait {context.reset();return try Self.rows(context:context)}
            let graph=try Self.validateGraph(rows)
            for hash in graph.assetHashes {_ = try AssetStore.verifiedData(hash:hash,root:root.appendingPathComponent("assets"))}
            try Self.validateStoredWireBodies(rows,fonts:graph.fonts) {try AssetStore.verifiedData(hash:$0,root:root.appendingPathComponent("assets"))}
            library=graph.library;searchDocuments=graph.searchDocuments;causalProjection=graph.causalProjection;validatedAssetHashes=graph.assetHashes;cacheEpoch=protection.currentCommitEpoch
        }
    }
}
