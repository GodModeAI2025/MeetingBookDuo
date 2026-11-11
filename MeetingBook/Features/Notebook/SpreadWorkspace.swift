import SwiftUI
import MeetingBookCore

struct SpreadWorkspace: View {
    @Bindable var session: EditorSession
    let notes: [Note]
    var navigationPending=false
    var indexIsPresented=false
    var indexPaper: AnyView? = nil
    var onIndex: (() -> Void)? = nil
    var bookmarkButton: AnyView? = nil
    var workspaceCommands: AnyView? = nil
    var libraryCommands: AnyView? = nil
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    var body: some View {
        let pair=NotebookSearch.spreadIDs(active:session.activePageID,notes:notes)
        let numbers=LibraryRules.displayNumbers(notes:notes)
        PageEditor(session:session,navigationPending:navigationPending,indexIsPresented:indexIsPresented,indexPaper:indexPaper,onIndex:onIndex,bookmarkButton:bookmarkButton,workspaceCommands:workspaceCommands,libraryCommands:libraryCommands,navigationIDs:LibraryRules.orderedNotes(notes).flatMap(\.pageIDs),onNavigate:onSelect,
                   leadingPageNumber:pair.left.flatMap{numbers[$0]},trailingPageNumber:pair.right.flatMap{numbers[$0]},
                   leadingPaper:pair.right == session.activePageID ? paper(pair.left,blank:true) : nil,
                   trailingPaper:pair.left == session.activePageID ? paper(pair.right) : nil)

    }
    private func paper(_ id: UUID?,blank: Bool=false) -> AnyView {
        if id == nil && blank {return AnyView(BookPlaceholder(paper:session.activeContent.style.paper,add:false,enlarged:session.mode == .reading && session.largerReadingView).accessibilityHidden(true))}
        if let id { return AnyView(FrozenPage(store:session.store,pageID:id,content:session.drafts[id]?.content,enlarged:session.mode == .reading && session.largerReadingView,onSelect:onSelect)) }
        return AnyView(Button(action:onAdd) {BookPlaceholder(paper:session.activeContent.style.paper,add:true,enlarged:session.mode == .reading && session.largerReadingView)})
    }

}
struct BookPlaceholder: View {
    @Environment(\.paperAppearance) private var paperAppearance
    @Environment(\.personalSymbols) private var personalSymbols
    let paper: String
    let add: Bool
    var enlarged=false
    @Environment(\.paperViewportOffset) private var offset
    var body: some View {
        GeometryReader { geometry in
            let scale=geometry.size.width/720*(enlarged ? 2 : 1)
            let origin=BookPresentation.viewportOffset(offset,scale:scale,viewport:geometry.size)
            ZStack(alignment:.topLeading) {
                paperAppearance.color
                ZStack(alignment:.trailing) {
                    Color(uiColor:PageRenderer.paperColor(paper))
                    LinearGradient(colors:[.clear,.black.opacity(0.08)],startPoint:.leading,endPoint:.trailing).frame(width:24)
                    if add {Label { Text("Add page") } icon: { AppSymbol.addPage.image(in:personalSymbols) }.foregroundStyle(Color(uiColor:.darkGray)).frame(maxWidth:.infinity,maxHeight:.infinity)}
                }.frame(width:720*scale,height:1000*scale)
                 .position(x:360*scale-origin.x,y:500*scale-origin.y)
            }.clipped()
        }
    }
}

private struct FrozenPage: View {
    private struct RenderKey: Equatable { let id: UUID;let content: PageContent?;let store: UUID;let width: CGFloat;let density: CGFloat;let enlarged: Bool }
    let store: NotebookStore
    let pageID: UUID
    let content: PageContent?
    let enlarged: Bool
    let onSelect: (UUID) -> Void
    @Environment(\.displayScale) private var density
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        GeometryReader { geometry in
        Group {
            if let image { FrozenPaperHost(image:image,enlarged:enlarged,onSelect:{onSelect(pageID)}) }
            else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .paperSurface()
        .task(id:RenderKey(id:pageID,content:content,store:store.identity,width:geometry.size.width,density:density,enlarged:enlarged)) {
            do {
                let value: PageContent
                if let content { value=content } else { value=try await store.openPage(id:pageID).content }
                let resources=try await PageRenderer.resources(for:value,store:store);try Task.checkCancellation()
                image=try PageRenderer.image(value,resources:resources,scale:max(1,geometry.size.width/720*(enlarged ? 2 : 1)*density))
            } catch is CancellationError {} catch { self.error=error.localizedDescription }
        }
        }
    }
}


private struct FrozenPaperHost: UIViewControllerRepresentable {
    @Environment(\.paperAppearance) private var paperAppearance
    let image: UIImage
    let enlarged: Bool
    @Environment(\.paperViewportOffset) private var offset
    let onSelect: () -> Void
    func makeUIViewController(context: Context) -> FrozenPaperController { let view=FrozenPaperController();view.onSelect=onSelect;return view }
    func updateUIViewController(_ controller: FrozenPaperController,context: Context) { controller.overrideUserInterfaceStyle = .light;controller.view.backgroundColor=paperAppearance.uiColor;controller.image.image=image;controller.enlarged=enlarged;controller.offset=offset;controller.onSelect=onSelect;controller.view.setNeedsLayout() }
}
final class FrozenPaperController: UIViewController {
    let scroll=UIScrollView(),image=UIImageView()
    var enlarged=false
    var offset=CGPoint.zero
    var onSelect: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = PageRenderer.paperColor("classic")
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
