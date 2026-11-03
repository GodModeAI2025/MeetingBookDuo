import Foundation
import Darwin
import PencilKit
import MeetingBookCore

struct ImportPreview: Sendable, Equatable, Identifiable {
    let id: UUID
    let sha256: String
    let byteCount: UInt64
    let sourceName: String
    let unsaved: Bool
    let noteCount: Int
    let pageCount: Int
}
enum RestorePolicy: Sendable { case replace, merge }
actor RestoreService {
    let store: NotebookStore
    let root: URL
    let safetyRoot: URL
    private struct Staged { let preview: ImportPreview;let directory: URL;let source: URL;let generation: String;let sizePolicy:PackageSizePolicy }
    private var staged:[UUID:Staged]=[:]
    init(store: NotebookStore,root: URL,safetyRoot: URL? = nil) { self.store=store;self.root=root;self.safetyRoot=safetyRoot ?? root.deletingLastPathComponent().appendingPathComponent("SafetyBackups") }
    func inspectImport(url: URL,sizePolicy:PackageSizePolicy = .ordinary) async throws -> ImportPreview {
        let directory=try PackageIO.directory(in:root),owned=directory.appendingPathComponent("source.notebookpkg")
        do {
            let access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
            var failure:NSError?,copied:Result<(size:UInt64,hash:String),Error>?
            NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&failure) { coordinated in copied=Result { try PackageIO.digest(coordinated,maximum:sizePolicy.zipLimits.file,copyTo:owned) } }
            if let failure { throw failure };guard let copied else { throw NotebookError.invalidAsset }
            let digest=try copied.get(),reader=NotebookPackage(root:directory)
            let content=try await reader.inspect(url:owned,directory:try PackageIO.directory(in:directory),policy:sizePolicy)
            try await reader.validateNativeAssets(content)
            try Task.checkCancellation()
            let preview=ImportPreview(id:UUID(),sha256:digest.hash,byteCount:digest.size,sourceName:url.lastPathComponent,unsaved:content.unsaved,noteCount:content.notes,pageCount:content.pages)
            staged[preview.id]=Staged(preview:preview,directory:directory,source:owned,generation:try await store.snapshotGeneration(),sizePolicy:sizePolicy)
            return preview
        } catch { try? FileManager.default.removeItem(at:directory);throw error }
    }
    func discard(_ preview: ImportPreview) throws {
        if let value=staged.removeValue(forKey:preview.id) { try FileManager.default.removeItem(at:value.directory) }
    }
    func restore(_ preview: ImportPreview,policy: RestorePolicy,cloudScope: SyncScope? = nil,cloudGraphToken: String? = nil) async throws {
        guard let value=staged.removeValue(forKey:preview.id),value.preview==preview else { throw NotebookError.invalidModel }
        defer { try? FileManager.default.removeItem(at:value.directory) }
        let digest=try PackageIO.digest(value.source,maximum:value.sizePolicy.zipLimits.file)
        guard digest.hash==preview.sha256,digest.size==preview.byteCount else { throw NotebookError.hashMismatch }
        let reader=NotebookPackage(root:value.directory)
        let content=try await reader.inspect(url:value.source,directory:try PackageIO.directory(in:value.directory),policy:value.sizePolicy)
        try await reader.validateNativeAssets(content)
        let capture=try await store.captureBackup()
        guard capture.generation==value.generation else { await store.assets.releasePin(capture.pin);throw NotebookError.revisionConflict }
        // A complete verified package is retained independently of disposable picker staging.
        _ = try await NotebookPackage(root:safetyRoot).create(capture:capture,assets:store.assets)
        guard try await store.snapshotGeneration()==value.generation else { throw NotebookError.revisionConflict }
        for (hash,url) in content.assets {
            try Task.checkCancellation()
            let asset=try await store.assets.stage(data:Data(contentsOf:url),expectedHash:hash)
            guard try await store.snapshotGeneration()==value.generation else { throw NotebookError.revisionConflict }
            _ = try await store.assets.finalize(asset)
            guard try await store.snapshotGeneration()==value.generation else { throw NotebookError.revisionConflict }
        }
        if let cloudScope {
            guard policy == .merge,let cloudGraphToken else {throw NotebookError.invalidModel}
            try await store.importChosenLocalLibrary(files:content.records,expectedScope:cloudScope,expectedGeneration:value.generation,expectedGraphToken:cloudGraphToken)
        } else { try await store.activateRestore(files:content.records,expectedGeneration:value.generation,policy:policy) }
    }

}

enum TransferError: LocalizedError {
    case openFontProject,unsavedWindows,pageTooLarge,activationUncertain
    var errorDescription: String? {
        switch self {
        case .activationUncertain: String(localized:"Recovery selection was written, but durability could not be confirmed. Both libraries were kept. Close and reopen MeetingBook to inspect the selected library.")
        case .openFontProject: String(localized:"Close Font Studio in every window before restoring. Save or export any unsaved character first.")
        case .unsavedWindows: String(localized:"Another editor has unsaved or pending work. Save or export it in that window before restoring. Your drafts are still here.")
        case .pageTooLarge: String(localized:"This page exceeds the export limit of 40 million decoded image pixels. Export a notebook package to preserve all originals.")
        }
    }
}

