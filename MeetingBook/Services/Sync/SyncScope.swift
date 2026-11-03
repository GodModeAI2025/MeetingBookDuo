import Foundation
import MeetingBookCore

/// Local ownership, never an Apple ID, credential or permission to contact CloudKit.
struct SyncScope: Codable, Sendable, Equatable {
    var version=1
    let libraryID: UUID
    var accountFingerprint: String?
    var container: String?
    var environment: String?
    var generation: UInt64=0
    var engineID: UUID?
    var enabled=false
    var receiveOnly: Bool? = nil
    var archived: Bool? = nil
    func validate() throws {
        guard version==1 || version==2 else { throw NotebookError.unsupportedVersion }
        guard (version==2 && receiveOnly != nil) || (version==1 && receiveOnly==nil) else {throw NotebookError.unsupportedVersion}
        guard generation<UInt64.max, (accountFingerprint == nil)==(container == nil), (container == nil)==(environment == nil),
              accountFingerprint.map(PageContent.isHash) ?? true,
              container.map({$0.hasPrefix("iCloud.") && $0.utf8.count<=255}) ?? true,
              environment.map({["development","production"].contains($0)}) ?? true,
              !enabled || (accountFingerprint != nil && engineID != nil && archived != true) else { throw NotebookError.invalidModel }
    }
}

/// Immutable authoring intent; value is a single entity, never a library snapshot.
struct CausalOperation: Codable, Sendable, Equatable, Identifiable {
    var version=1
    let id: UUID
    let transactionID: UUID
    let libraryID: UUID
    let accountFingerprint: String?
    let entity: String
    let bases: [UUID]
    let baseValueHash: String?
    let deviceID: UUID
    let sequence: Int64
    let createdAt: Date
    let value: Data?
    let valueHash: String
    let revisions: Set<UUID>
    let assets: Set<String>
    func validate() throws {
        guard version==1 || version==2 else { throw NotebookError.unsupportedVersion }
        guard !entity.isEmpty,entity.utf8.count<=512,sequence>0,createdAt.timeIntervalSince1970.isFinite,bases.count<=100_000,revisions.count<=100_000,assets.count<=100_000,Set(bases).count==bases.count,!bases.contains(id),
              value.map({$0.count<=16_000_000}) ?? true,assets.allSatisfy(PageContent.isHash),
              baseValueHash.map(PageContent.isHash) ?? true,valueHash==AssetStore.hash(value ?? Data()),accountFingerprint.map(PageContent.isHash) ?? true else { throw NotebookError.invalidModel }
        let parts=entity.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        var valid=entity=="bookmarkOrder" || entity=="preference/textDefaults"
        if parts.count>=2,let id=UUID(uuidString:parts[1]),id.uuidString==parts[1] {
            switch parts[0] {
            case "revision","resolution": valid=parts.count==2
            case "fontVersion": valid=parts.count==2 || (parts.count==3 && parts[2]=="owner")
            case "note": valid=parts.count==3 && (["title","order","pages","deleted"].contains(parts[2]) || (version==2 && parts[2]=="timestamps"))
            case "page": valid=parts.count==3 && ["head","owner","order","bookmark","deleted","retired"].contains(parts[2])
            case "font": valid=(parts.count==3 && ["name","publications"].contains(parts[2])) || (parts.count==4 && parts[2]=="glyph" && UInt32(parts[3]).flatMap(Unicode.Scalar.init) != nil && UInt32(parts[3]).map({String($0)==parts[3]})==true)
            default: break
            }
        }
        guard version==1 || parts.first=="note" else {throw NotebookError.unsupportedVersion}
        guard valid else {throw NotebookError.unsupportedVersion}
        if let value {try ImportValidation.validateJSON(value)}
    }
}
struct RevisionHeader: Codable, Sendable, Equatable {
    let id: UUID;let pageID: UUID;let parentRevisionIDs: [UUID];let deviceID: UUID
    let sequence: Int64;let createdAt: Date;let contentHash: String;let reason: RevisionReason
    init(_ value: PageRevision) {
        id=value.id;pageID=value.pageID;parentRevisionIDs=value.parentRevisionIDs;deviceID=value.deviceID
        sequence=value.sequence;createdAt=value.createdAt;contentHash=value.contentHash;reason=value.reason
    }
}
struct ScopedAcknowledgement: Codable, Sendable { let operationID: UUID;let valueHash: String;let scope: SyncScope;var systemFields: Data? = nil;var received: Bool? = nil }
struct IncomingOperation: Codable, Sendable { let operation: CausalOperation;let scope: SyncScope;let systemFields: Data;var availableAssets: Set<String>? = nil }
struct EngineCheckpoint: Codable, Sendable { let scope: SyncScope;let bytes: Data }
struct RetentionResult: Sendable { var prunedRevisions=0;var expiredPages=0;var removedAssets=0;var deferred=false }

