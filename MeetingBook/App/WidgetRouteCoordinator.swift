import Foundation
import Observation
import MeetingBookCore

enum WidgetRouteDestination:Equatable {case new,page(UUID),unavailable}

@MainActor @Observable final class WidgetRouteCoordinator {
    enum ChooserOwner:Equatable {case startup,user,route}
    var chooserPresented=false {didSet {if !chooserPresented {chooserOwner=nil}}}
    private(set) var chooserOwner:ChooserOwner?
    private(set) var processing=false
    private var retryRequested=false
    func presentChooser(_ owner:ChooserOwner) {chooserOwner=owner;chooserPresented=true}
    func beginAttempt(eligible:Bool) -> Bool {
        if processing {retryRequested=true;return false}
        guard eligible,pending != nil else {return false}
        processing=true;retryRequested=false;return true
    }
    func endAttempt() -> Bool {
        processing=false
        let retry=retryRequested && pending != nil;retryRequested=false
        return retry
    }
    private(set) var pending:MeetingBookRoute?
    private(set) var generation=UUID()
    private(set) var hasReceivedRoute=false
    func receive(_ route:MeetingBookRoute) {
        pending=route;generation=UUID();hasReceivedRoute=true
        if chooserOwner == .startup {chooserPresented=false}
        if processing {retryRequested=true}
    }
    func finish() {pending=nil}
    func resolve(store:NotebookStore?,leave:() async throws -> Void) async throws -> WidgetRouteDestination? {
        guard let store,let route=pending else {return nil}
        let token=generation
        try await leave()
        guard token==generation else {return nil}
        let destination=try await store.resolveWidgetRoute(route)
        guard token==generation else {return nil}
        return destination
    }
}

extension NotebookStore {
    func resolveWidgetRoute(_ route:MeetingBookRoute) throws -> WidgetRouteDestination {
        switch route {
        case .new:return .new
        case let .note(noteID,pageID):
            guard let note=library.notes.first(where:{$0.id==noteID && $0.deletedAt==nil}) else {return .unavailable}
            if note.pageIDs.contains(pageID) {return .page(pageID)}
            // A stale page may fall back; a page owned by another note must never do so.
            if try record(pageID.uuidString) != nil,try loadPage(pageID).noteID != noteID {return .unavailable}
            return note.pageIDs.first.map(WidgetRouteDestination.page) ?? .unavailable
        }
    }
    func widgetCapture(previewEnabled:Bool) throws -> (snapshot:WidgetSnapshot,guardValue:StorePublicationGuard) {
        try protection.locked {(try widgetSnapshot(previewEnabled:previewEnabled),protection.publicationGuard())}
    }
    /// Synchronous actor capture: library and page rows belong to the same committed graph.
    func widgetSnapshot(previewEnabled:Bool) throws -> WidgetSnapshot {
        try ensureCacheEpoch()
        guard library.ownership?.archived != true,library.ownership?.receiveOnly != true else {return WidgetSnapshot()}
        func target(_ id:UUID?) throws -> WidgetSnapshot.Target? {
            guard let id,let note=library.notes.first(where:{$0.deletedAt==nil && $0.pageIDs.contains(id)}) else {return nil}
            let preview:String?
            if previewEnabled {
                let page=try loadPage(id)
                var text=""
                for block in page.content.textBlocks {
                    if !text.isEmpty {text.append("\n")}
                    text.append(contentsOf:block.text.prefix(120))
                    text=WidgetSnapshot.boundedPreview(text)
                    if text.count>=120 || text.utf8.count>=12000 {break}
                }
                preview=text
            } else {preview=nil}
            return .init(noteID:note.id,pageID:id,preview:preview)
        }
        let ids=try bookmarkedIDs(),valid=Set(ids)
        let bookmark=library.bookmarkOrder?.last(where:{valid.contains($0)}) ?? ids.last
        return try WidgetSnapshot(previewEnabled:previewEnabled,last:target(library.preferences.lastPageID),bookmark:target(bookmark))
    }
}
