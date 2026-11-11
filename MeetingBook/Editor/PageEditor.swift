import SwiftUI
import PhotosUI
import MeetingBookCore

enum EditorCommandSymbol: String, CaseIterable {
    case dismiss="keyboard.chevron.compact.down",mode="pencil.and.outline",previous="chevron.left",next="chevron.right",undo="arrow.uturn.backward",page="doc"
}

struct PageEditor: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var personalSymbols
    @Bindable var session: EditorSession
    var navigationPending=false
    var indexIsPresented=false
    var indexPaper: AnyView? = nil
    var onIndex: (() -> Void)? = nil
    var bookmarkButton: AnyView? = nil
    var workspaceCommands: AnyView? = nil
    var libraryCommands: AnyView? = nil
    var navigationIDs: [UUID]? = nil
    var onNavigate: ((UUID) -> Void)? = nil
    var leadingPageNumber: Int? = nil
    var trailingPageNumber: Int? = nil
    var leadingPaper: AnyView? = nil
    var trailingPaper: AnyView? = nil
    private var pageIDs: [UUID] { navigationIDs ?? session.snapshot.note.pageIDs }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyboardActions=EditorKeyboardActions()
    @State private var softwareKeyboardVisible=false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo:.caption) private var footerHeight: CGFloat = 34
    @State private var viewportOffset=CGPoint.zero
    @State private var photo: PhotosPickerItem?
    @State private var showingPhotoPicker=false
    @State private var error: String?
    @State private var altText=""
    @State private var editingAlt=false
    var body: some View {
        VStack(spacing:0) {
            GeometryReader { geometry in
                let presentation=BookPresentation.resolve(geometry,regular:horizontalSizeClass == .regular,accessibility:typeSize.isAccessibilitySize,layoutDirection:layoutDirection,indexPresented:indexIsPresented,footerHeight:footerHeight)
                let activeIndex=presentation.spread && (indexIsPresented || leadingPaper != nil) ? 1 : 0
                let active=presentation.contentFrames[activeIndex]
                let passive=presentation.spread ? (indexIsPresented ? presentation.pages[0] : presentation.contentFrames[leadingPaper != nil ? 0 : 1]) : .zero
                let activeLeaf=presentation.pages[activeIndex]
                let hidingEditor=indexIsPresented && !presentation.spread
                let numbers=presentation.leafPageNumbers(active:(pageIDs.firstIndex(of:session.activePageID) ?? 0)+1,leading:leadingPageNumber,trailing:trailingPageNumber,activeOnRight:leadingPaper != nil)
                let binding=presentation.binding(offset:viewportOffset,enlarged:session.mode == .reading && session.largerReadingView)
                ZStack(alignment:.topLeading) {
                    paperAppearance.color
                    CanvasHost(session:session,indexObscuresEditor:hidingEditor,error:$error,keyboardCommands:AnyView(keyboardCommands.environment(\.personalSymbols,personalSymbols).paperContext(paperAppearance)),onOffset:{ value in if viewportOffset != value {viewportOffset=value} },onSoftwareKeyboard:{softwareKeyboardVisible=$0},keyboardActions:keyboardActions)
                        .frame(width:active.width,height:active.height).position(x:active.midX,y:active.midY)
                        .allowsHitTesting(!hidingEditor && !session.isUnavailable).accessibilityHidden(hidingEditor)
                    if presentation.spread {
                        (indexIsPresented ? indexPaper : (leadingPaper ?? trailingPaper))
                            .environment(\.paperViewportOffset,viewportOffset)
                            .frame(width:passive.width,height:passive.height).position(x:passive.midX,y:passive.midY)
                        BookBinding(frame:binding)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    if hidingEditor {
                        indexPaper.frame(width:activeLeaf.width,height:activeLeaf.height).position(x:activeLeaf.midX,y:activeLeaf.midY)
                    }
                    if !hidingEditor && !softwareKeyboardVisible {
                        edgeCommands.frame(width:BookPresentation.commandMargin,height:max(0,activeLeaf.height-LeafHitView.cornerHeight*2),alignment:.top)
                            .position(x:presentation.spread && activeIndex == 0 ? activeLeaf.minX+BookPresentation.commandMargin/2 : activeLeaf.maxX-BookPresentation.commandMargin/2,y:activeLeaf.midY)
                    }
                    ForEach(presentation.pages.indices,id: \.self) { index in
                        if let number=numbers[index] {
                            footer(number:number,active:presentation.pages[index] == activeLeaf)
                                .frame(width:presentation.pages[index].width,height:footerHeight)
                                .position(x:presentation.pages[index].midX,y:presentation.pages[index].maxY-footerHeight/2)
                        }
                    }
                }.contentShape(.accessibility,Rectangle())
                 .accessibilityElement(children:.contain).accessibilityIdentifier("notebook.paper")
                 .preference(key:BookPresentationPreference.self,value:presentation)
                 .preference(key:PaperViewportPreference.self,value:viewportOffset)
            }

        }
        .paperSurface()
        .ignoresSafeArea(.keyboard,edges:.bottom)
        .disabled(session.navigationLocked && !session.retainsTypingFocusDuringTurn)
        .allowsHitTesting(!session.navigationLocked)
        .interactiveDismissDisabled(session.strokeActive)
        .task { await session.loadFonts();if let warning=session.errorMessage { error=warning } }
        .photosPicker(isPresented:$showingPhotoPicker,selection:$photo,matching:.images)
        .onChange(of:photo) { _,item in
            guard let item else { return }
            let token=session.beginAssetWrite(pageID:session.activePageID)
            run {
                defer { photo=nil }
                try await session.importImage(completingAssetToken:token) { try await item.loadTransferable(type:Data.self) }
            }
        }
        .alert("Editor error",isPresented:Binding(get:{error != nil},set:{ if !$0 { error=nil } })) { Button("OK",role:.cancel) {} } message: { Text(error ?? "") }
        .alert("Alternative text",isPresented:$editingAlt) {
            TextField("Description",text:$altText)
            Button("Save") { session.setAltText(altText) };Button("Cancel",role:.cancel) {}
        }
        .onDisappear { run { try await session.leave() } }
    }
    private func footer(number: Int,active: Bool) -> some View {
        BookPageNumber(number:number).frame(maxWidth:.infinity)
            .overlay(alignment:typeSize.isAccessibilitySize ? .bottom : .trailing) {
                if active {
                    status.font(.caption2).fixedSize(horizontal:false,vertical:typeSize.isAccessibilitySize)
                        .padding(.trailing,typeSize.isAccessibilitySize ? 0 : 12)
                        .frame(maxWidth:typeSize.isAccessibilitySize ? .infinity : 120,alignment:typeSize.isAccessibilitySize ? .center : .trailing)
                }
            }
    }
    private var edgeCommands: some View {
        ViewThatFits(in:.vertical) {
            VStack(spacing:4) {
                indexButton
                if !typeSize.isAccessibilitySize {bookmarkButton}
                modeButton
                if !typeSize.isAccessibilitySize {navigationButtons();pageButton}
                moreButton
            }
            VStack(spacing:4) {indexButton;modeButton;moreButton}
        }.labelStyle(.iconOnly).buttonStyle(.plain).font(.system(size:18))
         .foregroundStyle(Color(uiColor:.darkText)).padding(.vertical,8)
         .disabled(navigationPending)
    }
    @ViewBuilder private var indexButton: some View {
        if let onIndex {
            Button(action:onIndex) {Label {Text("Index")} icon: {AppSymbol.library.image(in:personalSymbols)}.frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
                .disabled(session.strokeActive).accessibilityIdentifier("notebook.showIndex").keyboardShortcut("i",modifiers:[.command,.shift])
        }
    }
    private var modeButton: some View {
        EditorModeMenu(session:session,error:$error,minimumTarget:44).accessibilityIdentifier("editor.mode").disabled(session.isUnavailable)
    }
    private var pageButton: some View {
        EditorPageMenu(session:session,showingPhotoPicker:$showingPhotoPicker,error:$error,altText:$altText,editingAlt:$editingAlt,minimumTarget:44).accessibilityIdentifier("editor.pageMenu").disabled(session.isUnavailable)
    }
    private var moreButton: some View {
        Menu {
            bookmarkButton
            navigationButtons()
            pageButton
            workspaceCommands.disabled(session.isUnavailable)
            libraryCommands
        } label: {Label {Text("More")} icon: {AppSymbol.appearance.image(in:personalSymbols)}.frame(minWidth:44,minHeight:44)}.accessibilityIdentifier("editor.more")
    }
    private var keyboardCommands: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:4) {keyboardPrimaryCommands;keyboardNavigationCommands}
            VStack(spacing:4) {keyboardPrimaryCommands;keyboardNavigationCommands}
        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tint).font(.body)
         .frame(maxWidth:.infinity,minHeight:44).padding(.vertical,4)
         .background(paperAppearance.color).disabled(navigationPending || session.navigationLocked)
    }
    private var keyboardPrimaryCommands: some View {
        HStack(spacing:4) {
            Button {keyboardActions.controller?.view.endEditing(true)} label: {
                Label { Text("Hide keyboard") } icon: { AppSymbol.hideKeyboard.image(in:personalSymbols) }.fixedSize().frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            }.accessibilityIdentifier("editor.keyboard.dismiss")
            EditorModeMenu(session:session,error:$error,minimumTarget:44).accessibilityIdentifier("editor.keyboard.mode")
            EditorPageMenu(session:session,showingPhotoPicker:$showingPhotoPicker,error:$error,altText:$altText,editingAlt:$editingAlt,minimumTarget:44).accessibilityIdentifier("editor.keyboard.pageMenu")
        }
    }
    private var keyboardNavigationCommands: some View {
        HStack(spacing:4) {navigationButtons(keyboard:true)}
    }
    @ViewBuilder private func navigationButtons(keyboard: Bool=false) -> some View {
        Button {navigate(-1)} label: {Label { Text("Previous page") } icon: { AppSymbol.previous.image(in:personalSymbols) }.fixedSize(horizontal:false,vertical:false).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .keyboardShortcut(.leftArrow,modifiers:.command).accessibilityIdentifier(keyboard ? "editor.keyboard.previous" : "editor.previous")
            .disabled(session.isUnavailable || session.navigationLocked || session.strokeActive || pageIDs.first == session.activePageID)
        Button {navigate(1)} label: {Label { Text("Next page") } icon: { AppSymbol.next.image(in:personalSymbols) }.fixedSize(horizontal:false,vertical:false).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .keyboardShortcut(.rightArrow,modifiers:.command).accessibilityIdentifier(keyboard ? "editor.keyboard.next" : "editor.next")
            .disabled(session.isUnavailable || session.navigationLocked || session.strokeActive || pageIDs.last == session.activePageID)
        Button {run {try await session.flush();try await session.undo()}} label: {Label { Text("Undo") } icon: { AppSymbol.undo.image(in:personalSymbols) }.fixedSize(horizontal:false,vertical:false).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .keyboardShortcut("z").accessibilityIdentifier(keyboard ? "editor.keyboard.undo" : "editor.undo")
            .disabled(session.isUnavailable || session.navigationLocked || (!session.canUndo && session.saveState == .saved))
    }
    @ViewBuilder private var status: some View {
        switch session.saveState {
        case .saved: Text("Saved locally").foregroundStyle(.secondary)
        case .dirty: Text("Unsaved changes")
        case .saving: ProgressView("Saving")
        case .conflict: Text("Conflict: draft retained").foregroundStyle(.red)
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { self.error=error.localizedDescription } } }
    private func navigate(_ offset: Int) {
        guard let index=pageIDs.firstIndex(of:session.activePageID),pageIDs.indices.contains(index+offset) else { return }
        let target=pageIDs[index+offset]
        if let onNavigate { onNavigate(target);return }
        run { try await session.leave();session.select(pageID:target) }
    }
}
private struct EditorModeMenu: View {
    @Environment(\.personalSymbols) private var personalSymbols
    let session: EditorSession
    @Binding var error: String?
    var minimumTarget: CGFloat=0
    var body: some View {
        Menu {
            Picker("Mode",selection:Binding(get:{session.mode},set:{ mode in Task { do { try await session.setMode(mode) } catch { self.error=error.localizedDescription } } })) {
                Label { Text("Read") } icon: { AppSymbol.reading.image(in:personalSymbols) }.tag(EditorSession.Mode.reading)
                Label { Text("Type") } icon: { AppSymbol.typing.image(in:personalSymbols) }.tag(EditorSession.Mode.typing)
                Label { Text("Draw") } icon: { AppSymbol.drawing.image(in:personalSymbols) }.tag(EditorSession.Mode.drawing)
                Label { Text("Select") } icon: { AppSymbol.selecting.image(in:personalSymbols) }.tag(EditorSession.Mode.selecting)
            }
        } label: { Label { Text("Mode") } icon: { AppSymbol.mode.image(in:personalSymbols) }.fixedSize(horizontal:false,vertical:false).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle()) }.disabled(session.navigationLocked)
    }
}
private struct EditorPageMenu: View {
    @Environment(\.personalSymbols) private var personalSymbols
    @Bindable var session: EditorSession
    @Binding var showingPhotoPicker: Bool
    @Binding var error: String?
    @Binding var altText: String
    @Binding var editingAlt: Bool
    var minimumTarget: CGFloat=0
    var body: some View {
        Menu {
            Button { run { try await session.redo() } } label: { Label { Text("Redo") } icon: { AppSymbol.redo.image(in:personalSymbols) } }.disabled(!session.canRedo)
            Button { run { try await session.leave() } } label: { Label { Text("Save locally") } icon: { AppSymbol.save.image(in:personalSymbols) } }.disabled(session.busy)
            Button { showingPhotoPicker=true } label: { Label { Text("Import image") } icon: { AppSymbol.importImage.image(in:personalSymbols) } }
            Button("Copy page") { run { try await PageClipboard.copy(content:session.activeContent,store:session.store) } }
            Button("Paste page or image") { run { try await PageClipboard.paste(into:session) } }
            Button("Duplicate page") { run { try await session.duplicate(pageID:session.activePageID) } }
            Button("Insert page") { run { try await session.insert(templates:[session.activeContent.template],after:session.activePageID) } }
            Button("Clear page",role:.destructive) { run { try await session.clear(pageID:session.activePageID) } }
            Button("Remove page",role:.destructive) { run { try await session.remove(pageID:session.activePageID) } }.disabled(session.snapshot.pages.count<2)
            Toggle("Draw with finger",isOn:$session.fingerDrawing)
            Toggle("Larger reading view",isOn:$session.largerReadingView)
            if let id=session.selectedElementID,let image=session.activeContent.images.first(where: { $0.id == id }) {
                Button("Edit alternative text") { altText=image.altText;editingAlt=true }
            }
        } label: {Label { Text("Page") } icon: { AppSymbol.page.image(in:personalSymbols) }.fixedSize(horizontal:false,vertical:false).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle())}
        .disabled(session.navigationLocked || session.strokeActive || session.busy || session.hasCurrentAssetWrites)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { self.error=error.localizedDescription } } }
}

