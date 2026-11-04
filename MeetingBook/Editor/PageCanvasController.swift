import UIKit
import PencilKit
import SwiftUI
import MeetingBookCore

@MainActor final class PageCanvasController: UIViewController, UITextViewDelegate, PKCanvasViewDelegate {
    let session: EditorSession
    let scroll=UIScrollView(),page=UIView()
    private let canvas=SessionCanvas()
    private let keyboardCommands=UIHostingController(rootView:AnyView(EmptyView()))
    let commandBar=UIView()
    private lazy var keyboardHeightConstraint=commandBar.heightAnchor.constraint(equalToConstant:44)
    private var keyboardHeight: CGFloat=44
    private var keyboardSizeObservation: NSKeyValueObservation?
    #if DEBUG
    private var debugSwiftUIType="unseen"
    private var debugKeyboardFloor: CGFloat=0
    func traceKeyboardEnvironment(_ type: DynamicTypeSize) {
        debugSwiftUIType=String(describing:type);traceKeyboard("SwiftUI")
    }
    private func traceKeyboard(_ event: String,notified: String = "none") {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_TRACE_KEYBOARD"] == "1" else {return}
        let viewCategory=viewIfLoaded?.traitCollection.preferredContentSizeCategory.rawValue ?? "unloaded"
        let windowCategory=viewIfLoaded?.window?.traitCollection.preferredContentSizeCategory.rawValue ?? "no-window"
        let hostViewCategory=keyboardCommands.viewIfLoaded?.traitCollection.preferredContentSizeCategory.rawValue ?? "unloaded"
        NSLog("MB_KEYBOARD %@","event=\(event) notified=\(notified) global=\(UIApplication.shared.preferredContentSizeCategory.rawValue) swiftUI=\(debugSwiftUIType) controller=\(traitCollection.preferredContentSizeCategory.rawValue) view=\(viewCategory) window=\(windowCategory) host=\(keyboardCommands.traitCollection.preferredContentSizeCategory.rawValue) hostView=\(hostViewCategory) accessory=\(commandBar.traitCollection.preferredContentSizeCategory.rawValue) preferred=\(keyboardCommands.preferredContentSize.height) floor=\(debugKeyboardFloor) frame=\(commandBar.bounds.height) viewBounds=\(String(describing:viewIfLoaded?.bounds)) windowBounds=\(String(describing:viewIfLoaded?.window?.bounds)) safeArea=\(String(describing:viewIfLoaded?.safeAreaInsets)) locked=\(session.navigationLocked) turnFocus=\(session.retainsTypingFocusDuringTurn) responder=\(textViews.values.contains(where: \.isFirstResponder))")
    }
    @objc private func traceKeyboardNotification(_ notification: Notification) {
        traceKeyboard("notification",notified:notification.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? String ?? "missing")
    }
    @objc private func traceKeyboardFrame(_ notification: Notification) {
        let begin=(notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
        let end=(notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        traceKeyboard("keyboard-frame",notified:"begin=\(String(describing:begin)) end=\(String(describing:end))")
    }
    #endif
    let palette=PKToolPicker()
    private let paper=PaperView()
    private(set) var coverPresented=false
    private var coveredInputs: [UUID:(UIView?,UIView?)]=[:]
    func setCoverPresented(_ covered:Bool) {
        guard covered != coverPresented else {return}
        coverPresented=covered
        for (id,text) in textViews {
            if covered {
                coveredInputs[id]=(text.inputView,text.inputAccessoryView)
                // Keep the native selection and marked text on the same responder.
                text.inputView=UIView(frame:.zero);text.inputAccessoryView=nil
            } else if let original=coveredInputs.removeValue(forKey:id) {
                text.inputView=original.0;text.inputAccessoryView=original.1
            }
            if text.isFirstResponder {text.reloadInputViews()}
        }
        if covered {palette.setVisible(false,forFirstResponder:canvas)}
        refresh()
    }
    private var textViews: [UUID:TextBlockView]=[:]
    private var configuredBlocks: [UUID:TextBlock]=[:]
    private var imageViews: [UUID:UIImageView]=[:]
    private var shownPageID: UUID?
    private struct FocusIntent: Equatable {let page: UUID;let mode: EditorSession.Mode;let selection: UUID?}
    private var appliedFocusIntent: FocusIntent?
    private var resources=PageRenderer.Resources()
    private var loadTask: Task<Void,Never>?
    private var lastViewportSize=CGSize.zero
    private var settingDrawing=false
    private var drawingHash: String?
    private var drawingGenerations: [UUID:UInt64]=[:]
    var reportError: ((Error)->Void)?
    var reportViewportOffset: ((CGPoint)->Void)?
    var reportSoftwareKeyboard: ((Bool)->Void)?
    private var softwareKeyboardVisible=false
    init(session: EditorSession) {
        self.session=session;super.init(nibName:nil,bundle:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(softwareKeyboardFrameChanged(_:)),name:UIResponder.keyboardWillChangeFrameNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(softwareKeyboardDidHide),name:UIResponder.keyboardDidHideNotification,object:nil)
        keyboardCommands.sizingOptions = .preferredContentSize
        keyboardCommands.safeAreaRegions=[]
        // The app owns command layout; keyboard-window accessory sizing can clamp large symbols.
        #if DEBUG
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PageCanvasController, _) in
            controller.traceKeyboard("trait")
        }
        if ProcessInfo.processInfo.environment["MEETINGBOOK_TRACE_KEYBOARD"] == "1" {
            NotificationCenter.default.addObserver(self,selector:#selector(traceKeyboardNotification(_:)),name:UIContentSizeCategory.didChangeNotification,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(traceKeyboardFrame(_:)),name:UIResponder.keyboardWillChangeFrameNotification,object:nil)
        }
        #endif
        keyboardSizeObservation=keyboardCommands.observe(\.preferredContentSize,options:[.new]) { [weak self] _,_ in
            Task { @MainActor [weak self] in self?.updateKeyboardHeight() }
        }
    }
    @objc private func softwareKeyboardFrameChanged(_ notification: Notification) {
        guard let window=viewIfLoaded?.window,let frame=(notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {return}
        let overlap=window.bounds.intersection(window.convert(frame,from:window.screen.coordinateSpace)).height
        let visible=overlap>1 && textViews.values.contains(where: \.isFirstResponder)
        if visible != softwareKeyboardVisible {softwareKeyboardVisible=visible;reportSoftwareKeyboard?(visible)}
    }
    @objc private func softwareKeyboardDidHide() {
        if softwareKeyboardVisible {softwareKeyboardVisible=false;reportSoftwareKeyboard?(false)}
    }
    override func viewDidDisappear(_ animated: Bool) {super.viewDidDisappear(animated);softwareKeyboardDidHide()}
    required init?(coder: NSCoder) { nil }
    func setPaperAppearance(_ appearance: PaperAppearance) {
        loadViewIfNeeded()
        overrideUserInterfaceStyle = .light
        view.backgroundColor=appearance.uiColor
        commandBar.backgroundColor=appearance.uiColor
        keyboardCommands.view.backgroundColor=appearance.uiColor
    }
    func setKeyboardCommands(_ content: AnyView,dynamicTypeSize: DynamicTypeSize) {
        keyboardCommands.traitOverrides.preferredContentSizeCategory=UIContentSizeCategory(dynamicTypeSize)
        keyboardCommands.rootView=content
        updateKeyboardHeight()
    }
    private func updateKeyboardHeight() {
        guard isViewLoaded,commandBar.bounds.width>0 else {return}
        let font=UIFont.preferredFont(forTextStyle:.body,compatibleWith:keyboardCommands.traitCollection)
        let configuration=UIImage.SymbolConfiguration(font:font)
        let glyphHeight=EditorCommandSymbol.allCases.compactMap {UIImage(systemName:$0.rawValue,withConfiguration:configuration)?.size.height}.max() ?? 0
        // SwiftUI's ideal height can under-report scaled symbol ink.
        let measured=keyboardCommands.sizeThatFits(in:CGSize(width:commandBar.bounds.width,height:max(44,view.bounds.height)))
        let height=ceil(max(44,measured.height,glyphHeight+8))
        #if DEBUG
        debugKeyboardFloor=height;traceKeyboard("measure")
        #endif
        guard height.isFinite,height != keyboardHeight else {return}
        keyboardHeight=height;keyboardHeightConstraint.constant=session.mode == .typing ? height : 0
        commandBar.setNeedsLayout()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title:String(localized:"Undo"),action:#selector(undoAction),input:"z",modifierFlags:.command),
         UIKeyCommand(title:String(localized:"Redo"),action:#selector(redoAction),input:"z",modifierFlags:[.command,.shift])]
    }
    @objc private func undoAction() { guard !coverPresented else {return};view.endEditing(true);Task { do { try await session.flush();try await session.undo();refresh() } catch { reportError?(error) } } }
    @objc private func redoAction() { guard !coverPresented else {return};view.endEditing(true);Task { do { try await session.redo();refresh() } catch { reportError?(error) } } }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = PageRenderer.paperColor(session.activeContent.style.paper)
        keyboardCommands.view.backgroundColor = .clear
        commandBar.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(commandBar)
        addChild(keyboardCommands)
        keyboardCommands.view.translatesAutoresizingMaskIntoConstraints=false
        commandBar.addSubview(keyboardCommands.view)
        keyboardCommands.didMove(toParent:self)
        NSLayoutConstraint.activate([keyboardHeightConstraint,
            commandBar.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo:view.keyboardLayoutGuide.topAnchor),
            keyboardCommands.view.leadingAnchor.constraint(equalTo:commandBar.leadingAnchor),
            keyboardCommands.view.trailingAnchor.constraint(equalTo:commandBar.trailingAnchor),
            keyboardCommands.view.topAnchor.constraint(equalTo:commandBar.topAnchor),
            keyboardCommands.view.bottomAnchor.constraint(equalTo:commandBar.bottomAnchor)])
        scroll.accessibilityIdentifier="editor.viewport";scroll.delegate=self
        scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:commandBar.topAnchor)])
        page.accessibilityIdentifier="Canonical page";page.frame=CGRect(x:0,y:0,width:720,height:1000);scroll.addSubview(page);scroll.contentSize=page.bounds.size
        paper.frame=page.bounds;paper.reportError={ [weak self] error in Task { @MainActor in self?.reportError?(error) } };page.addSubview(paper)
        canvas.frame=page.bounds;canvas.backgroundColor = .clear;canvas.isOpaque=false;canvas.delegate=self
        canvas.isScrollEnabled=false;canvas.drawingPolicy = .pencilOnly;page.addSubview(canvas)
        palette.addObserver(canvas)
        let tap=UITapGestureRecognizer(target:self,action:#selector(insertText(_:)));paper.addGestureRecognizer(tap);paper.isUserInteractionEnabled=true
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated);refresh() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardHeight()
        guard scroll.bounds.width>0 else { return }
        let previousScale=page.transform.a
        let origin=CGPoint(x:scroll.contentOffset.x/max(previousScale,0.001),y:scroll.contentOffset.y/max(previousScale,0.001))
        let scale=scroll.bounds.width/720*(session.mode == .reading && session.largerReadingView ? 2 : 1)
        page.transform = .identity;page.frame=CGRect(x:0,y:0,width:720,height:1000)
        page.transform=CGAffineTransform(scaleX:scale,y:scale);page.frame.origin = .zero
        scroll.contentSize=CGSize(width:720*scale,height:1000*scale)
        if lastViewportSize != scroll.bounds.size || previousScale != scale {
            scroll.contentOffset=BookPresentation.viewportOffset(origin,scale:scale,viewport:scroll.bounds.size)
            lastViewportSize=scroll.bounds.size;revealCaret()
        }
    }
    func refresh() {
        guard isViewLoaded else { return }
        let id=session.activePageID,content=session.activeContent
        commandBar.isHidden=coverPresented || session.mode != .typing
        keyboardHeightConstraint.constant=session.mode == .typing ? keyboardHeight : 0
        let keepsFocus=session.navigationLocked && session.retainsTypingFocusDuringTurn && session.mode == .typing
        if session.navigationLocked && !keepsFocus { view.endEditing(true) }
        scroll.isUserInteractionEnabled = !session.navigationLocked || keepsFocus
        scroll.isScrollEnabled = !session.navigationLocked && !session.strokeActive
        view.setNeedsLayout()
        if shownPageID != id {
            view.endEditing(true);textViews.values.forEach { $0.removeFromSuperview() };textViews=[:]
            imageViews.values.forEach { $0.removeFromSuperview() };imageViews=[:];shownPageID=id;drawingHash=nil
        }
        paper.content=content;paper.setNeedsDisplay()
        for key in textViews.keys where !content.textBlocks.contains(where: { $0.id == key }) { textViews.removeValue(forKey:key)?.removeFromSuperview() }
        for block in content.textBlocks {
            if let old=configuredBlocks[block.id],let text=textViews[block.id],text.markedTextRange == nil {
                var previous=old;previous.text=block.text
                if previous != block {
                    let selection=text.selectedRange,focused=text.isFirstResponder
                    text.removeFromSuperview();let replacement=TextBlockView(block:block,content:content,versions:session.versions)
                    if coverPresented {replacement.inputView=UIView(frame:.zero);replacement.inputAccessoryView=nil}
                    replacement.delegate=self;page.insertSubview(replacement,belowSubview:canvas);textViews[block.id]=replacement
                    let count=(block.text as NSString).length,location=min(selection.location,(block.text as NSString).length)
                    replacement.selectedRange=NSRange(location:location,length:min(selection.length,count-location))
                    if focused { replacement.becomeFirstResponder() }
                }
            }
            configuredBlocks[block.id]=block
            if let text=textViews[block.id] {
                if !text.text.utf8.elementsEqual(block.text.utf8) && text.markedTextRange == nil {
                    let selection=text.selectedRange;text.text=block.text
                    let count=(block.text as NSString).length,location=min(selection.location,(block.text as NSString).length)
                    text.selectedRange=NSRange(location:location,length:min(selection.length,count-location))
                }
                text.isInputLocked={ [weak self,weak session] in self?.coverPresented != false || (session.map {$0.isUnavailable || $0.navigationLocked || $0.frozenPageIDs.contains(id)} ?? true) }
                text.isEditable = !session.isUnavailable && session.mode == .typing && !session.frozenPageIDs.contains(id) && (!session.navigationLocked || keepsFocus);text.isSelectable=(session.mode == .typing || session.mode == .selecting) && (!session.navigationLocked || keepsFocus)
            } else {
                let text=TextBlockView(block:block,content:content,versions:session.versions);text.delegate=self
                text.isInputLocked={ [weak self,weak session] in self?.coverPresented != false || (session.map {$0.isUnavailable || $0.navigationLocked || $0.frozenPageIDs.contains(id)} ?? true) }
                text.isEditable = !session.isUnavailable && session.mode == .typing && !session.frozenPageIDs.contains(id) && (!session.navigationLocked || keepsFocus);text.isSelectable=(session.mode == .typing || session.mode == .selecting) && (!session.navigationLocked || keepsFocus)
                if coverPresented {
                    coveredInputs[block.id]=(text.inputView,text.inputAccessoryView)
                    text.inputView=UIView(frame:.zero);text.inputAccessoryView=nil
                }
                page.insertSubview(text,belowSubview:canvas);textViews[block.id]=text
            }
        }
        let intent=FocusIntent(page:id,mode:session.mode,selection:session.selectedElementID)
        if !coverPresented,!session.navigationLocked,intent != appliedFocusIntent {
            if session.mode == .typing,let selected=session.selectedElementID,let text=textViews[selected] {
                let alreadyFocused=text.isFirstResponder
                if alreadyFocused || text.becomeFirstResponder() {
                    appliedFocusIntent=intent
                    if !alreadyFocused {text.selectedRange=NSRange(location:(text.text as NSString).length,length:0)}
                }
            } else {appliedFocusIntent=intent}
        }
        if session.mode != .typing { textViews.values.forEach { $0.resignFirstResponder() } }
        if let selection=session.pendingTextSelection,selection.pageID == id,let text=textViews[selection.blockID] {
            if session.mode == .typing,!session.navigationLocked {text.becomeFirstResponder()}
            text.selectedRange=selection.range;session.pendingTextSelection=nil
        }
        canvas.isUserInteractionEnabled=session.mode == .drawing && !session.busy && !session.navigationLocked
        canvas.drawingPolicy=session.fingerDrawing ? .anyInput : .pencilOnly
        palette.setVisible(!coverPresented && session.mode == .drawing,forFirstResponder:canvas)
        if !coverPresented && session.mode == .drawing { canvas.becomeFirstResponder() }
        loadTask?.cancel()
        loadTask=Task { [weak self] in
            guard let self else { return }
            do {
                let loaded=try await PageRenderer.resources(for:content,store:session.store)
                try Task.checkCancellation();guard shownPageID == id else { return };resources=loaded
                if drawingHash != content.drawingAssetHash,!session.strokeActive { settingDrawing=true;canvas.drawing=loaded.drawing;settingDrawing=false;drawingHash=content.drawingAssetHash }
                for key in imageViews.keys where !content.images.contains(where: { $0.id == key }) { imageViews.removeValue(forKey:key)?.removeFromSuperview() }
                for item in content.images {
                    let image=imageViews[item.id] ?? UIImageView();image.image=loaded.images[item.assetHash];image.frame=CGRect(x:item.frame.x,y:item.frame.y,width:item.frame.width,height:item.frame.height)
                    image.isAccessibilityElement=true;image.accessibilityLabel=item.altText.isEmpty ? String(localized:"Image") : item.altText
                    image.isUserInteractionEnabled=session.mode == .selecting
                    image.accessibilityCustomActions=[
                        UIAccessibilityCustomAction(name:String(localized:"Select image")) { [weak self] _ in self?.session.selectedElementID=item.id;return true },
                        UIAccessibilityCustomAction(name:String(localized:"Move left")) { [weak self] _ in self?.adjustImage(item.id,dx:-10,dy:0,scale:1) ?? false },
                        UIAccessibilityCustomAction(name:String(localized:"Move right")) { [weak self] _ in self?.adjustImage(item.id,dx:10,dy:0,scale:1) ?? false },
                        UIAccessibilityCustomAction(name:String(localized:"Move up")) { [weak self] _ in self?.adjustImage(item.id,dx:0,dy:-10,scale:1) ?? false },
                        UIAccessibilityCustomAction(name:String(localized:"Move down")) { [weak self] _ in self?.adjustImage(item.id,dx:0,dy:10,scale:1) ?? false },
                        UIAccessibilityCustomAction(name:String(localized:"Larger")) { [weak self] _ in self?.adjustImage(item.id,dx:0,dy:0,scale:1.1) ?? false },
                        UIAccessibilityCustomAction(name:String(localized:"Smaller")) { [weak self] _ in self?.adjustImage(item.id,dx:0,dy:0,scale:1/1.1) ?? false }
                    ]
                    if imageViews[item.id] == nil {
                        image.addGestureRecognizer(UIPanGestureRecognizer(target:self,action:#selector(moveImage(_:))))
                        image.addGestureRecognizer(UIPinchGestureRecognizer(target:self,action:#selector(scaleImage(_:))))
                        image.addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(selectImage(_:))))
                        page.insertSubview(image,belowSubview:canvas);imageViews[item.id]=image
                    }
                }
                let ordered=content.textBlocks.map { ($0.zIndex,textViews[$0.id] as UIView?) }+content.images.map { ($0.zIndex,imageViews[$0.id] as UIView?) }
                for (_,element) in ordered.sorted(by: { $0.0<$1.0 }) { if let element { page.insertSubview(element,belowSubview:canvas) } }
            } catch is CancellationError {} catch { reportError?(error) }
        }
    }
    @objc private func insertText(_ gesture: UITapGestureRecognizer) {
        guard session.mode == .typing,!session.navigationLocked else { return }
        let point=gesture.location(in:page);var content=session.activeContent;content.prepareForEditing()
        guard let region=content.template.writingRegions.first(where: { CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height).contains(point) }),
              let index=region.baselines.indices.min(by: { abs(region.baselines[$0]-point.y)<abs(region.baselines[$1]-point.y) }) else { return }
        let y=region.frame.y+(region.baselines[index]-(region.baselines.first ?? region.frame.y))
        let x=min(max(region.frame.x,point.x),max(region.frame.x,region.frame.x+region.frame.width-120))
        var block=TextBlock(text:"",frame:.init(x:x,y:y,width:region.frame.x+region.frame.width-x,height:region.frame.y+region.frame.height-y),zIndex:(content.textBlocks.map(\.zIndex)+content.images.map(\.zIndex)).max().map { $0+1 } ?? 0,fontVersionID:session.selectedFontVersionID)
        block.fontSize=session.textDefaults.fontSize;block.ink=session.textDefaults.ink;block.fontCatalogID=session.textDefaults.fontCatalogID;block.writingRegionID=region.id;block.baselineIndex=index
        content.textBlocks.append(block);session.setDraft(content,pageID:session.activePageID);refresh()
        textViews[block.id]?.becomeFirstResponder();session.selectedElementID=block.id;session.activeRegionID=region.id
    }
    func textViewDidBeginEditing(_ textView: UITextView) { session.selectedElementID=(textView as? TextBlockView)?.blockID }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        !coverPresented && !session.navigationLocked && session.mode == .typing && !session.frozenPageIDs.contains(session.activePageID)
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !session.navigationLocked,let text=textView as? TextBlockView,let id=shownPageID,var content=session.drafts[id]?.content,
              let index=content.textBlocks.firstIndex(where: { $0.id == text.blockID }) else { return }
        content.prepareForEditing();content.textBlocks[index].text=text.text
        session.textSelection = .init(pageID:id,blockID:text.blockID,range:text.selectedRange)
        session.setDraft(content,pageID:id,markedText:text.markedTextRange != nil);revealCaret()
        if text.markedTextRange == nil { Task { do { try await session.commitText(blockID:text.blockID,pageID:id);refresh() } catch { reportError?(error) } } }
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.isFirstResponder,let text=textView as? TextBlockView,let id=shownPageID {
            session.selectedElementID=text.blockID
            session.textSelection = .init(pageID:id,blockID:text.blockID,range:text.selectedRange)
        }
        revealCaret()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if scrollView === scroll {reportViewportOffset?(CGPoint(x:scroll.contentOffset.x/max(page.transform.a,0.001),y:scroll.contentOffset.y/max(page.transform.d,0.001)))} }
    private func revealCaret() {
        guard let text=textViews.values.first(where: \.isFirstResponder),let selection=text.selectedTextRange else { return }
        let rect=text.convert(text.caretRect(for:selection.end).insetBy(dx:-8,dy:-12),to:scroll)
        scroll.scrollRectToVisible(rect,animated:false)
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { session.strokeActive=true;scroll.isScrollEnabled=false }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        session.strokeActive=false;scroll.isScrollEnabled=true
        saveDrawing()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !settingDrawing,!session.strokeActive { saveDrawing() }
    }
    private func saveDrawing() {
        guard !settingDrawing,let id=shownPageID else { return }
        let token=session.beginAssetWrite(pageID:id)
        let bytes=canvas.drawing.dataRepresentation()
        drawingGenerations[id,default:0] &+= 1
        let generation=drawingGenerations[id]
        Task {
            defer { session.endAssetWrite(token) }
            do {
                let asset=try await session.store.assets.stage(data:bytes);let hash=try await session.store.assets.finalize(asset)
                guard drawingGenerations[id] == generation,session.completeDrawingWrite(token,hash:hash) else { return }
                if shownPageID == id { drawingHash=hash }
            } catch { reportError?(error) }
        }
    }
    @objc private func selectImage(_ gesture: UITapGestureRecognizer) { session.selectedElementID=imageViews.first { $0.value === gesture.view }?.key }
    @objc private func moveImage(_ gesture: UIPanGestureRecognizer) {
        guard let view=gesture.view,let id=imageViews.first(where: { $0.value === view })?.key else { return }
        session.selectedElementID=id
        let offset=gesture.translation(in:page);gesture.setTranslation(.zero,in:page)
        view.frame.origin.x=min(max(0,view.frame.minX+offset.x),720-view.frame.width)
        view.frame.origin.y=min(max(0,view.frame.minY+offset.y),1000-view.frame.height)
        if gesture.state == .ended { storeImageFrame(id,view.frame) }
    }
    @objc private func scaleImage(_ gesture: UIPinchGestureRecognizer) {
        guard let view=gesture.view,let id=imageViews.first(where: { $0.value === view })?.key else { return }
        session.selectedElementID=id
        let scale=min(gesture.scale,min((720-view.frame.minX)/view.frame.width,(1000-view.frame.minY)/view.frame.height))
        if view.frame.width*scale>=20,view.frame.height*scale>=20 { view.frame.size=CGSize(width:view.frame.width*scale,height:view.frame.height*scale) };gesture.scale=1
        if gesture.state == .ended { storeImageFrame(id,view.frame) }
    }
    private func adjustImage(_ id: UUID,dx: CGFloat,dy: CGFloat,scale: CGFloat) -> Bool {
        guard session.mode == .selecting,let image=imageViews[id] else { return false }
        var rect=image.frame
        let factor=min(scale,min(720/rect.width,1000/rect.height))
        guard rect.width*factor>=20,rect.height*factor>=20 else { return false }
        rect.size=CGSize(width:rect.width*factor,height:rect.height*factor)
        rect.origin.x=min(max(0,rect.minX+dx),720-rect.width);rect.origin.y=min(max(0,rect.minY+dy),1000-rect.height)
        image.frame=rect;session.selectedElementID=id;storeImageFrame(id,rect);return true
    }
    private func storeImageFrame(_ id: UUID,_ rect: CGRect) {
        var content=session.activeContent;guard let index=content.images.firstIndex(where: { $0.id == id }) else { return }
        content.images[index].frame = .init(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height);session.setDraft(content,pageID:session.activePageID)
    }
}
@MainActor private final class PaperView: UIView {
    var content=PageContent() { didSet { if content.template != oldValue.template || content.style != oldValue.style { reportedError=false } } }
    var reportError: ((Error)->Void)?
    var reportViewportOffset: ((CGPoint)->Void)?
    private var reportedError=false
    override func draw(_ rect: CGRect) {
        guard let context=UIGraphicsGetCurrentContext() else { return }
        do { try PageRenderer.drawPaper(content,in:context) }
        catch { if !reportedError { reportedError=true;reportError?(error) } }
    }
}

@MainActor private final class SessionCanvas: PKCanvasView { override var undoManager: UndoManager? { nil } }
