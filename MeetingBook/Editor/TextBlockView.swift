import UIKit
import CoreText
import MeetingBookCore

/// Explicit TextKit 1 stack: UIKit retains selection, marked text and native input handling.
@MainActor final class TextBlockView: UITextView {
    override var undoManager: UndoManager? { nil }
    var isInputLocked: () -> Bool = { false }
    private var inputLocked: Bool {isInputLocked()}
    override func insertText(_ text: String) { if !inputLocked {super.insertText(text)} }
    override func deleteBackward() { if !inputLocked {super.deleteBackward()} }
    override func setMarkedText(_ markedText: String?,selectedRange: NSRange) { if !inputLocked {super.setMarkedText(markedText,selectedRange:selectedRange)} }
    override func replace(_ range: UITextRange,withText text: String) { if !inputLocked {super.replace(range,withText:text)} }
    override func paste(_ sender: Any?) { if !inputLocked {super.paste(sender)} }
    override func cut(_ sender: Any?) { if !inputLocked {super.cut(sender)} }
    override func canPerformAction(_ action: Selector,withSender sender: Any?) -> Bool { !inputLocked && super.canPerformAction(action,withSender:sender) }
    let blockID: UUID
    let ruling: StoredRegionLayout
    init(block: TextBlock, content: PageContent, versions: [FontVersion]) {
        blockID=block.id
        ruling=StoredRegionLayout(block:block,template:content.template)
        let storage=NSTextStorage(),manager=NSLayoutManager()
        let container=NSTextContainer(size:CGSize(width:block.frame.width,height:10_000_000))
        container.lineFragmentPadding=0;container.widthTracksTextView=false;container.heightTracksTextView=false
        manager.addTextContainer(container);storage.addLayoutManager(manager);manager.delegate=ruling
        super.init(frame:CGRect(x:block.frame.x,y:block.frame.y,width:block.frame.width,height:block.frame.height),textContainer:container)
        backgroundColor = .clear;isScrollEnabled=false;textContainerInset = .zero
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
        let font=HandwritingFontCatalog.font(catalogID:block.fontCatalogID,personalVersion:versions.first { $0.id == block.fontVersionID },size:block.fontSize ?? content.style.fontSize)
        let attributes: [NSAttributedString.Key:Any]=[.font:font,.foregroundColor:Self.ink(block.ink ?? content.style.ink),.paragraphStyle:paragraph]
        attributedText=NSAttributedString(string:block.text,attributes:attributes);typingAttributes=attributes
        accessibilityLabel=String(localized:"Text block")
    }
    required init?(coder: NSCoder) { nil }
    override func caretRect(for position: UITextPosition) -> CGRect {
        var caret=super.caretRect(for:position)
        layoutManager.ensureLayout(for:textContainer)
        let offset=offset(from:beginningOfDocument,to:position),length=(text as NSString).length
        let baseline: Double
        if offset == length && (length == 0 || text.hasSuffix("\n") || text.hasSuffix("\r")) {
            let lines=canonicalBaselines().count
            baseline=ruling.baseline(at:lines)-frame.minY
        } else if layoutManager.numberOfGlyphs>0 {
            let glyph=layoutManager.glyphIndexForCharacter(at:min(offset,max(0,length-1)))
            baseline=layoutManager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY+layoutManager.location(forGlyphAt:glyph).y
        } else { return caret }
        let font=font ?? .systemFont(ofSize:30)
        caret.origin.y=baseline-font.ascender;caret.size.height=font.ascender-font.descender
        return caret
    }
    static func ink(_ name: String) -> UIColor {
        switch name {
        case "marine":UIColor(red:61/255,green:85/255,blue:122/255,alpha:1)
        case "plum":UIColor(red:117/255,green:59/255,blue:103/255,alpha:1)
        case "ochre":UIColor(red:174/255,green:112/255,blue:69/255,alpha:1)
        case "teal":UIColor(red:65/255,green:123/255,blue:122/255,alpha:1)
        case "graphite":UIColor(red:41/255,green:42/255,blue:43/255,alpha:1)
        case "blue":.systemBlue;case "red":.systemRed;case "green":.systemGreen;case "purple":.systemPurple;default:.black
        }
    }
    func canonicalBaselines() -> [Double] {
        layoutManager.ensureLayout(for:textContainer)
        var result: [Double]=[]
        layoutManager.enumerateLineFragments(forGlyphRange:layoutManager.glyphRange(for:textContainer)) { _,_,_,range,_ in
            guard range.length>0 else { return }
            let rect=self.layoutManager.lineFragmentRect(forGlyphAt:range.location,effectiveRange:nil)
            let location=self.layoutManager.location(forGlyphAt:range.location)
            result.append(Double(self.frame.minY+rect.minY+location.y))
        }
        return result
    }
    func validateInkEnvelope() throws {
        layoutManager.ensureLayout(for:textContainer)
        var previousDescent=0.0,previousBaseline=frame.minY,failure=false,lineIndex=0
        layoutManager.enumerateLineFragments(forGlyphRange:layoutManager.glyphRange(for:textContainer)) { rect,_,_,range,stop in
            guard lineIndex<self.ruling.availableLines else { stop.pointee=true;return };lineIndex += 1
            let characters=self.layoutManager.characterRange(forGlyphRange:range,actualGlyphRange:nil)
            let line=CTLineCreateWithAttributedString(self.textStorage.attributedSubstring(from:characters))
            let bounds=CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
            let baseline=Double(self.frame.minY+rect.minY+self.layoutManager.location(forGlyphAt:range.location).y)
            if bounds.height.isFinite && !bounds.isNull {
                if baseline-max(0,bounds.maxY)<previousBaseline+previousDescent-0.5 { failure=true }
                previousDescent=max(0,-bounds.minY)
            }
            previousBaseline=baseline
        }
        if failure { throw EditorLayoutError.inkDoesNotFit }
    }
    func validateVisibleContent() throws {
        try validateInkEnvelope()
        let visibleGlyphs=layoutManager.glyphRange(for:textContainer)
        let visibleCharacters=layoutManager.characterRange(forGlyphRange:visibleGlyphs,actualGlyphRange:nil)
        guard NSMaxRange(visibleCharacters)==textStorage.length,canonicalBaselines().count<=ruling.availableLines else { throw NotebookError.invalidModel }
    }
    static func paginate(block: TextBlock, content: PageContent, versions: [FontVersion]) throws -> [TextBlock] {
        var remaining=block.text,chunks: [TextBlock]=[]
        repeat {
            var candidate=block;candidate.text=remaining
            if !chunks.isEmpty,let region=content.template.writingRegions.first(where: { $0.id == block.writingRegionID }) {
                candidate.frame=region.frame;candidate.baselineIndex=0
            }
            let view=TextBlockView(block:candidate,content:content,versions:versions)
            let manager=view.layoutManager;manager.ensureLayout(for:view.textContainer)
            try view.validateInkEnvelope()
            var end=0,line=0
            manager.enumerateLineFragments(forGlyphRange:manager.glyphRange(for:view.textContainer)) { _,_,_,range,stop in
                if line >= view.ruling.availableLines { stop.pointee=true;return }
                end=NSMaxRange(manager.characterRange(forGlyphRange:range,actualGlyphRange:nil));line += 1
            }
            if remaining.isEmpty { chunks.append(candidate);break }
            let source=remaining as NSString
            end=min(end,source.length)
            if end<source.length, end>0 {
                let sequence=source.rangeOfComposedCharacterSequence(at:end)
                if sequence.location<end { end=sequence.location }
            }
            guard end>0 else { throw NotebookError.invalidModel }
            candidate.text=source.substring(to:end)
            if !chunks.isEmpty { candidate=Self.copy(candidate,id:UUID()) }
            chunks.append(candidate);remaining=source.substring(from:end)
            if remaining.isEmpty,line>=view.ruling.availableLines,(candidate.text.hasSuffix("\n") || candidate.text.hasSuffix("\r")) {
                var empty=Self.copy(candidate,id:UUID());empty.text=""
                if let region=content.template.writingRegions.first(where: { $0.id == block.writingRegionID }) { empty.frame=region.frame;empty.baselineIndex=0 }
                chunks.append(empty)
            }
            guard chunks.count<=5000 else { throw NotebookError.invalidModel }
        } while !remaining.isEmpty
        return chunks
    }
    static func copy(_ block: TextBlock, id: UUID) -> TextBlock {
        var copy=TextBlock(id:id,text:block.text,frame:block.frame,zIndex:block.zIndex,fontVersionID:block.fontVersionID)
        copy.fontSize=block.fontSize;copy.ink=block.ink;copy.fontCatalogID=block.fontCatalogID
        copy.writingRegionID=block.writingRegionID;copy.baselineIndex=block.baselineIndex
        return copy
    }
}

