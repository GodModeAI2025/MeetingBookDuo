import Foundation

public struct TemplateConfiguration: Codable, Sendable, Equatable {
    public var year = 2026
    public var month = 1
    public var day = 1
    public var mondayFirst = true
    public var locale = "de"
    public var variant: String? = nil
    public var count = 1
    public var people = 8
    public var compositionCounts: [String:Int] = [:]
    public var schoolYear = false
    public var textSize: Double = 30
    /// Actual ink envelope in canonical units. Apple adapters measure the selected font.
    public var inkAscent: Double = 30.6
    public var inkDescent: Double = 9
    public var timeFieldWidth: Double = 120
    public var holidayJurisdiction = "none"
    public var importedVacations: [CalendarInterval] = []
    public init() {}
    public var lineStep: Double { max(40, ceil(inkAscent + inkDescent)) }
}
public struct TemplatePoint: Codable, Sendable, Equatable {
    public let x: Double; public let y: Double
    public init(_ x: Double, _ y: Double) { self.x=x; self.y=y }
}
public struct TemplatePrimitive: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case line, rectangle, ellipse, polyline, text }
    public var kind: Kind
    public var frame: PageRect
    public var points: [TemplatePoint] = []
    public var text: String = ""
    public var fontSize: Double = 16
    public var lineWidth: Double = 0.7
    public var tone: Double = 0.65
    public var filled = false
    public init(kind: Kind, frame: PageRect) { self.kind=kind; self.frame=frame }
}
public enum TemplateBlockType: String, Codable, Sendable, CaseIterable {
    case fields, heading, text, prompt, table, scale, checks, checklist, lines, dots, weekdays, faces, battery, box, band, linescale, wheel, rating_list, paragraphs, breath, spacer
    case grid, body, mindmap, chart, markGrid, calendar, cornell, quadrants
}
public struct TemplateBlock: Codable, Sendable, Equatable {
    public var type: TemplateBlockType
    public var label: String
    public var items: [String]
    public var rows: Int
    public var weights: [Double]
    public var checks: [Int]
    public var rowLabels: [String]
    public var height: Double
    public var detail: String
    /// Definition-only cycle, resolved to a literal label before storing a page.
    public var labelCycle: [String]?
    public var cycleOffset: Int?
    public init(_ type: TemplateBlockType, _ label: String = "", items: [String] = [], rows: Int = 3, weights: [Double] = [], checks: [Int] = [], rowLabels: [String] = [], height: Double = 0, detail: String = "", labelCycle: [String]? = nil, cycleOffset: Int? = nil) {
        self.type=type; self.label=label; self.items=items; self.rows=rows; self.weights=weights; self.checks=checks; self.rowLabels=rowLabels; self.height=height; self.detail=detail;self.labelCycle=labelCycle;self.cycleOffset=cycleOffset
    }
}