private struct CanvasHost: UIViewControllerRepresentable {
    let session: EditorSession
    let indexObscuresEditor: Bool
    @Binding var error: String?
    var keyboardCommands: AnyView
    var onOffset: (CGPoint)->Void
    var onSoftwareKeyboard: (Bool)->Void
    let keyboardActions: EditorKeyboardActions
    func makeUIViewController(context: Context) -> PageCanvasController {
        let controller=PageCanvasController(session:session);controller.reportError={ error=$0.localizedDescription }
        configureCallbacks(controller)
        #if DEBUG
        controller.traceKeyboardEnvironment(context.environment.dynamicTypeSize)
        #endif
        controller.setPaperAppearance(context.environment.paperAppearance)
        controller.setKeyboardCommands(keyboardCommands,dynamicTypeSize:context.environment.dynamicTypeSize);return controller
    }
    func updateUIViewController(_ controller: PageCanvasController,context: Context) {
        _ = session.navigationLocked;_ = session.retainsTypingFocusDuringTurn;_ = session.activePageID;_ = session.activeContent;_ = session.mode;_ = session.fingerDrawing;_ = session.versions;_ = session.largerReadingView
        #if DEBUG
        controller.traceKeyboardEnvironment(context.environment.dynamicTypeSize)
        #endif
        controller.setPaperAppearance(context.environment.paperAppearance)
        controller.setKeyboardCommands(keyboardCommands,dynamicTypeSize:context.environment.dynamicTypeSize)
        configureCallbacks(controller);controller.setCoverPresented(context.environment.notebookCovered || indexObscuresEditor);controller.refresh()
    }
    private func configureCallbacks(_ controller: PageCanvasController) {
        keyboardActions.controller=controller
        controller.reportViewportOffset={value in DispatchQueue.main.async {onOffset(value)}}
        controller.reportSoftwareKeyboard={visible in DispatchQueue.main.async {onSoftwareKeyboard(visible)}}
    }
}

private final class EditorKeyboardActions {
    weak var controller: PageCanvasController?
}

private struct PaperViewportOffsetKey: EnvironmentKey { static let defaultValue=CGPoint.zero }
extension EnvironmentValues {
    var paperViewportOffset: CGPoint { get {self[PaperViewportOffsetKey.self]} set {self[PaperViewportOffsetKey.self]=newValue} }
}

struct PaperViewportPreference: PreferenceKey {
    static var defaultValue: CGPoint { .zero }
    static func reduce(value: inout CGPoint,nextValue: () -> CGPoint) {value=nextValue()}
}
