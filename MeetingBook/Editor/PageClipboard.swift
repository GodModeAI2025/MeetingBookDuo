import UIKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers
import MeetingBookCore

struct PageClipboard: Codable {
    static let type="de.meetingbook.editable-page"
    var version=1
    let content: PageContent
    let assets: [String:Data]
    let fonts: [FontVersion]
    func validate() throws {
        guard version == 1 else { throw NotebookError.unsupportedVersion }
        try content.validate()
        guard assets.count<=1100,fonts.count<=100,assets.values.reduce(0,{ $0+$1.count })<=100_000_000,
              Set(fonts.map(\.id)).count == fonts.count else { throw NotebookError.invalidAsset }
        let required=content.assetHashes.union(fonts.map(\.assetHash))
        guard Set(assets.keys)==required,content.textBlocks.compactMap(\.fontVersionID).allSatisfy({ id in fonts.contains { $0.id == id } }) else { throw NotebookError.invalidAsset }
        for (hash,bytes) in assets { guard PageContent.isHash(hash),AssetStore.hash(bytes)==hash else { throw NotebookError.hashMismatch } }
        for version in fonts { try FontValidation.validateGenerated(assets[version.assetHash]!) }
        if let hash=content.drawingAssetHash { _ = try PKDrawing(data:assets[hash]!) }
        for image in content.images {
            for hash in [image.assetHash,image.previewAssetHash].compactMap({ $0 }) {
                guard let source=CGImageSourceCreateWithData(assets[hash]! as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                      CGImageSourceGetCount(source)==1,CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
                      width>0,height>0,width<=40_000_000/height,
                      properties[kCGImagePropertyGPSDictionary] == nil,properties[kCGImagePropertyExifDictionary] == nil,
                      properties[kCGImagePropertyIPTCDictionary] == nil,
                      (properties[kCGImagePropertyOrientation] as? Int ?? 1)==1 else { throw NotebookError.invalidAsset }
                if hash == image.previewAssetHash { guard max(width,height)<=4096 else { throw NotebookError.invalidAsset } }
            }
        }
    }
    @MainActor static func copy(content: PageContent, store: NotebookStore) async throws {
        let lease=store.protection.retain(blocksCollection:true);defer {withExtendedLifetime(lease){}}
        let fonts=try await store.fontVersions().filter { font in content.textBlocks.contains { $0.fontVersionID == font.id } }
        var assets: [String:Data]=[:]
        for hash in content.assetHashes.union(fonts.map(\.assetHash)) { assets[hash]=try await store.assets.read(hash:hash) }
        let payload=PageClipboard(content:content,assets:assets,fonts:fonts);try payload.validate()
        let encoded=try JSONEncoder().encode(payload);guard encoded.count<=140_000_000 else { throw NotebookError.invalidAsset }
        let resources=try await PageRenderer.resources(for:content,store:store)
        let fallback=try PageRenderer.image(content,resources:resources).pngData()!
        UIPasteboard.general.setItems([[Self.type:encoded,UTType.png.identifier:fallback]])
    }
    @MainActor static func paste(into session: EditorSession) async throws {
        // This read happens only in response to the explicit Paste command.
        if let data=UIPasteboard.general.data(forPasteboardType:type) {
            guard data.count<=140_000_000 else { throw NotebookError.invalidAsset }
            let payload=try JSONDecoder().decode(Self.self,from:data);try payload.validate()
            try await session.flush()
            let token=session.beginAssetWrite(pageID:session.activePageID);defer {session.endAssetWrite(token)}
            for (hash,bytes) in payload.assets { let staged=try await session.store.assets.stage(data:bytes,expectedHash:hash);_ = try await session.store.assets.finalize(staged) }
            try await session.paste(content:EditorSession.freshIDs(payload.content),fonts:payload.fonts,completingAssetToken:token)
        } else {
            for type in [UTType.png,UTType.jpeg,UTType.heic,UTType.tiff] {
                if let data=UIPasteboard.general.data(forPasteboardType:type.identifier) { try await session.importImage(data);return }
            }
            throw NotebookError.invalidAsset
        }
    }
}
