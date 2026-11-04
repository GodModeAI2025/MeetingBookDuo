import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum BookCoverColor: String, Codable, Sendable, CaseIterable {
    case graphite,forest,bordeaux,linen

    var name: LocalizedStringResource {
        switch self {
        case .graphite: "Graphite"
        case .forest: "Forest green"
        case .bordeaux: "Bordeaux"
        case .linen: "Linen"
        }
    }
}

struct BookCoverConfiguration: Codable, Sendable, Equatable {
    var title=""
    var coverColor: BookCoverColor = .graphite
    var bandColor: BookCoverColor = .graphite
    var imageData: Data?
    var cropX: Double=0
    var cropY: Double=0

    var displayTitle: String {title.isEmpty ? String(localized:"MeetingBook") : title}
}

extension EnvironmentValues {
    @Entry var bookCover: BookCoverStore? = nil
}

@MainActor @Observable final class BookCoverStore {
    struct Snapshot: Sendable, Equatable {
        let configuration: BookCoverConfiguration
        let revision: UUID?
    }
    private(set) var snapshot=Snapshot(configuration:BookCoverConfiguration(),revision:nil)
    private(set) var loadError: String?
    @ObservationIgnored private let writer: BookCoverWriter
    @ObservationIgnored private var generation = -1

    init(directory: URL?=nil) {
        var root=URL.applicationSupportDirectory.appendingPathComponent("BookCover",isDirectory:true)
        #if DEBUG
        if let value=ProcessInfo.processInfo.environment["MEETINGBOOK_TEST_LIBRARY"],let id=UUID(uuidString:value) {
            root=URL.applicationSupportDirectory.appendingPathComponent("UITestBookCovers/"+id.uuidString,isDirectory:true)
        }
        #endif
        writer=BookCoverWriter(directory:directory ?? root)
    }
    func load() async {publish(await writer.load(retry:true))}
    func save(_ configuration: BookCoverConfiguration,expectedRevision: UUID?) async throws {
        let state=await writer.load(retry:false)
        publish(state)
        guard state.loadError == nil else {throw BookCoverError.unreadable}
        publish(try await writer.save(configuration,expectedRevision:expectedRevision))
    }
    private func publish(_ state: BookCoverState) {
        guard state.generation>generation else {return}
        generation=state.generation;snapshot=state.snapshot;loadError=state.loadError
    }
    nonisolated static func prepareImage(_ data: Data) throws -> Data {
        try BookCoverImage.prepare(data)
    }
}

enum BookCoverError: LocalizedError, Sendable {
    case unreadable,unsupportedVersion,invalidFile,invalidConfiguration,invalidImage,conflict
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized:"The book cover could not be read. Retry loading before making changes.")
        case .unsupportedVersion: String(localized:"This book cover file uses an unsupported version.")
        case .invalidFile: String(localized:"The book cover file is invalid or too large.")
        case .invalidConfiguration: String(localized:"Use a title of up to 120 characters and a valid image crop.")
        case .invalidImage: String(localized:"Choose a still image up to 25 MB and 40 megapixels.")
        case .conflict: String(localized:"The book cover changed in another window. Your draft has been kept.")
        }
    }
}

private struct BookCoverState: Sendable {
    var generation=0
    var snapshot=BookCoverStore.Snapshot(configuration:BookCoverConfiguration(),revision:nil)
    var loadError: String?
}

