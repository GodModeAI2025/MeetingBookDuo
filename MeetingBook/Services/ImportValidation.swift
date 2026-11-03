import Foundation
import MeetingBookCore

/// Deliberately restricted ZIP32 container; no decompressor runs before this check.
enum ImportValidation {
    struct Limits: Sendable {
        var entries=20_000
        var payload: UInt64=2_000_000_000
        var file: UInt64=2_016_000_000
    }
    struct Entry: Sendable {
        let path: String
        let size: UInt64
        let crc: UInt32
        let offset: UInt64
    }
    static func inspectZIP(url: URL, limits: Limits = Limits()) throws -> [Entry] {
        let file=try FileHandle(forReadingFrom:url);defer { try? file.close() }
        let length=try file.seekToEnd()
        guard length>=22,length<=limits.file else { throw NotebookError.invalidAsset }
        func read(_ offset: UInt64,_ count: Int) throws -> Data {
            guard offset<=length,UInt64(count)<=length-offset else { throw NotebookError.invalidModel }
            try file.seek(toOffset:offset)
            guard let data=try file.read(upToCount:count),data.count==count else { throw NotebookError.invalidModel }
            return data
        }
        let end=try read(length-22,22)
        guard end.u32(0)==0x06054b50,end.u16(4)==0,end.u16(6)==0,end.u16(8)==end.u16(10),end.u16(20)==0 else { throw NotebookError.unsupportedVersion }
        let count=Int(end.u16(10)),central=UInt64(end.u32(16)),centralSize=UInt64(end.u32(12))
        guard count>0,count<=limits.entries,central+centralSize==length-22 else { throw NotebookError.invalidModel }
        var cursor=central,local: UInt64=0,total: UInt64=0,paths=Set<String>(),entries:[Entry]=[]
        for _ in 0..<count {
            try Task.checkCancellation()
            let c=try read(cursor,46)
            guard c.u32(0)==0x02014b50,[UInt16(0x314),0x315].contains(c.u16(4)),c.u16(6)==20,
                  [UInt16(0),0x800].contains(c.u16(8)),c.u16(10)==0,
                  c.u16(30)==0,c.u16(32)==0,c.u16(34)==0,c.u16(36)==0,
                  c.u32(38)>>16 & 0xf000 == 0x8000,c.u32(38)&0xffff==0,
                  c.u32(20)==c.u32(24),UInt64(c.u32(42))==local else { throw NotebookError.unsupportedVersion }
            let nameLength=Int(c.u16(28))
            guard (1...128).contains(nameLength),cursor+46+UInt64(nameLength)<=central+centralSize else { throw NotebookError.invalidModel }
            let name=try read(cursor+46,nameLength)
            guard let path=String(data:name,encoding:.ascii),validPath(path),paths.insert(path).inserted else { throw NotebookError.invalidModel }
            let size=UInt64(c.u32(24))
            guard size<=limits.payload-total else { throw NotebookError.invalidAsset };total+=size
            let h=try read(local,30)
            guard h.u32(0)==0x04034b50,h.u16(26)==c.u16(28),h.u16(28)==0,
                  h.subdata(in:4..<26)==c.subdata(in:6..<28),
                  local+30+UInt64(nameLength)+size<=central,
                  try read(local+30,nameLength)==name else { throw NotebookError.invalidModel }
            entries.append(Entry(path:path,size:size,crc:c.u32(16),offset:local+30+UInt64(nameLength)))
            local+=30+UInt64(nameLength)+size;cursor+=46+UInt64(nameLength)
        }
        guard cursor==central+centralSize,local==central else { throw NotebookError.invalidModel }
        return entries
    }
    static func validPath(_ path: String) -> Bool {
        if ["manifest.json","library.json"].contains(path) { return true }
        let pieces=path.split(separator:"/",omittingEmptySubsequences:false)
        guard pieces.count==2 else { return false }
        let directory=String(pieces[0]),name=String(pieces[1])
        if directory=="records" { return name.count==11 && name.hasSuffix(".json") && name.prefix(6).utf8.allSatisfy({(48...57).contains($0)}) && (Int(name.prefix(6)) ?? 4096)<4096 }
        if directory=="assets" { return name.hasSuffix(".blob") && PageContent.isHash(String(name.dropLast(5))) }
        if directory=="licenses" {
            let stem=name.dropLast(4)
            return name.hasSuffix(".txt") && !stem.isEmpty && stem.count<=80 && stem.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0==45 }
        }
        let suffix=directory=="fonts" ? ".ttf" : ".json"
        guard ["notes","pages","revisions","font-projects","fonts"].contains(directory),name.hasSuffix(suffix) else { return false }
        let stem=String(name.dropLast(suffix.count))
        return UUID(uuidString:stem)?.uuidString.lowercased()==stem
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i+1])<<8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i+2))<<16 }
}

