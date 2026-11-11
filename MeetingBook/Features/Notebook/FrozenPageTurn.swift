import SwiftUI
import MeetingBookCore

struct BookPageNumber: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let number: Int
    var body: some View {
        Text("Page \(number)").font(.caption)
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:typeSize.isAccessibilitySize ? .top : .center)
    }
}

struct FrozenPageTurn: UIViewRepresentable {
    @Environment(\.paperAppearance) private var paperAppearance
    let source: UIImage
    let destination: UIImage
    let completion: () -> Void
    func makeUIView(context: Context) -> SnapshotTurnView { SnapshotTurnView(source:source,destination:destination,completion:completion) }
    func updateUIView(_ view: SnapshotTurnView,context: Context) {view.backgroundColor=paperAppearance.uiColor}
}
final class SnapshotTurnView: UIView {
    private let source=UIImageView(),destination=UIImageView()
    private let completion: () -> Void
    private var started=false
    init(source: UIImage,destination: UIImage,completion: @escaping () -> Void) {
        self.completion=completion
        super.init(frame:.zero);backgroundColor = .clear
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
            UIView.transition(from:self.source,to:self.destination,duration:0.2,options:[.transitionCrossDissolve,.showHideTransitionViews]) { [weak self] _ in
                guard let self,self.window != nil else { return };self.completion()
            }
        }
    }
}

@MainActor enum NotebookFrozenRenderer {
    static func image(activeID: UUID,notes: [Note],sessions: [UUID:EditorSession],store: NotebookStore,presentation: BookPresentation,offset: CGPoint = .zero,enlarged: Bool = false,density: CGFloat = 1,dynamicType: DynamicTypeSize = .large) async throws -> UIImage {
        let pair=NotebookSearch.spreadIDs(active:activeID,notes:notes)
        let ids: [UUID?]=presentation.spread ? (presentation.indexPresented ? [nil,activeID] : [pair.left,pair.right]) : [activeID]
        var images:[UIImage?]=[]
        var papers:[String?]=[]
        var paper="classic"
        for id in ids {
            guard let id else {images.append(nil);papers.append(nil);continue}
            let content: PageContent
            if let editor=sessions.values.first(where:{$0.drafts[id] != nil}) {
                guard !editor.hasCurrentAssetWrites,!editor.strokeActive else {throw EditorOperationError.inProgress}
                content=editor.drafts[id]!.content
            } else {content=try await store.openPage(id:id).content}
            papers.append(content.style.paper)
            if id == activeID {paper=content.style.paper}
            let resources=try await PageRenderer.resources(for:content,store:store)
            images.append(try PageRenderer.image(content,resources:resources,scale:max(1,presentation.contentFrames[images.count].width/720*(enlarged ? 2 : 1)*density)))
        }
        let format=UIGraphicsImageRendererFormat();format.scale=density;format.opaque=true
        return UIGraphicsImageRenderer(size:presentation.size,format:format).image { context in
            PageRenderer.paperColor(paper).setFill();context.fill(CGRect(origin:.zero,size:presentation.size))
            for (index,image) in images.enumerated() {
                let frame=presentation.contentFrames[index]
                let leaf=presentation.pages[index]
                PageRenderer.paperColor(papers[index] ?? paper).setFill();context.fill(leaf)
                context.cgContext.saveGState();context.cgContext.clip(to:frame)
                if let image {
                    let scale=frame.width/720*(enlarged ? 2 : 1)
                    let origin=BookPresentation.viewportOffset(offset,scale:scale,viewport:frame.size)
                    image.draw(in:CGRect(x:frame.minX-origin.x,y:frame.minY-origin.y,width:720*scale,height:1000*scale))
                } else if !(presentation.indexPresented && index == 0) {
                    let placeholder=ImageRenderer(content:BookPlaceholder(paper:paper,add:index == 1,enlarged:enlarged).environment(\.dynamicTypeSize,dynamicType).environment(\.paperViewportOffset,offset).paperContext(PaperAppearance(defaultPaper:paper)).frame(width:frame.width,height:frame.height))
                    placeholder.scale=density
                    placeholder.uiImage?.draw(in:frame)
                }
                context.cgContext.restoreGState()
                if let id=ids[index],let number=LibraryRules.displayNumbers(notes:notes)[id] {
                    let footer=ImageRenderer(content:BookPageNumber(number:number).environment(\.dynamicTypeSize,dynamicType).foregroundStyle(Color(uiColor:.darkText)).frame(width:leaf.width,height:presentation.footerHeight))
                    footer.scale=density
                    footer.uiImage?.draw(in:CGRect(x:leaf.minX,y:leaf.maxY-presentation.footerHeight,width:leaf.width,height:presentation.footerHeight))
                }
            }
            if presentation.spread {
                let binding=ImageRenderer(content:BookBinding(frame:presentation.binding(offset:offset,enlarged:enlarged)).frame(width:presentation.size.width,height:presentation.size.height))
                binding.scale=density
                binding.uiImage?.draw(at:.zero)
            }
        }
    }
}


