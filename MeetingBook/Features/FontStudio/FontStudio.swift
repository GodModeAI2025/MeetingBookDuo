import SwiftUI
import PencilKit
import MeetingBookCore

struct FontStudio: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var personalSymbols
    let store: NotebookStore
    var didCommit: @MainActor () -> Void = {}
    @State private var symbolStudio=false
    @Environment(\.dismiss) private var dismiss
    @State private var projects:[FontProject]=[]
    @State private var storageLease: StorageLease?
    @State private var name=""
    @State private var creating=false
    @FocusState private var nameFocused: Bool
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Group {
                Section {
                    Button { symbolStudio=true } label: { Label {Text("Own app symbols")} icon: {AppSymbol.appSymbols.image(in:personalSymbols)} }.accessibilityIdentifier("symbols.open")
                }
                Section {
                    Text("Your handwriting, made into a real font.").font(.title2)
                    Text("Draw each character locally. Published versions stay unchanged so older notes keep their appearance.")
                }
                Section("New font project") {
                    TextField("Name",text:$name).focused($nameFocused).submitLabel(.done).onSubmit {nameFocused=false}
                    Button("Create project") { nameFocused=false;Task { creating=true;defer {creating=false};do { let p=FontProject(name:name);try await store.saveFontProject(p);projects=await store.fontProjects();name="";didCommit() } catch { self.error=error.localizedDescription } } }.disabled(creating || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Section("Your projects") {
                    ForEach(projects) { project in NavigationLink(project.name) { FontProjectEditor(store:store,initial:project,didCommit:didCommit) }.accessibilityIdentifier("font.project."+project.id.uuidString) }
                }
                if let error { Text(error).foregroundStyle(.red) }
                }.listRowBackground(paperAppearance.color)
            }.paperSurface().navigationTitle("Font Studio")
            .toolbar { Button("Done") { dismiss() } }
            .task { storageLease=store.protection.retain(blocksCollection:true);projects=await store.fontProjects() }
            .onDisappear {storageLease=nil}
                .fullScreenCover(isPresented:$symbolStudio) { SymbolStudio().bookCoverShield() }
        }
    }
}