struct OutgoingCapture: Sendable {
    let scope: SyncScope
    let operations: [CausalOperation]
    let revisionPayloads: [UUID:Data]
    let fontDependencies: [RetainedFontVersion]
    let lease: StorageLease
}

extension RevisionHeader {
    /// Latest on each causal branch, never a comparison of different devices' counters.
    static func protectedRecoveryParents(_ headers: [RevisionHeader]) -> Set<UUID> {
        let byID=Dictionary(uniqueKeysWithValues:headers.map{($0.id,$0)})
        let destructive=headers.filter{$0.reason != .edit && $0.reason != .recovery}
        let ids=Set(destructive.map(\.id))
        var superseded=Set<UUID>()
        for revision in destructive {
            var pending=revision.parentRevisionIDs,seen=Set<UUID>()
            while let id=pending.popLast() {
                guard seen.insert(id).inserted,let parent=byID[id] else {continue}
                if ids.contains(id) {superseded.insert(id)}
                pending+=parent.parentRevisionIDs
            }
        }
        return destructive.filter{!superseded.contains($0.id)}.reduce(into:Set<UUID>()){$0.formUnion($1.parentRevisionIDs)}
    }
}

/// Dependency metadata only; never an editable Font Studio project.
struct RetainedFontVersion: Codable, Sendable, Equatable {
    var version=1
    let font: FontVersion
    let ownerProjectID: UUID
    let originLibraryID: UUID
}


extension CausalOperation {
    /// Validate the actual entity schema before trusting a granular wire value.
    func validateWireValue() throws {
        guard bases.count<=100_000,revisions.count<=100_000,assets.count<=100_000,createdAt.timeIntervalSince1970.isFinite else {throw NotebookError.invalidModel}
        guard let value else {
            guard !entity.hasSuffix("/timestamps") else {throw NotebookError.invalidModel}
            return
        } // Entity removal; complete graph validation decides whether it is legal.
        let decoder=JSONDecoder(),parts=entity.split(separator:"/").map(String.init)
        func read<T:Decodable>(_ type:T.Type) throws -> T {try decoder.decode(type,from:value)}
        func ids() throws {let ids=try read([UUID].self);guard ids.count<=100_000,Set(ids).count==ids.count else {throw NotebookError.invalidModel}}
        if entity=="bookmarkOrder" {try ids();return}
        if entity=="preference/textDefaults" {try read(TextDefaults?.self)?.validate();return}
        guard parts.count>=2,let id=UUID(uuidString:parts[1]) else {throw NotebookError.invalidModel}
        if parts[0]=="resolution" {
            let resolution=try read(SyncResolution.self);try resolution.validate()
            guard resolution.id==id,resolution.accountFingerprint==accountFingerprint,resolution.authorLibraryID==libraryID else {throw NotebookError.invalidModel};return
        }
        if parts[0]=="revision" {
            let header=try read(RevisionHeader.self)
            guard header.id==id,header.sequence>0,PageContent.isHash(header.contentHash),Set(header.parentRevisionIDs).count==header.parentRevisionIDs.count,!header.parentRevisionIDs.contains(id) else {throw NotebookError.invalidModel};return
        }
        if parts[0]=="fontVersion",parts.count==2 {
            let font=try read(FontVersion.self)
            guard font.id==id,PageContent.isHash(font.assetHash),assets.contains(font.assetHash),!font.postScriptName.isEmpty else {throw NotebookError.invalidModel};try font.metrics?.validate();return
        }
        guard parts.count>=3 else {throw NotebookError.invalidModel}
        switch parts[2] {
        case "timestamps": try read(NoteTimestampMetadata.self).validate()
        case "head","owner": _ = try read(UUID.self)
        case "title","name": guard try read(String.self).utf8.count<=10_000 else {throw NotebookError.invalidModel}
        case "order": let number=try read(Int64.self);guard number>=0,number<Int64.max else {throw NotebookError.invalidModel}
        case "pages","publications": try ids()
        case "bookmark": _ = try read(Bool.self)
        case "deleted": if let date=try read(Date?.self) {guard date.timeIntervalSince1970.isFinite else {throw NotebookError.invalidModel}}
        case "retired": let page=try read(PageSnapshot.self);guard page.id==id else {throw NotebookError.invalidModel};try page.content.validate()
        case "glyph":
            struct Glyph:Decodable {let hash:String?;let metrics:GlyphCaptureMetrics?}
            let glyph=try read(Glyph.self)
            guard (glyph.metrics==nil || glyph.hash != nil),glyph.hash.map({PageContent.isHash($0) && assets.contains($0)}) ?? true else {throw NotebookError.invalidModel};try glyph.metrics?.validate()
        default: throw NotebookError.unsupportedVersion
        }
    }
}


