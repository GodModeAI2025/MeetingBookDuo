import Foundation
import MeetingBookCore

/// One short synchronous exclusion boundary for publication, DB commit and physical unlink.
/// No lock is held across an actor suspension. Leases may span awaits.
final class StorageProtection: @unchecked Sendable {
    // Strong for process lifetime: Core Text may retain a registered path after its store closes.
    private static let registryLock=NSLock()
    nonisolated(unsafe) private static var registry:[String:StorageProtection]=[:]
    static func forRoot(_ root: URL) -> StorageProtection {
        registryLock.lock();defer {registryLock.unlock()}
        let key=root.standardizedFileURL.path
        if let existing=registry[key] {return existing}
        let value=StorageProtection();registry[key]=value;return value
    }
    struct Pin:Sendable { var hashes: Set<String>;var revisions: Set<UUID>;var draftPages: Set<UUID>;var remotePages: Set<UUID>;var remoteFonts: Set<UUID>;var blocksCollection: Bool }
    private let lock=NSRecursiveLock()
    private var pins:[UUID:Pin]=[:]
    private var commitEpoch=UUID()
    private var retentionEpoch=UUID()
    private var published:Set<String>=[]
    private var registered:Set<String>=[]
    func locked<T>(_ operation: () throws -> T) rethrows -> T { lock.lock();defer {lock.unlock()};return try operation() }
    func retain(hashes: Set<String> = [],revisions: Set<UUID> = [],draftPages: Set<UUID> = [],remotePages: Set<UUID> = [],remoteFonts: Set<UUID> = [],blocksCollection: Bool = false) -> StorageLease {
        let id=UUID();update(id,hashes:hashes,revisions:revisions,draftPages:draftPages,remotePages:remotePages,remoteFonts:remoteFonts,blocksCollection:blocksCollection)
        return StorageLease(id:id,owner:self)
    }
    func update(_ id: UUID,hashes: Set<String>,revisions: Set<UUID> = [],draftPages: Set<UUID> = [],remotePages: Set<UUID> = [],remoteFonts: Set<UUID> = [],blocksCollection: Bool = false) {
        locked { pins[id]=Pin(hashes:hashes,revisions:revisions,draftPages:draftPages,remotePages:remotePages,remoteFonts:remoteFonts,blocksCollection:blocksCollection) }
    }
    func release(_ id: UUID) { locked { _ = pins.removeValue(forKey:id) } }
    func publish(_ hash: String) { locked { _ = published.insert(hash) } }
    var currentCommitEpoch:UUID {locked {commitEpoch}}
    var currentRetentionEpoch:UUID {locked {retentionEpoch}}
    func recoveryPublished() {locked {retentionEpoch=UUID()}}
    func committed(_ hashes: Set<String>) { locked { published.subtract(hashes);commitEpoch=UUID() } }
    func publicationGuard() -> StorePublicationGuard {locked {StorePublicationGuard(protection:self,epoch:commitEpoch)}}
    fileprivate func readCommitted(expected:UUID,_ action:() throws -> Void) throws {
        try locked {guard commitEpoch==expected else {throw NotebookError.revisionConflict};try action()}
    }
    fileprivate func publish(expected:UUID,_ action:() throws -> Void) throws {
        try locked {
            guard commitEpoch==expected,snapshot.draftPages.isEmpty,snapshot.remoteFonts.isEmpty else {throw NotebookError.revisionConflict}
            try action()
        }
    }
    func register(_ hash: String) { locked { _ = registered.insert(hash) } }
    var snapshot: Pin { locked { Pin(hashes:pins.values.reduce(published.union(registered)){$0.union($1.hashes)},revisions:pins.values.reduce([]){$0.union($1.revisions)},draftPages:pins.values.reduce([]){$0.union($1.draftPages)},remotePages:pins.values.reduce([]){$0.union($1.remotePages).union($1.draftPages)},remoteFonts:pins.values.reduce([]){$0.union($1.remoteFonts)},blocksCollection:pins.values.contains{$0.blocksCollection}) } }
}
final class StorageLease: @unchecked Sendable {
    let id: UUID
    private let owner: StorageProtection
    init(id: UUID,owner: StorageProtection) { self.id=id;self.owner=owner }
    func update(hashes: Set<String>,revisions: Set<UUID> = [],draftPages: Set<UUID> = [],remotePages: Set<UUID> = [],remoteFonts: Set<UUID> = [],blocksCollection: Bool = false) { owner.update(id,hashes:hashes,revisions:revisions,draftPages:draftPages,remotePages:remotePages,remoteFonts:remoteFonts,blocksCollection:blocksCollection) }
    deinit { owner.release(id) }
}

struct StorePublicationGuard:Sendable {
    fileprivate let protection:StorageProtection
    fileprivate let epoch:UUID
    func performCommittedRead(_ action:() throws -> Void) throws {try protection.readCommitted(expected:epoch,action)}
    func perform(_ action:() throws -> Void) throws {try protection.publish(expected:epoch,action)}
}