struct FontProjectEditor: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var personalSymbols
    let store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    @State private var exitPrompt=false
    @State private var emergencyShare: SharedFiles?
    @State private var emergencyCleanup: (@MainActor () async -> Void)?
    @State private var exportingEmergency=false
    @State private var emergencyTask: Task<Void,Never>?
    @State private var storageLease: StorageLease?
    @State private var project: FontProject
    @State private var knownVersions:[FontVersion]=[]
    private var publishedVersions:[FontVersion] { project.publicationIDs.compactMap { id in (project.versions+knownVersions).first{$0.id==id} } }
    @State private var codePoint: UInt32=65
    @State private var drawing=PKDrawing()
    @State private var loaded=UInt32(65)
    @State private var glyphBaseHash: String?
    @State private var glyphBaseMetrics: GlyphCaptureMetrics?
    @State private var edits=GlyphEditState()
    private var dirty: Bool { edits.dirty }
    @State private var saving=true
    @State private var erasing=false
    @State private var strokeActive=false
    @State private var group="uppercase"
    @State private var advance=600.0
    @State private var bearing=40.0
    @State private var issues:[GlyphIssue]=[]
    @State private var error: String?
    @State private var status=""
    @State private var buildTask: Task<Void,Never>?
    @State private var building=false
    @State private var publication: UUID?
    let didCommit: @MainActor () -> Void
    init(store: NotebookStore,initial: FontProject,didCommit: @escaping @MainActor () -> Void = {}) { self.store=store;self.didCommit=didCommit;_project=State(initialValue:initial) }
    var characters: [UInt32] {
        FontCoverage.required.sorted().filter { cp in
            switch group {
            case "uppercase":return (65...90).contains(cp)
            case "lowercase":return (97...122).contains(cp)
            case "digits":return (48...57).contains(cp)
            case "missing":return cp != 32 && (project.glyphAssetHashes[cp] == nil || project.glyphMetrics[cp] == nil)
            default:return cp != 32 && !(65...90).contains(cp) && !(97...122).contains(cp) && !(48...57).contains(cp)
            }
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text(project.name).font(.title)
                ProgressView(value:Double(FontCoverage.required.filter{$0 == 32 || project.glyphAssetHashes[$0] != nil && project.glyphMetrics[$0] != nil}.count),total:103)
                Text("\(FontCoverage.required.filter{$0 == 32 || project.glyphAssetHashes[$0] != nil && project.glyphMetrics[$0] != nil}.count) of 103 characters · space is automatic")
                Picker("Character group",selection:$group) { Text("ABC").tag("uppercase");Text("abc").tag("lowercase");Text("123").tag("digits");Text("Symbols").tag("symbols");Text("Missing").tag("missing") }.pickerStyle(.menu)
                ScrollView(.horizontal) { HStack(spacing:8) {
                    ForEach(characters,id:\.self) { cp in
                        Button { switchGlyph(cp) } label: {
                            VStack { Text(String(UnicodeScalar(cp)!)).font(.title2);Image(systemName:project.glyphAssetHashes[cp] != nil && project.glyphMetrics[cp] != nil ? "checkmark.circle.fill" : "circle.dotted").font(.caption) }.frame(minWidth:44,minHeight:58)
                        }.buttonStyle(.plain).padding(8).background(cp == codePoint ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10)).foregroundStyle(cp == codePoint ? Color.accentColor : .primary).accessibilityAddTraits(cp == codePoint ? .isSelected : []).disabled(saving || strokeActive)
                    }
                } }
                Text("Draw \(String(UnicodeScalar(codePoint)!))").font(.title2)
                Text("Baseline is the third guide. Capitals reach the first, lowercase the second. Descenders stay above the fourth.").font(.caption).foregroundStyle(.secondary)
                GlyphBoard(drawing:$drawing,dirty:Binding(get:{edits.dirty},set:{if $0 {edits.changed()}}),active:$strokeActive,erasing:erasing).aspectRatio(1,contentMode:.fit).frame(maxWidth:520).background(paperAppearance.color).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.quaternary)).disabled(saving)
                HStack {
                    Toggle("Eraser",isOn:$erasing).toggleStyle(.button)
                    Button("Clear",role:.destructive) { drawing=PKDrawing();edits.changed() }.disabled(saving || strokeActive)
                    Spacer()
                    Button("Save character") { Task { await saveGlyph() } }.disabled(saving || !dirty || strokeActive)
                }
                Button { emergencyExport() } label: { Label { Text("Export unsaved character") } icon: { AppSymbol.exportCharacter.image(in:personalSymbols) } }.disabled(saving || strokeActive || exportingEmergency)
                DisclosureGroup("Character spacing") {
                    Slider(value:Binding(get:{advance},set:{advance=$0;edits.changed()}),in:200...1500,step:10) { Text("Advance width") }
                    Text("Advance: \(Int(advance))")
                    Slider(value:Binding(get:{bearing},set:{bearing=$0;edits.changed()}),in:0...200,step:5) { Text("Left bearing") }
                    Text("Left bearing: \(Int(bearing))")
                }.disabled(saving || strokeActive)
                HStack {
                    Button { step(-1) } label: { Label { Text("Previous") } icon: { AppSymbol.previous.image(in:personalSymbols) } }
                    Spacer()
                    Button { step(1) } label: { Label { Text("Next") } icon: { AppSymbol.next.image(in:personalSymbols) } }
                }.disabled(saving || strokeActive)
                Divider()
                if building { ProgressView("Building font locally");Button("Cancel build") { buildTask?.cancel();publication=nil;building=false }.disabled(saving) }
                else { Button { publish() } label: { Label { Text("Validate and publish version") } icon: { AppSymbol.publishFont.image(in:personalSymbols) } }.buttonStyle(.borderedProminent).disabled(saving || strokeActive) }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !issues.isEmpty { Text("Missing or invalid characters: \(issues.count)").font(.headline) }
                ForEach(issues,id:\.codePoint) { issue in Button("\(String(UnicodeScalar(issue.codePoint)!)): \(PersonalFontLabels.issue(issue.reason))") { switchGlyph(issue.codePoint) } }
                Text("Published versions: \(project.publicationIDs.count)").font(.headline).accessibilityIdentifier("font.versions")
                ForEach(publishedVersions) { version in
                    VStack(alignment:.leading) {
                        Text(PersonalFontLabels.version(version.id,projects:[project])).font(.caption).textSelection(.enabled)
                        Text("ÄÖÜ äöü ß € · The quick brown fox").font(Font(HandwritingFontCatalog.font(catalogID:nil,personalVersion:version,size:30)))
                    }
                }
            }.padding()
        }.paperSurface().navigationTitle("Draw characters").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving || dirty || building || exportingEmergency)
        .interactiveDismissDisabled(dirty || saving || building || exportingEmergency)
        .toolbar { Button("Close project") { if dirty { exitPrompt=true } else { buildTask?.cancel();dismiss() } }.disabled(saving || strokeActive || exportingEmergency) }
        .confirmationDialog("Keep your draft?",isPresented:$exitPrompt,titleVisibility:.visible) {
            Button("Keep draft") { Task { await saveGlyph();if !dirty { buildTask?.cancel();dismiss() } } }
            Button("Discard unsaved character",role:.destructive) { buildTask?.cancel();dismiss() }
            Button("Cancel",role:.cancel) {}
        }
        .onAppear {storageLease=store.protection.retain(remoteFonts:[project.id],blocksCollection:true)}
        .onDisappear {storageLease=nil}
        .task { do {knownVersions=try await store.fontVersions()} catch {self.error=error.localizedDescription;return};for version in publishedVersions { do { try await PersonalFontService(assets:store.assets).register(version:version) } catch { self.error=error.localizedDescription } };await loadGlyph() }
        .sheet(item:$emergencyShare,onDismiss:finishEmergencyShare) { item in ShareFiles(urls:item.urls,onComplete:finishEmergencyShare) }
        .onDisappear { buildTask?.cancel();emergencyTask?.cancel();finishEmergencyShare() }
    }
    private func step(_ offset: Int) {
        let all=FontCoverage.required.sorted().filter{$0 != 32}
        if let i=all.firstIndex(of:codePoint),all.indices.contains(i+offset) { switchGlyph(all[i+offset]) }
    }
    private func switchGlyph(_ cp: UInt32) {
        guard !strokeActive,!saving else { return }
        Task { await saveGlyph();guard !dirty else { return };codePoint=cp;await loadGlyph() }
    }
    private func loadGlyph() async {
        saving=true;defer { saving=false }
        do {
            let currentProjects=await store.fontProjects();knownVersions=try await store.fontVersions()
            if let current=currentProjects.first(where:{$0.id==project.id}) {project=current}
            let data: PKDrawing
            if let hash=project.glyphAssetHashes[codePoint] { data=try PKDrawing(data:await store.assets.read(hash:hash)) } else { data=PKDrawing() }
            drawing=data;loaded=codePoint;glyphBaseHash=project.glyphAssetHashes[codePoint];glyphBaseMetrics=project.glyphMetrics[codePoint]
            advance=project.glyphMetrics[codePoint]?.advanceWidth ?? 600
            bearing=project.glyphMetrics[codePoint]?.leftBearing ?? 40
            edits.reset()
        } catch { self.error=error.localizedDescription }
    }
    private func emergencyExport() {
        guard !saving,!strokeActive,!exportingEmergency else { return }
        let bytes=drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
        let metrics=bytes == nil ? nil : GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:advance,leftBearing:bearing)
        let glyph=UnsavedGlyph(projectID:project.id,codePoint:loaded,bytes:bytes,metrics:metrics)
        exportingEmergency=true
        emergencyTask=Task {
            defer { exportingEmergency=false }
            do {
                let root=try await store.emergencyExportDirectory(),package=NotebookPackage(root:root)
                let capture=try await store.captureBackup(glyph:glyph)
                let url=try await package.create(capture:capture,assets:store.assets)
                if Task.isCancelled { try await package.remove(url);throw CancellationError() }
                emergencyCleanup={ try? await package.remove(url) };emergencyShare=SharedFiles(urls:[url])
            } catch { self.error=error.localizedDescription }
        }
    }
    private func finishEmergencyShare() {
        let action=emergencyCleanup;emergencyCleanup=nil;emergencyShare=nil
        if let action { Task { await action() } }
    }
    private func saveGlyph() async {
        guard dirty,!saving,!strokeActive else { return };saving=true;defer { saving=false }
        do {
            let savedGeneration=edits.generation,cp=loaded,expectedHash=glyphBaseHash,expectedMetrics=glyphBaseMetrics
            let bytes=drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
            let metrics=bytes == nil ? nil : GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:advance,leftBearing:bearing)
            var hash: String?
            if let bytes { let asset=try await store.assets.stage(data:bytes);hash=try await store.assets.finalize(asset) }
            project=try await store.saveFontGlyph(projectID:project.id,codePoint:cp,expectedHash:expectedHash,expectedMetrics:expectedMetrics,hash:hash,metrics:metrics);didCommit()
            glyphBaseHash=hash;glyphBaseMetrics=metrics
            edits.saved(generation:savedGeneration)
            status=dirty ? "" : String(localized:"Character saved locally")

        } catch NotebookError.revisionConflict { self.error=String(localized:"This character changed in another window. Your unsaved drawing is still here. Keep this project open to preserve it, or explicitly discard it before reopening the saved character.") } catch { self.error=error.localizedDescription }
    }
    private func publish() {
        buildTask=Task {
            await saveGlyph();guard !dirty else { return }
            let token=UUID();publication=token;building=true;error=nil;issues=[]
            defer { if publication==token {building=false} }
            do {
                let service=PersonalFontService(assets:store.assets),snapshot=project
                let found=try await service.validate(project:snapshot);try Task.checkCancellation()
                guard found.isEmpty else { issues=found;return }
                #if DEBUG
                if ProcessInfo.processInfo.environment["MEETINGBOOK_FONT_BUILD_PAUSE"] == "1" { try await Task.sleep(for:.seconds(6)) }
                #endif
                let result=try await service.build(project:snapshot);try Task.checkCancellation()
                _=try await store.assets.finalize(result.asset);try Task.checkCancellation()
                try await service.register(version:result.version);try Task.checkCancellation()
                while saving { try await Task.sleep(for:.milliseconds(10)) }
                guard publication==token else { return }
                saving=true;defer { saving=false }
                project=try await store.publishFontVersion(projectID:project.id,version:result.version);didCommit();status=String(localized:"Published locally. Existing notes keep their version.")
            } catch is CancellationError {} catch { self.error=error.localizedDescription }
        }
    }
}