/// Cold recovery never touches the failed store. The only activation mutation is a bounded root-ID file.
actor ColdRecoveryService {
    let baseRoot: URL
    private let synchronize: @Sendable (URL,Bool) throws -> Void
    private var directory: URL { baseRoot.deletingLastPathComponent().appendingPathComponent(baseRoot.lastPathComponent+"-RecoveryRoots") }
    private var pointer: URL { directory.appendingPathComponent("active-root.json") }
    private struct Pointer: Codable { let version: Int;let rootID: String }
    private struct Candidate { let rootID: UUID;let root: URL;let store: NotebookStore;let restore: RestoreService;let preview: ImportPreview;let priorPointer: Data? }
    private var candidates:[UUID:Candidate]=[:]
    private var ownedStores:[UUID:NotebookStore]=[:]
    private var ownedCandidates:[UUID:(root:URL,store:NotebookStore,priorPointer:Data?)]=[:]
    init(baseRoot: URL,synchronize: @escaping @Sendable (URL,Bool) throws -> Void = AssetStore.synchronize) { self.baseRoot=baseRoot;self.synchronize=synchronize }
    private func pointerBytes() throws -> Data? {
        var info=stat()
        if lstat(pointer.path,&info) != 0 { guard errno==ENOENT else { throw POSIXError(.EIO) };return nil }
        let file=try PackageIO.openRegular(pointer);defer { try? file.close() }
        guard try file.seekToEnd()<=4096 else { throw NotebookError.invalidModel };try file.seek(toOffset:0)
        guard let bytes=try file.readToEnd(),!bytes.isEmpty else { throw NotebookError.invalidModel };return bytes
    }
    func safetyPackages() throws -> [SavedPackage] {
        var roots:Set<URL>=[baseRoot]
        if let selected=try? selectedRoot() { roots.insert(selected) }
        return try roots.flatMap { try NotebookPackage.saved(in:$0.appendingPathComponent("RecoveryPackages")) }.sorted{$0.createdAt>$1.createdAt}
    }
    func selectedRoot() throws -> URL {
        guard let bytes=try pointerBytes() else { return baseRoot }
        try ImportValidation.validateJSON(bytes,maximum:4096)
        let value=try JSONDecoder().decode(Pointer.self,from:bytes)
        guard value.version==1,let id=UUID(uuidString:value.rootID),id.uuidString.lowercased()==value.rootID else { throw NotebookError.invalidModel }
        let root=directory.appendingPathComponent(value.rootID)
        let attributes=try FileManager.default.attributesOfItem(atPath:root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NotebookError.invalidModel }
        let database=try PackageIO.openRegular(root.appendingPathComponent("metadata.sqlite"));try database.close()
        return root
    }
    /// Called once per app launch, before any editor/import sessions exist.
    func cleanAbandonedImportFiles() throws {
        guard FileManager.default.fileExists(atPath:directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where UUID(uuidString:child.lastPathComponent) != nil {
            let attributes=try FileManager.default.attributesOfItem(atPath:child.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NotebookError.invalidModel }
            let temporary=child.appendingPathComponent("Transfers/Temporary")
            if FileManager.default.fileExists(atPath:temporary.path) { try FileManager.default.removeItem(at:temporary) }
        }
    }
    func inspectImport(url: URL,sizePolicy:PackageSizePolicy = .ordinary) async throws -> ImportPreview {
        let prior=try pointerBytes(),id=UUID(),root=directory.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:AssetStore.protection)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:AssetStore.protection)
        let store=try await NotebookStore.open(root:root)
        let restore=RestoreService(store:store,root:root.appendingPathComponent("Transfers/Temporary/Imports"),safetyRoot:root.appendingPathComponent("RecoveryPackages"))
        let preview=try await restore.inspectImport(url:url,sizePolicy:sizePolicy)
        candidates[preview.id]=Candidate(rootID:id,root:root,store:store,restore:restore,preview:preview,priorPointer:prior)
        return preview
    }
    func discard(_ preview: ImportPreview) async throws {
        if let value=candidates.removeValue(forKey:preview.id) { try await value.restore.discard(preview) }
    }
    func activate(_ preview: ImportPreview) async throws {
        guard let candidate=candidates.removeValue(forKey:preview.id),candidate.preview==preview else { throw NotebookError.invalidModel }
        try await candidate.restore.restore(preview,policy:.replace)
        // Read-only graph/asset validation on reopen precedes publishing the owned root ID.
        _ = try await NotebookStore.open(root:candidate.root)
        try publishRoot(rootID:candidate.rootID,root:candidate.root,priorPointer:candidate.priorPointer)
    }
    private func publishRoot(rootID: UUID,root: URL,priorPointer: Data?) throws {
        let lock=Darwin.open(directory.appendingPathComponent("activation.lock").path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lock>=0 else { throw POSIXError(.EIO) }
        defer { _ = flock(lock,LOCK_UN);Darwin.close(lock) }
        guard flock(lock,LOCK_EX|LOCK_NB)==0,try pointerBytes()==priorPointer else { throw NotebookError.revisionConflict }
        try Task.checkCancellation()
        let bytes=try JSONEncoder().encode(Pointer(version:1,rootID:rootID.uuidString.lowercased()))
        let staged=directory.appendingPathComponent("pointer-"+UUID().uuidString+".tmp")
        try PackageIO.write(bytes,to:staged);try synchronize(staged,false)
        try synchronize(root,true)
        // After rename cancellation cannot undo activation. A flush error retains both complete roots.
        guard Darwin.rename(staged.path,pointer.path)==0 else { throw POSIXError(.EIO) }
        do { try synchronize(directory,true);try synchronize(pointer,false) } catch { throw TransferError.activationUncertain }
    }
}

