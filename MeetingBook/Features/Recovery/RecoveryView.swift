import SwiftUI
import UniformTypeIdentifiers
import MeetingBookCore

extension UTType { static let notebookPackage=UTType(exportedAs:"de.meetingbook.notebookpkg",conformingTo:.zip) }

struct RecoveryView: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Bindable var library: LibraryModel
    let session: EditorSession?
    let sessions: [EditorSession]
    var initialImportURL: URL?
    var archivedSessions:[UUID:[UUID:EditorSession]]=[:]
    @Environment(\.dismiss) private var dismiss
    @State private var exporter: ExportService?
    @State private var importer: RestoreService?
    @State private var task: Task<Void,Never>?
    @State private var busy=false
    @State private var choosing=false
    @State private var largeImport=false
    @State private var preview: ImportPreview?
    @State private var share: SharedFiles?
    @State private var cleanup: (@MainActor () async -> Void)?
    @State private var backups:[SavedPackage]=[]
    @State private var warnings:[String]=[]
    @State private var error: String?
    @State private var scope="note"
    @State private var format="pdf"
    @State private var retentionMessage: String?
    @State private var completed=0
    @State private var total=0
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section("Export") {
                    Picker("Pages",selection:$scope) { Text("Current page").tag("page");Text("Current note").tag("note");Text("Saved notebook").tag("library") }
                    Picker("Format",selection:$format) { Text("PDF").tag("pdf");Text("PNG").tag("png");Text("TXT").tag("txt") }
                    Button("Export pages") { perform { try await exportPages() } }.disabled(session == nil && scope != "library")
                    Text("PDF keeps supported text selectable. PNG is flattened at 1440 × 2000 pixels. TXT omits drawings, images and layout.").font(.caption)
                }.disabled(busy)
                Section("Backup and emergency recovery") {
                    Button("Back up saved library") { perform { try await backup(emergency:false) } }
                    Button("Export unsaved drafts from this window") { perform { try await backup(emergency:true) } }
                    Text("Emergency packages include this window’s captured note drafts, labelled UNSAVED. Other windows and open Font Studio drawings must be exported there.").font(.caption)
                    Text("Packages contain private notes and handwriting fonts. Choose a protected destination. Open MeetingBook packages in MeetingBook; ordinary ZIP archives are not supported. Packages are not password-encrypted.").font(.caption)
                }.disabled(busy)
                if !archivedSessions.isEmpty {
                    Section("Earlier library drafts in this window") {
                        Text("These sessions remain attached to their original library. Unsaved drafts are available only while this window remains open.").font(.caption)
                        ForEach(archivedSessions.keys.sorted(by:{$0.uuidString<$1.uuidString}),id:\.self) { id in
                            Button("Export earlier library drafts") {perform {try await exportArchived(id)}}
                        }
                    }.disabled(busy)
                }
                Section("Import and restore") {
                    Toggle("Allow large MeetingBook backups",isOn:$largeImport)
                    Text("Large backups require a current MeetingBook version and may need more time and memory. Enable this before choosing a large package.").font(.caption)
                    Button("Inspect notebook package") { choosing=true }
                    if let preview {
                        Text(preview.sourceName);if preview.unsaved { Text("Contains captured unsaved drafts").foregroundStyle(.orange) }
                        Text("\(preview.noteCount) notes · \(preview.pageCount) pages")
                        Text("A verified safety backup is kept before activation. Sync stays off. Merge adds separate copies of the imported notes. Replace opens the imported notebook in place of the current library.").font(.caption)
                        Button("Merge into library") { perform { try await restore(preview,policy:.merge) } }
                        Button("Replace library",role:.destructive) { perform { try await restore(preview,policy:.replace) } }
                        Button("Discard preview",role:.cancel) { perform { try await importer?.discard(preview);self.preview=nil } }
                    }
                }.disabled(busy)
                Section("Local storage") {
                    Text("Cleanup removes expired, unreferenced local payloads. Protected recovery, pending sync, open work and backups are kept.").font(.caption)
                    Button("Clean expired local data") { perform {
                        guard let store=library.store else {return}
                        let result=try await store.collectRetention()
                        retentionMessage=result.deferred ? String(localized:"Finish asset imports and close Font Studio, then try cleanup again.") : String(localized:"Cleanup checked expired local data. Protected data was kept.")
                        try await library.reload()
                    } }
                    if let retentionMessage {Text(retentionMessage)}
                }.disabled(busy)
                if !backups.isEmpty { Section("Safety backups") { ForEach(backups) { backup in Button(backup.createdAt.formatted(date:.abbreviated,time:.shortened)) { perform { if let preview {try await importer?.discard(preview)};preview=try await importer?.inspectImport(url:backup.url,sizePolicy:.large) } } } }.disabled(busy) }
                if busy { Section { ProgressView(value:Double(completed),total:Double(max(total,1)));Button("Cancel") { task?.cancel() } } }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if !warnings.isEmpty { Section("Export notices") { ForEach(Array(warnings.enumerated()),id:\.offset) { Text($0.element) } } }
                }.listRowBackground(paperAppearance.color)
            }.paperSurface().navigationTitle("Export and recovery")
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
        }
        .interactiveDismissDisabled(busy)
        .task {
            guard let store=library.store,let root=library.transferDirectory else { return }
            backups=(try? await store.safetyPackages()) ?? []
            exporter=ExportService(store:store,root:root.appendingPathComponent("Exports"))
            importer=RestoreService(store:store,root:root.appendingPathComponent("Imports"),safetyRoot:library.safetyDirectory)
            if let initialImportURL { perform { preview=try await importer?.inspectImport(url:initialImportURL) } }
        }
        .fileImporter(isPresented:$choosing,allowedContentTypes:[.notebookPackage]) { result in perform { if let preview { try await importer?.discard(preview);self.preview=nil };preview=try await importer?.inspectImport(url:result.get(),sizePolicy:largeImport ? .large : .ordinary) } }
        .sheet(item:$share,onDismiss:finishShare) { item in ShareFiles(urls:item.urls,onComplete:finishShare) }
        .onDisappear { task?.cancel();finishShare();if let preview,let importer { Task { try? await importer.discard(preview) } } }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return };busy=true;error=nil;completed=0;total=0
        task=Task { defer {busy=false};do { try await action() } catch is CancellationError {} catch { self.error=error.localizedDescription };if let store=library.store {backups=(try? await store.safetyPackages()) ?? []} }
    }
    private func exportPages() async throws {
        guard let store=library.store,let exporter else { throw NotebookError.notFound }
        for editor in sessions { try await editor.leave() }
        let selection:NotebookStore.ExportSelection
        if scope=="library" { selection = .library }
        else if let session { selection=scope=="page" ? .page(session.activePageID) : .note(session.snapshot.note.id) }
        else { throw NotebookError.notFound }
        let kind:ExportRequest.Format=format=="pdf" ? .pdf : (format=="png" ? .png : .txt)
        let request=try await store.captureExport(selection:selection,format:kind)
        let result=try await exporter.export(request) { done,count in await MainActor.run { completed=done;total=count } }
        warnings=result.warnings;cleanup={ try? await exporter.remove(result) };share=SharedFiles(urls:result.urls)
    }
    private func backup(emergency: Bool) async throws {
        guard let store=library.store,let root=library.transferDirectory else { throw NotebookError.notFound }
        if emergency { guard sessions.allSatisfy({!$0.busy && !$0.strokeActive && $0.pendingAssetWrites.isEmpty}) else { throw EditorOperationError.inProgress } }
        let drafts=emergency ? sessions.flatMap(\.draftLeases) : []
        let capture=try await store.captureBackup(drafts:drafts)
        let package=NotebookPackage(root:root.appendingPathComponent("Packages"))
        let url=try await package.create(capture:capture,assets:store.assets)
        cleanup={ try? await package.remove(url) };share=SharedFiles(urls:[url])
    }
    private func exportArchived(_ id:UUID) async throws {
        let captured=Array((archivedSessions[id] ?? [:]).values)
        guard let original=captured.first?.store,captured.allSatisfy({$0.store.identity==original.identity && !$0.busy && !$0.strokeActive && $0.pendingAssetWrites.isEmpty}) else {throw TransferError.unsavedWindows}
        let capture=try await original.captureBackup(drafts:captured.flatMap(\.draftLeases)),root=original.root
        let package=NotebookPackage(root:root.appendingPathComponent("Transfers/Temporary/Packages"))
        let url=try await package.create(capture:capture,assets:original.assets)
        cleanup={try? await package.remove(url)};share=SharedFiles(urls:[url])
    }
    private func restore(_ preview: ImportPreview,policy: RestorePolicy) async throws {
        guard let importer else { throw NotebookError.notFound }
        try library.beginRestore();var committed=false
        defer {library.endRestore(committed:committed)}
        self.preview=nil;try await importer.restore(preview,policy:policy);committed=true
        try await library.reload()
    }
    private func finishShare() {
        let action=cleanup;cleanup=nil;share=nil
        if let action { Task { await action() } }
    }
}