private struct GlyphBoard: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var dirty: Bool
    @Binding var active: Bool
    let erasing: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> GlyphBoardView { let view=GlyphBoardView();view.canvas.delegate=context.coordinator;return view }
    func updateUIView(_ view: GlyphBoardView,context: Context) {
        view.backgroundColor=context.environment.paperAppearance.uiColor
        view.overrideUserInterfaceStyle = .light
        context.coordinator.parent=self
        if view.canvas.drawing.dataRepresentation() != drawing.dataRepresentation() { context.coordinator.updating=true;view.canvas.drawing=drawing;context.coordinator.updating=false }
        view.canvas.tool=erasing ? PKEraserTool(.bitmap) : PKInkingTool(.pen,color:.black,width:6)
    }
    final class Coordinator: NSObject,PKCanvasViewDelegate {
        var parent: GlyphBoard;var updating=false
        init(_ parent: GlyphBoard) { self.parent=parent }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { parent.active=true }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { parent.active=false }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { guard !updating else { return };parent.drawing=canvasView.drawing;parent.dirty=true }
    }
}
private final class GlyphBoardView: UIView {
    let canvas=PKCanvasView()
    private let guides=GlyphGuides()
    override init(frame:CGRect) {
        super.init(frame:frame);guides.backgroundColor = .clear;guides.isOpaque=false;addSubview(guides);addSubview(canvas)
        canvas.backgroundColor = .clear;canvas.isOpaque=false;canvas.drawingPolicy = .anyInput;canvas.isScrollEnabled=false
        canvas.accessibilityLabel=String(localized:"Character drawing area");canvas.accessibilityIdentifier="font.glyph.canvas"
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews();let scale=min(bounds.width,bounds.height)/400
        for view in [guides,canvas] { view.bounds=CGRect(x:0,y:0,width:400,height:400);view.transform=CGAffineTransform(scaleX:scale,y:scale);view.center=CGPoint(x:bounds.midX,y:bounds.midY) }
    }
}
private final class GlyphGuides: UIView {
    override func draw(_ rect:CGRect) {
        guard let c=UIGraphicsGetCurrentContext() else { return }
        c.setStrokeColor(UIColor.gray.cgColor);c.setLineWidth(1)
        for y in [90.0,150,300,375] { c.move(to:CGPoint(x:20,y:y));c.addLine(to:CGPoint(x:380,y:y));c.strokePath() }
    }
}


