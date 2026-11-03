import UIKit
import CoreText
import MeetingBookCore

@MainActor enum HandwritingFontCatalog {
    struct Entry: Identifiable { let id: String; let name: String; let file: String; let postScriptName: String; let license: String }
    static let entries=[Entry(id:"bundled.caveat",name:"Caveat",file:"Caveat",postScriptName:"Caveat-Regular",license:"Caveat-OFL"),Entry(id:"bundled.gochi-hand",name:"Gochi Hand",file:"GochiHand-Regular",postScriptName:"GochiHand-Regular",license:"GochiHand-OFL")]
    static func mandatoryGlyphBounds(for font: UIFont) -> CGRect {
        var characters=FontCoverage.required.map(UInt16.init),glyphs=Array(repeating:CGGlyph(0),count:103)
        guard CTFontGetGlyphsForCharacters(font as CTFont,&characters,&glyphs,103) else { return .infinite }
        return CTFontGetBoundingRectsForGlyphs(font as CTFont,.horizontal,&glyphs,nil,103)
    }
    static func fitsRuling(font: UIFont, spacing: CGFloat) -> Bool {
        spacing.isFinite && spacing > 0 && mandatoryGlyphBounds(for:font).height <= spacing
    }
    private static var registered=Set<String>()
    static func font(catalogID: String?, personalVersion: FontVersion? = nil, size: CGFloat) -> UIFont {
        let size=size.isFinite && size > 0 && size <= 200 ? size : 30
        if let version=personalVersion,let font=UIFont(name:version.postScriptName,size:size) { return font }
        if personalVersion == nil,let entry=entries.first(where:{ $0.id == catalogID }) {
            if !registered.contains(entry.id),let url=Bundle.main.url(forResource:entry.file,withExtension:"ttf"),CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil) { registered.insert(entry.id) }
            if registered.contains(entry.id),let font=UIFont(name:entry.postScriptName,size:size) { return font }
        }
        return .systemFont(ofSize:size)
    }
    static func licenseText(for entry: Entry) throws -> String {
        guard let url=Bundle.main.url(forResource:entry.license,withExtension:"txt") else { throw FontBuildError.invalidFont }
        return try String(contentsOf:url,encoding:.utf8)
    }
}

final class RuledFontLayout: NSObject, NSLayoutManagerDelegate {
    let spacing: CGFloat
    let baselineOffset: CGFloat
    init(spacing: CGFloat = 40, baselineOffset: CGFloat = 40) { self.spacing=spacing;self.baselineOffset=baselineOffset }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>, lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height=spacing
        lineFragmentUsedRect.pointee.size.height=spacing
        baselineOffset.pointee=self.baselineOffset
        return true
    }
}