struct SharedFiles: Identifiable { let id=UUID();let urls:[URL] }
struct ShareFiles: UIViewControllerRepresentable {
    let urls:[URL]
    let onComplete: @MainActor () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller=UIActivityViewController(activityItems:urls,applicationActivities:nil)
        controller.completionWithItemsHandler={ _,_,_,_ in Task { @MainActor in onComplete() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) {}
}

struct ColdRecoveryView: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Bindable var library: LibraryModel
    let baseRoot: URL
    var initialImportURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var service: ColdRecoveryService?
    @State private var preview: ImportPreview?
    @State private var backups:[SavedPackage]=[]
    @State private var choosing=false
    @State private var largeImport=false
    @State private var busy=false
    @State private var error: String?
    @State private var task: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Text("The original library could not be opened. It will remain untouched. Inspect a notebook package to recover into a separate local library.")
                    Toggle("Allow large MeetingBook backups",isOn:$largeImport)
                    Text("Large backups require a current MeetingBook version and may need more time and memory. Enable this before choosing a large package.").font(.caption)
                    Button("Inspect notebook package") { choosing=true }.disabled(busy)
                }
                if !backups.isEmpty { Section("Safety backups") { ForEach(backups) { backup in Button(backup.createdAt.formatted(date:.abbreviated,time:.shortened)) { run { if let preview {try await service?.discard(preview)};preview=try await service?.inspectImport(url:backup.url,sizePolicy:.large) } } } }.disabled(busy) }
                if let preview {
                    Section("Preview") {
                        Text(preview.sourceName);if preview.unsaved { Text("Contains captured unsaved drafts").foregroundStyle(.orange) };Text("\(preview.noteCount) notes · \(preview.pageCount) pages")
                        Text("Restore activates the verified new library. The original files remain available for recovery. Sync stays off.")
                        Button("Restore into new library") { run { guard let service else {return};try library.beginRestore();var committed=false;defer {library.endRestore(committed:committed)};self.preview=nil;try await service.activate(preview);committed=true;await library.retry();if library.store != nil {dismiss()} } }.disabled(busy)
                    }
                }
                if busy { ProgressView();Button("Cancel") { task?.cancel() } }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.listRowBackground(paperAppearance.color)
            }.paperSurface().navigationTitle("Recovery mode").toolbar { Button("Done") { dismiss() }.disabled(busy) }
        }.interactiveDismissDisabled(busy)
        .task { let recovery=ColdRecoveryService(baseRoot:baseRoot);service=recovery;backups=(try? await recovery.safetyPackages()) ?? [];if let initialImportURL { run { preview=try await recovery.inspectImport(url:initialImportURL) } } }
        .fileImporter(isPresented:$choosing,allowedContentTypes:[.notebookPackage]) { result in run { if let preview {try await service?.discard(preview)};preview=try await service?.inspectImport(url:result.get(),sizePolicy:largeImport ? .large : .ordinary) } }
        .onDisappear { task?.cancel();if let preview,let service { Task {try? await service.discard(preview)} } }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else {return};busy=true;error=nil
        task=Task { defer {busy=false};do {try await action()} catch is CancellationError {} catch {self.error=error.localizedDescription} }
    }
}
