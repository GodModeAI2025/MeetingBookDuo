import Foundation
public enum LibraryRules {
    public static func orderedNotes(_ notes: [Note], includeDeleted: Bool = false) -> [Note] { notes.filter { includeDeleted || $0.deletedAt == nil }.sorted { $0.orderKey == $1.orderKey ? $0.id.uuidString < $1.id.uuidString : $0.orderKey < $1.orderKey } }
    public static func displayNumbers(notes: [Note]) -> [UUID:Int] { Dictionary(uniqueKeysWithValues: orderedNotes(notes).flatMap(\.pageIDs).enumerated().map { ($0.element,$0.offset+1) }) }
    public static func spread(containing number: Int) -> (left: Int?, right: Int) { number <= 1 ? (nil,1) : (number / 2 * 2, number / 2 * 2 + 1) }
}