extension ColdRecoveryService {
    struct OwnedLibrary: Sendable { let rootID: UUID;let store: NotebookStore }
    func createOwnedLibrary() async throws -> OwnedLibrary {
        let id=UUID(),prior=try pointerBytes(),root=directory.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:AssetStore.protection)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:AssetStore.protection)
        let store=try await NotebookStore.open(root:root)
        guard try pointerBytes()==prior else {throw NotebookError.revisionConflict}
        ownedStores[id]=store;ownedCandidates[id]=(root,store,prior);return OwnedLibrary(rootID:id,store:store)
    }
    func prepareOwnedLibrary(rootID: UUID) async throws -> OwnedLibrary {
        let prior=try pointerBytes(),root=directory.appendingPathComponent(rootID.uuidString.lowercased())
        let attributes=try FileManager.default.attributesOfItem(atPath:root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw NotebookError.invalidModel}
        let file=try PackageIO.openRegular(root.appendingPathComponent("metadata.sqlite"));try file.close()
        let store:NotebookStore
        if let retained=ownedStores[rootID] {store=retained} else {store=try await NotebookStore.open(root:root);ownedStores[rootID]=store}
        guard try pointerBytes()==prior else {throw NotebookError.revisionConflict}
        ownedCandidates[rootID]=(root,store,prior);return OwnedLibrary(rootID:rootID,store:store)
    }
    func activateOwnedLibrary(rootID: UUID,expectedScope: SyncScope,sourceGuard:StorePublicationGuard? = nil,publication: @Sendable (() throws -> Void) throws -> Void = {try $0()}) async throws {
        guard let candidate=ownedCandidates[rootID] else {throw NotebookError.notFound}
        try await candidate.store.requireScope(expectedScope)
        _ = try await NotebookStore.open(root:candidate.root)
        try await candidate.store.requireScope(expectedScope)
        if let sourceGuard {try sourceGuard.perform {try publication {try publishRoot(rootID:rootID,root:candidate.root,priorPointer:candidate.priorPointer)}}}
        else {try publication {try publishRoot(rootID:rootID,root:candidate.root,priorPointer:candidate.priorPointer)}}
        ownedCandidates.removeValue(forKey:rootID)
    }
    /// Inventory only identifiers. Failed and frozen roots are retained and may fail explicit preparation.
    func ownedRootIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath:directory.path) else {return []}
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).compactMap {url in
            guard let id=UUID(uuidString:url.lastPathComponent),url.lastPathComponent==id.uuidString.lowercased() else {return nil}
            return id
        }.sorted{$0.uuidString<$1.uuidString}
    }
}


extension ColdRecoveryService {
    /// Fork only an unassigned base through the validated logical package path; retain source and backup.
    func adoptLocalBase(source:NotebookStore,expectedScope:SyncScope,expectedGeneration:String,
                        publication:@Sendable (() throws -> Void) throws -> Void) async throws -> OwnedLibrary {
        guard source.root.path==baseRoot.path,expectedScope.accountFingerprint==nil else {throw NotebookError.revisionConflict}
        try await source.requireScope(expectedScope)
        let sourceGuard=try await source.publicationGuard(expectedScope:expectedScope,expectedGeneration:expectedGeneration)
        let capture=try await source.captureBackup()
        guard capture.generation==expectedGeneration else {await source.assets.releasePin(capture.pin);throw NotebookError.revisionConflict}
        let package=try await NotebookPackage(root:baseRoot.appendingPathComponent("RecoveryPackages")).create(capture:capture,assets:source.assets)
        let owned=try await createOwnedLibrary()
        let restore=RestoreService(store:owned.store,root:owned.store.root.appendingPathComponent("Transfers/Temporary/Imports"),safetyRoot:owned.store.root.appendingPathComponent("RecoveryPackages"))
        let preview=try await restore.inspectImport(url:package,sizePolicy:.large)
        try await restore.restore(preview,policy:.replace)
        try await source.requireScope(expectedScope)
        guard try await source.snapshotGeneration()==expectedGeneration else {throw NotebookError.revisionConflict}
        try await activateOwnedLibrary(rootID:owned.rootID,expectedScope:owned.store.syncScope(),sourceGuard:sourceGuard,publication:publication)
        return owned
    }
}
