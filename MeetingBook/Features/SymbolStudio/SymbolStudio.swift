import SwiftUI
import PencilKit

struct SymbolStudio: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var symbols
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft=SymbolDraft()
    @State private var path: [AppSymbol]=[]
    @State private var wide=false
    @State private var pending: Destination?
    @State private var exitPrompt=false
    @State private var resetPrompt=false
    @State private var conflict=false
    @State private var error: String?
    private enum Destination { case symbol(AppSymbol),gallery,exit }

    var body: some View {
        GeometryReader { geometry in
            let expanded=geometry.size.width>=760 && !typeSize.isAccessibilitySize
            NavigationStack(path:$path) {
                HStack(spacing:0) {
                    gallery.frame(maxWidth:expanded ? 320 : .infinity)
                    if expanded {
                        Divider()
                        if draft.symbol != nil { editor }
                        else { ContentUnavailableView("Choose a symbol",systemImage:"square.and.pencil",description:Text("Start with a tool you use every day.")).frame(maxWidth:.infinity) }
                    }
                }
                .navigationTitle("Own app symbols")
                .toolbar { ToolbarItem(placement:.confirmationAction) { closeButton } }
                .navigationDestination(for:AppSymbol.self) { _ in
                    editor.navigationTitle(draft.symbol?.title ?? "Own app symbols")
                        .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden()
                        .toolbar {
                            ToolbarItem(placement:.cancellationAction) {
                                Button { request(.gallery) } label: { Label {Text("All symbols")} icon: {AppSymbol.previous.image(in:symbols)} }
                                    .disabled(draft.busy || draft.active).accessibilityIdentifier("symbols.back")
                            }
                            ToolbarItem(placement:.confirmationAction) { closeButton }
                        }
                }
            }
            .onChange(of:expanded,initial:true) { _,value in
                wide=value
                path=value ? [] : draft.symbol.map {[$0]} ?? []
            }
        }
        .paperSurface()
        .interactiveDismissDisabled(draft.dirty || draft.busy || draft.active)
        .alert("Save your symbol?",isPresented:$exitPrompt) {
            Button("Save and continue") { Task { if await save() { completePending() } } }
            Button("Discard changes",role:.destructive) { completePending() }
            Button("Cancel",role:.cancel) { pending=nil }
        } message: { Text("Your drawing has changes that are not saved yet.") }
        .confirmationDialog("Reset this symbol?",isPresented:$resetPrompt,titleVisibility:.visible) {
            Button("Reset to standard",role:.destructive) { Task { await reset() } }
            Button("Cancel",role:.cancel) {}
        } message: { Text("This removes your saved drawing and any changes in this editor.") }
        .alert("Symbol changed",isPresented:$conflict) {
            Button("Keep my draft") { if let symbols { draft.keepDraft(from:symbols) } }
            Button("Load saved version",role:.destructive) { if let symbol=draft.symbol,let symbols { draft.load(symbol,from:symbols) } }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Another window saved this symbol. Keep your draft, then choose Use symbol to replace the saved version. Loading the saved version discards your draft.") }
        .alert("App symbols",isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {
            Button("OK",role:.cancel) {}
        } message: { Text(error ?? "") }
    }

    private var closeButton: some View {
        Button("Done") { request(.exit) }.disabled(draft.busy || draft.active).accessibilityIdentifier("symbols.done")
    }
    private var gallery: some View {
        List {
                Group {
            Section {
                Text("Make familiar tools your own.").font(.title2).fontWeight(.medium)
                Text("Draw one symbol or a whole set. Tools without a drawing keep their standard symbol.").foregroundStyle(.secondary)
                Toggle("Use own symbols",isOn:Binding(get:{symbols?.enabled ?? false},set:{value in
                    Task { do { try await symbols?.setEnabled(value) } catch { self.error=error.localizedDescription } }
                })).disabled(symbols == nil || symbols?.loadError != nil || draft.busy || draft.active).accessibilityIdentifier("symbols.enabled")
            }
            if let loadError=symbols?.loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry loading") { Task { await symbols?.load() } }
                }
            }
            ForEach(AppSymbol.Category.allCases) { category in
                Section { ForEach(AppSymbol.allCases.filter {$0.category==category && $0 != .library && $0 != .search}) { symbol in
                    Button { request(.symbol(symbol)) } label: {
                        HStack(spacing:12) {
                            Image(systemName:symbol.standardSymbol).font(.title3).frame(width:28).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment:.leading,spacing:3) {
                                Text(symbol.title).foregroundStyle(.primary)
                                Text(symbols?.images[symbol] == nil ? LocalizedStringResource("Standard") : LocalizedStringResource("Own drawing")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:8)
                            if let image=symbols?.images[symbol] {
                                Image(uiImage:image).renderingMode(.template).frame(width:24,height:24).foregroundStyle(.primary).accessibilityHidden(true)
                            }
                            if draft.symbol==symbol { Image(systemName:"checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
                        }.frame(minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(draft.busy || draft.active || symbols == nil)
                     .accessibilityIdentifier("symbols.item."+symbol.rawValue)
                     .accessibilityAddTraits(draft.symbol==symbol ? .isSelected : [])
                } } header: {Text(category.title)}
            }
            Section {
                Text("Your symbols stay in this app on this device. Notebook exports and notebook iCloud transfer do not include them. Your device backup may include them.").font(.footnote).foregroundStyle(.secondary)
            }
            }.listRowBackground(paperAppearance.color)
            }.paperSurface().listStyle(.insetGrouped).accessibilityIdentifier("symbols.gallery")
    }
    private var editor: some View {
        ScrollView {
            if let symbol=draft.symbol {
                VStack(alignment:.leading,spacing:20) {
                    HStack(spacing:12) {
                        Image(systemName:symbol.standardSymbol).font(.title).frame(width:44,height:44).background(.quaternary,in:RoundedRectangle(cornerRadius:12)).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:4) {
                            Text(symbol.title).font(.title2).fontWeight(.semibold).accessibilityIdentifier("symbols.title")
                            Text(draft.dirty ? LocalizedStringResource("Unsaved drawing") : symbols?.images[symbol] == nil ? LocalizedStringResource("Standard symbol") : LocalizedStringResource("Saved drawing")).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("symbols.status")
                        }
                    }
                    ZStack {
                        SymbolBoard(draft:draft).id(symbol)
                        if draft.drawing.strokes.isEmpty && !draft.active {
                            VStack(spacing:8) {
                                Image(systemName:symbol.standardSymbol).font(.system(size:48,weight:.ultraLight)).foregroundStyle(.gray.opacity(0.5))
                                Text("Draw your symbol here").font(.callout).foregroundStyle(.primary)
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }.aspectRatio(1,contentMode:.fit).frame(maxWidth:520)
                        .background(paperAppearance.color,in:RoundedRectangle(cornerRadius:20))
                        .clipShape(RoundedRectangle(cornerRadius:20))
                        .overlay(RoundedRectangle(cornerRadius:20).stroke(.quaternary))
                        .disabled(draft.busy)
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:8) { drawingTools }
                        VStack(alignment:.leading,spacing:8) { drawingTools }
                    }
                    .disabled(draft.busy || draft.active)
                    HStack(spacing:16) {
                        ZStack {
                            RoundedRectangle(cornerRadius:12).fill(.quaternary)
                            if let preview=draft.preview { Image(uiImage:preview).renderingMode(.template).frame(width:24,height:24) }
                            else { Image(systemName:symbol.standardSymbol).frame(width:24,height:24).foregroundStyle(.secondary) }
                        }.frame(width:56,height:56).accessibilityIdentifier("symbols.preview").accessibilityLabel("Toolbar preview")
                        VStack(alignment:.leading,spacing:4) {
                            Text("Toolbar preview").font(.headline)
                            Text("Keep the shape simple so it reads at a small size.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message=draft.previewError {Text(message).font(.callout).foregroundStyle(.red)}
                    Button { Task { _=await save() } } label: {
                        Text("Use symbol").frame(maxWidth:.infinity,minHeight:44)
                    }.buttonStyle(.borderedProminent).disabled(!draft.dirty || draft.preview == nil || draft.busy || draft.active)
                        .accessibilityIdentifier("symbols.use")
                    Button(role:.destructive) { resetPrompt=true } label: {
                        Text("Reset to standard").frame(minHeight:44).contentShape(Rectangle())
                    }.disabled(symbols?.images[symbol] == nil || draft.busy || draft.active)
                        .accessibilityIdentifier("symbols.reset")
                }.padding(20).frame(maxWidth:560).frame(maxWidth:.infinity)
            }
        }.paperSurface().accessibilityIdentifier("symbols.editor")
    }
    @ViewBuilder private var drawingTools: some View {
        Button { draft.erasing=false } label: { Label {Text("Pen")} icon: {AppSymbol.pen.image(in:symbols)}.frame(minHeight:44) }
            .buttonStyle(.bordered).tint(draft.erasing ? .secondary : .accentColor).accessibilityAddTraits(draft.erasing ? [] : .isSelected).accessibilityIdentifier("symbols.pen")
        Button { draft.erasing=true } label: { Label {Text("Eraser")} icon: {AppSymbol.eraser.image(in:symbols)}.frame(minHeight:44) }
            .buttonStyle(.bordered).tint(draft.erasing ? .accentColor : .secondary).accessibilityAddTraits(draft.erasing ? .isSelected : []).accessibilityIdentifier("symbols.eraser")
        Button { draft.undo() } label: { Label {Text("Undo")} icon: {AppSymbol.undo.image(in:symbols)}.frame(minHeight:44) }
            .buttonStyle(.bordered).disabled(draft.history.isEmpty).accessibilityIdentifier("symbols.undo")
        Button(role:.destructive) { draft.change(PKDrawing()) } label: { Label {Text("Clear")} icon: {AppSymbol.delete.image(in:symbols)}.frame(minHeight:44) }
            .buttonStyle(.bordered).disabled(draft.drawing.strokes.isEmpty).accessibilityIdentifier("symbols.clear")
    }
    private func request(_ destination: Destination) {
        guard !draft.busy,!draft.active else {return}
        if case .symbol(let symbol)=destination,symbol==draft.symbol {if !wide {path=[symbol]};return}
        pending=destination
        if draft.dirty {exitPrompt=true} else {completePending()}
    }
    private func completePending() {
        guard let destination=pending else {return};pending=nil
        switch destination {
        case .symbol(let symbol):
            guard let symbols else {return};draft.load(symbol,from:symbols);if !wide {path=[symbol]}
        case .gallery: draft.clear();path=[]
        case .exit: dismiss()
        }
    }
    private func save() async -> Bool {
        guard let symbols,draft.symbol != nil,!draft.busy,!draft.active else {return false}
        draft.busy=true;defer {draft.busy=false}
        do {try await draft.save(to:symbols);return true}
        catch PersonalSymbolError.conflict {conflict=true}
        catch {self.error=error.localizedDescription}
        return false
    }
    private func reset() async {
        guard let symbols,let symbol=draft.symbol else {return}
        draft.busy=true;defer {draft.busy=false}
        do {try await symbols.reset(symbol,expectedRevision:draft.revision);draft.load(symbol,from:symbols)}
        catch PersonalSymbolError.conflict {conflict=true}
        catch {self.error=error.localizedDescription}
    }
}

@MainActor @Observable final class SymbolDraft {
    var symbol: AppSymbol?
    var drawing=PKDrawing()
    var revision: UUID?
    var dirty=false
    var active=false
    var erasing=false
    var busy=false
    var history: [PKDrawing]=[]
    var preview: UIImage?
    var previewError: String?
    private var saved=PKDrawing().dataRepresentation()
    private var previewGeneration=0
    func load(_ symbol: AppSymbol,from store: PersonalSymbolStore) {
        let snapshot=store.snapshot(for:symbol)
        self.symbol=symbol;drawing=snapshot.drawing;revision=snapshot.revision
        saved=drawing.dataRepresentation();dirty=false;history=[];erasing=false
        previewGeneration += 1;preview=store.images[symbol];previewError=nil
    }
    func save(to store: PersonalSymbolStore) async throws {
        guard let symbol else {return}
        try await store.save(drawing,for:symbol,expectedRevision:revision)
        load(symbol,from:store)
    }
    func keepDraft(from store: PersonalSymbolStore) {
        guard let symbol else {return}
        let snapshot=store.snapshot(for:symbol)
        revision=snapshot.revision;saved=snapshot.drawing.dataRepresentation()
        dirty=drawing.dataRepresentation() != saved
    }
    func clear() {symbol=nil;drawing=PKDrawing();history=[];dirty=false;previewGeneration += 1;preview=nil;previewError=nil}
    func change(_ next: PKDrawing,remember: Bool=true) {
        guard drawing.dataRepresentation() != next.dataRepresentation() else {return}
        if remember {history.append(drawing)}
        drawing=next;dirty=next.dataRepresentation() != saved
        previewGeneration += 1;let generation=previewGeneration
        preview=nil;previewError=nil
        Task {
            do {
                let image=try await PersonalSymbolStore.previewImage(for:next)
                if generation==previewGeneration {preview=image}
            } catch {
                if generation==previewGeneration && !next.strokes.isEmpty {previewError=error.localizedDescription}
            }
        }
    }
    func undo() {guard let previous=history.popLast() else {return};change(previous,remember:false)}
}

private struct SymbolBoard: UIViewRepresentable {
    let draft: SymbolDraft
    func makeCoordinator() -> Coordinator {Coordinator(draft)}
    func makeUIView(context: Context) -> SymbolBoardView {
        let view=SymbolBoardView();view.canvas.delegate=context.coordinator;return view
    }
    func updateUIView(_ view: SymbolBoardView,context: Context) {
        view.backgroundColor=context.environment.paperAppearance.uiColor
        view.overrideUserInterfaceStyle = .light
        view.isUserInteractionEnabled=context.environment.isEnabled
        if !draft.active,view.canvas.drawing.dataRepresentation() != draft.drawing.dataRepresentation() {
            context.coordinator.updating=true
            view.canvas.drawing=draft.drawing
            context.coordinator.programmatic=view.canvas.drawing.dataRepresentation()
            context.coordinator.updating=false
        }
        view.canvas.tool=draft.erasing ? PKEraserTool(.bitmap) : PKInkingTool(.pen,color:.black,width:9)
    }
    final class Coordinator: NSObject,PKCanvasViewDelegate {
        let draft: SymbolDraft
        let symbol: AppSymbol?
        var updating=false
        var programmatic=Data()
        init(_ draft: SymbolDraft) {self.draft=draft;symbol=draft.symbol}
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard draft.symbol==symbol else {return};draft.active=true
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            // Keep the canvas active until PencilKit publishes its completed stroke.
            DispatchQueue.main.async {
                guard self.draft.symbol==self.symbol else {return}
                self.draft.change(canvasView.drawing);self.draft.active=false
            }
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !updating,!draft.active else {return}
            // Commit before SwiftUI can restore the previous draft over the completed stroke.
            if draft.symbol==symbol && canvasView.drawing.dataRepresentation() != programmatic {draft.change(canvasView.drawing)}
        }

    }
}
private final class SymbolBoardView: UIView {
    let canvas=PKCanvasView()
    override init(frame:CGRect) {
        super.init(frame:frame);addSubview(canvas)
        canvas.backgroundColor = .clear;canvas.isOpaque=false;canvas.drawingPolicy = .anyInput;canvas.isScrollEnabled=false
        canvas.accessibilityLabel=String(localized:"Symbol drawing area");canvas.accessibilityIdentifier="symbols.canvas"
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layoutSubviews() {
        super.layoutSubviews();let scale=min(bounds.width,bounds.height)/400
        canvas.bounds=CGRect(x:0,y:0,width:400,height:400);canvas.transform=CGAffineTransform(scaleX:scale,y:scale)
        canvas.center=CGPoint(x:bounds.midX,y:bounds.midY)
    }
}
