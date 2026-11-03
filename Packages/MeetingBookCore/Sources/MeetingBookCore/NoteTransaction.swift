import Foundation

public struct NoteSnapshot: Sendable, Equatable {
    public let note: Note
    public let pages: [PageSnapshot]
    public init(note: Note, pages: [PageSnapshot]) { self.note=note;self.pages=pages }
}
public enum NoteChange: Sendable {
    case update(pageID: UUID, content: PageContent, reason: RevisionReason)
    case insert(id: UUID, content: PageContent, after: UUID?)
    case remove(pageID: UUID)
    case restore(pageID: UUID, after: UUID?)
    public var pageID: UUID {
        switch self { case .update(let id,_,_),.insert(let id,_,_),.remove(let id),.restore(let id,_): id }
    }
    public var content: PageContent? {
        switch self { case .update(_,let content,_),.insert(_,let content,_): content;default:nil }
    }
}
public struct NoteEditTransaction: Sendable {
    public let noteID: UUID
    public let expectedPageIDs: [UUID]
    public var expectedRevisionIDs: [UUID:UUID]
    public var importedFonts: [FontVersion] = []
    public let changes: [NoteChange]
    public init(snapshot: NoteSnapshot, changes: [NoteChange]) {
        noteID=snapshot.note.id;expectedPageIDs=snapshot.note.pageIDs
        expectedRevisionIDs=Dictionary(uniqueKeysWithValues:snapshot.pages.map { ($0.id,$0.currentRevisionID) })
        self.changes=changes
    }
}
public struct NoteCommitReceipt: Sendable {
    public let snapshot: NoteSnapshot
    public let removedPageIDs: [UUID]
    public let savedAt: Date
    public let confirmedAssetHashes: Set<String>
    public init(snapshot: NoteSnapshot, removedPageIDs: [UUID], savedAt: Date, confirmedAssetHashes: Set<String>) {
        self.snapshot=snapshot;self.removedPageIDs=removedPageIDs;self.savedAt=savedAt;self.confirmedAssetHashes=confirmedAssetHashes
    }
}
