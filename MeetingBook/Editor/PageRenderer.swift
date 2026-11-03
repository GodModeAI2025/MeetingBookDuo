import UIKit
import PencilKit
import MeetingBookCore

struct PageRenderTimings: Codable, Sendable {
    var paperMilliseconds=0.0
    var textMilliseconds=0.0
    var imageDecodeAndDrawMilliseconds=0.0
    var pencilRasterAndDrawMilliseconds=0.0
}

@MainActor enum PageRenderer {
    struct Resources { var images: [String:UIImage]=[:];var drawing=PKDrawing();var versions: [FontVersion]=[];var fontWarnings: [String]=[];var preparationMilliseconds:[Double]=[] }
    static func resources(for content: PageContent, store: NotebookStore, originalImages: Bool = false, versions: [FontVersion]? = nil) async throws -> Resources {
        var result=Resources()
        if let versions { result.versions=versions } else { result.versions=try await store.fontVersions() }
        let service=PersonalFontService(assets:store.assets)
        for version in result.versions where content.textBlocks.contains(where: { $0.fontVersionID == version.id }) {
            do { try await service.register(version:version) } catch { result.fontWarnings.append(version.id.uuidString+": "+error.localizedDescription) }
        }
        for item in content.images {
            let hash=originalImages ? item.assetHash : (item.previewAssetHash ?? item.assetHash)
            let data=try await store.assets.read(hash:hash)
            let start=ProcessInfo.processInfo.systemUptime
            guard let image=UIImage(data:data) else { throw NotebookError.invalidAsset };result.images[item.assetHash]=image
            result.preparationMilliseconds.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        if let hash=content.drawingAssetHash { let bytes=try await store.assets.read(hash:hash),start=ProcessInfo.processInfo.systemUptime;result.drawing=try PKDrawing(data:bytes);result.preparationMilliseconds.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
        return result
    }
    static func drawPaper(_ content: PageContent,in context: CGContext) throws {
        if let ruling=content.style.ruling,content.template.supportsPaperRuling {
            context.setFillColor(UIColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:720,height:1000))
            context.setStrokeColor(UIColor(red:200/255,green:200/255,blue:194/255,alpha:1).cgColor);context.setFillColor(UIColor.lightGray.cgColor);context.setLineWidth(0.7)
            for region in content.template.writingRegions {
                let step=region.baselineStep ?? content.template.geometry.ruling
                for baseline in region.baselines {
                    if ruling == "dots" {
                        for x in stride(from:region.frame.x,through:region.frame.x+region.frame.width,by:step) { context.fillEllipse(in:CGRect(x:x-0.8,y:baseline-0.8,width:1.6,height:1.6)) }
                    } else { context.move(to:CGPoint(x:region.frame.x,y:baseline));context.addLine(to:CGPoint(x:region.frame.x+region.frame.width,y:baseline));context.strokePath() }
                }
                if ruling == "grid",let first=region.baselines.first,let last=region.baselines.last {
                    for x in stride(from:region.frame.x,through:region.frame.x+region.frame.width,by:step) { context.move(to:CGPoint(x:x,y:first));context.addLine(to:CGPoint(x:x,y:last));context.strokePath() }
                }
            }
        } else { try TemplateRenderer.draw(content.template,in:context) }
        context.saveGState();context.setBlendMode(.multiply);context.setFillColor(paperColor(content.style.paper).cgColor);context.fill(CGRect(x:0,y:0,width:720,height:1000));context.restoreGState()
    }
    static func paperColor(_ name: String) -> UIColor {
        switch name {
        case "classic":UIColor(red:247/255,green:246/255,blue:242/255,alpha:1)
        case "cream":UIColor(red:242/255,green:223/255,blue:193/255,alpha:1)
        case "rose":UIColor(red:232/255,green:192/255,blue:195/255,alpha:1)
        case "ivory":UIColor(red:1,green:0.985,blue:0.94,alpha:1)
        default:.white
        }
    }
    static func draw(_ content: PageContent, resources: Resources, in context: CGContext,measure: ((PageRenderTimings) -> Void)? = nil) throws {
        var timings=PageRenderTimings();let paperStart=ProcessInfo.processInfo.systemUptime
        try content.validate();try drawPaper(content,in:context)
        timings.paperMilliseconds=(ProcessInfo.processInfo.systemUptime-paperStart)*1000
        UIGraphicsPushContext(context);defer { UIGraphicsPopContext() }
        enum Layer { case text(TextBlock),image(ImageElement) }
        let layers=content.textBlocks.map { ($0.zIndex,Layer.text($0)) }+content.images.map { ($0.zIndex,Layer.image($0)) }
        for (_,layer) in layers.sorted(by: { $0.0<$1.0 }) {
            let start=ProcessInfo.processInfo.systemUptime
            switch layer {
            case .text(let block):
                let view=TextBlockView(block:block,content:content,versions:resources.versions)
                view.layoutManager.ensureLayout(for:view.textContainer)
                try view.validateVisibleContent()
                let range=view.layoutManager.glyphRange(for:view.textContainer),point=CGPoint(x:block.frame.x,y:block.frame.y)
                view.layoutManager.drawBackground(forGlyphRange:range,at:point);view.layoutManager.drawGlyphs(forGlyphRange:range,at:point)
                timings.textMilliseconds+=(ProcessInfo.processInfo.systemUptime-start)*1000
            case .image(let image):
                guard let pixels=resources.images[image.assetHash] else { throw NotebookError.invalidAsset }
                pixels.draw(in:CGRect(x:image.frame.x,y:image.frame.y,width:image.frame.width,height:image.frame.height))
                timings.imageDecodeAndDrawMilliseconds+=(ProcessInfo.processInfo.systemUptime-start)*1000
            }
        }
        let inkStart=ProcessInfo.processInfo.systemUptime
        if !resources.drawing.strokes.isEmpty {
            let bounds=resources.drawing.bounds.insetBy(dx:-4,dy:-4).integral.intersection(CGRect(x:0,y:0,width:720,height:1000))
            if !bounds.isNull,!bounds.isEmpty { resources.drawing.image(from:bounds,scale:2).draw(in:bounds) }
        }
        timings.pencilRasterAndDrawMilliseconds=(ProcessInfo.processInfo.systemUptime-inkStart)*1000;measure?(timings)
    }
    static func image(_ content: PageContent, resources: Resources, scale: CGFloat = 1,measure: ((PageRenderTimings) -> Void)? = nil) throws -> UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=scale;format.opaque=true
        var failure: Error?
        let image=UIGraphicsImageRenderer(size:CGSize(width:720,height:1000),format:format).image { renderer in
            do { try draw(content,resources:resources,in:renderer.cgContext,measure:measure) } catch { failure=error }
        }
        if let failure { throw failure };return image
    }
}
