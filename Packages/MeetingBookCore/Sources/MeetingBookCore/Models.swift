import Foundation
public enum NotebookError: Error, Equatable { case unsupportedVersion, invalidModel, notFound, revisionConflict, lastPage, hashMismatch, invalidAsset, expiredTrash }
public struct Note: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var orderKey: Int64
    public var pageIDs: [UUID]
    public var deletedAt: Date?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public init(id: UUID = UUID(), title: String, orderKey: Int64, pageIDs: [UUID], createdAt: Date? = nil, modifiedAt: Date? = nil) { self.id=id; self.title=title; self.orderKey=orderKey; self.pageIDs=pageIDs;self.createdAt=createdAt;self.modifiedAt=modifiedAt }
    public func validateAuthorDates() throws {
        guard [createdAt,modifiedAt].compactMap({$0}).allSatisfy({$0.timeIntervalSince1970.isFinite}) else {throw NotebookError.invalidModel}
    }
}
public struct PageStyle: Codable, Sendable, Equatable {
    public var paper = "ivory"; public var ink = "black"; public var fontSize: Double = 30
    public var ruling: String?
    public init() {}
}
public struct TemplateInstance: Codable, Sendable, Equatable {
    private enum CodingKeys: String,CodingKey { case version,definitionID,definitionVersion,variant,configuration,primitives,geometry,writingRegions }
    public var version = 2
    public var definitionID = "meetingbook.lined"
    public var definitionVersion = 1
    public var variant = "default"
    public var configuration: TemplateConfiguration? = nil
    public var primitives: [TemplatePrimitive] = []
    public var geometry = PageGeometry()
    public var writingRegions = [WritingRegion()]
    public var supportsPaperRuling: Bool { ["meetingbook.lined","meetingbook.blank"].contains(definitionID) && !primitives.contains(where: { $0.kind == .text }) }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        guard version == 1 || version == 2 else { throw NotebookError.unsupportedVersion }
        definitionID=try c.decode(String.self,forKey:.definitionID)
        definitionVersion=try c.decodeIfPresent(Int.self,forKey:.definitionVersion) ?? 1
        variant=try c.decodeIfPresent(String.self,forKey:.variant) ?? "default"
        configuration=try c.decodeIfPresent(TemplateConfiguration.self,forKey:.configuration)
        primitives=try c.decodeIfPresent([TemplatePrimitive].self,forKey:.primitives) ?? []
        geometry=try c.decode(PageGeometry.self,forKey:.geometry)
        writingRegions=try c.decode([WritingRegion].self,forKey:.writingRegions)
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(version,forKey:.version);try c.encode(definitionID,forKey:.definitionID)
        try c.encode(geometry,forKey:.geometry);try c.encode(writingRegions,forKey:.writingRegions)
        // Legacy revision hashes depend on the exact original field set.
        if version>=2 {
            try c.encode(definitionVersion,forKey:.definitionVersion);try c.encode(variant,forKey:.variant)
            try c.encodeIfPresent(configuration,forKey:.configuration);try c.encode(primitives,forKey:.primitives)
        }
    }

}
public struct TextBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var frame: PageRect
    public var text: String
    public var zIndex: Int
    public var fontVersionID: UUID?
    public var fontCatalogID: String?
    public var fontSize: Double?
    public var ink: String?
    public var writingRegionID: UUID?
    public var baselineIndex: Int?
    public init(id: UUID = UUID(), text: String, frame: PageRect = .init(x:56,y:64,width:608,height:872), zIndex: Int = 0, fontVersionID: UUID? = nil) { self.id=id; self.text=text; self.frame=frame; self.zIndex=zIndex; self.fontVersionID=fontVersionID }
}
public struct ImageElement: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var frame: PageRect
    public var zIndex: Int
    public var assetHash: String
    public var previewAssetHash: String?
    public var altText: String
    public init(id: UUID = UUID(), frame: PageRect, zIndex: Int = 0, assetHash: String, altText: String) { self.id=id; self.frame=frame; self.zIndex=zIndex; self.assetHash=assetHash; self.altText=altText }
}
public struct PageContent: Codable, Sendable, Equatable {
    public var version = 1
    public var textBlocks: [TextBlock] = []
    public var images: [ImageElement] = []
    public var drawingAssetHash: String?
    public var style = PageStyle()
    public var template = TemplateInstance()
    public init() {}
    public var assetHashes: Set<String> { Set(images.map(\.assetHash) + images.compactMap(\.previewAssetHash) + [drawingAssetHash].compactMap { $0 }) }
    public func validate() throws {
        guard (1...2).contains(version), (1...2).contains(template.version), template.geometry.version == 1 else { throw NotebookError.unsupportedVersion }
        try TemplateValidation.validate(template)
        if let ruling=style.ruling {
            guard version>=2 else { throw NotebookError.unsupportedVersion }
            guard ["lined","dots","grid"].contains(ruling),template.supportsPaperRuling else { throw NotebookError.invalidModel }
        }
        for block in textBlocks {
            guard version >= 2 || (block.fontCatalogID == nil && block.fontSize == nil && block.ink == nil && block.writingRegionID == nil && block.baselineIndex == nil) else { throw NotebookError.unsupportedVersion }
            if let size=block.fontSize { guard size.isFinite, size > 0, size <= 300 else { throw NotebookError.invalidModel } }
            if let ink=block.ink { guard ["marine","plum","ochre","teal","graphite","black","blue","red","green","purple"].contains(ink) else { throw NotebookError.invalidModel } }
            if let catalog=block.fontCatalogID { guard !catalog.isEmpty,catalog.utf8.count<=200 else { throw NotebookError.invalidModel } }
            if let regionID=block.writingRegionID {
                guard let region=template.writingRegions.first(where: { $0.id == regionID }),
                      let index=block.baselineIndex, region.baselines.indices.contains(index) else { throw NotebookError.invalidModel }
            } else if block.baselineIndex != nil { throw NotebookError.invalidModel }
        }
        guard version >= 2 || images.allSatisfy({ $0.previewAssetHash == nil }) else { throw NotebookError.unsupportedVersion }
        let g=template.geometry
        guard g.width == 720, g.height == 1000, g.ruling.isFinite, g.ruling > 0,
              style.fontSize.isFinite, style.fontSize > 0, style.fontSize <= 300,
              textBlocks.count <= 10000, images.count <= 1000,
              Set(textBlocks.map(\.id)).count == textBlocks.count, Set(images.map(\.id)).count == images.count,
              textBlocks.allSatisfy({ $0.frame.isValid && $0.text.utf8.count <= 10_000_000 }), images.allSatisfy({ $0.frame.isValid && $0.altText.utf8.count<=10000 }),
              assetHashes.allSatisfy(Self.isHash) else { throw NotebookError.invalidModel }
    }
    public mutating func prepareForEditing() {
        for index in textBlocks.indices {
            if textBlocks[index].fontSize == nil { textBlocks[index].fontSize=style.fontSize }
            if textBlocks[index].ink == nil { textBlocks[index].ink=style.ink }
        }
        version=2
    }
    public static func isHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
public struct PageSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let noteID: UUID
    public var orderKey: Int64
    public var currentRevisionID: UUID
    public var bookmark: Bool
    public var content: PageContent
    public init(id: UUID = UUID(), noteID: UUID, orderKey: Int64, currentRevisionID: UUID = UUID(), bookmark: Bool = false, content: PageContent = .init()) { self.id=id; self.noteID=noteID; self.orderKey=orderKey; self.currentRevisionID=currentRevisionID; self.bookmark=bookmark; self.content=content }
}
public enum RevisionReason: String, Codable, Sendable { case edit, clear, delete, fontApply, importData, migration, conflict, recovery }
public struct PageRevision: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let pageID: UUID; public let parentRevisionIDs: [UUID]; public let deviceID: UUID
    public let sequence: Int64; public let createdAt: Date; public let contentHash: String; public let content: PageContent; public let reason: RevisionReason
    public init(id: UUID, pageID: UUID, parentRevisionIDs: [UUID], deviceID: UUID, sequence: Int64, createdAt: Date, contentHash: String, content: PageContent, reason: RevisionReason) { self.id=id;self.pageID=pageID;self.parentRevisionIDs=parentRevisionIDs;self.deviceID=deviceID;self.sequence=sequence;self.createdAt=createdAt;self.contentHash=contentHash;self.content=content;self.reason=reason }
}
public struct PageEditTransaction: Sendable {
    public let pageID: UUID; public let expectedRevisionID: UUID; public let content: PageContent; public let reason: RevisionReason
    public init(pageID: UUID, expectedRevisionID: UUID, content: PageContent, reason: RevisionReason = .edit) { self.pageID=pageID;self.expectedRevisionID=expectedRevisionID;self.content=content;self.reason=reason }
}
public struct CommitReceipt: Sendable {
    public let pageID: UUID; public let revision: PageRevision; public let savedAt: Date; public let confirmedAssetHashes: Set<String>
    public init(pageID: UUID, revision: PageRevision, savedAt: Date, confirmedAssetHashes: Set<String>) { self.pageID=pageID;self.revision=revision;self.savedAt=savedAt;self.confirmedAssetHashes=confirmedAssetHashes }
}
public struct FontVersion: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let assetHash: String; public let postScriptName: String; public let metrics: FontMetrics?
    public init(id: UUID = UUID(), assetHash: String, postScriptName: String, metrics: FontMetrics? = nil) { self.id=id;self.assetHash=assetHash;self.postScriptName=postScriptName;self.metrics=metrics }
}
public struct FontProject: Codable, Sendable, Equatable, Identifiable {
    public var publishedVersionIDs: [UUID]?
    public var publicationIDs: [UUID] { publishedVersionIDs ?? versions.map(\.id) }
    public var formatVersion = 2
    public let id: UUID; public var name: String; public var glyphAssetHashes: [UInt32:String]; public var glyphMetrics: [UInt32:GlyphCaptureMetrics]; public var versions: [FontVersion]
    public init(id: UUID = UUID(), name: String, glyphAssetHashes: [UInt32:String] = [:], glyphMetrics: [UInt32:GlyphCaptureMetrics] = [:], versions: [FontVersion] = []) { self.id=id;self.name=name;self.glyphAssetHashes=glyphAssetHashes;self.glyphMetrics=glyphMetrics;self.versions=versions }
}
extension FontProject {
    public init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        let version=try values.decodeIfPresent(Int.self,forKey:.formatVersion) ?? 1
        guard (1...3).contains(version) else { throw NotebookError.unsupportedVersion }
        formatVersion=max(version,2)
        publishedVersionIDs=try values.decodeIfPresent([UUID].self,forKey:.publishedVersionIDs)
        guard (version==3)==(publishedVersionIDs != nil) else { throw NotebookError.unsupportedVersion }
        id=try values.decode(UUID.self,forKey:.id);name=try values.decode(String.self,forKey:.name)
        glyphAssetHashes=try values.decode([UInt32:String].self,forKey:.glyphAssetHashes)
        glyphMetrics=try values.decodeIfPresent([UInt32:GlyphCaptureMetrics].self,forKey:.glyphMetrics) ?? [:]
        versions=try values.decode([FontVersion].self,forKey:.versions)
    }
    public func validateMetadata() throws {
        guard (formatVersion==2 || formatVersion==3),(formatVersion==3)==(publishedVersionIDs != nil),name.utf8.count <= 10000,glyphAssetHashes.count <= 4096,glyphMetrics.keys.allSatisfy({ glyphAssetHashes[$0] != nil }) else { throw NotebookError.invalidModel }
        let owned=versions.map(\.id),ownedSet=Set(versions.map(\.id))
        guard ownedSet.count==owned.count,publicationIDs.count<=20_000,Set(publicationIDs).count==publicationIDs.count,
              publicationIDs.filter(ownedSet.contains)==owned else { throw NotebookError.invalidModel }
        for metrics in glyphMetrics.values { try metrics.validate() }
        for version in versions { try version.metrics?.validate() }
    }
}

