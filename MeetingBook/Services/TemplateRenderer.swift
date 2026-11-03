import Foundation
import CoreGraphics
import CoreText
import MeetingBookCore
#if canImport(UIKit)
import UIKit
#endif

/// The same resolved vector plan is used by editor, picker previews and PDF export.
/// Caller supplies the single page-to-view transform; this renderer never changes stored coordinates.
@MainActor enum TemplateRenderer {
    enum RenderError: Error { case labelOverflow(String) }
    static func draw(_ instance: TemplateInstance, in context: CGContext) throws {
        try TemplateValidation.validate(instance)
        context.saveGState();defer {context.restoreGState()}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:720,height:1000))
        if instance.version == 1 || (instance.definitionID=="meetingbook.lined" && instance.primitives.isEmpty) {
            context.setStrokeColor(CGColor(gray:0.8,alpha:1));context.setLineWidth(0.7)
            for region in instance.writingRegions { for baseline in region.baselines {
                context.move(to:CGPoint(x:region.frame.x,y:baseline));context.addLine(to:CGPoint(x:region.frame.x+region.frame.width,y:baseline));context.strokePath()
            } }
        }
        for primitive in instance.primitives {
            let f=primitive.frame,rect=CGRect(x:f.x,y:f.y,width:f.width,height:f.height)
            context.setLineWidth(primitive.lineWidth)
            context.setStrokeColor(CGColor(gray:primitive.tone,alpha:1));context.setFillColor(CGColor(gray:primitive.tone,alpha:1))
            switch primitive.kind {
            case .line,.polyline:
                guard let first=primitive.points.first else {continue}
                context.beginPath();context.move(to:CGPoint(x:first.x,y:first.y))
                for point in primitive.points.dropFirst() {context.addLine(to:CGPoint(x:point.x,y:point.y))};context.strokePath()
            case .rectangle: if primitive.filled {context.fill(rect)} else {context.stroke(rect)}
            case .ellipse: if primitive.filled {context.fillEllipse(in:rect)} else {context.strokeEllipse(in:rect)}
            case .text: try drawLabel(primitive.text,in:rect,size:primitive.fontSize,tone:primitive.tone,context:context)
            }
        }
    }
    private static func drawLabel(_ value:String,in rect:CGRect,size:Double,tone:Double,context:CGContext) throws {
        var fontSize=size
        var setter:CTFramesetter!
        var measured=CGSize.zero
        repeat {
            let font=CTFontCreateWithName("Helvetica" as CFString,fontSize,nil)
            let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:tone,alpha:1)]
            setter=CTFramesetterCreateWithAttributedString(NSAttributedString(string:value,attributes:attributes))
            measured=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(),nil,CGSize(width:rect.width,height:10000),nil)
            if measured.height<=rect.height+0.1 {break}
            fontSize -= 0.5
        } while fontSize>=10
        guard measured.height<=rect.height+0.1 else {throw RenderError.labelOverflow(value)}
        context.saveGState();defer {context.restoreGState()}
        context.translateBy(x:rect.minX,y:rect.maxY);context.scaleBy(x:1,y:-1);context.textMatrix = .identity
        let path=CGPath(rect:CGRect(origin:.zero,size:rect.size),transform:nil)
        let frame=CTFramesetterCreateFrame(setter,CFRange(),path,nil)
        guard CTFrameGetVisibleStringRange(frame).length == (value as NSString).length else {throw RenderError.labelOverflow(value)}
        CTFrameDraw(frame,context)
    }
    #if canImport(UIKit)
    static func measuredConfiguration(_ configuration: TemplateConfiguration, font: UIFont) throws -> TemplateConfiguration {
        let bounds=HandwritingFontCatalog.mandatoryGlyphBounds(for:font)
        guard bounds.minY.isFinite,bounds.maxY.isFinite else {throw NotebookError.invalidModel}
        var result=configuration;result.textSize=Double(font.pointSize)
        // Reserve native primary and system fallback line metrics for newly generated regions.
        let fallback=UIFont.systemFont(ofSize:font.pointSize)
        result.inkAscent=max(1,Double(bounds.maxY),Double(font.ascender),Double(fallback.ascender))
        result.inkDescent=max(0,Double(-bounds.minY),Double(-font.descender),Double(-fallback.descender))
        var characters=Array("0123456789:".utf16),glyphs=Array(repeating:CGGlyph(0),count:11),advances=Array(repeating:CGSize.zero,count:11)
        guard CTFontGetGlyphsForCharacters(font as CTFont,&characters,&glyphs,11) else {throw NotebookError.invalidModel}
        CTFontGetAdvancesForGlyphs(font as CTFont,.horizontal,&glyphs,&advances,11)
        result.timeFieldWidth=ceil(Double(advances.prefix(10).map(\.width).max()!*4+advances[10].width))+18

        try TemplateValidation.validate(result);return result
    }
    static func preview(_ instance:TemplateInstance,scale:CGFloat=1) throws -> UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=scale;format.opaque=true
        var failure:(any Error)?
        let image=UIGraphicsImageRenderer(size:CGSize(width:720,height:1000),format:format).image { renderer in
            do {try draw(instance,in:renderer.cgContext)} catch {failure=error}
        }
        if let failure {throw failure};return image
    }
    #endif
}