final class StoredRegionLayout: NSObject, NSLayoutManagerDelegate {
    let baselines: [Double]
    let originY: Double
    let step: Double
    var availableLines: Int { baselines.count }
    init(block: TextBlock, template: TemplateInstance) {
        originY=block.frame.y
        let exact=template.writingRegions.first { $0.frame == block.frame }
        let region=template.writingRegions.first { $0.id == block.writingRegionID } ?? exact
            ?? template.writingRegions.first { $0.frame.x<block.frame.x+block.frame.width && $0.frame.x+$0.frame.width>block.frame.x && $0.frame.y<block.frame.y+block.frame.height && $0.frame.y+$0.frame.height>block.frame.y }
        step=region?.baselineStep ?? template.geometry.ruling
        let minimum=block.writingRegionID == nil && exact == nil ? block.frame.y+step : block.frame.y
        baselines=region.map { Array($0.baselines.dropFirst(block.baselineIndex ?? 0)).filter { $0>=minimum && $0<=block.frame.y+block.frame.height } } ?? []
    }
    func baseline(at index: Int) -> Double {
        if baselines.indices.contains(index) { return baselines[index] }
        return (baselines.last ?? originY)+Double(index-baselines.count+1)*step
    }
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard let container=textContainer,layoutManager.extraLineFragmentTextContainer === container else { return }
        let original=layoutManager.extraLineFragmentRect
        let start=original.minY
        let target=baselines.first { $0>start+originY+0.5 } ?? (baselines.last ?? originY)+step
        let rect=CGRect(x:original.minX,y:start,width:original.width,height:max(1,target-originY-start))
        layoutManager.setExtraLineFragmentRect(rect,usedRect:CGRect(x:rect.minX,y:rect.minY,width:0,height:rect.height),textContainer:container)
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<CGRect>, lineFragmentUsedRect used: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in container: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let y=Double(rect.pointee.minY)+originY
        let target=baselines.first { $0>y+0.5 } ?? ((baselines.last ?? originY)+max(1,ceil((y-(baselines.last ?? originY)+0.5)/step))*step)
        let height=max(1,target-y)
        rect.pointee.size.height=height;used.pointee.size.height=height;baselineOffset.pointee=height
        return true
    }
}

enum EditorLayoutError: LocalizedError {
    case inkDoesNotFit
    var errorDescription: String? { String(localized:"The text is too tall for this ruling. Choose a smaller size; your draft was kept.") }
}