public struct TextDefaults: Codable, Sendable, Equatable {
    public var fontSize: Double
    public var ink: String
    public var fontCatalogID: String?
    public var fontVersionID: UUID?
    public init(fontSize: Double = 30, ink: String = "marine", fontCatalogID: String? = nil, fontVersionID: UUID? = nil) {
        self.fontSize=fontSize;self.ink=ink;self.fontCatalogID=fontCatalogID;self.fontVersionID=fontVersionID
    }
    public func validate() throws {
        guard [24.0,30,36].contains(fontSize),["marine","plum","ochre","teal","graphite","black","blue","red","green","purple"].contains(ink),
              fontCatalogID.map({ !$0.isEmpty && $0.utf8.count<=200 }) ?? true else { throw NotebookError.invalidModel }
    }
}
public struct LibraryPreferences: Codable, Sendable, Equatable {
    public var version = 1; public var lastPageID: UUID?; public var syncEnabled = false
    public var textDefaults: TextDefaults?
    public func validate() throws {
        guard (1...2).contains(version),version>=2 || textDefaults == nil else { throw NotebookError.unsupportedVersion }
        try textDefaults?.validate()
    }
    public init() {}
}
public struct OutboxEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let pageID: UUID; public let revisionID: UUID; public let createdAt: Date
    public init(pageID: UUID, revisionID: UUID, createdAt: Date) { id=UUID();self.pageID=pageID;self.revisionID=revisionID;self.createdAt=createdAt }
}

extension NotebookError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: String(localized:"This library uses an unsupported version. Your data was kept.")
        case .invalidModel: String(localized:"The saved content is invalid. Your data was kept.")
        case .notFound: String(localized:"The requested page or note could not be found.")
        case .revisionConflict: String(localized:"This page changed. Reopen it before saving; your draft has not been saved.")
        case .lastPage: String(localized:"A note must keep at least one page.")
        case .hashMismatch: String(localized:"An asset failed its integrity check. Your data was kept.")
        case .invalidAsset: String(localized:"This asset is invalid or too large.")
        case .expiredTrash: String(localized:"The 30-day restoration period has ended.")
        }
    }
}
