import Foundation
import SwiftUI
import MeetingBookCore

enum NotebookSearch {
    static func swipeTarget(active: UUID,ids: [UUID],horizontal: Double,vertical: Double,reading: Bool) -> UUID? {
        guard reading,abs(horizontal)>=80,abs(horizontal)>abs(vertical)*1.5,let index=ids.firstIndex(of:active) else { return nil }
        let target=index+(horizontal<0 ? 1 : -1)
        return ids.indices.contains(target) ? ids[target] : nil
    }
    static func usesSpread(width: Double,height: Double,accessibility: Bool) -> Bool { BookPresentation(size:CGSize(width:width,height:height),regular:true,accessibility:accessibility).spread }
    static func snippet(title: String,body: String,query: String) -> String? {
        guard !query.isEmpty else { return String(body.prefix(180)) }
        if let match=body.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) {
            let start=body.index(match.lowerBound,offsetBy:-50,limitedBy:body.startIndex) ?? body.startIndex
            return (start == body.startIndex ? "" : "…")+String(body[start...].prefix(180))
        }
        return title.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) == nil ? nil : String(body.prefix(180))
    }
    static func spreadIDs(active: UUID,notes: [Note]) -> (left: UUID?,right: UUID?) {
        let ids=LibraryRules.orderedNotes(notes).flatMap(\.pageIDs)
        guard let index=ids.firstIndex(of:active) else { return (nil,nil) }
        let pair=LibraryRules.spread(containing:index+1)
        return (pair.left.flatMap { ids.indices.contains($0-1) ? ids[$0-1] : nil },ids.indices.contains(pair.right-1) ? ids[pair.right-1] : nil)
    }
}

// Frames describe viewports, never persisted paper or text coordinates.
struct BookPresentation: Equatable {
    struct Exclusion: Equatable {
        var frame: CGRect
        var division: Bool
        var active: Bool = true
    }
    var size: CGSize
    var regular: Bool
    var accessibility: Bool
    var regions: [Exclusion]
    var pages: [CGRect]
    var spread: Bool { pages.count == 2 }
    var gutter: CGRect {
        guard spread else { return .zero }
        let a=pages[0],b=pages[1]
        if b.minX >= a.maxX { return CGRect(x:a.maxX,y:max(a.minY,b.minY),width:b.minX-a.maxX,height:min(a.height,b.height)) }
        return CGRect(x:max(a.minX,b.minX),y:a.maxY,width:min(a.width,b.width),height:max(0,b.minY-a.maxY))
    }
    func binding(offset: CGPoint,enlarged: Bool) -> CGRect {
        let gap=gutter
        guard spread,gap.width<gap.height else {return gap}
        let bottom=pages.map { page -> CGFloat in
            let scale=page.width/720*(enlarged ? 2 : 1)
            let origin=Self.viewportOffset(offset,scale:scale,viewport:page.size)
            return page.minY+min(page.height,1000*scale-origin.y)
        }.min() ?? gap.minY
        return CGRect(x:gap.minX,y:gap.minY,width:gap.width,height:max(0,bottom-gap.minY))
    }
    init(size: CGSize,regular: Bool,accessibility: Bool,regions: [Exclusion] = []) {
        self.size=size;self.regular=regular;self.accessibility=accessibility;self.regions=regions
        let bounds=CGRect(origin:.zero,size:size)
        var panes=[bounds]
        for region in regions where region.active {
            panes=panes.flatMap { pane -> [CGRect] in
                let cut=pane.intersection(region.frame)
                guard !cut.isNull else {return [pane]}
                let horizontal=[CGRect(x:pane.minX,y:pane.minY,width:max(0,cut.minX-pane.minX),height:pane.height),CGRect(x:cut.maxX,y:pane.minY,width:max(0,pane.maxX-cut.maxX),height:pane.height)]
                let vertical=[CGRect(x:pane.minX,y:pane.minY,width:pane.width,height:max(0,cut.minY-pane.minY)),CGRect(x:pane.minX,y:cut.maxY,width:pane.width,height:max(0,pane.maxY-cut.maxY))]
                if region.division {return cut.height>=cut.width ? horizontal : vertical}
                return [((horizontal+vertical).max { $0.width*$0.height < $1.width*$1.height })!]
            }.filter { $0.width>0 && $0.height>0 }
        }
        // Half canonical width keeps a 24-unit document font at a readable 12-point minimum.
        func usable(_ rect: CGRect) -> Bool {rect.width>=360 && rect.height>=360}
        if regular && !accessibility {
            if panes.count==1,let pane=panes.first {
                let inset=pane.insetBy(dx:12,dy:12),gap:CGFloat=12
                let width=(inset.width-gap)/2
                let pair=[CGRect(x:inset.minX,y:inset.minY,width:width,height:inset.height),CGRect(x:inset.minX+width+gap,y:inset.minY,width:width,height:inset.height)]
                let singleFit=min(inset.width/720,inset.height/1000)
                // Keep paired handwriting near the single-page fit size; tall windows favor one readable page.
                if pair.allSatisfy(usable),width/720 >= singleFit*0.8 {pages=pair;return}
            } else if panes.count==2,panes.allSatisfy(usable) {
                pages=panes;return
            }
        }
        pages=[panes.max { $0.width*$0.height < $1.width*$1.height } ?? .zero]
    }
    static func resolve(_ geometry: GeometryProxy,regular: Bool,accessibility: Bool,layoutDirection: LayoutDirection) -> Self {
        var regions:[Exclusion]=[]
        if #available(iOS 27.1, *) {
            for division in [true,false] {
                regions += geometry.reservedRegions(kind:division ? .division : .occlusion,options:.includeInactive,layoutDirectionBehavior:.fixed).map { region in
                    let margin=region.margins,frame=region.frame
                    let left=layoutDirection == .leftToRight ? margin.leading : margin.trailing
                    return Exclusion(frame:CGRect(x:frame.minX-left,y:frame.minY-margin.top,width:frame.width+margin.leading+margin.trailing,height:frame.height+margin.top+margin.bottom),division:division,active:region.isActive)
                }
            }
        }
        return Self(size:geometry.size,regular:regular,accessibility:accessibility,regions:regions)
    }
    static func viewportOffset(_ canonical: CGPoint,scale: CGFloat,viewport: CGSize) -> CGPoint {
        CGPoint(x:min(max(0,canonical.x*scale),max(0,720*scale-viewport.width)),y:min(max(0,canonical.y*scale),max(0,1000*scale-viewport.height)))
    }
}

struct BookPresentationPreference: PreferenceKey {
    static var defaultValue: BookPresentation? { nil }
    static func reduce(value: inout BookPresentation?,nextValue: () -> BookPresentation?) {value=nextValue() ?? value}
}
