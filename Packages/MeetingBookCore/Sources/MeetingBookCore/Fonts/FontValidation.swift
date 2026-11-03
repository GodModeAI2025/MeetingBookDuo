import Foundation

/// Strict validation of our generated simple-outline format, not a general downloaded-font parser.
public enum FontValidation {
    public static func validateGenerated(_ data: Data) throws {
        guard data.count <= 8_000_000,data.count >= 172,data.count % 4 == 0 else { throw FontBuildError.invalidFont }
        let reader=FontReader(bytes:Array(data))
        guard try reader.u32(0) == 0x00010000,try reader.u16(4) == 10,checksum(reader.bytes) == 0xB1B0AFBA else { throw FontBuildError.invalidFont }
        var tables=[String:FontReader](),ranges=[Range<Int>]()
        for index in 0..<10 {
            let base=12+index*16,tag=String(bytes:reader.bytes[base..<base+4],encoding:.ascii) ?? ""
            let offset=try reader.u32(base+8),length=try reader.u32(base+12)
            guard offset >= 172, offset % 4 == 0,length > 0,offset <= data.count,length <= data.count-offset,tables[tag] == nil else { throw FontBuildError.invalidFont }
            let range=offset..<offset+length
            guard ranges.allSatisfy({ !$0.overlaps(range) }) else { throw FontBuildError.invalidFont };ranges.append(range)
            var bytes=Array(reader.bytes[range]);let table=FontReader(bytes:bytes)
            if tag == "head" { guard length == 54 else { throw FontBuildError.invalidFont };bytes.replaceSubrange(8..<12,with:[0,0,0,0]) }
            guard try Int(checksum(bytes)) == reader.u32(base+4) else { throw FontBuildError.invalidFont }
            tables[tag]=table
        }
        guard Set(tables.keys) == Set(["OS/2","cmap","glyf","head","hhea","hmtx","loca","maxp","name","post"]) else { throw FontBuildError.invalidFont }
        let head=tables["head"]!,maxp=tables["maxp"]!,loca=tables["loca"]!,glyf=tables["glyf"]!,hmtx=tables["hmtx"]!,cmap=tables["cmap"]!,hhea=tables["hhea"]!
        guard try head.u32(12) == 0x5F0F3CF5,try head.u16(18) == 1000,try head.u16(50) == 1,
              try maxp.u32(0) == 0x10000,try maxp.u16(4) == 104,try hhea.u16(34) == 104,
              loca.bytes.count == 420,hmtx.bytes.count == 416,try cmap.u16(20) == 12,try cmap.u32(32) == 103,
              try tables["OS/2"]!.u16(8) == 0 else { throw FontBuildError.invalidFont }
        for (index,code) in FontCoverage.required.enumerated() {
            let base=36+12*index
            guard try cmap.u32(base) == Int(code),try cmap.u32(base+4) == Int(code),try cmap.u32(base+8) == index+1 else { throw FontBuildError.invalidFont }
        }
        var total=0
        for index in 0..<104 {
            try Task.checkCancellation()
            let start=try loca.u32(index*4),end=try loca.u32(index*4+4)
            guard start <= end,end <= glyf.bytes.count else { throw FontBuildError.invalidFont }
            if index == 1 { guard start == end else { throw FontBuildError.invalidFont };continue }
            guard end-start >= 12 else { throw FontBuildError.invalidFont }
            let glyph=FontReader(bytes:Array(glyf.bytes[start..<end])),count=try glyph.u16(0)
            guard (1...128).contains(count) else { throw FontBuildError.invalidFont }
            var endpoints=[Int]()
            for contour in 0..<count { endpoints.append(try glyph.u16(10+contour*2)) }
            let points=endpoints.last!+1,instructions=10+count*2,flags=instructions+2
            total += points
            guard points <= 8192,total <= 250000,try glyph.u16(instructions) == 0, flags+points*5 <= glyph.bytes.count else { throw FontBuildError.invalidFont }
            guard glyph.bytes[flags..<flags+points].allSatisfy({ $0 == 1 }) else { throw FontBuildError.invalidFont }
            var decoded=[GlyphOutline.Point](),x=0,y=0
            for p in 0..<points {
                x += try glyph.i16(flags+points+p*2);y += try glyph.i16(flags+points*3+p*2);decoded.append(.init(x,y))
            }
            var contours=[[GlyphOutline.Point]](),previous=0
            for end in endpoints { guard end >= previous,end < points else { throw FontBuildError.invalidFont };contours.append(Array(decoded[previous...end]));previous=end+1 }
            let outline=GlyphOutline(contours:contours,advanceWidth:try hmtx.u16(index*4))
            do { try outline.validate(space:false) } catch { throw FontBuildError.invalidFont }
            for axis in 0..<4 { guard try outline.bounds[axis] == glyph.i16(2+axis*2) else { throw FontBuildError.invalidFont } }
            guard try hmtx.i16(index*4+2) == outline.bounds[0] else { throw FontBuildError.invalidFont }
        }
        guard try loca.u32(416) == glyf.bytes.count else { throw FontBuildError.invalidFont }
    }
}
private struct FontReader {
    let bytes: [UInt8]
    func u16(_ offset: Int) throws -> Int {
        guard offset >= 0,offset <= bytes.count-2 else { throw FontBuildError.invalidFont }
        return Int(bytes[offset]) << 8 | Int(bytes[offset+1])
    }
    func i16(_ offset: Int) throws -> Int { Int(Int16(bitPattern:UInt16(try u16(offset)))) }
    func u32(_ offset: Int) throws -> Int { try u16(offset) << 16 | u16(offset+2) }
}
