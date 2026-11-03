import Foundation

/// The extension's complete data boundary. No store, path or font reference crosses it.
struct WidgetSnapshot:Codable,Sendable,Equatable {
    static let group="group.de.meetingbook.app"
    static var directory:URL? {FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group)?.appendingPathComponent("WidgetData",isDirectory:true)}
    static let kind="MeetingBookNotebook"
    static let filename="WidgetSnapshot-v1.json"
    static let maximumBytes=32*1024
    struct Target:Codable,Sendable,Equatable {
        let noteID:UUID
        let pageID:UUID
        let preview:String?
        var url:URL {MeetingBookRoute.note(noteID:noteID,pageID:pageID).url}
    }
    var schemaVersion=1
    var generation=UUID()
    var previewEnabled=false
    var last:Target?
    var bookmark:Target?
    enum Invalid:Error {case snapshot}
    func validate() throws {
        guard schemaVersion==1 else {throw Invalid.snapshot}
        for target in [last,bookmark].compactMap({$0}) {
            guard target.preview == nil || (previewEnabled && target.preview!.count<=120 && target.preview!.utf8.count<=12000) else {throw Invalid.snapshot}
        }
    }
    func encoded() throws -> Data {
        try validate();let data=try JSONEncoder().encode(self)
        guard data.count<=Self.maximumBytes else {throw Invalid.snapshot};return data
    }
    static func decode(_ data:Data) throws -> Self {
        guard data.count<=maximumBytes else {throw Invalid.snapshot}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys).isSubset(of:["schemaVersion","generation","previewEnabled","last","bookmark"]) else {throw Invalid.snapshot}
        for key in ["last","bookmark"] {
            if let raw=object[key],!(raw is NSNull) {
                guard let target=raw as? [String:Any],Set(target.keys).isSubset(of:["noteID","pageID","preview"]) else {throw Invalid.snapshot}
            }
        }
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    static func boundedPreview(_ text:String) -> String {
        var result=""
        for character in text.prefix(120) {
            let next=String(character)
            guard result.utf8.count+next.utf8.count<=12000 else {break}
            result.append(character)
        }
        return result
    }
    static func read(from directory:URL?) -> Self {
        guard let directory else {return Self()}
        do {
            let file=try FileHandle(forReadingFrom:directory.appendingPathComponent(filename));defer{try? file.close()}
            let data=try file.read(upToCount:maximumBytes+1) ?? Data()
            return try decode(data)
        } catch {return Self()}
    }
}
