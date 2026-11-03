import Foundation

/// Deterministic, unhinted simple-outline TrueType. No native framework or font dependency.
public enum TrueTypeWriter {
    public static func build(glyphs: [UInt32:GlyphOutline], postScriptName: String) throws -> Data {
        try Task.checkCancellation()
        let missing=FontCoverage.required.filter { glyphs[$0] == nil }
        guard missing.isEmpty else { throw FontBuildError.missingGlyphs(missing) }
        guard glyphs.count == FontCoverage.required.count, !postScriptName.isEmpty, postScriptName.utf8.count <= 63,
              postScriptName.utf8.allSatisfy({ (33...126).contains($0) && ![91,93,40,41,123,125,60,62,47,37].contains($0) }) else { throw FontBuildError.invalidFont }
        let ordered=[GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(450,700),.init(450,0)], [.init(100,50),.init(400,50),.init(400,650),.init(100,650)]],advanceWidth:500)]+FontCoverage.required.map { glyphs[$0]! }
        var glyf=Bytes(),loca=Bytes(),hmtx=Bytes();var pointCount=0
        for (index,glyph) in ordered.enumerated() {
            try Task.checkCancellation();try glyph.validate(space:index == 1)
            pointCount += glyph.contours.reduce(0) { $0+$1.count }
            guard pointCount <= 250000 else { throw FontBuildError.tooComplex }
            loca.u32(glyf.count);hmtx.u16(glyph.advanceWidth);hmtx.i16(glyph.bounds[0])
            if glyph.contours.isEmpty { continue }
            glyf.i16(glyph.contours.count);glyph.bounds.forEach { glyf.i16($0) }
            var end=0
            for contour in glyph.contours { end += contour.count;glyf.u16(end-1) }
            glyf.u16(0) // No glyph instructions.
            let points=glyph.contours.flatMap { $0 }
            glyf.raw(Array(repeating:1,count:points.count)) // All on-curve; straight quadratic segments.
            var previous=0
            for p in points { glyf.i16(p.x-previous);previous=p.x }
            previous=0
            for p in points { glyf.i16(p.y-previous);previous=p.y }
            glyf.pad()
        }
        loca.u32(glyf.count)
        let bounds=[ordered.map { $0.bounds[0] }.min()!,ordered.map { $0.bounds[1] }.min()!,ordered.map { $0.bounds[2] }.max()!,ordered.map { $0.bounds[3] }.max()!]
        var head=Bytes();head.u32(0x00010000);head.u32(0x00010000);head.u32(0);head.u32(0x5F0F3CF5);head.u16(3);head.u16(1000)
        head.raw(Array(repeating:0,count:16));bounds.forEach { head.i16($0) };head.u16(0);head.u16(8);head.i16(2);head.i16(1);head.i16(0)
        var hhea=Bytes();hhea.u32(0x00010000);hhea.i16(850);hhea.i16(-250);hhea.i16(0)
        hhea.u16(ordered.map(\.advanceWidth).max()!);hhea.i16(bounds[0]);hhea.i16(ordered.map { $0.advanceWidth-$0.bounds[2] }.min()!);hhea.i16(bounds[2]);hhea.i16(1);hhea.i16(0);hhea.i16(0)
        hhea.raw(Array(repeating:0,count:10));hhea.u16(ordered.count)
        var maxp=Bytes();maxp.u32(0x00010000);maxp.u16(ordered.count);maxp.u16(ordered.map { $0.contours.reduce(0) { $0+$1.count } }.max()!);maxp.u16(ordered.map { $0.contours.count }.max()!);maxp.u16(0);maxp.u16(0);maxp.u16(2);maxp.raw(Array(repeating:0,count:16))
        var cmap=Bytes();cmap.u16(0);cmap.u16(2);cmap.u16(0);cmap.u16(4);cmap.u32(20);cmap.u16(3);cmap.u16(10);cmap.u32(20)
        cmap.u16(12);cmap.u16(0);cmap.u32(16+12*FontCoverage.required.count);cmap.u32(0);cmap.u32(FontCoverage.required.count)
        for (index,code) in FontCoverage.required.enumerated() { cmap.u32(Int(code));cmap.u32(Int(code));cmap.u32(index+1) }
        var name=Bytes(),strings=Bytes()
        let names=[(1,postScriptName),(2,"Regular"),(3,postScriptName),(4,postScriptName),(5,"Version 1.000"),(6,postScriptName)]
        name.u16(0);name.u16(names.count);name.u16(6+12*names.count)
        for (id,value) in names {
            name.u16(3);name.u16(1);name.u16(0x0409);name.u16(id);name.u16(value.utf16.count*2);name.u16(strings.count)
            value.utf16.forEach { strings.u16(Int($0)) }
        }
        name.raw(strings.data)
        var post=Bytes();post.u32(0x00030000);post.u32(0);post.i16(-100);post.i16(50);post.raw(Array(repeating:0,count:20))
        var os2=Bytes();os2.u16(4);os2.i16(ordered.map(\.advanceWidth).reduce(0,+)/ordered.count);os2.u16(400);os2.u16(5);os2.u16(0)
        [650,600,0,75,650,600,0,350,50,300,0].forEach { os2.i16($0) };os2.raw(Array(repeating:0,count:10))
        os2.u32(3);os2.u32(2);os2.u32(0);os2.u32(0);os2.raw(Array("MTBK".utf8));os2.u16(0xC0);os2.u16(32);os2.u16(8364)
        os2.i16(850);os2.i16(-250);os2.i16(0);os2.u16(850);os2.u16(250);os2.u32(1);os2.u32(0);os2.i16(max(0,glyphs[120]!.bounds[3]));os2.i16(max(0,glyphs[72]!.bounds[3]));os2.u16(0);os2.u16(32);os2.u16(1)
        let tables=["OS/2":os2,"cmap":cmap,"glyf":glyf,"head":head,"hhea":hhea,"hmtx":hmtx,"loca":loca,"maxp":maxp,"name":name,"post":post]
        var result=Bytes(),body=Bytes();result.u32(0x00010000);result.u16(10);result.u16(128);result.u16(3);result.u16(32)
        var headOffset=0
        for tag in tables.keys.sorted() {
            let table=tables[tag]!,offset=172+body.count
            result.raw(Array(tag.utf8));result.u32(Int(checksum(table.data)));result.u32(offset);result.u32(table.count)
            if tag == "head" { headOffset=offset }
            body.raw(table.data);body.pad()
        }
        result.raw(body.data)
        let adjustment=0xB1B0AFBA &- checksum(result.data)
        for index in 0..<4 { result.data[headOffset+8+index]=UInt8(truncatingIfNeeded:adjustment >> (24-8*index)) }
        try Task.checkCancellation()
        return Data(result.data)
    }
}

struct Bytes {
    var data=[UInt8]()
    var count: Int { data.count }
    mutating func raw(_ bytes: [UInt8]) { data.append(contentsOf:bytes) }
    mutating func u16(_ value: Int) { data += [UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)] }
    mutating func i16(_ value: Int) { u16(value) }
    mutating func u32(_ value: Int) { u16(value >> 16);u16(value) }
    mutating func pad() { while data.count % 4 != 0 { data.append(0) } }
}
func checksum(_ data: [UInt8]) -> UInt32 {
    var sum: UInt32=0
    for offset in stride(from:0,to:data.count,by:4) {
        var value: UInt32=0
        for index in 0..<4 { value=(value << 8) | (offset+index < data.count ? UInt32(data[offset+index]) : 0) }
        sum &+= value
    }
    return sum
}