extension ImportValidation {
    /// JSONDecoder permits duplicate keys; reject ambiguity and deep containers before decoding models.
    static func validateJSON(_ data: Data, maximum: Int = 16_000_000) throws {
        guard data.count<=maximum else { throw NotebookError.invalidAsset }
        let bytes=Array(data);var index=0,nodes=0
        func whitespace() { while index<bytes.count && [UInt8(9),10,13,32].contains(bytes[index]) { index+=1 } }
        func string() throws -> String {
            let start=index;guard index<bytes.count,bytes[index]==34 else { throw NotebookError.invalidModel };index+=1
            while index<bytes.count {
                let b=bytes[index];index+=1
                if b==34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index])) }
                if b==92 { guard index<bytes.count else { throw NotebookError.invalidModel };index+=1 }
            }
            throw NotebookError.invalidModel
        }
        func value(_ depth: Int) throws {
            nodes+=1;guard depth<=64,nodes<=1_000_000 else { throw NotebookError.invalidAsset }
            if nodes%1024==0 { try Task.checkCancellation() }
            whitespace();guard index<bytes.count else { throw NotebookError.invalidModel }
            if bytes[index]==34 { _ = try string();return }
            if bytes[index]==123 || bytes[index]==91 {
                let object=bytes[index]==123,end:UInt8=object ? 125 : 93;index+=1;whitespace();var keys=Set<String>()
                if index<bytes.count,bytes[index]==end { index+=1;return }
                while true {
                    if object {
                        whitespace();guard keys.insert(try string()).inserted else { throw NotebookError.invalidModel }
                        whitespace();guard index<bytes.count,bytes[index]==58 else { throw NotebookError.invalidModel };index+=1
                    }
                    try value(depth+1);whitespace();guard index<bytes.count else { throw NotebookError.invalidModel }
                    let b=bytes[index];index+=1;if b==end { return };guard b==44 else { throw NotebookError.invalidModel }
                }
            }
            let start=index
            while index<bytes.count && ![UInt8(9),10,13,32,44,93,125].contains(bytes[index]) { index+=1 }
            guard index>start else { throw NotebookError.invalidModel }
        }
        try value(0);whitespace();guard index==bytes.count else { throw NotebookError.invalidModel }
        _ = try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
    }
}

/// A caller selects this budget before copying or inspecting untrusted input.
enum PackageSizePolicy: Sendable {
    case ordinary, large
    var zipLimits: ImportValidation.Limits { self == .large ? .init(entries:60_000,payload:2_000_000_000,file:2_032_000_000) : .init() }
    var metadataLimit:Int {self == .large ? 768_000_000 : 64_000_000}
    var manifestLimit:Int {self == .large ? 16_000_000 : 8_000_000}
}

/// Shared bounded raw-row encoding for large packages and local recovery checkpoints.
enum RecordChunks {
    static let kinds:Set<String>=["library","page","revision","outbox","pageTombstone","causalOperation","operationAck","incomingOperation","engineCheckpoint","revisionHeader","expiredPage","expiredNote","retainedFontVersion","syncWire","syncDelivery","syncApplied","syncConflict","derivedSyncCopy","syncContext","syncResolution","syncConsumed","syncRefetch","syncTransport"]
    static func path(_ index:Int) -> String {String(format:"records/%06d.json",index)}
    static func rawSize(_ row:NotebookStore.RecordRow) throws -> Int {
        guard !row.key.isEmpty,row.key.utf8.count<=128,row.key.utf8.allSatisfy({$0>=32 && $0<127}),kinds.contains(row.kind),row.kind.utf8.count<=64,row.payload.count<=16_000_000 else {throw NotebookError.invalidModel}
        return row.payload.count+row.key.utf8.count+row.kind.utf8.count
    }
    static func encode(_ rows:[NotebookStore.RecordRow]) throws -> [String:Data] {
        guard !rows.isEmpty,rows.count<=1_000_000 else {throw NotebookError.invalidAsset}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var result:[String:Data]=[:],chunk:[NotebookStore.RecordRow]=[],payload=0,total=0,encoded=0,keys=Set<String>()
        func flush() throws {
            guard !chunk.isEmpty,result.count<4096 else {throw NotebookError.invalidAsset}
            let bytes=try encoder.encode(chunk)
            guard bytes.count<=24_000_000,bytes.count<=768_000_000-encoded else {throw NotebookError.invalidAsset}
            encoded+=bytes.count;result[path(result.count)]=bytes;chunk=[];payload=0
        }
        for row in rows.sorted(by:{$0.key<$1.key}) {
            try Task.checkCancellation();let size=try rawSize(row)
            guard keys.insert(row.key).inserted,size<=576_000_000-total else {throw NotebookError.invalidAsset};total+=size
            if !chunk.isEmpty && (chunk.count==256 || row.payload.count>16_000_000-payload) {try flush()}
            chunk.append(row);payload+=row.payload.count
        }
        if !chunk.isEmpty {try flush()};return result
    }
    static func decode(_ files:[String:Data]) throws -> [NotebookStore.RecordRow] {
        guard !files.isEmpty,files.count<=4096,Set(files.keys)==Set((0..<files.count).map(path)) else {throw NotebookError.invalidModel}
        return try decode(count:files.count) {files[path($0)]!}
    }
    static func decode(count:Int,expectedRows:[Int]? = nil,load:(Int)throws->Data) throws -> [NotebookStore.RecordRow] {
        guard (1...4096).contains(count),expectedRows == nil || expectedRows?.count==count else {throw NotebookError.invalidModel}
        var rows:[NotebookStore.RecordRow]=[],raw=0,encoded=0,keys=Set<String>()
        for index in 0..<count {
          try autoreleasepool {
            try Task.checkCancellation();let bytes=try load(index)
            guard bytes.count<=768_000_000-encoded else {throw NotebookError.invalidAsset};encoded+=bytes.count
            try ImportValidation.validateJSON(bytes,maximum:24_000_000)
            let chunk=try JSONDecoder().decode([NotebookStore.RecordRow].self,from:bytes)
            guard !chunk.isEmpty,chunk.count<=256,chunk.count<=1_000_000-rows.count,expectedRows == nil || expectedRows?[index]==chunk.count else {throw NotebookError.invalidAsset}
            var payload=0
            for row in chunk {
                let size=try rawSize(row)
                guard keys.insert(row.key).inserted,size<=576_000_000-raw,row.payload.count<=16_000_000-payload else {throw NotebookError.invalidAsset}
                raw+=size;payload+=row.payload.count
                try ImportValidation.validateJSON(row.payload)
            }
            rows.append(contentsOf:chunk)
          }
        }
        return rows
    }
}
