import SwiftUI
import MeetingBookCore

struct SpreadWorkspace: View {
    @Bindable var session: EditorSession
    let notes: [Note]
    var navigationPending=false
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    var body: some View {
        let pair=NotebookSearch.spreadIDs(active:session.activePageID,notes:notes)
        PageEditor(session:session,navigationPending:navigationPending,navigationIDs:LibraryRules.orderedNotes(notes).flatMap(\.pageIDs),onNavigate:onSelect,
                   leadingPaper:pair.right == session.activePageID ? paper(pair.left,blank:true) : nil,
                   trailingPaper:pair.left == session.activePageID ? paper(pair.right) : nil)
        .simultaneousGesture(DragGesture(minimumDistance:24).onEnded { value in
            guard !session.navigationLocked,!session.busy,!session.hasCurrentAssetWrites,
                  let target=NotebookSearch.swipeTarget(active:session.activePageID,ids:LibraryRules.orderedNotes(notes).flatMap(\.pageIDs),horizontal:value.translation.width,vertical:value.translation.height,reading:session.mode == .reading) else { return }
            onSelect(target)
        },including:session.mode == .reading ? .all : .none)
    }
    private func paper(_ id: UUID?,blank: Bool=false) -> AnyView {
        if id == nil && blank {return AnyView(BookPlaceholder(paper:session.activeContent.style.paper,add:false,enlarged:session.mode == .reading && session.largerReadingView).accessibilityHidden(true))}
        if let id { return AnyView(FrozenPage(store:session.store,pageID:id,content:session.drafts[id]?.content,enlarged:session.mode == .reading && session.largerReadingView,onSelect:onSelect)) }
        return AnyView(Button(action:onAdd) {BookPlaceholder(paper:session.activeContent.style.paper,add:true,enlarged:session.mode == .reading && session.largerReadingView)})
    }

}
struct BookPlaceholder: View {
    let paper: String
    let add: Bool
    var enlarged=false
    @Environment(\.paperViewportOffset) private var offset
    var body: some View {
        GeometryReader { geometry in
            let scale=geometry.size.width/720*(enlarged ? 2 : 1)
            let origin=BookPresentation.viewportOffset(offset,scale:scale,viewport:geometry.size)
            ZStack(alignment:.topLeading) {
                Color(uiColor:.secondarySystemBackground)
                ZStack(alignment:.trailing) {
                    Color(uiColor:PageRenderer.paperColor(paper))
                    LinearGradient(colors:[.clear,.black.opacity(0.08)],startPoint:.leading,endPoint:.trailing).frame(width:24)
                    if add {Label("Add page",systemImage:"doc.badge.plus").foregroundStyle(Color(uiColor:.darkGray)).frame(maxWidth:.infinity,maxHeight:.infinity)}
                }.frame(width:720*scale,height:1000*scale)
                 .position(x:360*scale-origin.x,y:500*scale-origin.y)
            }.clipped()
        }
    }
}

private struct FrozenPage: View {
    private struct RenderKey: Equatable { let id: UUID;let content: PageContent? }
    let store: NotebookStore
    let pageID: UUID
    let content: PageContent?
    let enlarged: Bool
    let onSelect: (UUID) -> Void
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        Group {
            if let image { FrozenPaperHost(image:image,enlarged:enlarged,onSelect:{onSelect(pageID)}) }
            else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .task(id:RenderKey(id:pageID,content:content)) {
            do {
                let value: PageContent
                if let content { value=content } else { value=try await store.openPage(id:pageID).content }
                let resources=try await PageRenderer.resources(for:value,store:store);try Task.checkCancellation()
                image=try PageRenderer.image(value,resources:resources,scale:0.7)
            } catch is CancellationError {} catch { self.error=error.localizedDescription }
        }
    }
}


private struct FrozenPaperHost: UIViewControllerRepresentable {
    let image: UIImage
    let enlarged: Bool
    @Environment(\.paperViewportOffset) private var offset
    let onSelect: () -> Void
    func makeUIViewController(context: Context) -> FrozenPaperController { let view=FrozenPaperController();view.onSelect=onSelect;return view }
    func updateUIViewController(_ controller: FrozenPaperController,context: Context) { controller.image.image=image;controller.enlarged=enlarged;controller.offset=offset;controller.onSelect=onSelect;controller.view.setNeedsLayout() }
}
final class FrozenPaperController: UIViewController {
    let scroll=UIScrollView(),image=UIImageView()
    var enlarged=false
    var offset=CGPoint.zero
    var onSelect: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .secondarySystemBackground
        scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor)])
        scroll.isScrollEnabled=false;scroll.addSubview(image);image.contentMode = .scaleToFill;image.isUserInteractionEnabled=true
        image.accessibilityIdentifier="passive.paper";image.isAccessibilityElement=true;image.accessibilityLabel=String(localized:"Open neighboring page");image.accessibilityTraits = .button
        image.addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(selectPage)))
        image.accessibilityCustomActions=[UIAccessibilityCustomAction(name:String(localized:"Open neighboring page"),target:self,selector:#selector(selectPage))]
    }
    @objc private func selectPage() -> Bool {onSelect?();return true}
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale=scroll.bounds.width/720*(enlarged ? 2 : 1)
        image.frame=CGRect(x:0,y:0,width:720*scale,height:1000*scale);scroll.contentSize=image.bounds.size
        scroll.contentOffset=BookPresentation.viewportOffset(offset,scale:scale,viewport:scroll.bounds.size)
    }
}