extension CausalOperation {
    var isMutableSyncEntity:Bool {
        !entity.hasPrefix("revision/") && !entity.hasPrefix("resolution/") && !(entity.hasPrefix("fontVersion/") && entity.split(separator:"/").count==2)
    }
}


/// Both keys are mandatory, including explicit null for genuinely unknown history.
struct NoteTimestampMetadata: Codable, Equatable {
    let createdAt: Date?
    let modifiedAt: Date?
    enum CodingKeys: String,CodingKey {case createdAt,modifiedAt}
    init(createdAt: Date?,modifiedAt: Date?) {self.createdAt=createdAt;self.modifiedAt=modifiedAt}
    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        guard values.contains(.createdAt),values.contains(.modifiedAt) else {throw NotebookError.invalidModel}
        createdAt=try values.decodeIfPresent(Date.self,forKey:.createdAt)
        modifiedAt=try values.decodeIfPresent(Date.self,forKey:.modifiedAt)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var values=encoder.container(keyedBy:CodingKeys.self)
        try values.encode(createdAt,forKey:.createdAt);try values.encode(modifiedAt,forKey:.modifiedAt)
    }
    func validate() throws {
        guard [createdAt,modifiedAt].compactMap({$0}).allSatisfy({$0.timeIntervalSince1970.isFinite}) else {throw NotebookError.invalidModel}
    }
    /// Causally maximal author events; UUID selects concurrent maxima, never wall-clock time.
    static func project(_ operations: [CausalOperation]) throws -> Self {
        let values=try operations.map {operation -> Self in
            guard let bytes=operation.value else {throw NotebookError.invalidModel}
            return try JSONDecoder().decode(Self.self,from:bytes)
        }
        let creations=Set(values.compactMap(\.createdAt))
        guard creations.count<=1 else {throw NotebookError.invalidModel}
        let superseded=Set(operations.flatMap(\.bases))
        guard let selected=operations.filter({!superseded.contains($0.id)}).max(by:{$0.id.uuidString<$1.id.uuidString}),let index=operations.firstIndex(where:{$0.id==selected.id}) else {throw NotebookError.invalidModel}
        return Self(createdAt:creations.first,modifiedAt:values[index].modifiedAt)
    }
}


extension CausalOperation {
    static func validateNoteMetadataCompleteness(_ operations: [CausalOperation]) throws {
        let members=Dictionary(grouping:operations,by:\.transactionID)
        // A claimed hash cannot establish history; nonempty bases must also pass graph validation.
        for operation in operations where operation.version==2 && operation.entity.hasPrefix("note/") && (operation.baseValueHash==nil || operation.bases.isEmpty) && !operation.entity.hasSuffix("/timestamps") {
            let prefix=operation.entity.split(separator:"/").prefix(2).joined(separator:"/")+"/"
            guard members[operation.transactionID]?.contains(where:{$0.entity==prefix+"timestamps" && $0.version==2 && $0.value != nil})==true else {throw NotebookError.invalidModel}
        }
    }
}