/// Resolves everything once. Stored pages never consult the catalog again.
struct TemplateLayout {
    let id: String
    let title: String
    let variant: String
    let config: TemplateConfiguration
    var pages: [TemplateInstance] = []
    var page = TemplateInstance()
    var y: Double = 112
    let left = 56.0, width = 608.0, bottom = 936.0
    init(id: String, title: String, variant: String, config: TemplateConfiguration) {
        self.id=id; self.title=title; self.variant=variant; self.config=config
        begin()
    }
    mutating func begin() {
        page=TemplateInstance(); page.definitionID=id; page.definitionVersion=1; page.variant=variant
        page.configuration=config; page.writingRegions=[]; page.primitives=[]; page.geometry.ruling=config.lineStep
        y=112
        let continuation=id=="journal.gratitude_day" && variant=="compact" ? (config.locale=="de" ? " · Fortsetzung " : " · Continued ") : " · "
        text(title + (pages.isEmpty ? "" : continuation+String(pages.count+1)),56,52,608,40,24)
    }
    mutating func finish() { if !page.primitives.isEmpty || !page.writingRegions.isEmpty { pages.append(page) }; begin() }
    mutating func ensure(_ h: Double) { if y+h > bottom { finish() } }
    mutating func text(_ value: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 28, _ size: Double = 16) {
        guard !value.isEmpty else { return }
        var p=TemplatePrimitive(kind:.text,frame:.init(x:x,y:y,width:w,height:h)); p.text=value; p.fontSize=size; p.tone=0.2
        page.primitives.append(p)
    }
    mutating func shape(_ kind: TemplatePrimitive.Kind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, tone: Double = 0.45, filled: Bool = false) {
        var p=TemplatePrimitive(kind:kind,frame:.init(x:x,y:y,width:w,height:h)); p.tone=tone; p.filled=filled; page.primitives.append(p)
    }
    mutating func line(_ x: Double, _ y: Double, _ x2: Double, _ y2: Double, tone: Double = 0.35) {
        var p=TemplatePrimitive(kind:.line,frame:.init(x:min(x,x2),y:min(y,y2),width:max(0.01,abs(x2-x)),height:max(0.01,abs(y2-y))))
        p.points=[.init(x,y),.init(x2,y2)];p.tone=tone; page.primitives.append(p)
    }
    mutating func path(_ points: [TemplatePoint]) {
        var p=TemplatePrimitive(kind:.polyline,frame:.init(x:0,y:0,width:720,height:1000));p.points=points;p.tone=0.3;p.lineWidth=1.2;page.primitives.append(p)
    }
    mutating func region(x: Double, top: Double, w: Double, lines: Int, ruled: Bool = true, label: String? = nil) {
        let first=top+config.inkAscent+2
        let baselines=(0..<lines).map { first+Double($0)*config.lineStep }
        let h=first-top+Double(lines-1)*config.lineStep+config.inkDescent+2
        let index=pages.count*10000+page.writingRegions.count+1
        // Stable within one resolved plan; UUID identity is independent of future catalog revisions.
        let uuid=UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",index))!
        page.writingRegions.append(.init(id:uuid,frame:.init(x:x,y:top,width:w,height:h),baselines:baselines,baselineStep:config.lineStep,label:label))
        if ruled { for baseline in baselines { line(x,baseline,x+w,baseline,tone:0.78) } }
    }
    mutating func prompt(_ label: String, lines: Int, checklist: Bool = false) {
        var remaining=max(1,lines);var continuation=false
        while remaining > 0 {
            ensure(100)
            let labelH=label.isEmpty ? 0.0 : (label.count > 65 ? 52.0 : 28.0)
            if !label.isEmpty { text(label+(continuation ? " …" : ""),left,y,width,labelH) };y += labelH
            let available=max(1,Int((bottom-y-config.inkAscent-config.inkDescent-4)/config.lineStep)+1)
            let n=min(remaining,available)
            region(x:left+(checklist ? 28:0),top:y,w:width-(checklist ? 28:0),lines:n,label:label)
            if checklist { for k in 0..<n { shape(.rectangle,left,y+config.inkAscent+Double(k)*config.lineStep-14,16,16) } }
            y += config.inkAscent+config.inkDescent+4+Double(n-1)*config.lineStep+20
            remaining -= n; continuation=true
            if remaining > 0 { finish() }
        }
    }
    mutating func table(_ b: TemplateBlock) {
        let columns=b.items
        // Wide source tables become keyed column groups with repeated row identifiers.
        let clock=b.detail=="clock",hours=b.detail=="hours",rowKeys=b.detail=="row-keys"
        let fixed=clock ? 84.0:140.0
        let numericWidth=config.timeFieldWidth*(hours ? 1.25:1)
        if (clock || hours) && numericWidth>width-fixed {
            for row in 0..<b.rows {
                let key=row<b.rowLabels.count ? b.rowLabels[row]:"#\(row+1)"
                for column in columns.dropFirst() {prompt(key+" · "+column,lines:max(1,Int(ceil(numericWidth/width))))}
            }
            return
        }
        let groupSize=(clock || hours) ? max(1,min(clock ? 4:3,Int((width-fixed)/numericWidth))) : 2
        let groups: [[Int]] = columns.count <= 3 && !clock && !hours ? [Array(columns.indices)] : stride(from:1,to:columns.count,by:groupSize).map { [0]+Array($0..<min($0+groupSize,columns.count)) }
        for group in groups {
            var row=0
            while row < b.rows {
                ensure(160)
                let weights=group.map { b.weights.isEmpty ? 1 : b.weights[$0] }
                let total=weights.reduce(0,+)
                let widths=(clock || hours) ? [fixed]+Array(repeating:(width-fixed)/Double(group.count-1),count:group.count-1) : weights.map { 120+(width-120*Double(group.count))*$0/total }
                let header=Double(group.map { columns[$0].count }.max() ?? 0)>24 ? 74.0 : 52.0
                text(b.label,left,y,width,28);if !b.label.isEmpty { y += 28 }
                var x=left
                for (k,c) in group.enumerated() { text(columns[c],x+6,y+4,widths[k]-12,header-8,15);x += widths[k] }
                y += header
                let numbered=groups.count>1 && (rowKeys || b.rowLabels.count<b.rows || b.rowLabels.contains(""))
                let rowH=clock ? max(52,config.lineStep+12):max(numbered ? 74:64,config.lineStep+(numbered ? 30:18))
                let fit=max(1,Int((bottom-y-16)/rowH))
                let end=min(b.rows,row+fit)
                for r in row..<end {
                    let key=rowKeys && r<b.rowLabels.count ? b.rowLabels[r]:"#\(r+1)"
                    x=left
                    for (k,c) in group.enumerated() {
                        shape(.rectangle,x,y,widths[k],rowH)
                        if numbered && c==0 {text(key,x+7,y+3,widths[k]-14,18,10)}
                        if !rowKeys && c == 0 && r < b.rowLabels.count && !b.rowLabels[r].isEmpty { text(b.rowLabels[r],x+6,y+8,widths[k]-12,rowH-16,16) }
                        else if b.checks.contains(c) { shape(.rectangle,x+widths[k]/2-9,y+rowH/2-9,18,18) }
                        else {
                            let marker=numbered && c==0
                            region(x:x+7,top:y+(marker ? 25:8),w:widths[k]-14,lines:1,label:columns[c]+" · \(key)")
                        }
                        x += widths[k]
                    }
                    y += rowH
                }
                y += 20; row=end
                if row < b.rows { finish() }
            }
        }
    }
    mutating func render(_ blocks: [TemplateBlock]) throws {
        for b in blocks {
            switch b.type {
            case .prompt, .lines: prompt(b.label,lines:b.rows)
            case .fields: for item in b.items { prompt(item,lines:1) }
            case .table: table(b)
            case .checklist: prompt(b.label,lines:b.rows,checklist:true)
            case .heading, .band:
                ensure(56); if b.type == .band { shape(.rectangle,left,y,width,48,tone:0.94,filled:true) }
                text(b.label,left+8,y+6,width-16,40,19);y += 56
            case .text, .paragraphs:
                for item in (b.items.isEmpty ? [b.label]:b.items) {
                    let h=max(28,ceil(Double(item.count)/65)*24)
                    ensure(h+16);text(item,left,y,width,h,16);y += h+16
                }
            case .spacer: ensure(b.height);y += b.height
            case .box:
                let h=max(100,b.height);ensure(h+16);shape(.rectangle,left,y,width,h)
                text(b.label,left+10,y+8,width-20,28);region(x:left+12,top:y+40,w:width-24,lines:max(1,Int((h-50-config.inkAscent-config.inkDescent)/config.lineStep)+1),ruled:false);y += h+20
            case .dots, .grid:
                let h=b.height == 0 ? 720 : b.height;ensure(h)
                region(x:left,top:y,w:width,lines:max(1,Int((h-config.inkAscent-config.inkDescent-4)/config.lineStep)+1),ruled:false)
                if b.type == .grid {
                    // A half-step lattice shares the actual stored text baseline origin.
                    let spacing=config.lineStep/2,origin=page.writingRegions.last!.baselines[0]
                    let first=origin-floor((origin-y)/spacing)*spacing
                    for yy in stride(from:first,through:y+h,by:spacing) {line(left,yy,left+width,yy,tone:0.82)}
                    for x in stride(from:left,through:left+width,by:spacing) {line(x,y,x,y+h,tone:0.82)}
                } else {
                    for yy in stride(from:y+20,through:y+h-16,by:20) {
                        for xx in stride(from:left+10,through:left+width-10,by:20) {shape(.ellipse,xx,yy,1.5,1.5,tone:0.65,filled:true)}
                    }
                }
                y += h+20
            default: try diagram(b)
            }
        }
    }
    mutating func resolve(_ blocks: [TemplateBlock]) throws -> [TemplateInstance] {
        try TemplateValidation.validate(config)
        try TemplateValidation.validate(blocks)
        try render(blocks); if !page.primitives.isEmpty || !page.writingRegions.isEmpty { pages.append(page) }
        for p in pages { try TemplateValidation.validate(p) }
        return pages
    }
}
