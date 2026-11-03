import SwiftUI
import MeetingBookCore

struct SearchHit: Identifiable, Sendable {
    let note: Note
    let pageID: UUID
    let snippet: String
    var id: UUID { pageID }
}

struct NotebookView: View {
    @Bindable var library: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var route=WidgetRouteCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var navigating=false
    @State private var book: BookPresentation?
    @State private var viewport=PaperViewportState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var didCollapseForSpread=false
    @State private var turn: (source: UIImage,destination: UIImage,editor: EditorSession,target: UUID,token: UUID)?
    @State private var sessions: [UUID:EditorSession]=[:]
    @State private var archivedSessions:[UUID:[UUID:EditorSession]]=[:]
    @State private var selection: UUID?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var openingID=UUID()
    @State private var session: EditorSession?
    @State private var query=""
    @State private var hits: [SearchHit]=[]
    @State private var scope="notes"
    @State private var addingPage=false
    @State private var newTitle=""
    @State private var studio=false
    @State private var settings=false
    @State private var syncSettings=false
    @State private var recovery=false
    @State private var coldRecovery=false
    @State private var importURL: URL?
    @State private var fontStudioToken=UUID()
    @State private var didStart=false
    @AppStorage("startup") private var startup="last"
    @AppStorage("haptics") private var haptics=false
    private var routeSheetPresented:Bool {studio || settings || syncSettings || recovery || coldRecovery || route.chooserPresented}
    private var notebook: some View {
        NavigationSplitView(columnVisibility:$columnVisibility,preferredCompactColumn:$compactColumn) {
            List(selection:$selection) {
                Section {
                    VStack(alignment:.leading,spacing:8) {
                        Image(systemName:"book.closed").font(library.notes.isEmpty ? .largeTitle : .title3).foregroundStyle(.tint)
                        if library.notes.isEmpty { Text("A place for your thoughts.").font(.title2).fontWeight(.medium) }
                        Text(library.syncScope?.enabled == true && library.syncScope?.accountFingerprint != nil ? LocalizedStringKey("Private notebook · optional iCloud transfer enabled") : LocalizedStringKey("Private. On your device.")).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical,library.notes.isEmpty ? 16 : 4)
                    TextField("Title",text:$newTitle)
                    Button("New note",systemImage:"square.and.pencil") { addingPage=false;route.presentChooser(.user) }.keyboardShortcut("n")
                }
                Section {
                    Picker("Show",selection:$scope) {
                        Text("Notes").tag("notes");Text("Bookmarks").tag("bookmarks");Text("Trash").tag("trash")
                    }.accessibilityIdentifier("notebook.scope")
                }
                Section(query.isEmpty ? LocalizedStringKey("Index") : LocalizedStringKey("Search results")) {
                    ForEach(hits) { hit in
                        Button { open(hit.pageID) } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Text(hit.note.title.isEmpty ? String(localized:"Untitled note") : hit.note.title).foregroundStyle(.primary)
                                Text("Page \(LibraryRules.displayNumbers(notes:library.notes)[hit.pageID] ?? 0)").font(.caption).foregroundStyle(.secondary)
                                if !query.isEmpty { Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }.tag(hit.pageID).accessibilityIdentifier("notebook.hit."+hit.pageID.uuidString).contextMenu {
                            if scope == "trash" { Button("Restore") { run { try await library.store?.restore(noteID:hit.note.id);try await library.reload();await search() } } }
                            else { Button("Move to Trash",role:.destructive) { run { if let draft=sessions[hit.note.id] { try await draft.leave() };try await library.store?.trash(noteID:hit.note.id);selection=nil;session=nil;try await library.reload();await search() } } }
                        }
                    }
                    if hits.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text(query.isEmpty ? LocalizedStringKey("No notes here") : LocalizedStringKey("No results"))
                                    .fixedSize(horizontal:false,vertical:true)
                            } icon: {Image(systemName:query.isEmpty ? "book" : "magnifyingglass")}
                        } description: {
                            Text(query.isEmpty ? LocalizedStringKey("Create a note to begin.") : LocalizedStringKey("Search titles and typed text. Drawings are not searched."))
                                .fixedSize(horizontal:false,vertical:true)
                        }
                    }
                }
            }.navigationTitle("MeetingBook").disabled(navigating)
            .searchable(text:$query,prompt:"Titles and typed text")
            .toolbar {
                ToolbarItemGroup(placement:.bottomBar) {
                    Button("Font Studio",systemImage:"character.cursor.ibeam") { studio=true }
                    Button("Export and recovery",systemImage:"square.and.arrow.up") { if library.store == nil { coldRecovery=true } else { recovery=true } }
                    Button("iCloud and recovery",systemImage:"icloud") { syncSettings=true }.accessibilityIdentifier("sync.settings")
                    Button("Settings",systemImage:"gearshape") { settings=true }
                }
            }
        } detail: {
            ZStack {
            if let session {
                NoteWorkspace(session:session,notes:library.notes,navigationPending:navigating,onSelect:open,onAdd:{addingPage=true;route.presentChooser(.user)},onBookmark:{ _ in library.bookmarkGeneration += 1;library.syncForeground() })
                    .allowsHitTesting(!navigating)
                    .id("\(session.store.identity)-\(library.restoreGeneration)-\(session.snapshot.note.id)")
                    .navigationTitle(session.snapshot.note.title.isEmpty ? String(localized:"Untitled note") : session.snapshot.note.title)
            } else {
                ContentUnavailableView("Your notebook",systemImage:"book.closed",description:Text("Choose a note from the index or create one."))
            }
            }.overlay(alignment:.topLeading) {
                ZStack(alignment:.topLeading) {
                    if let turn { FrozenPageTurn(source:turn.source,destination:turn.destination,reducedMotion:reducedMotion) { finishTurn() }.frame(width:turn.source.size.width,height:turn.source.size.height).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading) }
                    if navigating { VStack { HStack { Spacer();Button("Cancel page turn") { cancelTurn() }.buttonStyle(.borderedProminent) };Spacer();if turn == nil { ProgressView("Preparing page") };Spacer() }.padding() }
                }
            }.onPreferenceChange(BookPresentationPreference.self) { value in
                if let previous=book,let value,previous != value,navigating {traceNavigation("geometry old=\(previous) new=\(value)");cancelTurn()}
                book=value
                if value?.spread == true,!didCollapseForSpread {didCollapseForSpread=true;columnVisibility = .detailOnly}
            }
            .onPreferenceChange(PaperViewportPreference.self) {viewport.offset=$0}
        }
    }
    private var routedNotebook: some View {
        notebook
        .disabled(library.restoring || route.processing)
        .onChange(of:library.store?.identity) { old,new in
            cancelTurn();route.chooserPresented=false;studio=false;settings=false;recovery=false;importURL=nil
            if let old {archivedSessions[old]=sessions}
            sessions=new.flatMap{archivedSessions[$0]} ?? [:];session=nil;selection=nil
            Task {await search();await receiveRoute()}
        }
        .onChange(of:session?.isUnavailable) {_,_ in reconcileUnavailableSession()}
        .onChange(of:session?.activePageID) {_,id in if !navigating {selection=id}}
        .onChange(of:library.restoreGeneration) { _,_ in cancelTurn();sessions=[:];session=nil;selection=nil;Task { await search();await receiveRoute() } }
        .onOpenURL { url in
            if url.scheme?.lowercased()=="meetingbook" {
                guard let parsed=MeetingBookRoute.parse(url.absoluteString) else {library.error=String(localized:"This notebook link is invalid.");return}
                route.receive(parsed);cancelTurn();Task {await receiveRoute()}
            } else if url.isFileURL && url.pathExtension.lowercased()=="notebookpkg" {
                importURL=url;if library.store == nil { coldRecovery=true } else { recovery=true }
            }
        }
        .onChange(of:library.storeReady) {_,ready in if ready {Task {await receiveRoute();await start()}}}
        .onChange(of:library.restoring) {_,busy in if !busy {Task {await receiveRoute()}}}
        .onChange(of:scenePhase) {_,phase in if phase == .active {Task {library.syncForeground();await library.refreshWidget();await receiveRoute()}}}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.protectedDataDidBecomeAvailableNotification)) {_ in Task {library.syncForeground();await library.refreshWidget();await receiveRoute()}}
    }
    var body: some View {
        routedNotebook
        .sheet(isPresented:$coldRecovery,onDismiss:{importURL=nil}) { if let base=library.baseRoot { ColdRecoveryView(library:library,baseRoot:base,initialImportURL:importURL) } }
        .sheet(isPresented:$recovery,onDismiss:{importURL=nil}) { RecoveryView(library:library,session:session,sessions:Array(sessions.values),initialImportURL:importURL,archivedSessions:archivedSessions) }
        .sensoryFeedback(.selection,trigger:selection) { _,_ in haptics }
        .task { await library.open();await search();await receiveRoute();await start() }
        .task(id:query+scope+String(library.bookmarkGeneration)) { await search() }
        .onChange(of:routeSheetPresented) {_,shown in if !shown {Task {await receiveRoute()}}}
        .onChange(of:navigating) {_,busy in if !busy {Task {await receiveRoute()}}}
        .onChange(of:selection) { _,id in if let id,session?.activePageID != id { open(id) } }
        .sheet(isPresented:$route.chooserPresented) {
            if let store=library.store { TemplateChooser(store:store) { templates,selectedDefaults in
                var created: UUID?
                if addingPage,let session { try await session.insert(contents:templates,after:session.activePageID) }
                else { let result=try await store.createNote(title:newTitle,contents:templates);newTitle="";created=result.pages[0].id }
                if let size=templates.first?.style.fontSize {
                    var preferences=await store.preferences();preferences.version=2
                    var defaults=selectedDefaults;defaults.fontSize=size;preferences.textDefaults=defaults
                    do { try await store.savePreferences(preferences);await session?.loadFonts() } catch { library.error=error.localizedDescription }
                }
                do { try await library.reload();await search() } catch { library.error=error.localizedDescription }
                if let created { open(created) }
            } }
        }
        .sheet(isPresented:$studio) { if let store=library.store { FontStudio(store:store,didCommit:{library.syncForeground()}).onAppear { library.openFontStudios.insert(fontStudioToken) }.onDisappear { library.openFontStudios.remove(fontStudioToken) } } }
        .sheet(isPresented:$syncSettings) { SyncSettingsView(library:library) }
        .sheet(isPresented:$settings) { if let store=library.store { CustomizeView(store:store,session:session,library:library) } }
        .alert("Notebook error",isPresented:showingError) {
            Button("OK",role:.cancel) {}
            if route.pending != nil {Button("Retry link") {Task {await receiveRoute()}}}
            if library.store == nil { Button("Retry") { Task { await library.retry() } };Button("Recovery mode") { coldRecovery=true } }
        } message: { Text(library.error ?? "") }
    }
    private var showingError: Binding<Bool> {Binding(get:{library.error != nil},set:{if !$0 {library.error=nil}})}
    private func reconcileUnavailableSession() {
        guard let editor=session,editor.isUnavailable else {return}
        cancelTurn();library.error=editor.errorMessage
        if editor.leasedPageIDs.isEmpty,!editor.busy,!editor.hasCurrentAssetWrites,!editor.canUndo,!editor.canRedo {
            sessions.removeValue(forKey:editor.snapshot.note.id);session=nil;selection=nil;compactColumn = .sidebar
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { library.error=error.localizedDescription } } }
    private func traceNavigation(_ message: @autoclosure () -> String) {
        #if DEBUG
        let environment=ProcessInfo.processInfo.environment
        guard environment["MEETINGBOOK_TRACE_NAVIGATION"] == "1",
              let value=environment["MEETINGBOOK_TEST_LIBRARY"],let id=UUID(uuidString:value),
              let root=library.store?.root,
              let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {return}
        let expected=support.appendingPathComponent("UITestLibraries").appendingPathComponent(id.uuidString)
        guard root.standardizedFileURL == expected.standardizedFileURL,
              (try? root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false,
              (try? root.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else {return}
        NSLog("MB_NAV %@",message())
        #endif
    }
    private func open(_ id: UUID) {
        traceNavigation("request active=\(String(describing:session?.activePageID)) target=\(id) navigating=\(navigating) route=\(route.processing) global=\(LibraryRules.orderedNotes(library.notes).flatMap(\.pageIDs))")
        guard !navigating,!route.processing else { return }
        let sourceIsPresented=horizontalSizeClass == .regular || compactColumn == .detail
        let token=UUID();openingID=token;navigating=true
        Task {
            do {
                guard let store=library.store else { navigating=false;return }
                let old=session
                if let old,old.activePageID != id {
                    try await old.leave();traceNavigation("first-flush target=\(id)");guard openingID==token,library.store?.identity==store.identity else {return}
                    old.retainsTypingFocusDuringTurn=true;old.navigationLocked=true;await Task.yield();try await old.leave();traceNavigation("locked-flush target=\(id)")
                    guard openingID==token,library.store?.identity==store.identity else {return}
                }
                let page=try await store.openPage(id:id)
                guard openingID==token,library.store?.identity==store.identity else {return}
                let editor: EditorSession
                if let existing=sessions[page.noteID],existing.store.identity==store.identity {if existing.isUnavailable {try await existing.refresh()};editor=existing}
                else {
                    let capture=try await store.captureNote(id:page.noteID)
                    guard openingID==token,library.store?.identity==store.identity else {return}
                    editor=EditorSession(store:store,snapshot:capture.snapshot,lease:capture.lease);sessions[page.noteID]=editor;library.register(editor)
                }
                library.register(editor)
                await editor.loadFonts();guard openingID==token,library.store?.identity==store.identity else { return }
                if let old,old.activePageID != id,sourceIsPresented {
                    guard let presentation=book else {cancelTurn();return}
                    let source=try await NotebookFrozenRenderer.image(activeID:old.activePageID,notes:library.notes,sessions:sessions,store:store,presentation:presentation,offset:viewport.offset,enlarged:old.mode == .reading && old.largerReadingView)
                    let destinationViewport=Self.destinationViewport(from:old,to:editor,offset:viewport.offset)
                    let destination=try await NotebookFrozenRenderer.image(activeID:id,notes:library.notes,sessions:sessions,store:store,presentation:presentation,offset:destinationViewport.offset,enlarged:destinationViewport.enlarged)
                    guard openingID==token,library.store?.identity==store.identity else { return }
                    traceNavigation("render-ready target=\(id)")
                    turn=(source,destination,editor,id,token)
                } else { try await commitNavigation(editor:editor,id:id);navigating=false }
            } catch { guard openingID==token else {return};traceNavigation("error type=\(String(reflecting:type(of:error)))");cancelTurn();library.error=error.localizedDescription }
        }
    }
    static func destinationViewport(from source: EditorSession,to destination: EditorSession,offset: CGPoint) -> (offset: CGPoint,enlarged: Bool) {
        (source === destination ? offset : .zero,destination.mode == .reading && destination.largerReadingView)
    }
    private func cancelTurn() {
        traceNavigation("cancel active=\(String(describing:session?.activePageID)) rendering=\(turn != nil)")
        openingID=UUID();session?.retainsTypingFocusDuringTurn=false;session?.navigationLocked=false;turn=nil;navigating=false
        selection=session?.activePageID
    }
    private func finishTurn() {
        traceNavigation("finish active=\(String(describing:session?.activePageID))")
        guard let value=turn,value.token==openingID else { return }
        turn=nil
        Task { do {try await commitNavigation(editor:value.editor,id:value.target);navigating=false} catch {cancelTurn();library.error=error.localizedDescription} }
    }
    private func commitNavigation(editor: EditorSession,id: UUID) async throws {
        guard library.store?.identity==editor.store.identity else {throw NotebookError.revisionConflict}
        session?.retainsTypingFocusDuringTurn=false;editor.retainsTypingFocusDuringTurn=false
        session?.navigationLocked=false;editor.navigationLocked=false;editor.select(pageID:id);session=editor;selection=id;compactColumn = .detail
        traceNavigation("commit target=\(id)")
        sessions=sessions.filter { $0.key == editor.snapshot.note.id || !$0.value.leasedPageIDs.isEmpty || $0.value.busy || $0.value.hasCurrentAssetWrites || $0.value.canUndo || $0.value.canRedo }
        let original=editor.store
        editor.didCommit={ _ in Task { await library.localCommit(from:original);if library.store?.identity==original.identity {await search()} } }
        var p=await editor.store.preferences();p.lastPageID=id;try await editor.store.savePreferences(p)
        await library.refreshWidget()
    }
    private func receiveRoute() async {
        let eligible = !navigating && !routeSheetPresented && !library.restoring && library.storeReady && library.store != nil
        guard route.beginAttempt(eligible:eligible),let store=library.store else {return}
        let token=route.generation,departing=session,restoreEpoch=library.restoreGeneration
        func current() -> Bool {
            token==route.generation && library.store?.identity==store.identity && library.restoreGeneration==restoreEpoch && !library.restoring && library.storeReady
        }
        defer {
            departing?.navigationLocked=false
            let retry=route.endAttempt()
            if retry {Task {await receiveRoute()}}
        }
        do {
            let destination=try await route.resolve(store:store) {
                if let departing {try await departing.leave();departing.navigationLocked=true;try await departing.leave()}
            }
            guard current(),let destination else {return}
            switch destination {
            case .new: addingPage=false;route.presentChooser(.route)
            case .unavailable:
                session=nil;selection=nil;compactColumn = .sidebar
                library.error=String(localized:"This page is no longer available. Choose a note from the index.")
            case .page(let id):
                let page=try await store.openPage(id:id)
                guard current() else {return}
                let editor:EditorSession
                if let existing=sessions[page.noteID] {if existing.isUnavailable {try await existing.refresh()};editor=existing}
                else {let capture=try await store.captureNote(id:page.noteID);editor=EditorSession(store:store,snapshot:capture.snapshot,lease:capture.lease)}
                await editor.loadFonts()
                guard current() else {return}
                // Revalidate membership after all suspension points, before changing the window.
                guard try await store.resolveWidgetRoute(route.pending!) == .page(id) else {throw NotebookError.notFound}
                guard current() else {return}
                sessions[page.noteID]=editor;library.register(editor)
                try await commitNavigation(editor:editor,id:id)
            }
            if current() {route.finish();didStart=true}
        } catch {if current() {library.error=error.localizedDescription}}
    }
    private func start() async {
        guard !didStart,!route.hasReceivedRoute,library.storeReady,let store=library.store else { return };didStart=true
        if startup == "new" { route.presentChooser(.startup);return }
        let id: UUID?
        if startup == "bookmark" { do { id=try await store.latestBookmarkedPageID() } catch { library.error=error.localizedDescription;return } }
        else { id=await store.preferences().lastPageID }
        guard !route.hasReceivedRoute,library.store?.identity==store.identity else {return}
        if let id,library.notes.contains(where:{$0.deletedAt == nil && $0.pageIDs.contains(id)}) { open(id) }
    }
    private func search() async {
        guard let store=library.store else { return }
        let capturedQuery=query,capturedScope=scope,capturedGeneration=library.restoreGeneration
        do {
            let result=try await store.search(query:capturedQuery,scope:capturedScope)
            try Task.checkCancellation();guard capturedQuery==query,capturedScope==scope,library.store?.identity==store.identity,library.restoreGeneration==capturedGeneration else { return };hits=result
        } catch is CancellationError {} catch { guard library.store?.identity==store.identity,library.restoreGeneration==capturedGeneration else {return};library.error=error.localizedDescription }
    }
}

struct NoteWorkspace: View {
    @Bindable var session: EditorSession
    let notes: [Note]
    var navigationPending=false
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onBookmark: (UUID) -> Void
    @State private var readable=false
    @State private var customizing=false
    @State private var history=false
    @State private var destinations:[PageSnapshot]=[]
    @State private var error: String?
    var body: some View {
        SpreadWorkspace(session:session,notes:notes,navigationPending:navigationPending,onSelect:onSelect,onAdd:onAdd)
            .toolbar {
                ToolbarItemGroup(placement:.primaryAction) {
                  Group {
                    Button("Choose template",systemImage:"doc.badge.plus",action:onAdd).disabled(session.busy || session.hasCurrentAssetWrites)
                    Button("Bookmark",systemImage:session.snapshot.pages.first(where:{$0.id==session.activePageID})?.bookmark == true ? "bookmark.fill" : "bookmark") {
                        Task { do { let id=session.activePageID;let value=session.snapshot.pages.first(where:{$0.id==id})?.bookmark != true;try await session.setBookmark(pageID:id,value:value);onBookmark(id) } catch { self.error=error.localizedDescription } }
                    }
                    Menu("Reading and appearance",systemImage:"textformat") {
                        Button("Readable text",systemImage:"text.alignleft") { readable=true }
                        Button("Customize",systemImage:"slider.horizontal.3") { customizing=true }
                        Button("Page history",systemImage:"clock.arrow.circlepath") { history=true }.disabled(session.busy || session.hasCurrentAssetWrites)
                        ForEach(destinations) { page in Button("Page \(notes.flatMap(\.pageIDs).firstIndex(of:page.id).map{$0+1} ?? 0)") { onSelect(page.id) } }
                    }
                  }.disabled(navigationPending || session.navigationLocked)
                }
            }
            .sheet(isPresented:$readable) { NavigationStack { ScrollView { VStack(alignment:.leading,spacing:16) { ForEach(session.activeContent.textBlocks) { Text($0.text).frame(maxWidth:.infinity,alignment:.leading) };ForEach(session.activeContent.images) { Label($0.altText,systemImage:"photo") } }.padding().textSelection(.enabled) }.navigationTitle("Readable text").toolbar { Button("Done") { readable=false } } } }
            .task(id:session.activePageID) {
                do { let catalog=try TemplateCatalog.builtIn();let ids=catalog.entries.first{$0.id==session.activeContent.template.definitionID}?.navigationDestinationIDs ?? [];destinations=session.snapshot.pages.filter{ids.contains($0.content.template.definitionID)} } catch { self.error=error.localizedDescription }
            }
            .sheet(isPresented:$history) { RevisionHistoryView(session:session) }
            .sheet(isPresented:$customizing) { CustomizeView(store:session.store,session:session) }
            .alert("Notebook error",isPresented:Binding(get:{error != nil},set:{if !$0 { error=nil }})) { Button("OK",role:.cancel) {} } message: { Text(error ?? "") }
    }
}

@MainActor @Observable private final class PaperViewportState {
    var offset=CGPoint.zero
}
