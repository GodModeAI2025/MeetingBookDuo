import Foundation
import CryptoKit
import Darwin
import MeetingBookCore

struct StagedAsset: Sendable { let id: UUID; let hash: String }
actor AssetStore {
    nonisolated let protection: StorageProtection
    private var pins: [UUID:(lease:StorageLease,hashes:Set<String>)]=[:]
    /// Compatibility view of explicit acquirePin leases, excluding process/publication pins.
    var pinnedHashes: Set<String> { pins.values.reduce(into:Set<String>()){$0.formUnion($1.hashes)} }
    func acquirePin(_ hashes: Set<String>) throws -> UUID {
        guard hashes.allSatisfy(PageContent.isHash) else { throw NotebookError.invalidAsset }
        let pin=protection.retain(hashes:hashes);pins[pin.id]=(pin,hashes);return pin.id
    }
    func releasePin(_ id: UUID) { pins.removeValue(forKey:id) }
    let root: URL
    private let synchronize: @Sendable (URL, Bool) throws -> Void
    init(root: URL, protection: StorageProtection? = nil, synchronize: @escaping @Sendable (URL, Bool) throws -> Void = AssetStore.synchronize) throws {
        self.protection=protection ?? StorageProtection.forRoot(root)
        self.synchronize=synchronize
        self.root=root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true, attributes: Self.protection)
    }
    static var protection: [FileAttributeKey:Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.complete]
        #else
        [:]
        #endif
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    private func location(_ hash: String) throws -> URL {
        guard PageContent.isHash(hash) else { throw NotebookError.invalidAsset }
        return root.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash + ".blob")
    }
    func stage(data: Data, expectedHash: String? = nil) throws -> StagedAsset {
        guard data.count <= 100_000_000 else { throw NotebookError.invalidAsset }
        let hash=Self.hash(data)
        if let expectedHash, hash != expectedHash { throw NotebookError.hashMismatch }
        let asset=StagedAsset(id:UUID(),hash:hash)
        try data.write(to:root.appendingPathComponent("staging/"+asset.id.uuidString), options: [.atomic, .completeFileProtection])
        return asset
    }
    func finalize(_ asset: StagedAsset) throws -> String {
        try protection.locked {
        protection.publish(asset.hash)
        let source=root.appendingPathComponent("staging/"+asset.id.uuidString)
        let data=try Data(contentsOf:source)
        guard Self.hash(data) == asset.hash else { throw NotebookError.hashMismatch }
        // Flush bytes before publishing the content-addressed name.
        try synchronize(source,false)
        let destination=try location(asset.hash)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:Self.protection)
        if FileManager.default.fileExists(atPath:destination.path) { _ = try read(hash:asset.hash); try FileManager.default.removeItem(at:source) }
        else {
            guard Darwin.rename(source.path,destination.path) == 0 else { throw Self.posixError() }
        }
        try synchronize(root.appendingPathComponent("staging"),true)
        try ensureDurable(hash:asset.hash)
        return asset.hash
        }
    }
    func read(hash: String) throws -> Data { try Self.verifiedData(hash:hash,root:root) }
    /// Read-only stable location for native consumers; finalized assets must never be moved or changed.
    func verifiedURL(hash: String) throws -> URL { _ = try read(hash:hash);return try location(hash) }
    /// The commit boundary rechecks durability, including a prior failed finalization.
    func ensureDurable(hash: String) throws {
        _ = try read(hash:hash)
        let destination=try location(hash)
        try synchronize(destination.deletingLastPathComponent(),true)
        try synchronize(root,true)
        try synchronize(root.deletingLastPathComponent(),true)
        try synchronize(root.deletingLastPathComponent().deletingLastPathComponent(),true)
        // Directory fsync submits namespace updates; this device flush follows them.
        try synchronize(destination,false)
    }
    static func verifiedData(hash: String, root: URL) throws -> Data {
        guard PageContent.isHash(hash) else { throw NotebookError.invalidAsset }
        let destination=root.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash+".blob")
        let data=try Data(contentsOf:destination)
        guard Self.hash(data) == hash else { throw NotebookError.hashMismatch }
        return data
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    /// Darwin: checked directory fsync and strong regular-file device flush; no weaker fallback.
    static func synchronize(_ url: URL, _ directory: Bool) throws {
        let descriptor=Darwin.open(url.path,O_RDONLY | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw posixError() }
        do {
            var result: Int32
            repeat { result=directory ? Darwin.fsync(descriptor) : Darwin.fcntl(descriptor,F_FULLFSYNC) } while result == -1 && errno == EINTR
            guard result == 0 else { throw posixError() }
        } catch { _ = Darwin.close(descriptor);throw error }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
    }
}
