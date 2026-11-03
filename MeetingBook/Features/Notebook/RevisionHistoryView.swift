import SwiftUI
import MeetingBookCore

struct RevisionHistoryView: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var revisions:[PageRevision]=[]
    @State private var selected: EditorSession.Preview?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var busy=false
    @State private var historyLease: StorageLease?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Preview a saved revision before restoring it. Your current page is kept in history.");Text("Only retained content is offered. Pruned ancestry cannot be restored.").font(.caption) }
                ForEach(revisions) { revision in
                    Button { Task {
                        busy=true;defer {busy=false}
                        do {
                            try await session.leave()
                            selected=try session.preview(pageIDs:[revision.pageID],transform:{$0=revision.content},reason:.recovery)
                            let resources=try await PageRenderer.resources(for:revision.content,store:session.store)
                            image=try PageRenderer.image(revision.content,resources:resources,scale:0.6)
                        } catch { self.error=error.localizedDescription }
                    } } label: { Text(revision.createdAt,format:.dateTime.year().month().day().hour().minute().second()) }
                }
                if let image { Image(uiImage:image).resizable().scaledToFit().accessibilityLabel("Revision preview") }
                if let selected { Button("Restore this revision") { Task { busy=true;defer {busy=false};do {try await session.apply(selected);dismiss()} catch {self.error=error.localizedDescription} } } }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Page history").disabled(busy)
                .toolbar { Button("Done") { dismiss() } }
                .onDisappear {historyLease=nil}
                .task { historyLease=session.store.protection.retain(remotePages:[session.activePageID],blocksCollection:true);do { revisions=try await session.store.checkpoints(pageID:session.activePageID) } catch { self.error=error.localizedDescription } }
        }
    }
}
