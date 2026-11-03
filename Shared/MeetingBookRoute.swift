import Foundation

/// Match the complete wire spelling, before URLComponents can normalize hostile input.
enum MeetingBookRoute: Equatable, Sendable {
    case new
    case note(noteID: UUID, pageID: UUID)
    static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 128 else { return nil }
        if text == "meetingbook://new" { return .new }
        let prefix="meetingbook://note/"
        guard text.hasPrefix(prefix) else { return nil }
        let parts=text.dropFirst(prefix.count).components(separatedBy:"?page=")
        guard parts.count==2,let note=canonicalUUID(parts[0]),let page=canonicalUUID(parts[1]) else {return nil}
        return .note(noteID:note,pageID:page)
    }
    private static func canonicalUUID(_ text:String) -> UUID? {
        guard text.utf8.count==36,let id=UUID(uuidString:text),id.uuidString.lowercased()==text else {return nil}
        return id
    }
    var url:URL {
        switch self {
        case .new: URL(string:"meetingbook://new")!
        case let .note(note,page): URL(string:"meetingbook://note/\(note.uuidString.lowercased())?page=\(page.uuidString.lowercased())")!
        }
    }
}
