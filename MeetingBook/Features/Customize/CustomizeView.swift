import SwiftUI
import CoreHaptics
import MeetingBookCore

struct CustomizeView: View {
    let store: NotebookStore
    let session: EditorSession?
    var library:LibraryModel? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var defaults=TextDefaults()
    @State private var versions:[FontVersion]=[]
    @State private var fontProjects:[FontProject]=[]
    @State private var preview: EditorSession.Preview?
    @State private var previewImage: UIImage?
    @State private var error: String?
    @State private var busy=false
    @State private var fontsReady=false
    @AppStorage("paper") private var paper="classic"
    @AppStorage("ruling") private var ruling="lined"
    @AppStorage("haptics") private var haptics=false
    @AppStorage("startup") private var startup="last"
    var body: some View {
        NavigationStack {
            Form {
                Section("New writing") {
                    Picker("Font",selection:Binding(get:{defaults.fontVersionID?.uuidString ?? defaults.fontCatalogID ?? "system"},set:{value in if let id=UUID(uuidString:value) {defaults.fontVersionID=id} else {defaults.fontVersionID=nil;defaults.fontCatalogID=value} })) {
                        Text("Caveat").tag("bundled.caveat");Text("Gochi Hand").tag("bundled.gochi-hand");Text("System · readable").tag("system")
                        ForEach(versions) { Text(PersonalFontLabels.version($0.id,projects:fontProjects)).tag($0.id.uuidString) }
                    }
                    Picker("Document size",selection:$defaults.fontSize) { Text("Small · 24").tag(24.0);Text("Medium · 30").tag(30.0);Text("Large · 36").tag(36.0) }
                    Picker("Ink",selection:$defaults.ink) { Text("Marine").tag("marine");Text("Plum").tag("plum");Text("Ochre").tag("ochre");Text("Teal").tag("teal");Text("Graphite").tag("graphite") }
                    Picker("Paper",selection:$paper) { Text("Classic").tag("classic");Text("Cream").tag("cream");Text("Rose").tag("rose") }
                    Picker("Ruling",selection:$ruling) { Text("Lined").tag("lined");Text("Grid").tag("grid");Text("Dots").tag("dots") }
                    ContrastChoice(paper:paper,ink:$defaults.ink)
                    Text("ÄÖÜ äöü ß € · A quiet place to think.").font(Font(HandwritingFontCatalog.font(catalogID:defaults.fontCatalogID,personalVersion:versions.first{$0.id==defaults.fontVersionID},size:defaults.fontSize)))
                    Text("Defaults apply to new writing. Existing pages change only after preview and confirmation.").font(.caption)
                    Button("Save defaults") { run { var p=await store.preferences();p.version=2;p.textDefaults=defaults;try await store.savePreferences(p);library?.syncForeground();await session?.loadFonts() } }.disabled(!fontsReady)
                }
                if let session {
                    Section("Existing note") {
                        Button("Preview on this note") {
                            run {
                                try await session.leave()
                                await session.loadFonts()
                                let candidate=try session.preview(pageIDs:Set(session.snapshot.note.pageIDs)) { content in
                                    content.prepareForEditing();content.style.paper=paper;content.style.ink=defaults.ink;content.style.fontSize=defaults.fontSize
                                    if content.template.supportsPaperRuling { content.style.ruling=ruling }
                                    for i in content.textBlocks.indices { content.textBlocks[i].fontCatalogID=defaults.fontCatalogID;content.textBlocks[i].fontVersionID=defaults.fontVersionID;content.textBlocks[i].fontSize=defaults.fontSize;content.textBlocks[i].ink=defaults.ink }
                                }
                                if let content=candidate.contents[session.activePageID] { let resources=try await PageRenderer.resources(for:content,store:store);previewImage=try PageRenderer.image(content,resources:resources,scale:0.6) }
                                preview=candidate
                            }
                        }.disabled(session.busy || session.hasCurrentAssetWrites || !fontsReady)
                        if let previewImage { Image(uiImage:previewImage).resizable().scaledToFit().frame(maxHeight:400) }
                        if let preview { Button("Apply to note") { run { try await session.apply(preview);self.preview=nil;previewImage=nil } }.disabled(session.busy || session.hasCurrentAssetWrites || !fontsReady) }
                        Button("Undo",systemImage:"arrow.uturn.backward") { run { try await session.undo() } }.disabled(!session.canUndo || session.hasCurrentAssetWrites)
                    }
                }
                Section("Opening the notebook") {
                    Picker("Start with",selection:$startup) { Text("Last page").tag("last");Text("New note").tag("new");Text("Latest bookmark").tag("bookmark") }
                    if CHHapticEngine.capabilitiesForHardware().supportsHaptics { Toggle("Haptic feedback",isOn:$haptics) }
                }
                if let library {
                    Section("Widget privacy") {
                        Toggle("Show note text in widgets",isOn:Binding(get:{library.widgetPreviewEnabled},set:{enabled in Task {await library.setWidgetPreview(enabled)}}))
                        Text("Off by default. Enabling copies up to 120 characters from each linked page to system widget surfaces. Only saved text is copied; images and handwriting are not shared.").font(.caption)
                        Text("The shared file is protected while your device is locked. Already rendered widget previews may remain in system caches, including after locking or turning previews off. Refresh timing is controlled by the system.").font(.caption)
                        if library.widgetRevocationPending {Text("Preview removal is pending. Previously cached text may still be visible.").foregroundStyle(.secondary)}
                        if library.widgetPublicationFailed {
                            Text("The widget could not refresh. Your notebook changes are saved.")
                            Button("Retry widget update") {Task {await library.refreshWidget()}}
                        }
                    }
                }
                Section("Privacy and help") {
                    Text("MeetingBook works offline without registration. It does not record audio, read your location or contacts, run analytics, or recognize text in drawings.")
                    Text("Optional iCloud transfer requires your consent for the selected account and library, including notes, images and personal handwriting fonts. Local saves continue independently. Keep separate backups of important work.")
                    Text("If saving fails, keep this window open and use Export and recovery to capture its unsaved drafts. Other windows and open Font Studio drawings must be exported from their own window.")
                }
                Section("Licenses") {
                    ForEach(HandwritingFontCatalog.entries,id:\.id) { entry in NavigationLink(entry.name) { ScrollView { Text((try? HandwritingFontCatalog.licenseText(for:entry)) ?? String(localized:"License unavailable")).padding().textSelection(.enabled) } } }
                }
                Section("Software") {
                    NavigationLink("ZIPFoundation · MIT license") {
                        ScrollView { Text((Bundle.main.url(forResource:"ZIPFoundation-MIT",withExtension:"txt").flatMap {try? String(contentsOf:$0,encoding:.utf8)}) ?? String(localized:"License unavailable")).padding().textSelection(.enabled) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.navigationTitle("Customize").disabled(busy)
                .toolbar { Button("Done") { dismiss() } }
                .task { defaults=await store.preferences().textDefaults ?? TextDefaults();fontProjects=await store.fontProjects();versions=fontProjects.flatMap(\.versions);for v in versions { do { try await PersonalFontService(assets:store.assets).register(version:v) } catch { self.error=error.localizedDescription;return } };fontsReady=true }
                .onChange(of:defaults) { _,_ in preview=nil;previewImage=nil }
                .onChange(of:paper) { _,_ in preview=nil;previewImage=nil }
                .onChange(of:ruling) { _,_ in preview=nil;previewImage=nil }
        }
    }
    private func run(_ action:@escaping @MainActor () async throws -> Void) { Task { busy=true;defer {busy=false};do {try await action()} catch {self.error=error.localizedDescription} } }
}

@MainActor enum PaperContrast {
    static func ratio(paper: String,ink: String) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0;color.getRed(&r,green:&g,blue:&b,alpha:&a)
            func linear(_ v:CGFloat) -> Double { let x=Double(v);return x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
            return 0.2126*linear(r)+0.7152*linear(g)+0.0722*linear(b)
        }
        let paper=luminance(PageRenderer.paperColor(paper)),ink=luminance(TextBlockView.ink(ink))
        return (max(paper,ink)+0.05)/(min(paper,ink)+0.05)
    }
}
struct ContrastChoice: View {
    let paper: String
    @Binding var ink: String
    var body: some View {
        if PaperContrast.ratio(paper:paper,ink:ink)<4.5 {
            VStack(alignment:.leading,spacing:8) {
                Label("Low contrast when this page is scaled down.",systemImage:"eye.trianglebadge.exclamationmark")
                Button("Use graphite for stronger contrast") { ink="graphite" }
            }.font(.subheadline)
        }
    }
}

struct SyncSettingsView:View {
    @Bindable var library:LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var consent=false
    @State private var retireConfirmation=false
    var body:some View {
        NavigationStack {
            Form {
                Section("iCloud transfer") {
                    Text(status).accessibilityIdentifier("sync.status")
                    Text("Local saves work independently of iCloud. Sync is not a separate backup.").font(.caption)
                    if library.inspection == nil {
                        Button("Inspect iCloud library") {Task {await library.beginCloudInspection()}}
                        if library.syncScope?.accountFingerprint != nil {Button("Resume or retry this account") {Task {await library.retryCloud()}}}
                    }
                    if library.inspection != nil {Button("Retry inspection") {Task {await library.retryCloud()}}}
                    Button("Disable transfer, keep data") {Task {await library.disableCloud()}}
                    Text("Disabling keeps local and iCloud data. Already submitted transfers may finish.").font(.caption)
                }
                if library.inspection != nil {
                    Section("Choose this account’s library") {
                        Text("\(library.inspectionNotes) cloud notes available for inspection")
                        Text("Inspection may still have pending downloads. The current local library remains recoverable.")
                        Toggle("I allow notes, images and personal handwriting fonts, including future edits, to be transferred for this account and library.",isOn:$consent).accessibilityIdentifier("sync.consent")
                        Text("Merge adds all current local content as new copies to this cloud library. Keep separate opens the cloud library and retains the local library on this device.").font(.caption)
                        Button("Merge all local content") {Task {await library.commitCloudChoice(merge:true,personalContentConsent:consent)}}.disabled(!consent || library.inspectionToken==nil)
                        Button("Keep libraries separate") {Task {await library.commitCloudChoice(merge:false,personalContentConsent:consent)}}.disabled(!consent || library.inspectionToken==nil)
                    }
                }
                if let message=library.syncMessage {Section {Text(message).foregroundStyle(.secondary).textSelection(.enabled)}}
                if !library.pageConflicts.isEmpty {
                    Section("Page conflicts") {
                        Text("Choices affect the named page or deleted note. Other blocked changes may still need a separate decision.").font(.caption)
                        ForEach(library.pageConflicts) { conflict in
                            NavigationLink {SyncPageConflictView(library:library,conflict:conflict)} label: {Text(subject(conflict))}.accessibilityIdentifier("sync.conflict."+conflict.id.uuidString)
                        }
                    }
                }
                if !library.pendingSync.isEmpty {
                    Section("Pending changes") {
                        ForEach(library.pendingSync) { pending in
                            VStack(alignment:.leading,spacing:8) {
                                Text(reason(pending.reason)).font(.headline)
                                Text("\(pending.affectedPageIDs.count) pages · \(pending.affectedFontIDs.count) font projects")
                                if pending.reason == .conflict,let token=library.conflictToken {
                                    Text("This decision covers the complete incoming change, including its note structure and font changes.").font(.caption)
                                    Text(pending.entities.sorted().map{syncEntityDescription($0,library:library)}.joined(separator:"\n")).font(.caption).textSelection(.enabled)
                                    Button("Keep current complete change") {Task {await library.resolveConflict(transaction:pending.id,choice:.a,token:token)}}
                                    Button("Use incoming complete change") {Task {await library.resolveConflict(transaction:pending.id,choice:.b,token:token)}}
                                    Button("Keep both as separate copies") {Task {await library.resolveConflict(transaction:pending.id,choice:.both,token:token)}}
                                }
                            }
                        }
                        Text("Saved pages can still be protected by Undo in any window. Close Font Studio and finish drafts first.").font(.caption)
                        Button("Retire saved Undo history and retry") {retireConfirmation=true}
                    }
                }
                if !library.transportIssues.isEmpty {
                    Section("Transfer needs attention") {
                        ForEach(library.transportIssues.keys.sorted(),id:\.self) { id in
                            if let issue=library.transportIssues[id] {
                                VStack(alignment:.leading,spacing:8) {
                                    Text(issueMessage(issue.code))
                                    if let deadline=issue.retryAfter {Text(deadline,format:.dateTime)}
                                    if [.offline,.quota,.rateLimited,.oversize,.service,.missingProvider].contains(issue.code) {Button("Retry transfer") {Task {await library.retryIssue(id)}}}
                                }
                            }
                        }
                        Text("Use Export and recovery to keep a separate package while transfer is blocked.").font(.caption)
                    }
                }
                if !library.retainedRoots.isEmpty {
                    Section("Retained libraries on this device") {
                        Text("Open one retained library at a time with transfer disabled. Earlier unsaved drafts can be exported from their original window’s Export and recovery screen.").font(.caption)
                        ForEach(library.retainedRoots) {root in
                            if root.scope.receiveOnly == true {
                                Button("Resume read-only inspection") {Task {await library.resumeInspection(root.id)}}
                            } else {
                                Button {Task {await library.selectRetainedRoot(root.id)}} label: {
                                    VStack(alignment:.leading) {
                                        Text(root.scope.accountFingerprint == nil ? LocalizedStringResource("Retained local library") : LocalizedStringResource("Retained account library"))
                                        Text("\(root.notes) notes").font(.caption)
                                        Text(root.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }.disabled(library.syncBusy)
            .overlay {if library.syncBusy {ProgressView("Preparing transfer")}}
            .navigationTitle("iCloud").navigationBarTitleDisplayMode(.inline)
            .toolbar {Button("Done") {dismiss()}.disabled(library.syncBusy)}
            .onChange(of:library.inspection?.rootID) {_,_ in consent=false}
            .task {do {try await library.refreshSyncDiagnostics()} catch {library.syncStatus = .integrity;library.syncMessage=error.localizedDescription};await library.loadRetainedRoots()}
            .confirmationDialog("Retire Undo history in every window for this library?",isPresented:$retireConfirmation,titleVisibility:.visible) {
                Button("Retire Undo history") {Task {await library.retireUndoAndRetry()}}
            } message: {Text("Only saved sessions are eligible. Undo and Redo will be cleared explicitly; saved revisions and recovery copies remain available.")}
        }.interactiveDismissDisabled(library.syncBusy)
    }
    private var status:LocalizedStringResource {
        switch library.syncStatus {
        case .local: "On this device"
        case .disabled: "Transfer disabled; data retained"
        case .inspecting: "Inspecting iCloud without uploading local content"
        case .choice: "Waiting for your library and handwriting consent"
        case .pending: "Changes are still pending"
        case .checked: "No pending changes in this checked library"
        case .accountBlocked: "iCloud account needs attention"
        case .offline: "Transfer delayed; local work is available"
        case .quota: "iCloud storage is full; local work is available"
        case .integrity: "Transfer needs review; local content is retained"
        }
    }
    private func subject(_ conflict:SyncConflict) -> String {
        syncEntityDescription(library.conflictSubjects[conflict.id] ?? conflict.entity,library:library)
    }

    private func reason(_ reason:SyncPendingReason) -> LocalizedStringResource {
        switch reason {case .ready:"Ready for local activation";case .incomplete:"Waiting for complete downloaded content";case .leased:"Protected by an open draft or Undo history";case .conflict:"Complete change needs a decision"}
    }
    private func issueMessage(_ code:SyncTransportState.Code) -> LocalizedStringResource {
        switch code {
        case .offline:"Offline. Changes remain queued."
        case .quota:"iCloud storage is full. Free space and retry, or export a package."
        case .rateLimited:"iCloud requested a pause before retrying."
        case .oversize:"A transfer exceeds the supported size. Local content and package export remain available."
        case .serverVerification:"Waiting to verify the server’s existing content."
        case .collision:"Conflicting immutable content needs review. Nothing was silently replaced."
        case .service:"iCloud is temporarily unavailable."
        case .invalidDelivery:"Downloaded content could not be validated. The last valid content remains available."
        case .missingProvider:"A pending transfer could not be prepared. Retry after local work finishes."
        case .remoteDeletion:"A remote record is missing. Local data remains available for recovery."
        }
    }
}

private struct SyncPageConflictView:View {
    @Bindable var library:LibraryModel
    let conflict:SyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var previews:[UIImage]=[]
    @State private var sourceTexts:[String]=[]
    @State private var previewError:String?
    var body:some View {
        Form {
            Section("Affected content") {
                Text(syncEntityDescription(library.conflictSubjects[conflict.id] ?? conflict.entity,library:library)).textSelection(.enabled)
                if conflict.deletionOperationID != nil {
                    Text("Keeping deletion archives the untouched recovery copy. Restoring a deleted note makes the whole note visible; restoring a page restores its membership and order. Keeping a separate note preserves the original deletion.")
                } else {Text("A and B are the preserved source versions shown below. Keeping both also keeps a separate recovery note.")}
                ForEach(previews.indices,id:\.self) {index in
                    VStack {Text(previewTitle(index));Image(uiImage:previews[index]).resizable().scaledToFit().frame(maxHeight:420).accessibilityLabel(Text(index==0 ? LocalizedStringResource("Version A page preview") : LocalizedStringResource("Version B page preview")));if sourceTexts.indices.contains(index) {DisclosureGroup("Readable version text") {Text(sourceTexts[index]).textSelection(.enabled)}}}
                }
                if let previewError {Text(previewError)}
            }
            if let token=library.conflictToken {
                Section("Choose a preserved version") {
                    Button(actionTitle(.a)) {choose(.a,token)}
                    Button(actionTitle(.b)) {choose(.b,token)}
                    Button(actionTitle(.both)) {choose(.both,token)}
                }.disabled(library.syncBusy || library.inspection != nil)
            }
            if let message=library.syncMessage {Text(message)}
        }.navigationTitle("Review conflict")
        .onChange(of:library.pageConflicts.map(\.id)) {_,ids in if !ids.contains(conflict.id) {dismiss()}}
        .task {
            guard let store=library.store else {return}
            do {
                let revisions=try await store.conflictSourceRevisions(conflict)
                var images:[UIImage]=[]
                for revision in revisions {let resources=try await PageRenderer.resources(for:revision.content,store:store);images.append(try PageRenderer.image(revision.content,resources:resources,scale:0.6))}
                guard library.store?.identity==store.identity else {return};previews=images;sourceTexts=revisions.map{$0.content.textBlocks.map(\.text).joined(separator:"\n")}
            } catch {previewError=error.localizedDescription}
        }
    }
    private func previewTitle(_ index:Int) -> LocalizedStringResource {
        if conflict.deletionOperationID != nil {return "Edited version"}
        return index==0 ? "Version A" : "Version B"
    }
    private func actionTitle(_ choice:SyncConflictChoice) -> LocalizedStringResource {
        if conflict.deletionOperationID != nil {
            switch choice {case .a:return "Keep deletion";case .b:return "Restore edited version";case .both:return "Keep as a separate note"}
        }
        switch choice {case .a:return "Keep version A";case .b:return "Keep version B";case .both:return "Keep both versions"}
    }
    private func choose(_ choice:SyncConflictChoice,_ token:String) {Task {await library.resolveConflict(page:conflict.id,choice:choice,token:token)}}
}


@MainActor private func syncEntityDescription(_ entity:String,library:LibraryModel) -> String {
    let parts=entity.split(separator:"/").map(String.init)
    if entity=="bookmarkOrder" {return String(localized:"Bookmark order")}
    if entity=="preference/textDefaults" {return String(localized:"New writing settings")}
    guard parts.count>=2,let id=UUID(uuidString:parts[1]) else {return String(localized:"Related saved content")}
    let subject:String
    if parts[0]=="note" {subject=String(localized:"Note: \(library.notes.first(where:{$0.id==id})?.title ?? id.uuidString)")}
    else if parts[0]=="page",let note=library.notes.first(where:{$0.pageIDs.contains(id)}) {
        let number=LibraryRules.displayNumbers(notes:library.notes)[id] ?? 0
        subject=String(localized:"Page \(number)")+" · "+note.title
    } else if parts[0]=="font" {subject=String(localized:"Font project: \(library.syncFontNames[id] ?? id.uuidString)")}
    else if parts[0]=="page" {subject=String(localized:"Page: \(id.uuidString)")}
    else {subject=String(localized:"Related saved content")}
    return subject
}
