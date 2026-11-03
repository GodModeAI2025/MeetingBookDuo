import SwiftUI
import WidgetKit

struct NotebookEntry:TimelineEntry {
    let date:Date
    let snapshot:WidgetSnapshot
}
struct NotebookProvider:TimelineProvider {
    func placeholder(in context:Context) -> NotebookEntry {NotebookEntry(date:Date(),snapshot:WidgetSnapshot())}
    func getSnapshot(in context:Context,completion:@escaping @Sendable (NotebookEntry)->Void) {
        completion(context.isPreview ? placeholder(in:context) : current())
    }
    func getTimeline(in context:Context,completion:@escaping @Sendable (Timeline<NotebookEntry>)->Void) {
        completion(Timeline(entries:[context.isPreview ? placeholder(in:context) : current()],policy:.never))
    }
    private func current() -> NotebookEntry {
        NotebookEntry(date:Date(),snapshot:WidgetSnapshot.read(from:WidgetSnapshot.directory))
    }
}
struct NotebookWidgetView:View {
    let entry:NotebookEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redaction
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("MeetingBook").font(.headline)
            if family == .systemSmall {
                Spacer(minLength:0)
                Label("New note",systemImage:"square.and.pencil").font(.title3)
                Spacer(minLength:0)
            } else {
                HStack(alignment:.top,spacing:12) {
                    Link(destination:MeetingBookRoute.new.url) {Label("New note",systemImage:"square.and.pencil").frame(maxWidth:.infinity,alignment:.leading)}
                    target(entry.snapshot.last,title:"Last page",symbol:"book")
                    target(entry.snapshot.bookmark,title:"Bookmark",symbol:"bookmark")
                }.font(.subheadline)
                Spacer(minLength:0)
            }
        }
        .containerBackground(.background,for:.widget)
        .widgetURL(MeetingBookRoute.new.url)
    }
    @ViewBuilder private func target(_ target:WidgetSnapshot.Target?,title:LocalizedStringResource,symbol:String) -> some View {
        if let target {
            Link(destination:target.url) {
                VStack(alignment:.leading,spacing:6) {
                    Label(title,systemImage:symbol)
                    if redaction.isEmpty,let preview=target.preview,!preview.isEmpty {Text(preview).font(.caption).lineLimit(2).privacySensitive()}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        } else {
            VStack(alignment:.leading,spacing:6) {Label(title,systemImage:symbol);Text("Unavailable").font(.caption)}
                .foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
@main struct MeetingBookWidget:Widget {
    var body:some WidgetConfiguration {
        StaticConfiguration(kind:WidgetSnapshot.kind,provider:NotebookProvider()) {NotebookWidgetView(entry:$0)}
            .configurationDisplayName("MeetingBook")
            .description("Start a note or return to a saved page.")
            .supportedFamilies([.systemSmall,.systemMedium])
    }
}