struct LeafTurnTransaction {
    let token: UUID
    let source: UUID
    let target: UUID
    private(set) var resolved=false
    mutating func finish(token: UUID,completed: Bool) -> UUID? {
        guard token == self.token,!resolved else {return nil}
        resolved=true
        return completed ? target : nil
    }
}

struct LeafPreparationKey: Equatable {
    var store: UUID
    var restore: Int
    var revision: Int
    var active: UUID
    var presentation: BookPresentation
    var offset: CGPoint
    var enlarged: Bool
    var density: CGFloat
    var contents: [UUID:PageContent]
    var notes: [Note] = []
    var epoch: Int = 0
    var dynamicType: DynamicTypeSize = .large
    var broadEdges=true
}

struct LeafTurnPlan {
    let centerSpine: Bool
    let supportsCurl: Bool
    let frame: CGRect
    let previous: UUID?
    let next: UUID?
    private let previousIDs: [UUID]
    private let nextIDs: [UUID]
    init(active: UUID,notes: [Note],presentation: BookPresentation) {
        let ids=LibraryRules.orderedNotes(notes).flatMap(\.pageIDs)
        let index=ids.firstIndex(of:active) ?? 0
        let pages=presentation.pages
        centerSpine=presentation.spread && !presentation.indexPresented &&
            abs(pages[0].width-pages[1].width)<0.5 && abs(pages[0].height-pages[1].height)<0.5 &&
            abs(pages[0].minY-pages[1].minY)<0.5 && abs(pages[0].maxX-pages[1].minX)<0.5
        supportsCurl = !presentation.spread || centerSpine
        frame=supportsCurl ? (centerSpine ? pages[0].union(pages[1]) : pages[0]) : CGRect(origin:.zero,size:presentation.size)
        let start=presentation.spread ? (index == 0 ? -1 : (index%2 == 0 ? index-1 : index)) : index
        let step=presentation.spread ? 2 : 1
        previousIDs=(start-step..<start).compactMap {ids.indices.contains($0) ? ids[$0] : nil}
        nextIDs=(start+step..<start+step+step).compactMap {ids.indices.contains($0) ? ids[$0] : nil}
        previous=previousIDs.first;next=nextIDs.first
    }
    func direction(to id: UUID) -> UIPageViewController.NavigationDirection? {
        if previousIDs.contains(id) {return .reverse}
        if nextIDs.contains(id) {return .forward}
        return nil
    }
}

struct PreparedLeaves {
    let token=UUID()
    let key: LeafPreparationKey
    let plan: LeafTurnPlan
    let targets: [UUID]
    let images: [UIImage]
    let current: Int
}

struct NativeLeafPager: UIViewControllerRepresentable {
    let leaves: PreparedLeaves
    var destination: UUID? = nil
    let onBegin: (UUID,UUID) -> Bool
    let onFinish: (UUID,UUID,Bool) -> Void
    func makeUIViewController(context: Context) -> LeafPagerController {
        LeafPagerController(leaves:leaves,destination:destination,onBegin:onBegin,onFinish:onFinish)
    }
    func updateUIViewController(_ controller: LeafPagerController,context: Context) {}
    static func dismantleUIViewController(_ controller: LeafPagerController,coordinator: ()) {controller.invalidate()}
}

