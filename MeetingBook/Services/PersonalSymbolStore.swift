import Foundation
import Observation
import PencilKit
import UIKit

@MainActor @Observable final class PersonalSymbolStore {
    struct Snapshot: Sendable {
        let drawing: PKDrawing
        let revision: UUID?
    }
    private(set) var enabled=true
    private(set) var loadError: String?
    private(set) var images: [AppSymbol:UIImage]=[:]
    private var selectedImages: [AppSymbol:UIImage]=[:]
    private var snapshots: [AppSymbol:Snapshot]=[:]
    @ObservationIgnored private let writer: PersonalSymbolWriter
    @ObservationIgnored private var generation = -1

    init(directory: URL?=nil) {
        var root=URL.applicationSupportDirectory.appendingPathComponent("PersonalSymbols",isDirectory:true)
        #if DEBUG
        if let value=ProcessInfo.processInfo.environment["MEETINGBOOK_TEST_LIBRARY"],let id=UUID(uuidString:value) {
            root=URL.applicationSupportDirectory.appendingPathComponent("UITestPersonalSymbols/"+id.uuidString,isDirectory:true)
        }
        #endif
        writer=PersonalSymbolWriter(directory:directory ?? root)
    }
    static func previewImage(for drawing: PKDrawing) async throws -> UIImage {
        try await Task.detached(priority:.userInitiated) {try PersonalSymbolWriter.mask(for:drawing)}.value
    }
    func load() async {publish(await writer.load(retry:true))}
    func snapshot(for symbol: AppSymbol) -> Snapshot {snapshots[symbol] ?? Snapshot(drawing:PKDrawing(),revision:nil)}
    func customImage(for symbol: AppSymbol,selected: Bool=false) -> UIImage? {
        guard enabled else {return nil}
        return selected ? selectedImages[symbol] ?? images[symbol] : images[symbol]
    }
    func save(_ drawing: PKDrawing,for symbol: AppSymbol,expectedRevision: UUID?) async throws {
        try await prepare()
        publish(try await writer.save(drawing,for:symbol,expectedRevision:expectedRevision))
    }
    func reset(_ symbol: AppSymbol,expectedRevision: UUID?) async throws {
        try await prepare()
        publish(try await writer.reset(symbol,expectedRevision:expectedRevision))
    }
    func setEnabled(_ enabled: Bool) async throws {
        try await prepare()
        publish(try await writer.setEnabled(enabled))
    }
    private func prepare() async throws {
        let state=await writer.load(retry:false)
        publish(state)
        guard state.loadError == nil else {throw PersonalSymbolError.unreadable}
    }
    private func publish(_ state: PersonalSymbolState) {
        guard state.generation>generation else {return}
        generation=state.generation;enabled=state.enabled;loadError=state.loadError
        snapshots=state.snapshots;images=state.images;selectedImages=state.selectedImages
    }
}

enum PersonalSymbolError: LocalizedError, Sendable {
    case unreadable,unsupportedVersion,invalidFile,invalidDrawing,tooComplex,conflict
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized:"App symbols could not be read. Retry loading before making changes.")
        case .unsupportedVersion: String(localized:"This app symbol file uses an unsupported version.")
        case .invalidFile: String(localized:"The app symbol file is invalid or too large.")
        case .invalidDrawing: String(localized:"Draw a visible symbol with valid pen strokes.")
        case .tooComplex: String(localized:"This symbol is too complex. Use fewer strokes or points.")
        case .conflict: String(localized:"This symbol changed in another window. Your drawing has been kept.")
        }
    }
}

private struct PersonalSymbolState: Sendable {
    var generation=0
    var enabled=true
    var loadError: String?
    var snapshots: [AppSymbol:PersonalSymbolStore.Snapshot]=[:]
    var images: [AppSymbol:UIImage]=[:]
    var selectedImages: [AppSymbol:UIImage]=[:]
}

