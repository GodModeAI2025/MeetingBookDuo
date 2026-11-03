import Foundation
import UIKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import MeetingBookCore

struct ExportRequest: Sendable {
    enum Format: Sendable { case pdf,png,txt }
    let format: Format
    let pages: [PageSnapshot]
    let fonts: [FontVersion]
    let unsaved: Bool
    var lease: StorageLease? = nil
}
struct ExportPageTiming: Codable, Sendable {
    let resourceCreationMainMilliseconds: [Double]
    let fontPermissionMainMilliseconds: Double
    let native: PageRenderTimings
    var pngEncodingWorkerMilliseconds=0.0
}
struct ExportArtifact: Sendable, Identifiable {
    let id: UUID
    let urls: [URL]
    let warnings: [String]
    let pageDrawMilliseconds: [Double]
    let pageTimings:[ExportPageTiming]
}
actor ExportService {
    let store: NotebookStore
    let root: URL
    private var owned:[UUID:URL]=[:]
    init(store: NotebookStore,root: URL) { self.store=store;self.root=root }
    func export(_ request: ExportRequest,progress: @Sendable (Int,Int) async -> Void = { _,_ in }) async throws -> ExportArtifact {
        guard !request.pages.isEmpty,request.pages.count<=10_000,Set(request.pages.map(\.id)).count==request.pages.count else { throw NotebookError.invalidModel }
        let hashes=request.pages.reduce(into:Set<String>()) { $0.formUnion($1.content.assetHashes) }.union(request.fonts.map(\.assetHash))
        let pin=try await store.assets.acquirePin(hashes)
        let directory:URL
        do { directory=try PackageIO.directory(in:root) } catch { await store.assets.releasePin(pin);throw error }
        let prefix=request.unsaved ? "UNSAVED-MeetingBook" : "MeetingBook"
        do {
            var urls:[URL]=[],warnings:[String]=[],timings:[Double]=[]
            var outputBytes=0,phaseTimings:[ExportPageTiming]=[]
            let pdfURL=directory.appendingPathComponent(prefix+".pdf")
            let sink=request.format == .pdf ? try PDFSink(url:pdfURL) : nil
            var media=CGRect(x:0,y:0,width:720,height:1000)
            let context=try sink.map { sink -> CGContext in
                guard let consumer=CGDataConsumer(info:Unmanaged.passUnretained(sink).toOpaque(),cbks:&PDFSink.callbacks),let context=CGContext(consumer:consumer,mediaBox:&media,nil) else { throw NotebookError.invalidAsset };return context
            }
            let textURL=directory.appendingPathComponent(prefix+".txt"),text=request.format == .txt ? try PackageIO.create(textURL) : nil
            do {
                if let text {
                    let notice=(request.unsaved ? "UNSAVED / UNGESPEICHERT\n" : "")+String(localized:"Drawings, images, fonts and page layout are omitted. Unicode text follows in page order.")+"\n\n"
                    try text.write(contentsOf:Data(notice.utf8))
                }
                for (number,page) in request.pages.enumerated() {
                    try Task.checkCancellation();try page.content.validate()
                    if request.format == .pdf,page.content.textBlocks.contains(where: { block in block.text.unicodeScalars.contains { !FontCoverage.required.contains($0.value) && ![9,10,13].contains($0.value) } }) {
                        warnings.append(page.id.uuidString+": "+String(localized:"PDF copy and search may differ for emoji, combining marks and fallback scripts. Export TXT for the exact original Unicode text."))
                    }
                    if let text {
                        let blocks=page.content.textBlocks.sorted { a,b in a.frame.y==b.frame.y ? a.frame.x<b.frame.x : a.frame.y<b.frame.y }
                        let bytes=Data((blocks.map(\.text).joined(separator:"\n")+"\n\n").utf8)
                        guard bytes.count<=2_000_000_000-outputBytes else { throw NotebookError.invalidAsset };outputBytes+=bytes.count
                        try text.write(contentsOf:bytes)
                    } else {
                        try await checkResourceBudget(page.content)
                        let rendered=try await Self.render(page.content,store:store,fonts:request.fonts,png:request.format == .png)
                        try Task.checkCancellation();timings.append(rendered.milliseconds);phaseTimings.append(rendered.timing)
                        warnings+=rendered.warnings.map{page.id.uuidString+": "+$0}
                        if let context {
                            guard let provider=CGDataProvider(data:rendered.data as CFData),let document=CGPDFDocument(provider),let pdfPage=document.page(at:1) else { throw NotebookError.invalidAsset }
                            context.beginPDFPage(nil);context.drawPDFPage(pdfPage);context.endPDFPage()
                            if let error=sink?.failure { throw error }
                        } else {
                            let url=directory.appendingPathComponent(prefix+"-\(number+1).png")
                            let encodeStart=ProcessInfo.processInfo.systemUptime
                            let bytes=try Self.sanitizedPNG(Self.encodePNG(rendered))
                            phaseTimings[phaseTimings.count-1].pngEncodingWorkerMilliseconds=(ProcessInfo.processInfo.systemUptime-encodeStart)*1000
                            guard bytes.count<=2_000_000_000-outputBytes else { throw NotebookError.invalidAsset };outputBytes+=bytes.count
                            try PackageIO.write(bytes,to:url);urls.append(url)
                        }
                    }
                    try Task.checkCancellation();await progress(number+1,request.pages.count)
                }
                context?.closePDF();try sink?.finish();try text?.synchronize();try text?.close()
            } catch { context?.closePDF();try? sink?.finish();try? text?.close();throw error }
            if request.format == .pdf {
                guard let document=CGPDFDocument(pdfURL as CFURL),document.numberOfPages==request.pages.count else { throw NotebookError.invalidAsset };urls=[pdfURL]
            }
            if request.format == .txt { urls=[textURL] }
            for url in urls { try AssetStore.synchronize(url,false);_ = try PackageIO.digest(url) }
            try AssetStore.synchronize(directory,true);try Task.checkCancellation()
            let id=UUID();owned[id]=directory
            await store.assets.releasePin(pin)
            return ExportArtifact(id:id,urls:urls,warnings:warnings,pageDrawMilliseconds:timings,pageTimings:phaseTimings)
        } catch { await store.assets.releasePin(pin);try? FileManager.default.removeItem(at:directory);throw error }
    }
    func remove(_ artifact: ExportArtifact) throws {
        if let directory=owned.removeValue(forKey:artifact.id) { try FileManager.default.removeItem(at:directory) }
    }
    private func checkResourceBudget(_ content: PageContent) async throws {
        var pixels=0
        for hash in Set(content.images.map(\.assetHash)) {
            try Task.checkCancellation();let data=try await store.assets.read(hash:hash)
            guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=p[kCGImagePropertyPixelWidth] as? Int,let height=p[kCGImagePropertyPixelHeight] as? Int,
                  width>0,height>0,width<=40_000_000/height else { throw NotebookError.invalidAsset }
            pixels+=width*height;guard pixels<=40_000_000 else { throw TransferError.pageTooLarge }
        }
    }
    private struct Pixels: Sendable { let width: Int;let height: Int;let bitsPerComponent: Int;let bitsPerPixel: Int;let bytesPerRow: Int;let bitmapInfo: UInt32;let colorSpace: String }
    private struct Rendered: Sendable { let data: Data;let pixels: Pixels?;let warnings: [String];let milliseconds: Double;let timing: ExportPageTiming }
    private static func encodePNG(_ rendered: Rendered) throws -> Data {
        guard let p=rendered.pixels,let provider=CGDataProvider(data:rendered.data as CFData),let space=CGColorSpace(name:p.colorSpace as CFString),
              let image=CGImage(width:p.width,height:p.height,bitsPerComponent:p.bitsPerComponent,bitsPerPixel:p.bitsPerPixel,bytesPerRow:p.bytesPerRow,space:space,bitmapInfo:CGBitmapInfo(rawValue:p.bitmapInfo),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw NotebookError.invalidAsset }
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else { throw NotebookError.invalidAsset }
        CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else { throw NotebookError.invalidAsset }
        return output as Data
    }
    @MainActor private static func render(_ content: PageContent,store: NotebookStore,fonts: [FontVersion],png: Bool) async throws -> Rendered {
        let resources=try await PageRenderer.resources(for:content,store:store,originalImages:true,versions:fonts)
        try Task.checkCancellation()
        let permissionStart=ProcessInfo.processInfo.systemUptime
        if !png { try checkEmbedding(content,versions:resources.versions) }
        let permissionMS=(ProcessInfo.processInfo.systemUptime-permissionStart)*1000
        await Task.yield();try Task.checkCancellation()
        return try autoreleasepool {
            let start=ContinuousClock.now
            var native=PageRenderTimings()
            let data:Data
            var pixels:Pixels?
            if png {
                guard let image=try PageRenderer.image(content,resources:resources,scale:2,measure:{native=$0}).cgImage,let bytes=image.dataProvider?.data,let space=image.colorSpace?.name else { throw NotebookError.invalidAsset }
                data=bytes as Data;pixels=Pixels(width:image.width,height:image.height,bitsPerComponent:image.bitsPerComponent,bitsPerPixel:image.bitsPerPixel,bytesPerRow:image.bytesPerRow,bitmapInfo:image.bitmapInfo.rawValue,colorSpace:space as String)
            }
            else {
                var failure:Error?
                data=UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:720,height:1000)).pdfData { renderer in
                    renderer.beginPage()
                    do { try PageRenderer.draw(content,resources:resources,in:renderer.cgContext,measure:{native=$0}) } catch { failure=error }
                }
                if let failure { throw failure }
            }
            guard data.count<=200_000_000 else { throw NotebookError.invalidAsset }
            let duration=start.duration(to:.now),milliseconds=Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15
            return Rendered(data:data,pixels:pixels,warnings:resources.fontWarnings,milliseconds:milliseconds,timing:ExportPageTiming(resourceCreationMainMilliseconds:resources.preparationMilliseconds,fontPermissionMainMilliseconds:permissionMS,native:native))
        }
    }
    @MainActor private static func checkEmbedding(_ content: PageContent,versions: [FontVersion]) throws {
        var samples=content.textBlocks.map { block in
            NSAttributedString(string:block.text,attributes:[.font:HandwritingFontCatalog.font(catalogID:block.fontCatalogID,personalVersion:versions.first{$0.id==block.fontVersionID},size:block.fontSize ?? content.style.fontSize)])
        }
        samples+=content.template.primitives.filter{$0.kind == .text}.map { NSAttributedString(string:$0.text,attributes:[.font:UIFont(name:"Helvetica",size:$0.fontSize)!]) }
        for sample in samples {
            let line=CTLineCreateWithAttributedString(sample)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes=CTRunGetAttributes(run) as NSDictionary
                guard let font=attributes[kCTFontAttributeName] else { throw NotebookError.invalidAsset }
                let ct=font as! CTFont
                if let table=CTFontCopyTable(ct,CTFontTableTag(kCTFontTableOS2),[]) as Data? {
                    guard table.count>=10 else { throw NotebookError.invalidAsset }
                    let rights=UInt16(table[8])<<8|UInt16(table[9])
                    guard rights & 0x0302 == 0 else { throw NotebookError.invalidAsset }
                }
            }
        }
    }
    private static func sanitizedPNG(_ data: Data) throws -> Data {
        guard data.starts(with:[137,80,78,71,13,10,26,10]) else { throw NotebookError.invalidAsset }
        var clean=Data(data.prefix(8)),offset=8
        while offset<data.count {
            guard offset<=data.count-12 else { throw NotebookError.invalidAsset }
            let length=data[offset..<offset+4].reduce(0){($0<<8)|Int($1)}
            guard length<=data.count-offset-12 else { throw NotebookError.invalidAsset }
            let type=String(data:data[offset+4..<offset+8],encoding:.ascii),end=offset+12+length
            if !["eXIf","tEXt","zTXt","iTXt"].contains(type) { clean.append(data[offset..<end]) };offset=end
        }
        return clean
    }
}

/// Owned by the export actor. C callbacks synchronously write on that same executor.
private final class PDFSink {
    let file: FileHandle
    var failure: Error?
    var written=0
    init(url: URL) throws { file=try PackageIO.create(url) }
    func finish() throws { try file.synchronize();try file.close();if let failure { throw failure } }
    static var callbacks: CGDataConsumerCallbacks { get { CGDataConsumerCallbacks(putBytes:{ info,bytes,count in
        let sink=Unmanaged<PDFSink>.fromOpaque(info!).takeUnretainedValue()
        do { try Task.checkCancellation();guard count<=2_000_000_000-sink.written else { throw NotebookError.invalidAsset };try sink.file.write(contentsOf:Data(bytes:bytes,count:count));sink.written+=count;return count }
        catch { sink.failure=error;return 0 }
    },releaseConsumer:nil) } set {} }
}
