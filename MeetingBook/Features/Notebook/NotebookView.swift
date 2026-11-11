import SwiftUI
import MeetingBookCore

struct SearchHit: Identifiable, Sendable {
    let note: Note
    let pageID: UUID
    let snippet: String
    var id: UUID { pageID }
}

struct NotebookView: View {
    @Environment(\.personalSymbols) private var personalSymbols
    @State private var cover=BookCoverPresentation()
    @State private var defaultCoverFont: Font?
    @Bindable var library: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var route=WidgetRouteCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var navigating=false
    @State private var book: BookPresentation?
    @State private var viewport=PaperViewportState()
    @State private var indexIsPresented=true
    @State private var namingNote=false
    @State private var turn: (source: UIImage,destination: UIImage,editor: EditorSession,target: UUID,token: UUID,native: PreparedLeaves?)?
    @Environment(\.displayScale) private var displayScale
    @State private var preparedLeaves: PreparedLeaves?
    @State private var interactiveTurn: LeafTurnTransaction?
    @State private var preparationEpoch=0
    @State private var sessions: [UUID:EditorSession]=[:]
    @State private var archivedSessions:[UUID:[UUID:EditorSession]]=[:]
    @State private var selection: UUID?
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
    @AppStorage("paper") private var defaultPaper="classic"
    @AppStorage("startup") private var startup="last"
    @AppStorage("haptics") private var haptics=false
    private var paperAppearance: PaperAppearance { PaperAppearance(activePaper:session?.activeContent.style.paper,defaultPaper:defaultPaper) }
    private var routeSheetPresented:Bool {studio || settings || syncSettings || recovery || coldRecovery || route.chooserPresented}
    private var indexPaper: some View {
        IndexPaperView(hits:hits,selection:selection,query:$query,scope:$scope,numbers:LibraryRules.displayNumbers(notes:library.notes),entryFont:coverFont,onSelect:open,onNew:{namingNote=true},onTrash:{ hit in
            run { if let draft=sessions[hit.note.id] { try await draft.leave() };try await library.store?.trash(noteID:hit.note.id);selection=nil;session=nil;indexIsPresented=true;try await library.reload();await search() }
        },onRestore:{ hit in
            run { try await library.store?.restore(noteID:hit.note.id);try await library.reload();await search() }
        },onClose:session == nil ? nil : {indexIsPresented=false},transferEnabled:library.syncScope?.enabled == true && library.syncScope?.accountFingerprint != nil,commands:AnyView(libraryCommands)).disabled(navigating)
    }
    private var libraryCommands: some View {
        Group {
            Button {cover.close()} label: {Label {Text("Close book")} icon: {AppSymbol.closeBook.image(in:personalSymbols)}}.accessibilityIdentifier("cover.close")
            Button { studio=true } label: { Label { Text("Font Studio") } icon: { AppSymbol.fontStudio.image(in:personalSymbols) } }
            Button { if library.store == nil { coldRecovery=true } else { recovery=true } } label: { Label { Text("Export and recovery") } icon: { AppSymbol.exportRecovery.image(in:personalSymbols) } }
            Button { syncSettings=true } label: { Label { Text("iCloud and recovery") } icon: { AppSymbol.cloudRecovery.image(in:personalSymbols) } }.accessibilityIdentifier("sync.settings")
            Button { settings=true } label: { Label { Text("Settings") } icon: { AppSymbol.settings.image(in:personalSymbols) } }
        }
    }
    private var cancelTurnButton: some View {
        Button(action:cancelTurn) {Label("Cancel page turn",systemImage:"xmark").frame(width:44,height:44).contentShape(Rectangle())}
            .labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size:18))
            .foregroundStyle(Color(uiColor:.darkText)).background(paperAppearance.color)
            .accessibilityIdentifier("notebook.cancelTurn").keyboardShortcut(.cancelAction)
    }
    @ViewBuilder private var cancelTurnControl: some View {
        if let book,let session {
            let pair=NotebookSearch.spreadIDs(active:session.activePageID,notes:library.notes)
            let index=book.spread && (indexIsPresented || pair.right == session.activePageID) ? 1 : 0
            let leaf=book.pages[index]
            cancelTurnButton.position(x:book.spread && index == 0 ? leaf.minX+26 : leaf.maxX-26,y:leaf.minY+LeafHitView.cornerHeight+30)
        } else {cancelTurnButton.frame(maxWidth:.infinity,alignment:.trailing).padding(4)}
    }
    private var notebook: some View {
        ZStack {
            paperAppearance.color.ignoresSafeArea()
            if let session {
                NoteWorkspace(session:session,notes:library.notes,navigationPending:navigating,indexIsPresented:indexIsPresented,indexPaper:AnyView(indexPaper),libraryCommands:AnyView(libraryCommands),onIndex:{indexIsPresented.toggle()},onSelect:open,onAdd:{addingPage=true;route.presentChooser(.user)},onBookmark:{ _ in library.bookmarkGeneration += 1;library.syncForeground() })
                    .allowsHitTesting(!navigating)
                    .id("\(session.store.identity)-\(library.restoreGeneration)-\(session.snapshot.note.id)")
            } else { indexPaper }
        }.paperSurface().overlay(alignment:.topLeading) {
            ZStack(alignment:.topLeading) {
                if let turn {
                    if let leaves=turn.native {
                        NativeLeafPager(leaves:leaves,destination:turn.target,onBegin:{_,_ in true},onFinish:{_,_,completed in if completed {finishTurn(token:turn.token)} else {cancelTurn()}})
                            .frame(width:leaves.plan.frame.width,height:leaves.plan.frame.height).offset(x:leaves.plan.frame.minX,y:leaves.plan.frame.minY).id(leaves.token)
                    } else {
                        FrozenPageTurn(source:turn.source,destination:turn.destination) { finishTurn(token:turn.token) }.frame(width:turn.source.size.width,height:turn.source.size.height)
                    }
                } else if let leaves=preparedLeaves {
                    NativeLeafPager(leaves:leaves,onBegin:beginInteractiveTurn,onFinish:finishInteractiveTurn)
                        .frame(width:leaves.plan.frame.width,height:leaves.plan.frame.height).offset(x:leaves.plan.frame.minX,y:leaves.plan.frame.minY).id(leaves.token)
                }
                if navigating {
                    if turn == nil && interactiveTurn == nil {ProgressView("Preparing page").frame(maxWidth:.infinity,maxHeight:.infinity)}
                    cancelTurnControl
                }
            }
        }.onPreferenceChange(BookPresentationPreference.self) { value in
            if let previous=book,let value,previous != value,navigating {traceNavigation("geometry old=\(previous) new=\(value)");cancelTurn()}
            book=value
        }
        .onPreferenceChange(PaperViewportPreference.self) {viewport.offset=$0}
        .task(id:leafPreparationKey) {await prepareLeaves()}
        .alert("New note",isPresented:$namingNote) {
            TextField("Title",text:$newTitle)
            Button("Choose template") {addingPage=false;route.presentChooser(.user)}
            Button("Cancel",role:.cancel) {newTitle=""}
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
                cover.open();route.receive(parsed);cancelTurn();Task {await receiveRoute()}
            } else if url.isFileURL && url.pathExtension.lowercased()=="notebookpkg" {
                cover.open();importURL=url;if library.store == nil { coldRecovery=true } else { recovery=true }
            }
        }
        .onChange(of:library.storeReady) {_,ready in if ready {Task {await receiveRoute();await start()}}}
        .onChange(of:library.restoring) {_,busy in if !busy {Task {await receiveRoute()}}}
        .onChange(of:scenePhase) {_,phase in if phase == .active {Task {library.syncForeground();await library.refreshWidget();await receiveRoute()}} else {cancelTurn()}}
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.protectedDataDidBecomeAvailableNotification)) {_ in Task {library.syncForeground();await library.refreshWidget();await receiveRoute()}}
    }
    var body: some View {
        routedNotebook
        .bookCoverShield()
        .background {NotebookHingeObserver(presentation:cover).frame(width:1,height:1)}
        .sheet(isPresented:$coldRecovery,onDismiss:{importURL=nil}) { if let base=library.baseRoot { ColdRecoveryView(library:library,baseRoot:base,initialImportURL:importURL).bookCoverShield(allowInitiallyClosed:true) } }
        .sheet(isPresented:$recovery,onDismiss:{importURL=nil}) { RecoveryView(library:library,session:session,sessions:Array(sessions.values),initialImportURL:importURL,archivedSessions:archivedSessions).bookCoverShield(allowInitiallyClosed:true) }
        .sensoryFeedback(.selection,trigger:selection) { _,_ in haptics }
        .onChange(of:cover.isOpen) {_,opened in
            if opened {Task {await start()}}
            else {cancelTurn();Task {do {try await session?.flush()} catch {library.error=error.localizedDescription}}}
        }
        .task { await library.open();await search();await receiveRoute();await start() }
        .task(id:library.store?.identity) {await loadCoverFont()}
        .onChange(of:settings) {_,shown in if !shown {Task {await loadCoverFont()}}}
        .task(id:query+scope+String(library.bookmarkGeneration)) { await search() }
        .onChange(of:routeSheetPresented) {_,shown in if !shown {Task {await receiveRoute()}}}
        .onChange(of:navigating) {_,busy in if !busy {preparationEpoch += 1;Task {await receiveRoute()}}}
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
            }.bookCoverShield() }
        }
        .sheet(isPresented:$studio) { if let store=library.store { FontStudio(store:store,didCommit:{library.syncForeground()}).bookCoverShield().onAppear { library.openFontStudios.insert(fontStudioToken) }.onDisappear { library.openFontStudios.remove(fontStudioToken) } } }
        .sheet(isPresented:$syncSettings) { SyncSettingsView(library:library).bookCoverShield() }
        .sheet(isPresented:$settings) { if let store=library.store { CustomizeView(store:store,session:session,library:library).bookCoverShield() } }
        .alert("Notebook error",isPresented:showingError) {
            Button("OK",role:.cancel) {}
            if route.pending != nil {Button("Retry link") {Task {await receiveRoute()}}}
            if library.store == nil { Button("Retry") { Task { await library.retry() } };Button("Recovery mode") { coldRecovery=true } }
        } message: { Text(library.error ?? "") }
        .environment(\.coverPresentation,cover)
        .environment(\.coverTitleFont,coverFont)
        .paperContext(paperAppearance)
        .preferredColorScheme(cover.isOpen ? .light : .dark)
    }
    private var coverFont: Font {
        if session == nil,let defaultCoverFont {return defaultCoverFont}
        let defaults=session?.textDefaults ?? TextDefaults()
        let font=HandwritingFontCatalog.font(catalogID:defaults.fontCatalogID ?? "bundled.caveat",personalVersion:session?.versions.first{$0.id==defaults.fontVersionID},size:38)
        return .custom(font.fontName,size:38,relativeTo:.largeTitle)
    }
    private func loadCoverFont() async {
        guard let store=library.store else {return}
        let defaults=await store.preferences().textDefaults ?? TextDefaults()
        var version:FontVersion?
        if let id=defaults.fontVersionID {
            do {
                version=try await store.fontVersions().first{$0.id==id}
                if let version {try await PersonalFontService(assets:store.assets).register(version:version)}
            } catch {version=nil}
        }
        guard library.store?.identity==store.identity else {return}
        let font=HandwritingFontCatalog.font(catalogID:defaults.fontCatalogID ?? "bundled.caveat",personalVersion:version,size:38)
        defaultCoverFont = .custom(font.fontName,size:38,relativeTo:.largeTitle)
    }
    private var showingError: Binding<Bool> {Binding(get:{library.error != nil},set:{if !$0 {library.error=nil}})}
    private func reconcileUnavailableSession() {
        guard let editor=session,editor.isUnavailable else {return}
        cancelTurn();library.error=editor.errorMessage
        if editor.leasedPageIDs.isEmpty,!editor.busy,!editor.hasCurrentAssetWrites,!editor.canUndo,!editor.canRedo {
            sessions.removeValue(forKey:editor.snapshot.note.id);session=nil;selection=nil;indexIsPresented=true
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
    private func open(_ id: UUID) { navigate(id,animated:true) }
    private func navigate(_ id: UUID,animated: Bool) {
        traceNavigation("request active=\(String(describing:session?.activePageID)) target=\(id) navigating=\(navigating) route=\(route.processing) global=\(LibraryRules.orderedNotes(library.notes).flatMap(\.pageIDs))")
        guard !navigating,!route.processing else { return }
        let sourceIsPresented = !indexIsPresented
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
                if let old,old.activePageID != id,sourceIsPresented,animated,let presentation=book,
                   LeafTurnPlan(active:old.activePageID,notes:library.notes,presentation:presentation).direction(to:id) != nil {
                    let key=LeafPreparationKey(store:store.identity,restore:library.restoreGeneration,revision:library.bookmarkGeneration,active:old.activePageID,presentation:presentation,offset:viewport.offset,enlarged:old.mode == .reading && old.largerReadingView,density:displayScale,contents:[:],dynamicType:typeSize)
                    let source: UIImage,destination: UIImage,native: PreparedLeaves?
                    if reducedMotion || !LeafTurnPlan(active:old.activePageID,notes:library.notes,presentation:presentation).supportsCurl {
                        source=try await NotebookFrozenRenderer.image(activeID:old.activePageID,notes:library.notes,sessions:sessions,store:store,presentation:presentation,offset:viewport.offset,enlarged:key.enlarged,density:displayScale,dynamicType:typeSize)
                        let destinationViewport=Self.destinationViewport(from:old,to:editor,offset:viewport.offset)
                        destination=try await NotebookFrozenRenderer.image(activeID:id,notes:library.notes,sessions:sessions,store:store,presentation:presentation,offset:destinationViewport.offset,enlarged:destinationViewport.enlarged,density:displayScale,dynamicType:typeSize)
                        native=nil
                    } else {
                        source=UIImage();destination=UIImage()
                        native=try await NotebookFrozenRenderer.leaves(key:key,notes:library.notes,sessions:sessions,store:store,destination:id)
                    }
                    guard openingID==token,library.store?.identity==store.identity,book==presentation else {return}
                    turn=(source,destination,editor,id,token,native)
                } else { try await commitNavigation(editor:editor,id:id);navigating=false }
            } catch { guard openingID==token else {return};traceNavigation("error type=\(String(reflecting:type(of:error)))");cancelTurn();library.error=error.localizedDescription }
        }
    }
    static func destinationViewport(from source: EditorSession,to destination: EditorSession,offset: CGPoint) -> (offset: CGPoint,enlarged: Bool) {
        (source === destination ? offset : .zero,destination.mode == .reading && destination.largerReadingView)
    }
    private func cancelTurn() {
        traceNavigation("cancel active=\(String(describing:session?.activePageID)) rendering=\(turn != nil)")
        openingID=UUID();session?.retainsTypingFocusDuringTurn=false;session?.navigationLocked=false;turn=nil;interactiveTurn=nil;preparedLeaves=nil;navigating=false;preparationEpoch += 1
        selection=session?.activePageID
    }
    static func canPrepareLeafTurn(_ session: EditorSession) -> Bool {
        !session.isUnavailable && !session.busy && !session.hasCurrentAssetWrites && !session.strokeActive &&
            session.drafts.values.allSatisfy {$0.state == .saved && !$0.markedText}
    }
    private var leafPreparationKey: LeafPreparationKey? {
        guard cover.isOpen,scenePhase == .active,!reducedMotion,!indexIsPresented,let book,let session,
              Self.canPrepareLeafTurn(session),LeafTurnPlan(active:session.activePageID,notes:library.notes,presentation:book).supportsCurl,book.pages.allSatisfy({$0.width>0 && $0.height>0}),!library.restoring,!route.processing else {return nil}
        var key=LeafPreparationKey(store:session.store.identity,restore:library.restoreGeneration,revision:library.bookmarkGeneration,active:session.activePageID,presentation:book,offset:viewport.offset,enlarged:session.mode == .reading && session.largerReadingView,density:displayScale,contents:sessions.values.reduce(into:[:]) {result,editor in for (id,draft) in editor.drafts {result[id]=draft.content}},notes:library.notes,dynamicType:typeSize,broadEdges:session.mode == .reading)
        key.epoch=preparationEpoch
        return key
    }
    private func prepareLeaves() async {
        if interactiveTurn != nil {cancelTurn();return}
        preparedLeaves=nil
        guard !navigating,let key=leafPreparationKey,let store=library.store else {return}
        do {
            let leaves=try await NotebookFrozenRenderer.leaves(key:key,notes:library.notes,sessions:sessions,store:store)
            try Task.checkCancellation()
            guard key==leafPreparationKey,!navigating else {return}
            preparedLeaves=leaves
            traceNavigation("native-ready source=\(key.active) token=\(leaves.token)")
        } catch is CancellationError {} catch {if key==leafPreparationKey {library.error=error.localizedDescription}}
    }
    private func beginInteractiveTurn(token: UUID,target: UUID) -> Bool {
        guard !navigating,let leaves=preparedLeaves,leaves.token==token,leaves.key==leafPreparationKey,
              leaves.plan.direction(to:target) != nil,let session,!session.navigationLocked else {return false}
        traceNavigation("native-begin source=\(session.activePageID) target=\(target) token=\(token)")
        openingID=token;interactiveTurn=LeafTurnTransaction(token:token,source:session.activePageID,target:target)
        session.retainsTypingFocusDuringTurn=true;session.navigationLocked=true;navigating=true
        return true
    }
    private func finishInteractiveTurn(token: UUID,target: UUID,completed: Bool) {
        guard token==openingID,var transaction=interactiveTurn,transaction.target==target,transaction.source==session?.activePageID else {return}
        traceNavigation("native-result source=\(transaction.source) target=\(target) completed=\(completed)")
        let destination=transaction.finish(token:token,completed:completed)
        interactiveTurn=transaction
        guard let destination else {cancelTurn();return}
        interactiveTurn=nil;navigating=false;session?.navigationLocked=false
        navigate(destination,animated:false)
    }
    private func finishTurn(token: UUID) {
        traceNavigation("finish active=\(String(describing:session?.activePageID))")
        guard let value=turn,value.token==token,value.token==openingID else { return }
        turn=nil
        Task { do {guard openingID==token else {return};try await commitNavigation(editor:value.editor,id:value.target);guard openingID==token else {return};navigating=false} catch {cancelTurn();library.error=error.localizedDescription} }
    }
    private func commitNavigation(editor: EditorSession,id: UUID) async throws {
        guard library.store?.identity==editor.store.identity else {throw NotebookError.revisionConflict}
        session?.retainsTypingFocusDuringTurn=false;editor.retainsTypingFocusDuringTurn=false
        session?.navigationLocked=false;editor.navigationLocked=false;editor.select(pageID:id);session=editor;selection=id;if book?.spread != true {indexIsPresented=false}
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
                session=nil;selection=nil;indexIsPresented=true
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
        guard !didStart,!route.hasReceivedRoute,library.storeReady,let store=library.store else { return }
        if startup == "new",!cover.isOpen {return}
        didStart=true
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
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var personalSymbols
    @Bindable var session: EditorSession
    let notes: [Note]
    var navigationPending=false
    var indexIsPresented=false
    var indexPaper: AnyView? = nil
    var libraryCommands: AnyView? = nil
    var onIndex: (() -> Void)? = nil
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onBookmark: (UUID) -> Void
    @State private var readable=false
    @State private var customizing=false
    @State private var history=false
    @State private var destinations:[PageSnapshot]=[]
    @State private var error: String?
    var body: some View {
        SpreadWorkspace(session:session,notes:notes,navigationPending:navigationPending,indexIsPresented:indexIsPresented,indexPaper:indexPaper,onIndex:onIndex,bookmarkButton:AnyView(bookmarkButton),workspaceCommands:AnyView(workspaceCommands),libraryCommands:libraryCommands,onSelect:onSelect,onAdd:onAdd)
            .sheet(isPresented:$readable) { NavigationStack { ScrollView { VStack(alignment:.leading,spacing:16) { ForEach(session.activeContent.textBlocks) { Text($0.text).frame(maxWidth:.infinity,alignment:.leading) };ForEach(session.activeContent.images) { Label($0.altText,systemImage:"photo") } }.padding().textSelection(.enabled) }.paperSurface().navigationTitle("Readable text").toolbar { Button("Done") { readable=false } } }.bookCoverShield() }
            .task(id:session.activePageID) {
                do { let catalog=try TemplateCatalog.builtIn();let ids=catalog.entries.first{$0.id==session.activeContent.template.definitionID}?.navigationDestinationIDs ?? [];destinations=session.snapshot.pages.filter{ids.contains($0.content.template.definitionID)} } catch { self.error=error.localizedDescription }
            }
            .sheet(isPresented:$history) { RevisionHistoryView(session:session).bookCoverShield() }
            .sheet(isPresented:$customizing) { CustomizeView(store:session.store,session:session).bookCoverShield() }
            .alert("Notebook error",isPresented:Binding(get:{error != nil},set:{if !$0 { error=nil }})) { Button("OK",role:.cancel) {} } message: { Text(error ?? "") }
    }
    private var bookmarkButton: some View {
                    Button {
                        Task { do { let id=session.activePageID;let value=session.snapshot.pages.first(where:{$0.id==id})?.bookmark != true;try await session.setBookmark(pageID:id,value:value);onBookmark(id) } catch { self.error=error.localizedDescription } }
                    } label: { Label { Text("Bookmark") } icon: { AppSymbol.bookmark.image(in:personalSymbols,selected:session.snapshot.pages.first(where:{$0.id==session.activePageID})?.bookmark == true) }.frame(minWidth:44,minHeight:44).contentShape(Rectangle()) }
        .frame(minWidth:44,minHeight:44).accessibilityIdentifier("editor.bookmark")
        .disabled(session.isUnavailable || navigationPending || session.navigationLocked)
    }
    private var workspaceCommands: some View {
        Group {
                    Button(action:onAdd) {Label {Text("Choose template")} icon: {AppSymbol.addPage.image(in:personalSymbols)}}.disabled(session.busy || session.hasCurrentAssetWrites)
                    Group {
                        Button { readable=true } label: { Label { Text("Readable text") } icon: { AppSymbol.readableText.image(in:personalSymbols) } }
                        Button { customizing=true } label: { Label { Text("Customize") } icon: { AppSymbol.customize.image(in:personalSymbols) } }
                        Button { history=true } label: { Label { Text("Page history") } icon: { AppSymbol.history.image(in:personalSymbols) } }.disabled(session.busy || session.hasCurrentAssetWrites)
                        ForEach(destinations) { page in Button("Page \(notes.flatMap(\.pageIDs).firstIndex(of:page.id).map{$0+1} ?? 0)") { onSelect(page.id) } }
                    }
        }.disabled(session.isUnavailable || navigationPending || session.navigationLocked)
    }

}

