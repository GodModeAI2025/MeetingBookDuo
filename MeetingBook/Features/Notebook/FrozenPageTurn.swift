import SwiftUI
import MeetingBookCore

struct FrozenPageTurn: UIViewRepresentable {
    let source: UIImage
    let destination: UIImage
    let reducedMotion: Bool
    let completion: () -> Void
    func makeUIView(context: Context) -> SnapshotTurnView { SnapshotTurnView(source:source,destination:destination,reducedMotion:reducedMotion,completion:completion) }
    func updateUIView(_ view: SnapshotTurnView,context: Context) {}
}
final class SnapshotTurnView: UIView {
    private let source=UIImageView(),destination=UIImageView()
    private let reducedMotion: Bool
    private let completion: () -> Void
    private var started=false
    init(source: UIImage,destination: UIImage,reducedMotion: Bool,completion: @escaping () -> Void) {
        self.reducedMotion=reducedMotion;self.completion=completion
        super.init(frame:.zero);backgroundColor = .systemBackground
        self.source.image=source;self.destination.image=destination
        for image in [self.source,self.destination] { image.contentMode = .scaleAspectFit;image.autoresizingMask=[.flexibleWidth,.flexibleHeight];addSubview(image) }
        self.destination.isHidden=true
        accessibilityLabel=String(localized:"Turning frozen page preview")
    }
    required init?(coder:NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews();source.frame=bounds;destination.frame=bounds }
    override func didMoveToWindow() {
        super.didMoveToWindow();guard window != nil,!started else { return };started=true
        DispatchQueue.main.async { [weak self] in
            guard let self,self.window != nil else { return }
            UIView.transition(from:self.source,to:self.destination,duration:self.reducedMotion ? 0.2 : 0.7,options:[self.reducedMotion ? .transitionCrossDissolve : .transitionCurlUp,.showHideTransitionViews]) { [weak self] _ in
                guard let self,self.window != nil else { return };self.completion()
            }
        }
    }
}

@MainActor enum NotebookFrozenRenderer {
    static func image(activeID: UUID,notes: [Note],sessions: [UUID:EditorSession],store: NotebookStore,presentation: BookPresentation,offset: CGPoint = .zero,enlarged: Bool = false) async throws -> UIImage {
        let pair=NotebookSearch.spreadIDs(active:activeID,notes:notes)
        let ids: [UUID?]=presentation.spread ? [pair.left,pair.right] : [activeID]
        var images:[UIImage?]=[]
        var paper="classic"
        for id in ids {
            guard let id else {images.append(nil);continue}
            let content: PageContent
            if let editor=sessions.values.first(where:{$0.drafts[id] != nil}) {
                guard !editor.hasCurrentAssetWrites,!editor.strokeActive else {throw EditorOperationError.inProgress}
                content=editor.drafts[id]!.content
            } else {content=try await store.openPage(id:id).content}
            if id == activeID {paper=content.style.paper}
            let resources=try await PageRenderer.resources(for:content,store:store)
            images.append(try PageRenderer.image(content,resources:resources,scale:0.6))
        }
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        return UIGraphicsImageRenderer(size:presentation.size,format:format).image { context in
            UIColor.secondarySystemBackground.setFill();context.fill(CGRect(origin:.zero,size:presentation.size))
            UIColor.label.withAlphaComponent(0.08).setFill();context.fill(presentation.binding(offset:offset,enlarged:enlarged))
            for (index,image) in images.enumerated() {
                let frame=presentation.pages[index]
                context.cgContext.saveGState();context.cgContext.clip(to:frame)
                if let image {
                    let scale=frame.width/720*(enlarged ? 2 : 1)
                    let origin=BookPresentation.viewportOffset(offset,scale:scale,viewport:frame.size)
                    image.draw(in:CGRect(x:frame.minX-origin.x,y:frame.minY-origin.y,width:720*scale,height:1000*scale))
                } else {
                    let placeholder=ImageRenderer(content:BookPlaceholder(paper:paper,add:index == 1,enlarged:enlarged).environment(\.paperViewportOffset,offset).frame(width:frame.width,height:frame.height))
                    placeholder.uiImage?.draw(in:frame)
                }
                context.cgContext.restoreGState()
            }
        }
    }
}