// Presentation only: persisted service diagnostics and immutable font identities stay unchanged.
enum PersonalFontLabels {
    static func version(_ id: UUID,projects: [FontProject]) -> String {
        for project in projects {
            if let index=project.publicationIDs.firstIndex(of:id) {
                return project.name+" · "+String(localized:"Version \(index+1)")
            }
        }
        return String(localized:"Personal handwriting")
    }
    static func issue(_ reason: String) -> String {
        switch reason {
        case "missingDrawing": String(localized:"Draw and save this character.")
        case "missingMetrics", "invalidMetrics": String(localized:"Check the character width and guide measurements, then save again.")
        case "unsupportedInk": String(localized:"Redraw this character with the solid pen.")
        case "tooComplex": String(localized:"Simplify the strokes, then save again.")
        case "invalidOutline": String(localized:"Keep the strokes within the guides and save again.")
        case "invalidDrawing": String(localized:"This drawing could not be read. Redraw and save it.")
        case "registration": String(localized:"The font could not be activated. Try publishing again.")
        case "invalidFont": String(localized:"The font could not be validated. Check the characters and try again.")
        default: String(localized:"Check this character and save it again.")
        }
    }
}


struct GlyphEditState {
    private(set) var generation: UInt64=0
    private(set) var dirty=false
    mutating func changed() { generation &+= 1;dirty=true }
    mutating func saved(generation captured: UInt64) { if generation==captured {dirty=false} }
    mutating func reset() { generation &+= 1;dirty=false }
}