@MainActor @Observable private final class PaperViewportState {
    var offset=CGPoint.zero
}


private struct IndexPaperView: View {
    @Environment(\.personalSymbols) private var personalSymbols
    let hits: [SearchHit]
    let selection: UUID?
    @Binding var query: String
    @Binding var scope: String
    let numbers: [UUID:Int]
    let entryFont: Font
    let onSelect: (UUID) -> Void
    let onNew: () -> Void
    let onTrash: (SearchHit) -> Void
    let onRestore: (SearchHit) -> Void
    let onClose: (() -> Void)?
    let transferEnabled: Bool
    let commands: AnyView
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.firstTextBaseline) {
                    Text("Index").font(.largeTitle).bold().accessibilityAddTraits(.isHeader)
                    Spacer(minLength:8)
                    if let onClose {
                        Button(action:onClose) {Label("Close index",systemImage:"xmark").frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
                            .labelStyle(.iconOnly).accessibilityIdentifier("notebook.closeIndex")
                    }
                    Menu { commands } label: {Label {Text("Notebook actions")} icon: {AppSymbol.settings.image(in:personalSymbols)}.frame(minWidth:44,minHeight:44)}.labelStyle(.iconOnly).accessibilityIdentifier("notebook.actions")
                }
                HStack {
                    TextField("Titles and typed text",text:$query).textFieldStyle(.plain).accessibilityIdentifier("notebook.search").frame(minHeight:44)
                    if !query.isEmpty {Button("Clear search",systemImage:"xmark.circle.fill") {query=""}.labelStyle(.iconOnly).frame(minWidth:44,minHeight:44)}
                }.padding(.horizontal,12).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
                ViewThatFits(in:.horizontal) {
                    HStack {scopePicker;Spacer();newButton}
                    VStack(alignment:.leading) {scopePicker;newButton}
                }
                LazyVStack(alignment:.leading,spacing:8) {
                    ForEach(hits) { hit in
                        Button {onSelect(hit.pageID)} label: {
                            HStack(alignment:.firstTextBaseline,spacing:12) {
                                AppSymbol.bookmark.image(in:personalSymbols,selected:true).font(.caption).opacity(selection == hit.pageID ? 1 : 0).accessibilityHidden(true)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(hit.note.title.isEmpty ? String(localized:"Untitled note") : hit.note.title).font(entryFont)
                                    if !query.isEmpty {Text(hit.snippet).font(.subheadline).lineLimit(3)}
                                }
                                Spacer(minLength:4)
                                Text(numbers[hit.pageID].map{String($0)} ?? "–").monospacedDigit().font(.body)
                            }.foregroundStyle(Color(uiColor:.darkText)).frame(minHeight:52).padding(.vertical,6)
                             .background(alignment:.bottom) {Rectangle().fill(.primary.opacity(selection == hit.pageID ? 0.4 : 0.1)).frame(height:selection == hit.pageID ? 2 : 0.5)}
                        }.buttonStyle(.plain).accessibilityIdentifier("notebook.hit."+hit.pageID.uuidString)
                         .accessibilityAddTraits(selection == hit.pageID ? .isSelected : [])
                         .contextMenu {
                             if scope == "trash" {Button("Restore") {onRestore(hit)}}
                             else {Button("Move to Trash",role:.destructive) {onTrash(hit)}}
                         }
                    }
                    if hits.isEmpty {
                        ContentUnavailableView(query.isEmpty ? LocalizedStringKey("No notes here") : LocalizedStringKey("No results"),systemImage:"book",description:Text(query.isEmpty ? LocalizedStringKey("Create a note to begin.") : LocalizedStringKey("Search titles and typed text. Drawings are not searched.")))
                    }
                }
                Text(transferEnabled ? LocalizedStringKey("Private notebook · optional iCloud transfer enabled") : LocalizedStringKey("Private. On your device.")).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal,24).padding(.vertical,20)
        }.paperSurface().accessibilityIdentifier("notebook.index")
    }
    private var scopePicker: some View {
        Menu {
            Picker("Show",selection:$scope) {Text("Notes").tag("notes");Text("Bookmarks").tag("bookmarks");Text("Trash").tag("trash")}
        } label: {
            HStack {Text(scope == "notes" ? LocalizedStringKey("Notes") : scope == "bookmarks" ? LocalizedStringKey("Bookmarks") : LocalizedStringKey("Trash"));Image(systemName:"chevron.down")}
                .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
        }.accessibilityLabel(Text("Show")).accessibilityIdentifier("notebook.scope")
    }
    private var newButton: some View {
        Button(action:onNew) {Label {Text("New note")} icon: {AppSymbol.newNote.image(in:personalSymbols)}.frame(minHeight:44).contentShape(Rectangle())}.keyboardShortcut("n")
    }
}
