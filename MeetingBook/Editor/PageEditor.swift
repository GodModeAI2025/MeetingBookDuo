import SwiftUI
import PhotosUI
import MeetingBookCore

enum EditorCommandSymbol: String, CaseIterable {
    case dismiss="keyboard.chevron.compact.down",mode="pencil.and.outline",previous="chevron.left",next="chevron.right",undo="arrow.uturn.backward",page="doc"
}

struct PageEditor: View {
    @Bindable var session: EditorSession
    var navigationPending=false
    var navigationIDs: [UUID]? = nil
    var onNavigate: ((UUID) -> Void)? = nil
    var leadingPaper: AnyView? = nil
    var trailingPaper: AnyView? = nil
    private var pageIDs: [UUID] { navigationIDs ?? session.snapshot.note.pageIDs }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var softwareKeyboardVisible=false
    @State private var keyboardActions=EditorKeyboardActions()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var viewportOffset=CGPoint.zero
    @State private var photo: PhotosPickerItem?
    @State private var showingPhotoPicker=false
    @State private var error: String?
    @State private var altText=""
    @State private var editingAlt=false
    var body: some View {
        VStack(spacing:0) {
            GeometryReader { geometry in
                let presentation=BookPresentation.resolve(geometry,regular:horizontalSizeClass == .regular,accessibility:typeSize.isAccessibilitySize,layoutDirection:layoutDirection)
                let active=presentation.pages[presentation.spread && leadingPaper != nil ? 1 : 0]
                let passive=presentation.spread ? presentation.pages[leadingPaper != nil ? 0 : 1] : .zero
                let binding=presentation.binding(offset:viewportOffset,enlarged:session.mode == .reading && session.largerReadingView)
                ZStack(alignment:.topLeading) {
                    Color(uiColor:.secondarySystemBackground)
                    CanvasHost(session:session,error:$error,keyboardCommands:AnyView(keyboardCommands),onOffset:{ value in if viewportOffset != value {viewportOffset=value} },onSoftwareKeyboard:{softwareKeyboardVisible=$0},keyboardActions:keyboardActions)
                        .frame(width:active.width,height:active.height).position(x:active.midX,y:active.midY)
                    if presentation.spread {
                        (leadingPaper ?? trailingPaper)
                            .environment(\.paperViewportOffset,viewportOffset)
                            .frame(width:passive.width,height:passive.height).position(x:passive.midX,y:passive.midY)
                        Rectangle().fill(.primary.opacity(0.08))
                            .frame(width:binding.width,height:binding.height)
                            .position(x:binding.midX,y:binding.midY)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }.preference(key:BookPresentationPreference.self,value:presentation)
                 .preference(key:PaperViewportPreference.self,value:viewportOffset)
            }
            ViewThatFits(in:.horizontal) {
                HStack { Text("Page \((pageIDs.firstIndex(of:session.activePageID) ?? 0)+1)");Spacer();status }
                VStack(alignment:.leading) { Text("Page \((pageIDs.firstIndex(of:session.activePageID) ?? 0)+1)");status }
            }.font(.caption).padding(.horizontal,12).padding(.vertical,6)
        }
        .ignoresSafeArea(.keyboard,edges:.bottom)
        .toolbar {
            ToolbarItemGroup(placement:.bottomBar) {
                EditorModeMenu(session:session,error:$error).accessibilityIdentifier("editor.mode").disabled(navigationPending)
                navigationButtons().disabled(navigationPending)
                EditorPageMenu(session:session,showingPhotoPicker:$showingPhotoPicker,error:$error,altText:$altText,editingAlt:$editingAlt).accessibilityIdentifier("editor.pageMenu").disabled(navigationPending)
            }

        }
        .disabled(session.isUnavailable || (session.navigationLocked && !session.retainsTypingFocusDuringTurn))
        .allowsHitTesting(!session.isUnavailable && !session.navigationLocked)
        .toolbar(session.mode == .typing ? .hidden : .automatic,for:.bottomBar)
        .toolbar(verticalSizeClass == .compact && softwareKeyboardVisible ? .hidden : .visible,for:.navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(session.strokeActive)
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
    private var keyboardCommands: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:4) {keyboardPrimaryCommands;keyboardNavigationCommands}
            VStack(spacing:4) {keyboardPrimaryCommands;keyboardNavigationCommands}
        }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tint).font(.body)
         .frame(maxWidth:.infinity,minHeight:44).padding(.vertical,4)
         .background(.bar).disabled(navigationPending || session.navigationLocked)
    }
    private var keyboardPrimaryCommands: some View {
        HStack(spacing:4) {
            Button {keyboardActions.controller?.view.endEditing(true)} label: {
                Label("Hide keyboard",systemImage:EditorCommandSymbol.dismiss.rawValue).fixedSize().frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            }.accessibilityIdentifier("editor.keyboard.dismiss")
            EditorModeMenu(session:session,error:$error,minimumTarget:44).accessibilityIdentifier("editor.keyboard.mode")
            EditorPageMenu(session:session,showingPhotoPicker:$showingPhotoPicker,error:$error,altText:$altText,editingAlt:$editingAlt,minimumTarget:44).accessibilityIdentifier("editor.keyboard.pageMenu")
        }
    }
    private var keyboardNavigationCommands: some View {
        HStack(spacing:4) {navigationButtons(minimumTarget:44)}
    }
    @ViewBuilder private func navigationButtons(minimumTarget: CGFloat=0) -> some View {
        Button {navigate(-1)} label: {Label("Previous page",systemImage:EditorCommandSymbol.previous.rawValue).fixedSize(horizontal:minimumTarget>0,vertical:minimumTarget>0).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle())}
            .accessibilityIdentifier(minimumTarget>0 ? "editor.keyboard.previous" : "editor.previous")
            .disabled(session.navigationLocked || session.strokeActive || pageIDs.first == session.activePageID)
        Button {navigate(1)} label: {Label("Next page",systemImage:EditorCommandSymbol.next.rawValue).fixedSize(horizontal:minimumTarget>0,vertical:minimumTarget>0).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle())}
            .accessibilityIdentifier(minimumTarget>0 ? "editor.keyboard.next" : "editor.next")
            .disabled(session.navigationLocked || session.strokeActive || pageIDs.last == session.activePageID)
        Button {run {try await session.flush();try await session.undo()}} label: {Label("Undo",systemImage:EditorCommandSymbol.undo.rawValue).fixedSize(horizontal:minimumTarget>0,vertical:minimumTarget>0).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle())}
            .accessibilityIdentifier(minimumTarget>0 ? "editor.keyboard.undo" : "editor.undo")
            .disabled(session.navigationLocked || (!session.canUndo && session.saveState == .saved))
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
    let session: EditorSession
    @Binding var error: String?
    var minimumTarget: CGFloat=0
    var body: some View {
        Menu {
            Picker("Mode",selection:Binding(get:{session.mode},set:{ mode in Task { do { try await session.setMode(mode) } catch { self.error=error.localizedDescription } } })) {
                Label("Read",systemImage:"book").tag(EditorSession.Mode.reading)
                Label("Type",systemImage:"character.cursor.ibeam").tag(EditorSession.Mode.typing)
                Label("Draw",systemImage:"pencil.tip").tag(EditorSession.Mode.drawing)
                Label("Select",systemImage:"cursorarrow").tag(EditorSession.Mode.selecting)
            }
        } label: { Label("Mode",systemImage:EditorCommandSymbol.mode.rawValue).fixedSize(horizontal:minimumTarget>0,vertical:minimumTarget>0).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle()) }.disabled(session.navigationLocked)
    }
}
private struct EditorPageMenu: View {
    @Bindable var session: EditorSession
    @Binding var showingPhotoPicker: Bool
    @Binding var error: String?
    @Binding var altText: String
    @Binding var editingAlt: Bool
    var minimumTarget: CGFloat=0
    var body: some View {
        Menu {
            Button("Redo",systemImage:"arrow.uturn.forward") { run { try await session.redo() } }.disabled(!session.canRedo)
            Button("Save locally",systemImage:"checkmark.circle") { run { try await session.leave() } }.disabled(session.busy)
            Button("Import image",systemImage:"photo") { showingPhotoPicker=true }
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
        } label: {Label("Page",systemImage:EditorCommandSymbol.page.rawValue).fixedSize(horizontal:minimumTarget>0,vertical:minimumTarget>0).frame(minWidth:minimumTarget,minHeight:minimumTarget).contentShape(Rectangle())}
        .disabled(session.navigationLocked || session.strokeActive || session.busy || session.hasCurrentAssetWrites)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { self.error=error.localizedDescription } } }
}

private struct CanvasHost: UIViewControllerRepresentable {
    let session: EditorSession
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
        controller.setKeyboardCommands(keyboardCommands,dynamicTypeSize:context.environment.dynamicTypeSize);return controller
    }
    func updateUIViewController(_ controller: PageCanvasController,context: Context) {
        _ = session.navigationLocked;_ = session.retainsTypingFocusDuringTurn;_ = session.activePageID;_ = session.activeContent;_ = session.mode;_ = session.fingerDrawing;_ = session.versions;_ = session.largerReadingView
        #if DEBUG
        controller.traceKeyboardEnvironment(context.environment.dynamicTypeSize)
        #endif
        controller.setKeyboardCommands(keyboardCommands,dynamicTypeSize:context.environment.dynamicTypeSize)
        configureCallbacks(controller);controller.refresh()
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