final class LeafHitView: UIView {
    static let cornerHeight: CGFloat=80
    var broadEdges=true
    var turning=false
    var edgeInsets=UIEdgeInsets.zero
    override func point(inside point: CGPoint,with event: UIEvent?) -> Bool {
        guard super.point(inside:point,with:event) else {return false}
        if event?.allTouches?.contains(where:{$0.type == .pencil}) == true {return false}
        if turning {return true}
        // Only reserved command margins grow; an unreserved edge keeps its existing writing boundary.
        let leftCorner=CGSize(width:edgeInsets.left>0 ? BookPresentation.commandMargin : 44,height:edgeInsets.left>0 ? Self.cornerHeight : 44)
        let rightCorner=CGSize(width:edgeInsets.right>0 ? BookPresentation.commandMargin : 44,height:edgeInsets.right>0 ? Self.cornerHeight : 44)
        if point.x<leftCorner.width && (point.y<leftCorner.height || point.y>bounds.height-leftCorner.height) {return true}
        if point.x>bounds.width-rightCorner.width && (point.y<rightCorner.height || point.y>bounds.height-rightCorner.height) {return true}
        guard broadEdges else {return false}
        let left=edgeInsets.left,right=bounds.width-edgeInsets.right
        return (point.x>=left && point.x<=left+44) || (point.x<=right && point.x>=right-44)
    }
}

final class LeafPagerController: UIViewController,UIPageViewControllerDataSource,UIPageViewControllerDelegate {
    let pager: UIPageViewController
    private let leaves: PreparedLeaves
    private let destination: UUID?
    private let onBegin: (UUID,UUID) -> Bool
    private let onFinish: (UUID,UUID,Bool) -> Void
    private var controllers: [UIViewController]=[]
    private var pending: UUID?
    private var valid=true
    private var started=false
    private var hit: LeafHitView {view as! LeafHitView}
    init(leaves: PreparedLeaves,destination: UUID?,onBegin: @escaping (UUID,UUID)->Bool,onFinish: @escaping (UUID,UUID,Bool)->Void) {
        self.leaves=leaves;self.destination=destination;self.onBegin=onBegin;self.onFinish=onFinish
        pager=UIPageViewController(transitionStyle:.pageCurl,navigationOrientation:.horizontal,options:[.spineLocation:NSNumber(value:(leaves.plan.centerSpine ? UIPageViewController.SpineLocation.mid : .min).rawValue)])
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) {nil}
    override func loadView() {view=LeafHitView();view.backgroundColor = .clear}
    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier="notebook.leafPager"
        view.accessibilityElementsHidden=true
        for image in leaves.images {
            let controller=UIViewController(),imageView=UIImageView(image:image)
            imageView.contentMode = .scaleAspectFit;imageView.isUserInteractionEnabled=true;controller.view=imageView;controllers.append(controller)
        }
        pager.delegate=self
        // The edge spine uses UIKit's translucent reverse; only a center spine displays two real sides.
        pager.isDoubleSided=leaves.plan.centerSpine
        addChild(pager);view.addSubview(pager.view);pager.didMove(toParent:self)
        pager.setViewControllers(pair(leaves.current),direction:.forward,animated:false)
        pager.dataSource=destination == nil ? self : nil
        // UIKit permits relocating these recognizers; the clear edge host remains hittable while snapshots are hidden.
        for gesture in pager.gestureRecognizers {view.addGestureRecognizer(gesture)}
        pager.view.alpha=destination == nil ? 0 : 1
        hit.broadEdges=leaves.key.broadEdges
        let p=leaves.key.presentation
        if leaves.plan.centerSpine {hit.edgeInsets=UIEdgeInsets(top:0,left:BookPresentation.commandMargin,bottom:0,right:BookPresentation.commandMargin)}
        else {
            let activeRight=p.spread && leaves.plan.frame == p.pages.last
            hit.edgeInsets=UIEdgeInsets(top:0,left:p.spread && !activeRight ? BookPresentation.commandMargin : 0,bottom:0,right:!p.spread || activeRight ? BookPresentation.commandMargin : 0)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews();pager.view.frame=view.bounds
        // Outer commands stay live and stationary while the paper and its folio turn beneath them.
        let mask=CAShapeLayer(),path=UIBezierPath(rect:view.bounds)
        let margin=BookPresentation.commandMargin,corner=LeafHitView.cornerHeight
        let height=max(0,view.bounds.height-corner*2)
        if hit.edgeInsets.left>0 {path.append(UIBezierPath(rect:CGRect(x:0,y:corner,width:margin,height:height)))}
        if hit.edgeInsets.right>0 {path.append(UIBezierPath(rect:CGRect(x:view.bounds.width-margin,y:corner,width:margin,height:height)))}
        mask.path=path.cgPath;mask.fillRule = .evenOdd;pager.view.layer.mask=mask
        if let destination,!started,view.window != nil {
            started=true
            DispatchQueue.main.async { [weak self] in self?.turn(to:destination) }
        }
    }
    private var sides: Int {leaves.plan.centerSpine ? 2 : 1}
    private func pair(_ index: Int) -> [UIViewController] {Array(controllers[(index*sides)..<(index*sides+sides)])}
    private func target(for controller: UIViewController?) -> UUID? {
        guard let controller,let index=controllers.firstIndex(where:{$0 === controller}) else {return nil}
        return leaves.targets[index/sides]
    }
    private func turn(to target: UUID) {
        guard valid,let index=leaves.targets.firstIndex(of:target),index != leaves.current else {return}
        hit.turning=true;pending=target
        pager.setViewControllers(pair(index),direction:index>leaves.current ? .forward : .reverse,animated:true) { [weak self] finished in self?.finish(completed:finished) }
    }
    func invalidate() {valid=false;pager.delegate=nil;pager.dataSource=nil}
    private func finish(completed: Bool) {
        guard valid,let target=pending else {return}
        pending=nil;hit.turning=false
        if !completed {pager.view.alpha=0}
        onFinish(leaves.token,target,completed)
    }
    func pageViewController(_ pageViewController: UIPageViewController,viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard valid,let index=controllers.firstIndex(where:{$0 === viewController}),index>0 else {return nil}
        return controllers[index-1]
    }
    func pageViewController(_ pageViewController: UIPageViewController,viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard valid,let index=controllers.firstIndex(where:{$0 === viewController}),index+1<controllers.count else {return nil}
        return controllers[index+1]
    }
    func pageViewController(_ pageViewController: UIPageViewController,willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let target=target(for:pendingViewControllers.first),onBegin(leaves.token,target) else {
            DispatchQueue.main.async { [weak self] in guard let self,self.valid else {return};self.pager.setViewControllers(self.pair(self.leaves.current),direction:.forward,animated:false) }
            return
        }
        pending=target;hit.turning=true;pager.view.alpha=1
    }
    func pageViewController(_ pageViewController: UIPageViewController,didFinishAnimating finished: Bool,previousViewControllers: [UIViewController],transitionCompleted completed: Bool) {finish(completed:completed)}
}

