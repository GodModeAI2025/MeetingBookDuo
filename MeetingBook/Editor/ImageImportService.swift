import Foundation
import ImageIO
import UniformTypeIdentifiers
import MeetingBookCore

actor ImageImportService {
    struct Imported: Sendable { let assetHash: String;let previewAssetHash: String;let width: Int;let height: Int }
    let assets: AssetStore
    init(assets: AssetStore) { self.assets=assets }
    func importData(_ data: Data) async throws -> Imported {
        try Task.checkCancellation()
        guard !data.isEmpty,data.count<=25_000_000,
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=40_000_000/height else { throw NotebookError.invalidAsset }
        func normalized(maxSize: Int) throws -> CGImage {
            guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxSize,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw NotebookError.invalidAsset }
            return image
        }
        func sanitized(_ image: CGImage) throws -> Data {
            let bytes=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else { throw NotebookError.invalidAsset }
            // Only pixels are copied; source EXIF/GPS/IPTC dictionaries never enter the destination.
            CGImageDestinationAddImageAndMetadata(destination,image,CGImageMetadataCreateMutable(),nil)
            guard CGImageDestinationFinalize(destination),bytes.length<=100_000_000 else { throw NotebookError.invalidAsset }
            // ImageIO adds an eXIf chunk even for empty metadata; omit that complete chunk.
            let encoded=bytes as Data
            var clean=Data(encoded.prefix(8)),offset=8
            while offset<encoded.count {
                guard offset<=encoded.count-12 else { throw NotebookError.invalidAsset }
                let length=encoded[offset..<offset+4].reduce(0) { ($0<<8)|Int($1) }
                guard length<=encoded.count-offset-12 else { throw NotebookError.invalidAsset }
                let end=offset+12+length
                if encoded[offset+4..<offset+8] != Data("eXIf".utf8) { clean.append(encoded[offset..<end]) }
                offset=end
            }
            return clean
        }
        let full=try normalized(maxSize:max(width,height)),preview=try normalized(maxSize:min(4096,max(width,height)))
        let originalBytes=try sanitized(full),previewBytes=try sanitized(preview)
        try Task.checkCancellation()
        let original=try await assets.stage(data:originalBytes),working=try await assets.stage(data:previewBytes)
        let originalHash=try await assets.finalize(original),previewHash=try await assets.finalize(working)
        try Task.checkCancellation()
        return Imported(assetHash:originalHash,previewAssetHash:previewHash,width:full.width,height:full.height)
    }
}
