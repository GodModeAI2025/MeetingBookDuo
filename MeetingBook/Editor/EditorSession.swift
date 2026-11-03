import Foundation
import Observation
import MeetingBookCore

@MainActor @Observable final class EditorSession {
    enum Mode: String, CaseIterable { case reading, typing, drawing, selecting }
    enum SaveState: Equatable { case saved, dirty, saving, failed(String), conflict }
    struct Draft { var content: PageContent;var generation: UInt64=0;var state: SaveState = .saved;var markedText=false }
    struct Preview { let snapshot: NoteSnapshot;let contents: [UUID:PageContent];let reason: RevisionReason;let generations: [UUID:UInt64] }
    struct DraftLease: Sendable { let pageID: UUID;let baseRevisionID: UUID;let generation: UInt64;let content: PageContent }
    private struct Action {
        let before: NoteSnapshot;let after: NoteSnapshot
        let beforeSelection: TextSelection?;var afterSelection: TextSelection?
    }
    #if DEBUG
    var lastPaginationMS:Double?
    #endif
    let store: NotebookStore
    private(set) var snapshot: NoteSnapshot { didSet {refreshProtection()} }
    private(set) var drafts: [UUID:Draft] { didSet {refreshProtection()} }
    private(set) var activePageID: UUID
    private(set) var mode: Mode = .reading
    private(set) var isUnavailable=false
    var largerReadingView=false
    var selectedElementID: UUID?
    struct TextSelection {let pageID: UUID;let blockID: UUID;let range: NSRange}
    @ObservationIgnored var textSelection: TextSelection?
    @ObservationIgnored var pendingTextSelection: TextSelection?
    var activeRegionID: UUID?
    var selectedFontVersionID: UUID?
    var textDefaults=TextDefaults()
    private(set) var pendingAssetWrites: [UUID:UUID]=[:]
    /// Session-owned publication epochs also invalidate receipts held by old controllers.
    private var assetEpochs: [UUID:UInt64]=[:]
    private var assetWriteEpochs: [UUID:UInt64]=[:]
    var fingerDrawing=false
    private var activeStroke=false
    var strokeActive:Bool {
        get {activeStroke}
        set {store.protection.locked {activeStroke=newValue;refreshProtection()}}
    }
    var navigationLocked=false
    var retainsTypingFocusDuringTurn=false
    private(set) var busy=false
    private var textCommitTask: Task<Void,Error>?
    private struct Pagination {
        let pageID: UUID
        let blockID: UUID
        var continuationIDs: [UUID]=[]
        var undoIndex: Int?
    }
    private var pagination: Pagination? {didSet {refreshProtection()}}
    @ObservationIgnored private var textCommitWaiters: [UUID:CheckedContinuation<Void,Error>]=[:]
    private(set) var frozenPageIDs: Set<UUID>=[]
    private(set) var errorMessage: String?
    private(set) var versions: [FontVersion]=[]
    private var history: [Action]=[] { didSet {refreshProtection()} }
    @ObservationIgnored private var storageLease: StorageLease?
    @ObservationIgnored private var publicationLeases:[UUID:StorageLease]=[:]
    private var cursor=0
    private var retainedHeads: [UUID:UUID]=[:]
    @ObservationIgnored var didCommit: ((NoteSnapshot) -> Void)?
    @ObservationIgnored private var autosave: Task<Void,Never>?
    var canUndo: Bool { cursor>0 && !busy }
    var canRedo: Bool { cursor<history.count && !busy }
    private var activeTextSelection: TextSelection? {
        guard mode == .typing,let textSelection,selectedElementID == textSelection.blockID,activePageID == textSelection.pageID else {return nil}
        return textSelection
    }
    var activeContent: PageContent { drafts[activePageID]!.content }
    var saveState: SaveState { drafts[activePageID]?.state ?? .saved }
    /// A dirty/marked/stroking page is leased by this window and must never be replaced by sync.
    var leasedPageIDs: Set<UUID> { Set(drafts.filter { $0.value.state != .saved || $0.value.markedText }.keys).union(strokeActive ? [activePageID] : []).union(pagination.map {[$0.pageID]+$0.continuationIDs} ?? []) }
    var draftLeases: [DraftLease] {
        snapshot.pages.compactMap { page in
            guard leasedPageIDs.contains(page.id),let draft=drafts[page.id] else { return nil }
            return DraftLease(pageID:page.id,baseRevisionID:page.currentRevisionID,generation:draft.generation,content:draft.content)
        }
    }
    var draftSnapshot: NoteSnapshot {
        NoteSnapshot(note:snapshot.note,pages:snapshot.pages.map { page in var p=page;p.content=drafts[p.id]?.content ?? p.content;return p })
    }
    func beginAssetWrite(pageID: UUID) -> UUID { let token=UUID();publicationLeases[token]=store.protection.retain(draftPages:[pageID],blocksCollection:true);pendingAssetWrites[token]=pageID;assetWriteEpochs[token]=assetEpochs[pageID,default:0];return token }
    func endAssetWrite(_ token: UUID) { publicationLeases.removeValue(forKey:token);pendingAssetWrites.removeValue(forKey:token);assetWriteEpochs.removeValue(forKey:token) }
    var hasCurrentAssetWrites: Bool { pendingAssetWrites.contains { assetWriteEpochs[$0.key] == assetEpochs[$0.value,default:0] } }
    func completeDrawingWrite(_ token: UUID, hash: String) -> Bool {
        guard let id=pendingAssetWrites[token],assetWriteEpochs[token] == assetEpochs[id,default:0],var content=drafts[id]?.content else { return false }
        guard content.drawingAssetHash != hash else { return true }
        content.drawingAssetHash=hash;setDraft(content,pageID:id);return true
    }
    init(store: NotebookStore, snapshot: NoteSnapshot,lease: StorageLease? = nil) {
        precondition(!snapshot.pages.isEmpty)
        self.store=store;self.snapshot=snapshot;activePageID=snapshot.pages[0].id
        drafts=Dictionary(uniqueKeysWithValues:snapshot.pages.map { ($0.id,Draft(content:$0.content)) })
        retainedHeads=Dictionary(uniqueKeysWithValues:snapshot.pages.map { ($0.id,$0.currentRevisionID) })
        storageLease=lease ?? store.protection.retain();refreshProtection()
    }
    private func refreshProtection() {
        let pages=snapshot.pages+history.flatMap{$0.before.pages+$0.after.pages}
        let hashes=pages.reduce(into:Set<String>()){$0.formUnion($1.content.assetHashes)}.union(drafts.values.reduce(into:Set<String>()){$0.formUnion($1.content.assetHashes)})
        storageLease?.update(hashes:hashes,revisions:Set(pages.map(\.currentRevisionID)),draftPages:leasedPageIDs,remotePages:Set(history.flatMap{$0.before.pages+$0.after.pages}.map(\.id)))
    }
    func loadFonts() async {
        textDefaults=await store.preferences().textDefaults ?? TextDefaults()
        selectedFontVersionID=textDefaults.fontVersionID
        let published: [FontVersion]
        do {published=try await store.fontVersions()} catch {errorMessage=error.localizedDescription;return}
        let service=PersonalFontService(assets:store.assets)
        for version in published {
            do { try await service.register(version:version) }
            catch { errorMessage=error.localizedDescription }
        }
        versions=published
    }
    func setMode(_ mode: Mode) async throws {
        guard !isUnavailable || mode == .reading else {throw NotebookError.notFound}
        if mode == .drawing && self.mode != .drawing { try await leave() }
        self.mode=mode
    }
    func setBookmark(pageID: UUID,value: Bool) async throws {
        try await store.setBookmark(pageID:pageID,value:value)
        if let index=snapshot.pages.firstIndex(where:{$0.id==pageID}) { var pages=snapshot.pages;pages[index].bookmark=value;snapshot=NoteSnapshot(note:snapshot.note,pages:pages) }
    }
    func select(pageID: UUID) {
        guard !strokeActive, drafts[pageID] != nil else { return }
        activePageID=pageID;selectedElementID=nil;activeRegionID=nil;pendingTextSelection=nil
    }
    func setDraft(_ content: PageContent, pageID: UUID, markedText: Bool = false) {
        store.protection.locked {
            guard var draft=drafts[pageID] else { return }
            draft.content=content;draft.generation &+= 1;draft.state = isUnavailable ? .conflict : .dirty;draft.markedText=markedText;drafts[pageID]=draft
            autosave?.cancel()
            guard !markedText,!isUnavailable else { return }
            autosave=Task { [weak self] in
                do { try await Task.sleep(for:.milliseconds(500));try Task.checkCancellation();try await self?.flush() }
                catch is CancellationError {} catch { self?.errorMessage=error.localizedDescription }
            }
        }
    }
    func flush() async throws {
        if isUnavailable {if !leasedPageIDs.isEmpty {throw NotebookError.revisionConflict};return}
        if let task=textCommitTask {try await task.value}
        if let pending=pagination {try await commitText(blockID:pending.blockID,pageID:pending.pageID)}
        guard pagination == nil else {throw NotebookError.revisionConflict}
        guard !busy,!strokeActive,!hasCurrentAssetWrites else { throw EditorOperationError.inProgress }
        let dirty=drafts.filter { $0.value.state != .saved && !$0.value.markedText }
        guard !dirty.isEmpty else { return }
        #if DEBUG
        let paginationStart=ContinuousClock.now
        #endif
        for (id,draft) in dirty {
            for block in draft.content.textBlocks {
                if try paginationChunks(block:block,content:draft.content,pageID:id).count>1 {
                    try await commitText(blockID:block.id,pageID:id);try await flush();return
                }
            }
        }
        #if DEBUG
        let paginationDuration=paginationStart.duration(to:.now).components
        lastPaginationMS=Double(paginationDuration.seconds)*1000+Double(paginationDuration.attoseconds)/1e15
        #endif
        let changes=dirty.map { NoteChange.update(pageID:$0.key,content:$0.value.content,reason:.edit) }
        try await perform(changes)
    }
    func leave() async throws {
        guard !strokeActive,!drafts.values.contains(where: \.markedText) else { throw NotebookError.revisionConflict }
        while !pendingAssetWrites.isEmpty || busy { try await Task.sleep(for:.milliseconds(10)) }
        try await flush()
    }
    private func perform(_ changes: [NoteChange], recordUndo: Bool = true, basis: NoteSnapshot? = nil, importedFonts: [FontVersion] = [], completingAssetToken: UUID? = nil, continuingPagination: Bool = false) async throws {
        guard pagination == nil || continuingPagination else {throw EditorOperationError.inProgress}
        guard !busy,!strokeActive,!pendingAssetWrites.contains(where: { $0.key != completingAssetToken && assetWriteEpochs[$0.key] == assetEpochs[$0.value,default:0] }) else { throw EditorOperationError.inProgress }
        guard !drafts.values.contains(where: \.markedText) else { throw NotebookError.revisionConflict }
        for change in changes { assetEpochs[change.pageID,default:0] &+= 1 }
        let before=basis ?? snapshot
        let beforeSelection=clampedSelection(activeTextSelection,in:before)
        var edit=NoteEditTransaction(snapshot:before,changes:changes)
        edit.importedFonts=importedFonts
        for change in changes {
            if case .restore=change { edit.expectedRevisionIDs[change.pageID]=retainedHeads[change.pageID] }
        }
        let generations=drafts.mapValues(\.generation)
        busy=true;errorMessage=nil
        for change in changes where drafts[change.pageID] != nil { drafts[change.pageID]?.state = .saving }
        var completion:Result<Void,Error> = .success(())
        defer {
            busy=false
            let waiters=textCommitWaiters.values;textCommitWaiters=[:]
            for waiter in waiters {waiter.resume(with:completion)}
        }
        do {
            let receipt=try await store.commit(edit)
            snapshot=receipt.snapshot
            let touched=Set(changes.map(\.pageID))
            for page in receipt.snapshot.pages {
                retainedHeads[page.id]=page.currentRevisionID
                if drafts[page.id] != nil && !touched.contains(page.id) { continue }
                if let draft=drafts[page.id],draft.generation != generations[page.id] { drafts[page.id]?.state = .dirty }
                else { drafts[page.id]=Draft(content:page.content,generation:generations[page.id] ?? 0) }
            }
            for id in receipt.removedPageIDs { drafts.removeValue(forKey:id) }
            if drafts[activePageID] == nil { activePageID=snapshot.pages[0].id }
            if recordUndo {
                history=Array(history.prefix(cursor));history.append(Action(before:before,after:receipt.snapshot,beforeSelection:beforeSelection,afterSelection:clampedSelection(activeTextSelection,in:receipt.snapshot)))
                if history.count>100 { history.removeFirst(history.count-100) };cursor=history.count
            }
            didCommit?(receipt.snapshot)
        } catch {
            completion = .failure(error)
            errorMessage=error.localizedDescription
            for change in changes where drafts[change.pageID] != nil {
                drafts[change.pageID]?.state = (error as? NotebookError == .revisionConflict) ? .conflict : .failed(error.localizedDescription)
            }
            throw error
        }
    }
    func insert(templates: [TemplateInstance], after: UUID?) async throws {
        try await insert(contents:templates.map { var content=PageContent();content.template=$0;return content },after:after)
    }
    func insert(contents: [PageContent], after: UUID?) async throws {
        try await flush();var anchor=after;var changes: [NoteChange]=[]
        for content in contents {
            try content.validate()
            let id=UUID();changes.append(.insert(id:id,content:content,after:anchor));anchor=id
        }
        try await perform(changes)
    }
    func paste(content: PageContent, fonts: [FontVersion] = [],completingAssetToken: UUID? = nil) async throws {
        let anchor:UUID
        if let token=completingAssetToken {
            guard let page=pendingAssetWrites[token],assetWriteEpochs[token]==assetEpochs[page,default:0] else {throw NotebookError.revisionConflict};anchor=page
        } else {try await flush();anchor=activePageID}
        let service=PersonalFontService(assets:store.assets)
        for font in fonts { try await service.register(version:font) }
        for block in content.textBlocks { try TextBlockView(block:block,content:content,versions:versions+fonts).validateVisibleContent() }
        try await perform([.insert(id:UUID(),content:content,after:anchor)],importedFonts:fonts,completingAssetToken:completingAssetToken)
    }
    func importImage(_ data: Data) async throws {
        let pageID=activePageID,token=beginAssetWrite(pageID:activePageID)
        defer { endAssetWrite(token) }
        let imported=try await ImageImportService(assets:store.assets).importData(data)
        guard assetWriteEpochs[token] == assetEpochs[pageID,default:0],var content=drafts[pageID]?.content else { throw NotebookError.revisionConflict }
        content.prepareForEditing()
        let scale=min(608/Double(imported.width),600/Double(imported.height))
        var image=ImageElement(frame:.init(x:56,y:64,width:Double(imported.width)*scale,height:Double(imported.height)*scale),zIndex:(content.textBlocks.map(\.zIndex)+content.images.map(\.zIndex)).max().map { $0+1 } ?? 0,assetHash:imported.assetHash,altText:"")
        image.previewAssetHash=imported.previewAssetHash;content.images.append(image)
        try await perform([.update(pageID:pageID,content:content,reason:.edit)],completingAssetToken:token)
    }
    func setAltText(_ text: String) {
        var content=activeContent
        guard text.utf8.count<=10000,let index=content.images.firstIndex(where: { $0.id == selectedElementID }) else { return }
        content.images[index].altText=text;setDraft(content,pageID:activePageID)
    }
    func remove(pageID: UUID) async throws { try await flush();try await perform([.remove(pageID:pageID)]) }
    func clear(pageID: UUID) async throws {
        try await flush();guard var content=drafts[pageID]?.content else { throw NotebookError.notFound }
        content.textBlocks=[];content.images=[];content.drawingAssetHash=nil
        try await perform([.update(pageID:pageID,content:content,reason:.clear)])
    }
    func duplicate(pageID: UUID) async throws {
        try await flush();guard let content=drafts[pageID]?.content else { throw NotebookError.notFound }
        try await perform([.insert(id:UUID(),content:Self.freshIDs(content),after:pageID)])
    }
    static func freshIDs(_ content: PageContent) -> PageContent {
        var copy=content;copy.textBlocks=content.textBlocks.map { TextBlockView.copy($0,id:UUID()) }
        copy.images=content.images.map { item in var image=ImageElement(frame:item.frame,zIndex:item.zIndex,assetHash:item.assetHash,altText:item.altText);image.previewAssetHash=item.previewAssetHash;return image };return copy
    }
    func preview(pageIDs: Set<UUID>, transform: (inout PageContent) throws -> Void, reason: RevisionReason = .fontApply) throws -> Preview {
        guard !pendingAssetWrites.contains(where: { pageIDs.contains($0.value) && assetWriteEpochs[$0.key] == assetEpochs[$0.value,default:0] }) else { throw EditorOperationError.inProgress }
        guard !pageIDs.isEmpty,pageIDs.isSubset(of:Set(snapshot.note.pageIDs)),
              pageIDs.allSatisfy({ drafts[$0]?.state == .saved }) else { throw NotebookError.revisionConflict }
        var contents: [UUID:PageContent]=[:]
        for page in snapshot.pages where pageIDs.contains(page.id) {
            var content=drafts[page.id]!.content;content.prepareForEditing();try transform(&content);try validateNativeContent(content);contents[page.id]=content
        }
        return Preview(snapshot:snapshot,contents:contents,reason:reason,generations:drafts.mapValues(\.generation))
    }
    private func validateNativeContent(_ content: PageContent) throws {
        try content.validate()
        for block in content.textBlocks { try TextBlockView(block:block,content:content,versions:versions).validateVisibleContent() }
    }
    func apply(_ preview: Preview) async throws {
        guard !busy,!pendingAssetWrites.contains(where: { preview.contents[$0.value] != nil && assetWriteEpochs[$0.key] == assetEpochs[$0.value,default:0] }) else { throw EditorOperationError.inProgress }
        guard preview.generations == drafts.mapValues(\.generation),!drafts.values.contains(where: \.markedText) else { throw NotebookError.revisionConflict }
        for content in preview.contents.values { try validateNativeContent(content) }
        frozenPageIDs.formUnion(preview.contents.keys);defer { frozenPageIDs.subtract(preview.contents.keys) }
        try await perform(preview.contents.map { .update(pageID:$0.key,content:$0.value,reason:preview.reason) },basis:preview.snapshot)
    }
    private func awaitCurrentOperationForTextCommit() async throws {
        while busy || hasCurrentAssetWrites {
            if hasCurrentAssetWrites {try await Task.sleep(for:.milliseconds(10));continue}
            let id=UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation {textCommitWaiters[id]=$0}
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.textCommitWaiters.removeValue(forKey:id)?.resume(throwing:CancellationError())
                }
            }
        }
        try Task.checkCancellation()
    }
    private func paginationChunks(block: TextBlock,content: PageContent,pageID: UUID) throws -> [TextBlock] {
        if let saved=snapshot.pages.first(where: {$0.id == pageID})?.content,
           saved.template == content.template,saved.style.fontSize == content.style.fontSize,saved.style.ruling == content.style.ruling,
           var previous=saved.textBlocks.first(where: {$0.id == block.id}) {
            previous.ink=block.ink;previous.zIndex=block.zIndex
            // A saved trailing newline already has its continuation; unrelated edits must not create another.
            if previous == block,previous.text.utf8.elementsEqual(block.text.utf8) {return []}
        }
        return try TextBlockView.paginate(block:block,content:content,versions:versions)
    }
    func commitText(blockID: UUID, pageID: UUID) async throws {
        while let task=textCommitTask {try await task.value}
        guard let draft=drafts[pageID],draft.state != .saved,!draft.markedText,let block=draft.content.textBlocks.first(where: {$0.id == blockID}),
              try pagination != nil || paginationChunks(block:block,content:draft.content,pageID:pageID).count>1 else {return}
        if let pending=pagination, pending.pageID != pageID || pending.blockID != blockID {return}
        let task=Task { @MainActor in
            defer {self.textCommitTask=nil}
            try await self.awaitCurrentOperationForTextCommit()
            while let draft=self.drafts[pageID],draft.state != .saved,!draft.markedText,
                  let index=draft.content.textBlocks.firstIndex(where: {$0.id == blockID}) {
                var chunks=try self.pagination == nil
                    ? self.paginationChunks(block:draft.content.textBlocks[index],content:draft.content,pageID:pageID)
                    : TextBlockView.paginate(block:draft.content.textBlocks[index],content:draft.content,versions:self.versions)
                guard self.pagination != nil || chunks.count>1 else {return}
                let pending=self.pagination ?? Pagination(pageID:pageID,blockID:blockID)
                self.pagination=pending
                var content=draft.content;content.textBlocks[index]=chunks[0]
                var changes: [NoteChange]=[.update(pageID:pageID,content:content,reason:.edit)],anchor=pageID,ids=[UUID]()
                for offset in 1..<chunks.count {
                    var continuation=PageContent();continuation.version=2;continuation.template=content.template;continuation.style=content.style
                    if offset<=pending.continuationIDs.count {
                        let id=pending.continuationIDs[offset-1]
                        if let old=self.drafts[id]?.content.textBlocks.first {chunks[offset]=TextBlockView.copy(chunks[offset],id:old.id)}
                        continuation.textBlocks=[chunks[offset]]
                        changes.append(.update(pageID:id,content:continuation,reason:.edit));anchor=id
                    } else {
                        continuation.textBlocks=[chunks[offset]]
                        let id=UUID();changes.append(.insert(id:id,content:continuation,after:anchor));anchor=id
                    }
                    ids.append(anchor)
                }
                changes += pending.continuationIDs.dropFirst(ids.count).map { .remove(pageID:$0) }
                try await self.perform(changes,recordUndo:pending.undoIndex == nil,continuingPagination:true)
                let undoIndex=pending.undoIndex ?? self.cursor-1
                let action=self.history[undoIndex]
                self.history[undoIndex]=Action(before:action.before,after:self.snapshot,beforeSelection:action.beforeSelection,afterSelection:self.clampedSelection(self.activeTextSelection,in:self.snapshot))
                self.pagination=Pagination(pageID:pageID,blockID:blockID,continuationIDs:ids,undoIndex:undoIndex)
                // New native edits still contain the complete source string; reconcile only our own continuation pages.
                if self.drafts[pageID]?.generation != draft.generation {continue}
                self.pagination=nil
                var afterSelection=self.activeTextSelection
                if self.activePageID == pageID,self.selectedElementID == blockID {
                    var chunkIndex=chunks.count-1,range=NSRange(location:(chunks[chunkIndex].text as NSString).length,length:0)
                    if let selection=self.textSelection,selection.pageID == pageID,selection.blockID == blockID {
                        var offset=selection.range.location
                        for (index,chunk) in chunks.enumerated() {
                            let length=(chunk.text as NSString).length
                            if offset<length || index==chunks.count-1 {
                                chunkIndex=index;let location=min(offset,length)
                                range=NSRange(location:location,length:min(selection.range.length,length-location));break
                            }
                            offset -= length
                        }
                    }
                    self.activePageID=([pageID]+ids)[chunkIndex];self.selectedElementID=chunks[chunkIndex].id
                    self.pendingTextSelection=TextSelection(pageID:self.activePageID,blockID:chunks[chunkIndex].id,range:range)
                    afterSelection=self.pendingTextSelection
                }
                self.history[undoIndex].afterSelection=self.clampedSelection(afterSelection,in:self.snapshot)
                return
            }
        }
        textCommitTask=task
        try await task.value
    }
    private func restore(_ desired: NoteSnapshot) async throws {
        // String equality is normalization-insensitive; immutable payload history is not.
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard !drafts.values.contains(where: { $0.state != .saved || $0.markedText }) else { throw NotebookError.revisionConflict }
        let wanted=Set(desired.note.pageIDs),current=Set(snapshot.note.pageIDs)
        var changes=snapshot.note.pageIDs.filter { !wanted.contains($0) }.map { NoteChange.remove(pageID:$0) }
        var anchor: UUID?
        for page in desired.pages {
            if !current.contains(page.id) { changes.append(.restore(pageID:page.id,after:anchor)) }
            else if try encoder.encode(snapshot.pages.first(where: { $0.id == page.id })!.content) != encoder.encode(page.content) { changes.append(.update(pageID:page.id,content:page.content,reason:.recovery)) }
            anchor=page.id
        }
        // A saved no-op still has a history cursor, but needs no empty store transaction.
        if !changes.isEmpty { try await perform(changes,recordUndo:false) }
    }
    private func clampedSelection(_ selection: TextSelection?,in snapshot: NoteSnapshot) -> TextSelection? {
        guard let selection,let block=snapshot.pages.first(where: {$0.id == selection.pageID})?.content.textBlocks.first(where: {$0.id == selection.blockID}) else {return nil}
        let text=block.text as NSString
        var location=min(max(0,selection.range.location),text.length)
        let length=min(max(0,selection.range.length),text.length-location)
        if length == 0,location<text.length {location=text.rangeOfComposedCharacterSequence(at:location).location}
        let range=length == 0 ? NSRange(location:location,length:0) : text.rangeOfComposedCharacterSequences(for:NSRange(location:location,length:length))
        return TextSelection(pageID:selection.pageID,blockID:selection.blockID,range:range)
    }
    private func restoreSelection(_ selection: TextSelection?) {
        guard let selection=clampedSelection(selection,in:snapshot) else {return}
        activePageID=selection.pageID;selectedElementID=selection.blockID;textSelection=selection;pendingTextSelection=selection
    }
    func undo() async throws { guard canUndo else { return };guard !hasCurrentAssetWrites else { throw EditorOperationError.inProgress };try await restore(history[cursor-1].before);cursor -= 1;restoreSelection(history[cursor].beforeSelection) }
    func redo() async throws { guard canRedo else { return };guard !hasCurrentAssetWrites else { throw EditorOperationError.inProgress };try await restore(history[cursor].after);restoreSelection(history[cursor].afterSelection);cursor += 1 }
    /// Explicit user action only. Saved revisions remain in store history; in-memory Undo is retired.
    func retireUndoHistoryAfterConsent() throws {
        guard leasedPageIDs.isEmpty,!busy,!strokeActive,pendingAssetWrites.isEmpty else {throw TransferError.unsavedWindows}
        history=[];cursor=0
    }
    private func markUnavailable() {
        isUnavailable=true;mode = .reading;autosave?.cancel()
        for id in leasedPageIDs {drafts[id]?.state = .conflict}
        errorMessage=NotebookError.notFound.localizedDescription
    }
    func refresh() async throws {
        let capture:(snapshot:NoteSnapshot,lease:StorageLease)
        do {capture=try await store.captureNote(id:snapshot.note.id)}
        catch NotebookError.notFound {store.protection.locked {markUnavailable()};return}
        withExtendedLifetime(capture.lease) {
            store.protection.locked {
                let fresh=capture.snapshot,protected=leasedPageIDs
                if !protected.isEmpty || busy || hasCurrentAssetWrites || !history.isEmpty {
                    // Input arriving during capture keeps its original revision bases for emergency recovery.
                    for id in protected where fresh.note.pageIDs != snapshot.note.pageIDs || fresh.pages.first(where:{$0.id==id})?.currentRevisionID != snapshot.pages.first(where:{$0.id==id})?.currentRevisionID {drafts[id]?.state = .conflict}
                    if !Set(snapshot.note.pageIDs).isSubset(of:Set(fresh.note.pageIDs)) {markUnavailable()}
                    return
                }
                snapshot=fresh
                drafts=Dictionary(uniqueKeysWithValues:fresh.pages.map {($0.id,Draft(content:$0.content))})
                retainedHeads=Dictionary(uniqueKeysWithValues:fresh.pages.map {($0.id,$0.currentRevisionID)})
                if !fresh.note.pageIDs.contains(activePageID) {
                    activePageID=fresh.pages[0].id;selectedElementID=nil;activeRegionID=nil;textSelection=nil;pendingTextSelection=nil
                } else {
                    if let id=selectedElementID,!activeContent.textBlocks.contains(where:{$0.id==id}),!activeContent.images.contains(where:{$0.id==id}) {selectedElementID=nil}
                    if let id=activeRegionID,!activeContent.template.writingRegions.contains(where:{$0.id==id}) {activeRegionID=nil}
                    textSelection=clampedSelection(activeTextSelection,in:fresh);pendingTextSelection=clampedSelection(pendingTextSelection,in:fresh)
                    if pendingTextSelection?.pageID != activePageID || pendingTextSelection?.blockID != selectedElementID {pendingTextSelection=nil}
                }
                if isUnavailable {errorMessage=nil};isUnavailable=false
            }
        }
    }
}

enum EditorOperationError: LocalizedError {
    case inProgress
    var errorDescription: String? { String(localized:"Saving") }
}