@MainActor extension NotebookFrozenRenderer {
    static func leaves(key: LeafPreparationKey,notes: [Note],sessions: [UUID:EditorSession],store: NotebookStore,destination: UUID? = nil) async throws -> PreparedLeaves {
        let plan=LeafTurnPlan(active:key.active,notes:notes,presentation:key.presentation)
        let targets=[plan.previous,key.active,plan.next].compactMap{$0}.map {target in
            if let destination,plan.direction(to:target) == plan.direction(to:destination),target != key.active {return destination}
            return target
        }
        var images:[UIImage]=[]
        for target in targets {
            try Task.checkCancellation()
            let sourceEditor=sessions.values.first{$0.drafts[key.active] != nil}
            let targetEditor=sessions.values.first{$0.drafts[target] != nil}
            let sameNote=sourceEditor != nil && sourceEditor === targetEditor
            let offset=sameNote ? key.offset : .zero
            let enlarged=sameNote ? key.enlarged : (targetEditor?.mode == .reading && targetEditor?.largerReadingView == true)
            let snapshot=try await image(activeID:target,notes:notes,sessions:sessions,store:store,presentation:key.presentation,offset:offset,enlarged:enlarged,density:key.density,dynamicType:key.dynamicType)
            let pair=NotebookSearch.spreadIDs(active:target,notes:notes)
            let frames=plan.centerSpine ? key.presentation.pages : [key.presentation.pages[key.presentation.spread && pair.right == target ? 1 : 0]]
            for frame in frames {
                let format=UIGraphicsImageRendererFormat();format.scale=key.density;format.opaque=true
                let leaf=UIGraphicsImageRenderer(size:frame.size,format:format).image {_ in snapshot.draw(at:CGPoint(x:-frame.minX,y:-frame.minY))}
                images.append(leaf)

            }
        }
        try Task.checkCancellation()
        return PreparedLeaves(key:key,plan:plan,targets:targets,images:images,current:targets.firstIndex(of:key.active)!)
    }
}