/// Transactions do not suspend: revision, durable bytes and published appearance advance together.
private actor BookCoverWriter {
    private struct Header: Decodable {let version: Int}
    private struct Document: Codable {
        var version=1
        let revision: UUID
        let configuration: BookCoverConfiguration
    }
    private static let fileLimit=8*1024*1024
    private let directory: URL
    private var file: URL {directory.appendingPathComponent("cover.json")}
    private var state=BookCoverState()
    private var attemptedLoad=false
    private var loaded=false
    init(directory: URL) {self.directory=directory}

    func load(retry: Bool) -> BookCoverState {
        guard !loaded,(!attemptedLoad || retry) else {return state}
        attemptedLoad=true
        do {
            var snapshot=BookCoverStore.Snapshot(configuration:BookCoverConfiguration(),revision:nil)
            do {
                let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size=attributes[.size] as? NSNumber,size.intValue<=Self.fileLimit else {throw BookCoverError.invalidFile}
                let bytes=try Data(contentsOf:file)
                guard bytes.count<=Self.fileLimit else {throw BookCoverError.invalidFile}
                let decoder=JSONDecoder()
                guard try decoder.decode(Header.self,from:bytes).version==1 else {throw BookCoverError.unsupportedVersion}
                let document=try decoder.decode(Document.self,from:bytes)
                try validate(document.configuration)
                snapshot = .init(configuration:document.configuration,revision:document.revision)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {}
            state=BookCoverState(generation:state.generation+1,snapshot:snapshot)
            loaded=true
        } catch {
            state.generation += 1
            state.loadError=error.localizedDescription
        }
        return state
    }
    func save(_ configuration: BookCoverConfiguration,expectedRevision: UUID?) throws -> BookCoverState {
        guard loaded,state.loadError == nil else {throw BookCoverError.unreadable}
        guard state.snapshot.revision == expectedRevision else {throw BookCoverError.conflict}
        try validate(configuration)
        let revision=UUID(),document=Document(revision:revision,configuration:configuration)
        let bytes=try JSONEncoder().encode(document)
        guard bytes.count<=Self.fileLimit else {throw BookCoverError.invalidFile}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        try bytes.write(to:file,options:[.atomic,.completeFileProtection])
        state.generation += 1
        state.snapshot = .init(configuration:configuration,revision:revision)
        return state
    }
    private func validate(_ configuration: BookCoverConfiguration) throws {
        guard configuration.title.count<=120,configuration.title.utf8.count<=512,
              !configuration.title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              [configuration.cropX,configuration.cropY].allSatisfy({$0.isFinite && (-1...1).contains($0)}) else {throw BookCoverError.invalidConfiguration}
        if let data=configuration.imageData {try BookCoverImage.validate(data)}
    }
}

private enum BookCoverImage {
    static let outputLimit=4*1024*1024
    static func source(_ data: Data,byteLimit: Int,pixelLimit: Int) throws -> CGImageSource {
        guard !data.isEmpty,data.count<=byteLimit,
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetCount(source)==1,CGImageSourceGetStatus(source) == .statusComplete,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=pixelLimit/height else {throw BookCoverError.invalidImage}
        return source
    }
    static func prepare(_ data: Data) throws -> Data {
        let source=try source(data,byteLimit:25_000_000,pixelLimit:40_000_000)
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,
              let space=CGColorSpace(name:CGColorSpace.sRGB),
              let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {throw BookCoverError.invalidImage}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let normalized=context.makeImage() else {throw BookCoverError.invalidImage}
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil) else {throw BookCoverError.invalidImage}
        CGImageDestinationAddImage(destination,normalized,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination),bytes.length<=outputLimit else {throw BookCoverError.invalidImage}
        return try withoutMetadata(bytes as Data)
    }
    static func validate(_ data: Data) throws {
        guard data.count<=outputLimit,try withoutMetadata(data)==data else {throw BookCoverError.invalidImage}
        let source=try source(data,byteLimit:outputLimit,pixelLimit:2048*2048)
        guard CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              max(width,height)<=2048,
              CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else {throw BookCoverError.invalidImage}
    }
    /// Keep one baseline JPEG scan; remove every application/comment segment, including ICC/EXIF/XMP.
    private static func withoutMetadata(_ data: Data) throws -> Data {
        let bytes=[UInt8](data)
        guard bytes.count>=4,bytes[0]==0xFF,bytes[1]==0xD8 else {throw BookCoverError.invalidImage}
        var clean=Data(bytes.prefix(2)),offset=2
        while offset<bytes.count-3 {
            guard bytes[offset]==0xFF else {throw BookCoverError.invalidImage}
            let marker=bytes[offset+1],length=Int(bytes[offset+2])*256+Int(bytes[offset+3])
            guard length>=2,length<=bytes.count-offset-2 else {throw BookCoverError.invalidImage}
            let end=offset+2+length
            if !(0xE0...0xEF).contains(marker),marker != 0xFE {clean.append(contentsOf:bytes[offset..<end])}
            offset=end
            if marker==0xDA {
                let start=offset
                while offset<bytes.count-1 {
                    if bytes[offset]==0xFF {
                        let next=bytes[offset+1]
                        if next==0xD9,offset==bytes.count-2 {clean.append(contentsOf:bytes[start...]);return clean}
                        guard next==0 || (0xD0...0xD7).contains(next) else {throw BookCoverError.invalidImage}
                        offset += 1
                    }
                    offset += 1
                }
                throw BookCoverError.invalidImage
            }
        }
        throw BookCoverError.invalidImage
    }
}