/// Transactions do not suspend: revisions, durable bytes and cached masks advance together.
private actor PersonalSymbolWriter {
    private struct Entry: Codable {let revision: UUID;let drawing: Data?}
    private struct Document: Codable {
        var version=1
        var enabled=true
        var entries: [String:Entry]=[:]
    }
    private static let fileLimit=8*1024*1024
    private static let drawingLimit=256*1024
    private let directory: URL
    private var file: URL {directory.appendingPathComponent("symbols.json")}
    private var document=Document()
    private var state=PersonalSymbolState()
    private var attemptedLoad=false
    private var loaded=false
    init(directory: URL) {self.directory=directory}

    func load(retry: Bool) -> PersonalSymbolState {
        guard !loaded,(!attemptedLoad || retry) else {return state}
        attemptedLoad=true
        do {
            let candidate: Document
            do {
                let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size=attributes[.size] as? NSNumber,size.intValue<=Self.fileLimit else {throw PersonalSymbolError.invalidFile}
                let bytes=try Data(contentsOf:file)
                guard bytes.count<=Self.fileLimit else {throw PersonalSymbolError.invalidFile}
                candidate=try JSONDecoder().decode(Document.self,from:bytes)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                candidate=Document()
            }
            guard candidate.version==1 else {throw PersonalSymbolError.unsupportedVersion}
            guard candidate.entries.count<=AppSymbol.allCases.count else {throw PersonalSymbolError.invalidFile}
            var next=PersonalSymbolState()
            next.enabled=candidate.enabled
            for (key,entry) in candidate.entries {
                guard let symbol=AppSymbol(rawValue:key) else {throw PersonalSymbolError.invalidFile}
                let drawing: PKDrawing
                if let bytes=entry.drawing {
                    guard bytes.count<=Self.drawingLimit else {throw PersonalSymbolError.tooComplex}
                    drawing=try PKDrawing(data:bytes)
                    let image=try Self.mask(for:drawing)
                    next.images[symbol]=image
                    if symbol == .bookmark || symbol == .favorite {next.selectedImages[symbol]=Self.selected(image)}
                } else {drawing=PKDrawing()}
                next.snapshots[symbol] = .init(drawing:drawing,revision:entry.revision)
            }
            next.generation=state.generation+1
            document=candidate;state=next;loaded=true
        } catch {
            state.generation += 1
            state.loadError=error.localizedDescription
        }
        return state
    }
    func save(_ drawing: PKDrawing,for symbol: AppSymbol,expectedRevision: UUID?) throws -> PersonalSymbolState {
        try check(symbol,expectedRevision:expectedRevision)
        let image=try Self.mask(for:drawing),bytes=drawing.dataRepresentation(),revision=UUID()
        var next=document
        next.entries[symbol.rawValue]=Entry(revision:revision,drawing:bytes)
        try persist(next)
        document=next;state.generation += 1
        state.snapshots[symbol] = .init(drawing:drawing,revision:revision);state.images[symbol]=image
        if symbol == .bookmark || symbol == .favorite {state.selectedImages[symbol]=Self.selected(image)}
        return state
    }
    func reset(_ symbol: AppSymbol,expectedRevision: UUID?) throws -> PersonalSymbolState {
        try check(symbol,expectedRevision:expectedRevision)
        let revision=UUID()
        var next=document
        // A tombstone rejects drafts captured before this reset, including an original nil revision.
        next.entries[symbol.rawValue]=Entry(revision:revision,drawing:nil)
        try persist(next)
        document=next;state.generation += 1
        state.snapshots[symbol] = .init(drawing:PKDrawing(),revision:revision)
        state.images[symbol]=nil;state.selectedImages[symbol]=nil
        return state
    }
    func setEnabled(_ enabled: Bool) throws -> PersonalSymbolState {
        guard loaded,state.loadError == nil else {throw PersonalSymbolError.unreadable}
        guard enabled != document.enabled else {return state}
        var next=document;next.enabled=enabled
        try persist(next)
        document=next;state.enabled=enabled;state.generation += 1
        return state
    }
    private func check(_ symbol: AppSymbol,expectedRevision: UUID?) throws {
        guard loaded,state.loadError == nil else {throw PersonalSymbolError.unreadable}
        guard document.entries[symbol.rawValue]?.revision == expectedRevision else {throw PersonalSymbolError.conflict}
    }
    private func persist(_ next: Document) throws {
        let bytes=try JSONEncoder().encode(next)
        guard bytes.count<=Self.fileLimit else {throw PersonalSymbolError.invalidFile}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        try bytes.write(to:file,options:[.atomic,.completeFileProtection])
    }
    nonisolated static func mask(for drawing: PKDrawing) throws -> UIImage {
        guard !drawing.strokes.isEmpty else {throw PersonalSymbolError.invalidDrawing}
        guard drawing.strokes.count<=128 else {throw PersonalSymbolError.tooComplex}
        var points=0
        for stroke in drawing.strokes {
            points += stroke.path.count
            guard points<=16000 else {throw PersonalSymbolError.tooComplex}
            guard !stroke.path.isEmpty,stroke.path.allSatisfy({ point in
                [point.location.x,point.location.y,point.size.width,point.size.height,point.azimuth,point.altitude,point.timeOffset,point.opacity,point.force].allSatisfy { $0.isFinite && abs($0)<=10000 } && point.size.width>0 && point.size.height>0
            }) else {throw PersonalSymbolError.invalidDrawing}
            let t=stroke.transform
            guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy({ $0.isFinite && abs($0)<=10000 }),abs(t.a*t.d-t.b*t.c)>0.0001 else {throw PersonalSymbolError.invalidDrawing}
            if let mask=stroke.mask {
                var valid=true,count=0
                mask.cgPath.applyWithBlock { pointer in
                    let element=pointer.pointee
                    let n: Int
                    switch element.type {
                    case .moveToPoint,.addLineToPoint: n=1
                    case .addQuadCurveToPoint: n=2
                    case .addCurveToPoint: n=3
                    case .closeSubpath: n=0
                    @unknown default: valid=false;n=0
                    }
                    count += n
                    for i in 0..<n {
                        let p=element.points[i]
                        if !p.x.isFinite || !p.y.isFinite || abs(p.x)>10000 || abs(p.y)>10000 {valid=false}
                    }
                }
                guard valid,count<=16000 else {throw PersonalSymbolError.invalidDrawing}
            }
        }
        guard drawing.dataRepresentation().count<=drawingLimit else {throw PersonalSymbolError.tooComplex}
        let bounds=drawing.bounds
        guard !bounds.isNull,!bounds.isEmpty,[bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy({ $0.isFinite && abs($0)<=10000 }) else {throw PersonalSymbolError.invalidDrawing}
        let scale=80/max(bounds.width,bounds.height)
        let transform=CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:48-bounds.midX*scale,ty:48-bounds.midY*scale)
        let rendered=drawing.transformed(using:transform).image(from:CGRect(x:0,y:0,width:96,height:96),scale:1)
        guard let cg=rendered.cgImage,cg.width<=96,cg.height<=96 else {throw PersonalSymbolError.invalidDrawing}
        var pixels=Array(repeating:UInt8(0),count:96*96*4)
        let visible=pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context=CGContext(data:buffer.baseAddress,width:96,height:96,bitsPerComponent:8,bytesPerRow:96*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
            context.draw(cg,in:CGRect(x:0,y:0,width:96,height:96))
            return stride(from:3,to:buffer.count,by:4).contains {buffer[$0]>16}
        }
        guard visible else {throw PersonalSymbolError.invalidDrawing}
        return UIImage(cgImage:cg,scale:4,orientation:.up).withRenderingMode(.alwaysTemplate)
    }
    private static func selected(_ image: UIImage) -> UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=4;format.opaque=false
        return UIGraphicsImageRenderer(size:CGSize(width:24,height:24),format:format).image { renderer in
            image.withRenderingMode(.alwaysOriginal).draw(in:CGRect(x:0,y:0,width:24,height:24))
            let context=renderer.cgContext
            context.setBlendMode(.clear);context.fillEllipse(in:CGRect(x:15,y:15,width:9,height:9))
            context.setBlendMode(.normal);context.setFillColor(UIColor.black.cgColor)
            context.fillEllipse(in:CGRect(x:16,y:16,width:7,height:7))
            context.setBlendMode(.clear);context.setLineWidth(1)
            context.move(to:CGPoint(x:17.5,y:19.5));context.addLine(to:CGPoint(x:19,y:21));context.addLine(to:CGPoint(x:21.5,y:18));context.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
