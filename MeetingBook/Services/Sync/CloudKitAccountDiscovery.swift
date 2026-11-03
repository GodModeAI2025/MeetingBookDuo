import Foundation
import CloudKit
import MeetingBookCore

/// The notification arrives on arbitrary queues. Invalidate before an actor task can be delayed.
final class CloudKitAccountEpoch: @unchecked Sendable {
    private let lock=NSLock()
    private var value=UUID()
    private var observer:NSObjectProtocol?
    init() {
        observer=NotificationCenter.default.addObserver(forName:.CKAccountChanged,object:nil,queue:nil) { [weak self] _ in self?.invalidate() }
    }
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    func read() -> UUID {lock.withLock{value}}
    func invalidate() {lock.withLock{value=UUID()}}
    /// Serializes the final synchronous pointer write against account notifications; never spans await.
    func withCurrent(_ expected:UUID,_ action:() throws -> Void) throws {
        try lock.withLock { guard value==expected else {throw NotebookError.revisionConflict};try action() }
    }
}

actor CloudKitAccountDiscovery {
    struct AccountUnavailable:Error,Sendable {let status:CKAccountStatus}
    nonisolated private let epoch=CloudKitAccountEpoch()
    nonisolated func invalidate() {epoch.invalidate()}
    /// Explicit user-authorized inspection/discovery. Availability is not identity.
    func discover(configuration:CloudKitConfiguration) async throws -> String {
        let container=CKContainer(identifier:configuration.container)
        return try await discover(configuration:configuration,status:{try await container.accountStatus()},userID:{try await container.userRecordID()})
    }
    /// Deterministic account API seam; production always supplies the native container above.
    func discover(configuration:CloudKitConfiguration,status:@Sendable () async throws -> CKAccountStatus,userID:@Sendable () async throws -> CKRecord.ID) async throws -> String {
        let token=epoch.read()
        func check() throws {guard epoch.read()==token else {throw NotebookError.revisionConflict}}
        let firstStatus=try await status();try check()
        guard firstStatus == .available else {throw AccountUnavailable(status:firstStatus)}
        let first=try await userID();try check()
        let lastStatus=try await status();try check()
        guard lastStatus == .available else {throw AccountUnavailable(status:lastStatus)}
        let last=try await userID();try check()
        guard first==last else {throw NotebookError.revisionConflict}
        return try Self.fingerprint(user:first,configuration:configuration)
    }
    static func fingerprint(user:CKRecord.ID,configuration:CloudKitConfiguration) throws -> String {
        AssetStore.hash(try JSONEncoder().encode([configuration.container,configuration.environment,user.zoneID.ownerName,user.zoneID.zoneName,user.recordName]))
    }
}
