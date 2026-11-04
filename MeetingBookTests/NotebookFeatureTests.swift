import XCTest
import UIKit
import SwiftUI
import PencilKit
import CryptoKit
import Darwin
import ZIPFoundation
import MeetingBookCore
@testable import MeetingBook

@MainActor final class NotebookFeatureTests: XCTestCase {
    func testSearchToleratesAccentsAndFindsLateSnippetWithoutChangingScalars() {
        let body=String(repeating:"prefix ",count:100)+"Cafe\u{301} ÄÖÜ";let bytes=Array(body.utf8)
        XCTAssertTrue(NotebookSearch.snippet(title:"",body:body,query:"CAFE")?.contains("Cafe\u{301}") == true)
        XCTAssertNotNil(NotebookSearch.snippet(title:"Résumé",body:"Body",query:"resume"))
        XCTAssertNil(NotebookSearch.snippet(title:"",body:"",query:"drawing"))
        XCTAssertEqual(Array(body.utf8),bytes)
    }
    func testGlobalSpreadAcrossNoteBoundaryAndTrailingPlaceholder() {
        let a=(0..<2).map{_ in UUID()},b=(0..<3).map{_ in UUID()}
        let notes=[Note(title:"A",orderKey:0,pageIDs:a),Note(title:"B",orderKey:1,pageIDs:b)]
        var pair=NotebookSearch.spreadIDs(active:a[0],notes:notes);XCTAssertNil(pair.left);XCTAssertEqual(pair.right,a[0])
        pair=NotebookSearch.spreadIDs(active:a[1],notes:notes);XCTAssertEqual(pair.left,a[1]);XCTAssertEqual(pair.right,b[0])
        pair=NotebookSearch.spreadIDs(active:b[1],notes:notes);XCTAssertEqual(pair.left,b[1]);XCTAssertEqual(pair.right,b[2])
        pair=NotebookSearch.spreadIDs(active:a[1],notes:[notes[0]]);XCTAssertEqual(pair.left,a[1]);XCTAssertNil(pair.right)
    }
    func testBootstrapCaveatAndLegacyDefaultsStayUnchanged() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let initial=await store.preferences();XCTAssertEqual(initial.textDefaults?.fontCatalogID,"bundled.caveat")
        var preferences=initial;preferences.textDefaults=TextDefaults(fontCatalogID:nil);try await store.savePreferences(preferences)
        let reopened=try await NotebookStore.open(root:root);let saved=await reopened.preferences();XCTAssertNil(saved.textDefaults?.fontCatalogID)
    }
    func testCancelledTemplateGenerationProducesNoPlan() async throws {
        let catalog=try TemplateCatalog.builtIn()
        let work=Task { @MainActor in var config=TemplateConfiguration();config.count=1;return try catalog.instantiate(id:"journal.travel_day",configuration:config) }
        work.cancel()
        do { _=try await work.value;XCTFail("Cancelled generation returned pages") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

extension NotebookFeatureTests {
    func testConfiguredInsertionAndBookmarkKeepDirtyUnicode() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note)
        var content=PageContent();content.version=2;content.style.paper="rose";content.style.ruling="dots";content.style.fontSize=24
        try await session.insert(contents:[content],after:session.activePageID)
        XCTAssertEqual(session.snapshot.pages[1].content,content)
        var draft=session.activeContent;draft.textBlocks=[TextBlock(text:"e\u{301}")];session.setDraft(draft,pageID:session.activePageID)
        try await session.setBookmark(pageID:session.activePageID,value:true)
        XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),[101,204,129]);XCTAssertEqual(session.saveState,.dirty)
        XCTAssertTrue(session.snapshot.pages[0].bookmark)
        try await session.flush()
    }
}

extension NotebookFeatureTests {
    func testPaperInkContrastUsesActualRendererPalette() {
        XCTAssertEqual(PaperContrast.ratio(paper:"rose",ink:"ochre"),2.45,accuracy:0.01)
        XCTAssertEqual(PaperContrast.ratio(paper:"classic",ink:"teal"),4.48,accuracy:0.01)
        for paper in ["classic","cream","rose"] {
            XCTAssertLessThan(PaperContrast.ratio(paper:paper,ink:"ochre"),4.5)
            XCTAssertGreaterThan(PaperContrast.ratio(paper:paper,ink:"graphite"),4.5)
            XCTAssertGreaterThan(PaperContrast.ratio(paper:paper,ink:"marine"),4.5)
        }
    }
}

extension NotebookFeatureTests {
    func testWindowGeometryChoosesSpreadWithoutChangingIdentity() {
        XCTAssertTrue(NotebookSearch.usesSpread(width:900,height:700,accessibility:false))
        XCTAssertTrue(NotebookSearch.usesSpread(width:1200,height:800,accessibility:false))
        XCTAssertFalse(NotebookSearch.usesSpread(width:540,height:800,accessibility:false))
        XCTAssertFalse(NotebookSearch.usesSpread(width:1200,height:350,accessibility:false))
        XCTAssertFalse(NotebookSearch.usesSpread(width:1200,height:800,accessibility:true))
        let ids=[UUID(),UUID(),UUID()],notes=[Note(title:"",orderKey:0,pageIDs:ids)]
        for width in [540.0,1200,800,1400] {
            _=NotebookSearch.usesSpread(width:width,height:800,accessibility:false)
            XCTAssertEqual(NotebookSearch.spreadIDs(active:ids[1],notes:notes).right,ids[2])
        }
    }
    func testPassivePaperUsesCanonicalOffsetAtItsOwnScaleAndClamps() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),root=UIViewController(),controller=FrozenPaperController()
        window.rootViewController=root;window.makeKeyAndVisible();root.view.layoutIfNeeded()
        defer {window.isHidden=true}
        root.addChild(controller);root.view.addSubview(controller.view);controller.didMove(toParent:root)
        controller.view.frame=CGRect(x:100,y:200,width:360,height:200)
        try await Task.sleep(for:.milliseconds(200))
        controller.offset=CGPoint(x:0,y:240)
        controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scroll.bounds.size,CGSize(width:360,height:200))
        XCTAssertEqual(controller.scroll.contentOffset.y,120,accuracy:0.5)
        controller.offset=CGPoint(x:500,y:9000)
        controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scroll.contentOffset.x,0,accuracy:0.5)
        print("PASSIVE viewport \(controller.scroll.bounds) insets \(controller.scroll.adjustedContentInset) content \(controller.scroll.contentSize)")
        XCTAssertEqual(controller.scroll.contentOffset.y,300,accuracy:0.5)
        XCTAssertEqual(BookPresentation.viewportOffset(CGPoint(x:500,y:9000),scale:0.5,viewport:CGSize(width:360,height:200)),CGPoint(x:0,y:300))
    }
    func testBookPresentationUsesLocalTraitsAndUnequalReservedRegions() {
        let size=CGSize(width:1200,height:800)
        XCTAssertFalse(BookPresentation(size:size,regular:false,accessibility:false).spread)
        XCTAssertFalse(BookPresentation(size:CGSize(width:1032,height:1165),regular:true,accessibility:false).spread)
        XCTAssertTrue(BookPresentation(size:CGSize(width:900,height:700),regular:true,accessibility:false).spread)
        XCTAssertTrue(BookPresentation(size:CGSize(width:1376,height:800),regular:true,accessibility:false).spread)
        let cut=BookPresentation.Exclusion(frame:CGRect(x:450,y:0,width:30,height:800),division:true)
        let book=BookPresentation(size:size,regular:true,accessibility:false,regions:[cut])
        XCTAssertTrue(book.spread)
        XCTAssertEqual(book.pages.map(\.width),[450,720])
        XCTAssertEqual(book.gutter,cut.frame)
        XCTAssertEqual(book.binding(offset:.zero,enlarged:false).height,625,accuracy:0.5)
        var inactive=cut;inactive.active=false
        XCTAssertNotEqual(book,BookPresentation(size:size,regular:true,accessibility:false,regions:[inactive]))
        let occlusion=BookPresentation.Exclusion(frame:CGRect(x:0,y:0,width:90,height:90),division:false)
        let compact=BookPresentation(size:size,regular:false,accessibility:false,regions:[cut,occlusion])
        XCTAssertFalse(compact.pages[0].intersects(cut.frame))
        XCTAssertFalse(compact.pages[0].intersects(occlusion.frame))
        let horizontal=BookPresentation.Exclusion(frame:CGRect(x:0,y:380,width:1200,height:40),division:true)
        let stacked=BookPresentation(size:size,regular:true,accessibility:false,regions:[horizontal])
        XCTAssertTrue(stacked.spread);XCTAssertEqual(stacked.gutter,horizontal.frame)
    }
    func testNativeNavigationLockResignsTextAndRetainsDraft() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Unchanged e\u{301}")]
        let note=try await store.createNote(title:"",contents:[content])
        let session=EditorSession(store:store,snapshot:note)
        try await session.setMode(.typing)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        session.navigationLocked=true;controller.refresh()
        func textViews(_ view:UIView) -> [UITextView] { view.subviews.flatMap { ($0 as? UITextView).map{[$0]} ?? textViews($0) } }
        XCTAssertFalse(textViews(controller.view).isEmpty)
        XCTAssertTrue(textViews(controller.view).allSatisfy{!$0.isEditable && !$0.isFirstResponder})
        XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),Array(content.textBlocks[0].text.utf8))
        session.navigationLocked=false;controller.refresh();XCTAssertTrue(textViews(controller.view).allSatisfy(\.isEditable))
    }
}

extension NotebookFeatureTests {
    func testAccessoryFollowsRuntimeSwiftUIContentSize() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Environment Ä 👩🏽‍💻")]
        let note=try await store.createNote(title:"SwiftUI accessory environment",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        session.selectedElementID=content.textBlocks[0].id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene)
        window.traitOverrides.preferredContentSizeCategory = .large
        let host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}).environment(\.dynamicTypeSize,.large))
        window.rootViewController=host;window.makeKeyAndVisible();host.view.layoutIfNeeded();defer {window.isHidden=true}
        try await Task.sleep(for:.milliseconds(150))
        let text=try XCTUnwrap(host.view.findFirstResponder() as? TextBlockView)
        let controller=try XCTUnwrap(text.delegate as? PageCanvasController),accessory=controller.commandBar
        text.selectedRange=NSRange(location:2,length:3)
        XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory,.large)
        let traits=UITraitCollection(preferredContentSizeCategory:.accessibilityExtraExtraExtraLarge)
        let configuration=UIImage.SymbolConfiguration(font:UIFont.preferredFont(forTextStyle:.body,compatibleWith:traits))
        let glyphHeights=try EditorCommandSymbol.allCases.map {try XCTUnwrap(UIImage(systemName:$0.rawValue,withConfiguration:configuration)).size.height}
        let floor=ceil(max(44,(glyphHeights.max() ?? 0)+8))
        let grew=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in accessory.bounds.height>=floor},object:nil)
        host.rootView=SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}).environment(\.dynamicTypeSize,.accessibility5)
        host.view.layoutIfNeeded();await fulfillment(of:[grew],timeout:5)
        for symbol in EditorCommandSymbol.allCases {
            let height=try XCTUnwrap(UIImage(systemName:symbol.rawValue,withConfiguration:configuration)).size.height
            XCTAssertGreaterThanOrEqual(accessory.bounds.height,ceil(max(44,height+8)),"Runtime SwiftUI \(symbol.rawValue) must fit")
        }
        print("ACCESSORY_ENVIRONMENT native=\(controller.traitCollection.preferredContentSizeCategory.rawValue) frame=\(accessory.frame)")
        let largeHeight=accessory.bounds.height
        let shrank=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in accessory.bounds.height<largeHeight},object:nil)
        host.rootView=SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}).environment(\.dynamicTypeSize,.large)
        host.view.layoutIfNeeded();await fulfillment(of:[shrank],timeout:5)
        XCTAssertTrue(host.view.findFirstResponder() === text);XCTAssertNil(text.inputAccessoryView)
        XCTAssertEqual(text.selectedRange,NSRange(location:2,length:3));XCTAssertEqual(session.activeContent,content)
        XCTAssertGreaterThanOrEqual(accessory.bounds.height,44);XCTAssertLessThan(accessory.bounds.height,largeHeight)
    }
    func testCrossNoteFrozenDestinationMatchesFreshLiveViewportAndOwnZoom() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Oben — unten\nZielseite")]
        let a=try await store.createNote(title:"A",contents:[content,content])
        let b=try await store.createNote(title:"B",contents:[content])
        let source=EditorSession(store:store,snapshot:a),destination=EditorSession(store:store,snapshot:b)
        source.largerReadingView=true
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),root=UIViewController()
        window.rootViewController=root;window.makeKeyAndVisible();root.view.layoutIfNeeded();defer {window.isHidden=true}
        func mount(_ session: EditorSession) -> PageCanvasController {
            let controller=PageCanvasController(session:session)
            root.addChild(controller);root.view.addSubview(controller.view);controller.didMove(toParent:root)
            controller.view.frame=CGRect(x:100,y:200,width:360,height:500);controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
            return controller
        }
        func unmount(_ controller: PageCanvasController) {
            controller.willMove(toParent:nil);controller.view.removeFromSuperview();controller.removeFromParent()
        }
        let liveSource=mount(source)
        liveSource.scroll.contentOffset=CGPoint(x:90,y:240)
        let sourceScale=liveSource.page.transform.a
        let sourceOffset=CGPoint(x:liveSource.scroll.contentOffset.x/sourceScale,y:liveSource.scroll.contentOffset.y/sourceScale)
        XCTAssertEqual(sourceScale,1,accuracy:0.001);XCTAssertGreaterThan(sourceOffset.y,0)
        let same=NotebookView.destinationViewport(from:source,to:source,offset:sourceOffset)
        source.select(pageID:a.pages[1].id);liveSource.refresh();liveSource.view.layoutIfNeeded()
        XCTAssertEqual(same.offset,CGPoint(x:liveSource.scroll.contentOffset.x/sourceScale,y:liveSource.scroll.contentOffset.y/sourceScale))
        XCTAssertTrue(same.enlarged)
        unmount(liveSource)
        let presentation=BookPresentation(size:CGSize(width:360,height:500),regular:false,accessibility:false)
        let notes=[a.note,b.note],sessions=[a.note.id:source,b.note.id:destination]
        for (mode,enlarged) in [(EditorSession.Mode.reading,false),(.typing,true),(.reading,true)] {
            try await destination.setMode(mode);destination.largerReadingView=enlarged
            let live=mount(destination)
            let scale=live.page.transform.a
            let liveOffset=CGPoint(x:live.scroll.contentOffset.x/scale,y:live.scroll.contentOffset.y/scale)
            let liveEnlarged=scale>live.scroll.bounds.width/720+0.001
            let selected=NotebookView.destinationViewport(from:source,to:destination,offset:sourceOffset)
            XCTAssertEqual(liveOffset,.zero)
            XCTAssertEqual(selected.offset,liveOffset)
            XCTAssertEqual(selected.enlarged,liveEnlarged)
            let frozen=try await NotebookFrozenRenderer.image(activeID:b.pages[0].id,notes:notes,sessions:sessions,store:store,presentation:presentation,offset:selected.offset,enlarged:selected.enlarged)
            let expected=try await NotebookFrozenRenderer.image(activeID:b.pages[0].id,notes:notes,sessions:sessions,store:store,presentation:presentation,offset:liveOffset,enlarged:liveEnlarged)
            XCTAssertEqual(SHA256.hash(data:try XCTUnwrap(frozen.pngData())),SHA256.hash(data:try XCTUnwrap(expected.pngData())),"Frozen destination must match the live crop and scale for \(mode)")
            unmount(live)
        }
    }
    func testFrozenTransitionCompletionAndCancellationKeepSourceIdentity() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"",contents:[PageContent(),PageContent()])
        let editor=EditorSession(store:store,snapshot:note),source=note.pages[0].id,target=note.pages[1].id
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),root=UIViewController();window.rootViewController=root;window.makeKeyAndVisible()
        defer { window.isHidden=true }
        let image=try await NotebookFrozenRenderer.image(activeID:source,notes:[note.note],sessions:[note.note.id:editor],store:store,presentation:BookPresentation(size:CGSize(width:1440,height:1000),regular:true,accessibility:false))
        XCTAssertEqual(image.size.width,1440);XCTAssertEqual(image.size.height,1000)
        let cancelled=SnapshotTurnView(source:image,destination:image,reducedMotion:true) { editor.select(pageID:target) }
        cancelled.frame=root.view.bounds;root.view.addSubview(cancelled);cancelled.removeFromSuperview()
        try await Task.sleep(for:.milliseconds(400));XCTAssertEqual(editor.activePageID,source)
        let completed=SnapshotTurnView(source:image,destination:image,reducedMotion:true) { editor.select(pageID:target) }
        completed.frame=root.view.bounds;root.view.addSubview(completed)
        try await Task.sleep(for:.milliseconds(500));XCTAssertEqual(editor.activePageID,target)
    }
}

extension NotebookFeatureTests {
    func testHostedNormalNarrowFullGeometryPreservesOneEditorAndCoordinates() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Geometry Äß e\u{301}")]
        let note=try await store.createNote(title:"Hosted geometry fixture",contents:[content,content,content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();session.select(pageID:note.pages[1].id);session.selectedElementID=content.textBlocks[0].id
        try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        func controllers(_ controller:UIViewController) -> [PageCanvasController] { (controller as? PageCanvasController).map{[$0]} ?? controller.children.flatMap(controllers) }
        var original: PageCanvasController?
        var originalText: UITextView?
        let revision=session.snapshot.pages[1].currentRevisionID
        let generation=session.drafts[session.activePageID]?.generation
        for size in [CGSize(width:1200,height:800),CGSize(width:540,height:800),CGSize(width:1200,height:350),CGSize(width:1400,height:1000)] {
            host.view.frame=CGRect(origin:.zero,size:size);host.view.setNeedsLayout();host.view.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(150));host.view.layoutIfNeeded()
            let live=controllers(host);XCTAssertEqual(live.count,1)
            if let original { XCTAssertTrue(live.first === original) } else { original=live.first }
            XCTAssertTrue(live.first?.view.findFirstResponder() is UITextView)
            let text=try XCTUnwrap(live.first?.view.findFirstResponder() as? UITextView)
            if let originalText {XCTAssertTrue(text === originalText);XCTAssertEqual(text.selectedRange,NSRange(location:3,length:2))}
            else {originalText=text;text.selectedRange=NSRange(location:3,length:2)}
            func passive(_ controller:UIViewController) -> [FrozenPaperController] { (controller as? FrozenPaperController).map{[$0]} ?? controller.children.flatMap(passive) }
            if BookPresentation(size:size,regular:true,accessibility:false).spread {
                let frozen=try XCTUnwrap(passive(host).first),active=try XCTUnwrap(live.first)
                let left=active.page.convert(active.page.bounds,to:host.view),right=frozen.image.convert(frozen.image.bounds,to:host.view)
                XCTAssertEqual(left.minY,right.minY,accuracy:0.5)
                XCTAssertEqual(left.width,right.width,accuracy:0.5);XCTAssertEqual(left.height,right.height,accuracy:0.5)
            }

            XCTAssertEqual(session.activePageID,note.pages[1].id);XCTAssertEqual(session.activeContent.textBlocks[0].frame,content.textBlocks[0].frame)
            XCTAssertEqual(session.snapshot.pages[1].currentRevisionID,revision)
            XCTAssertEqual(session.drafts[session.activePageID]?.generation,generation)
            XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),Array(content.textBlocks[0].text.utf8))
            let image=UIGraphicsImageRenderer(size:size).image { context in host.view.layer.render(in:context.cgContext) }
            let attachment=XCTAttachment(image:image);attachment.name="Hosted geometry fixture \(Int(size.width))x\(Int(size.height)) - not Stage Manager";attachment.lifetime = .keepAlways;add(attachment)
        }
    }
}

extension NotebookFeatureTests {
    func testHostedMarkedTextAndUndoSurviveBookResize() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Ä e\u{301} 👩🏽‍💻")]
        let note=try await store.createNote(title:"Marked resize",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        var edited=content;edited.textBlocks[0].text += "!"
        session.setDraft(edited,pageID:session.activePageID);try await session.flush();XCTAssertTrue(session.canUndo)
        session.selectedElementID=content.textBlocks[0].id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        host.view.frame=CGRect(x:0,y:0,width:1200,height:900);host.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(150))
        let text=try XCTUnwrap(host.view.findFirstResponder() as? UITextView)
        text.selectedRange=NSRange(location:(text.text as NSString).length,length:0)
        let controller=try XCTUnwrap(text.delegate as? PageCanvasController)
        XCTAssertNil(text.undoManager) // Session history owns document-wide Undo, including pagination.
        text.setMarkedText("に",selectedRange:NSRange(location:1,length:0));controller.textViewDidChange(text)
        XCTAssertNotNil(text.markedTextRange)
        let bytes=Array(text.text.utf8),selection=text.selectedRange
        let draft=session.activeContent,generation=session.drafts[session.activePageID]?.generation,revision=session.snapshot.pages[0].currentRevisionID
        for size in [CGSize(width:540,height:800),CGSize(width:1300,height:900),CGSize(width:1200,height:350),CGSize(width:900,height:800)] {
            host.view.frame=CGRect(origin:.zero,size:size);host.view.setNeedsLayout();host.view.layoutIfNeeded()
            try await Task.sleep(for:.milliseconds(100))
            XCTAssertTrue(host.view.findFirstResponder() === text)
            XCTAssertNotNil(text.markedTextRange);XCTAssertEqual(text.selectedRange,selection)
            XCTAssertEqual(Array(text.text.utf8),bytes);XCTAssertTrue(session.canUndo)
            XCTAssertEqual(session.activeContent,draft);XCTAssertEqual(session.drafts[session.activePageID]?.generation,generation)
            XCTAssertEqual(session.snapshot.pages[0].currentRevisionID,revision)
        }
        text.unmarkText();controller.textViewDidChange(text)
        XCTAssertEqual(Array(text.text.utf8),bytes)
        try await Task.sleep(for:.milliseconds(100));try await session.flush()
        try await session.undo();XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),Array(edited.textBlocks[0].text.utf8))
        try await session.undo();XCTAssertEqual(Array(session.activeContent.textBlocks[0].text.utf8),Array(content.textBlocks[0].text.utf8))
    }
}

extension NotebookFeatureTests {
    func testPageTurnLockRetainsFocusAndRejectsNativeInput() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Keep Ä e\u{301} 👩🏽‍💻")]
        let note=try await store.createNote(title:"Turn input lock",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        session.selectedElementID=content.textBlocks[0].id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
        let text=try XCTUnwrap(host.view.findFirstResponder() as? TextBlockView)
        let controller=try XCTUnwrap(text.delegate as? PageCanvasController)
        text.selectedRange=NSRange(location:3,length:2)
        let selection=text.selectedRange,bytes=Array(text.text.utf8),draft=session.activeContent,viewport=controller.scroll.bounds.size
        session.retainsTypingFocusDuringTurn=true;session.navigationLocked=true
        // Native input can arrive before SwiftUI delivers the next controller refresh.
        text.insertText("blocked");text.setMarkedText("に",selectedRange:NSRange(location:1,length:0))
        if let range=text.selectedTextRange {text.replace(range,withText:"blocked")}
        XCTAssertEqual(Array(text.text.utf8),bytes);XCTAssertNil(text.markedTextRange)
        XCTAssertEqual(text.selectedRange,selection)
        controller.refresh()
        try await Task.sleep(for:.milliseconds(100));host.view.layoutIfNeeded()
        XCTAssertTrue(text.isFirstResponder);XCTAssertEqual(controller.scroll.bounds.size,viewport)
        XCTAssertFalse(controller.textView(text,shouldChangeTextIn:selection,replacementText:"blocked"))
        text.insertText("blocked");text.deleteBackward();text.setMarkedText("に",selectedRange:NSRange(location:1,length:0))
        if let range=text.selectedTextRange {text.replace(range,withText:"blocked")}
        let clipboard=UIPasteboard.general.items;defer {UIPasteboard.general.items=clipboard}
        UIPasteboard.general.string="blocked";text.paste(nil);text.cut(nil)
        XCTAssertEqual(Array(text.text.utf8),bytes);XCTAssertNil(text.markedTextRange)
        XCTAssertEqual(text.selectedRange,selection);XCTAssertEqual(session.activeContent,draft)
        session.navigationLocked=false;session.retainsTypingFocusDuringTurn=false;controller.refresh()
        XCTAssertTrue(text.isFirstResponder);XCTAssertTrue(text.isEditable)
        XCTAssertTrue(controller.textView(text,shouldChangeTextIn:selection,replacementText:"allowed"))
        session.navigationLocked=true;controller.refresh()
        XCTAssertFalse(text.isFirstResponder);XCTAssertFalse(text.isEditable)
        session.navigationLocked=false;controller.refresh()
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? { if isFirstResponder { return self };return subviews.lazy.compactMap{$0.findFirstResponder()}.first }
}

extension NotebookFeatureTests {
    func testReadSwipeThresholdDirectionAndCancellation() {
        let ids=[UUID(),UUID(),UUID()]
        XCTAssertEqual(NotebookSearch.swipeTarget(active:ids[1],ids:ids,horizontal:-90,vertical:10,reading:true),ids[2])
        XCTAssertEqual(NotebookSearch.swipeTarget(active:ids[1],ids:ids,horizontal:90,vertical:10,reading:true),ids[0])
        for (x,y,reading) in [(40.0,0.0,true),(90,100,true),(90,0,false)] {
            XCTAssertNil(NotebookSearch.swipeTarget(active:ids[1],ids:ids,horizontal:x,vertical:y,reading:reading))
        }
        XCTAssertNil(NotebookSearch.swipeTarget(active:ids[0],ids:ids,horizontal:90,vertical:0,reading:true))
    }
    func testPersonalFontLabelsRetainVersionIdentityAndExplainIssues() {
        let first=FontVersion(assetHash:"first",postScriptName:"internal-uuid"),second=FontVersion(assetHash:"second",postScriptName:"another-uuid")
        var project=FontProject(name:"My script",versions:[first])
        let label=PersonalFontLabels.version(first.id,projects:[project]);project.versions.append(second)
        XCTAssertEqual(label,PersonalFontLabels.version(first.id,projects:[project]))
        XCTAssertTrue(label.contains("My script"));XCTAssertFalse(label.contains("internal-uuid"))
        XCTAssertNotEqual(label,PersonalFontLabels.version(second.id,projects:[project]))
        for reason in ["missingDrawing","missingMetrics","invalidMetrics","invalidOutline","tooComplex","unsupportedInk","invalidDrawing","invalidFont","registration","unknown"] {
            XCTAssertNotEqual(PersonalFontLabels.issue(reason),reason)
        }
    }
}

extension NotebookFeatureTests {
    func testFontEditorsMergeDistinctGlyphsRejectSameGlyphAndPreserveVersions() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let original=FontProject(name:"Shared");try await store.saveFontProject(original)
        let asset=try await store.assets.stage(data:Data("glyph source fixture".utf8)),metrics=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:600,leftBearing:40)
        let hash=try await store.assets.finalize(asset)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for code: UInt32 in [65,66] {group.addTask { _=try await store.saveFontGlyph(projectID:original.id,codePoint:code,expectedHash:nil,expectedMetrics:nil,hash:hash,metrics:metrics) }}
            try await group.waitForAll()
        }
        let projects=await store.fontProjects(),merged=try XCTUnwrap(projects.first)
        XCTAssertEqual(merged.glyphAssetHashes.count,2)
        do { _=try await store.saveFontGlyph(projectID:original.id,codePoint:65,expectedHash:nil,expectedMetrics:nil,hash:nil,metrics:nil);XCTFail("stale glyph overwritten") } catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        let version=FontVersion(assetHash:hash,postScriptName:"SyntheticMetadata")
        let published=try await store.publishFontVersion(projectID:original.id,version:version)
        XCTAssertEqual(published.glyphAssetHashes.count,2)
        let next=try await store.saveFontGlyph(projectID:original.id,codePoint:67,expectedHash:nil,expectedMetrics:nil,hash:hash,metrics:metrics)
        XCTAssertEqual(next.versions,[version]);XCTAssertEqual(next.glyphAssetHashes.count,3)
        do { try await store.saveFontProject(original);XCTFail("whole stale project replaced") } catch { }
    }
    func testDelayedGlyphSaveKeepsNewerSpacingDirty() async {
        var edits=GlyphEditState();edits.changed();let savedGeneration=edits.generation
        await Task.yield();edits.changed();edits.saved(generation:savedGeneration)
        XCTAssertTrue(edits.dirty)
        edits.saved(generation:edits.generation);XCTAssertFalse(edits.dirty)
    }
    func testRemovedLatestBookmarkResolvesPreviousAfterReopen() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual=try await NotebookStore.open(root:root)
        let note=try await actual.createNote(title:"Bookmarks",contents:[PageContent(),PageContent()]);let a=note.pages[0].id,b=note.pages[1].id
        try await actual.setBookmark(pageID:a,value:true);try await actual.setBookmark(pageID:b,value:true)
        var latest=try await actual.latestBookmarkedPageID();XCTAssertEqual(latest,b)
        try await actual.setBookmark(pageID:b,value:false)
        let listed=try await actual.bookmarkedPageIDs();XCTAssertEqual(listed,[a])
        let reopened=try await NotebookStore.open(root:root);latest=try await reopened.latestBookmarkedPageID();XCTAssertEqual(latest,a)
        try await reopened.setBookmark(pageID:a,value:false);latest=try await reopened.latestBookmarkedPageID();XCTAssertNil(latest)
    }
}


@MainActor final class AcceptancePerformanceTests:XCTestCase {
    func testRetainedCorpusBackupRecoveryAndProducerMeasurements() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_RETAINED"]=="1" else {throw XCTSkip("Dedicated retained corpus lane only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task8C-Roundtrip-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let sourceRoot=root.appendingPathComponent("source")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/private/tmp/meetingbook-task8c-retained-closed"),to:sourceRoot)
        var measurements:[String:Any]=["root":root.path,"configuration":"native simulator; exact build configuration in companion source manifest; service boundaries, not rendered UI or physical acceptance"]
        func recordStage(_ phase:String) throws {
            measurements["lastCompletedPhase"]=phase
            measurements["currentResidentBytes"]=Self.currentResidentBytes()
            try JSONSerialization.data(withJSONObject:measurements,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("measurements.json"),options:.atomic)
            print("RETAINED stage \(phase) root \(root.path)")
        }
        var start=ContinuousClock.now
        let store=try await NotebookStore.open(root:sourceRoot)
        let notes=try await store.listNotes();XCTAssertEqual(notes.count,100)
        measurements["openToNotesMS"]=Self.ms(start);try recordStage("opened")
        if ProcessInfo.processInfo.environment["MEETINGBOOK_SAVE_ONLY"] != "1" {
        var search:[String:[Double]]=[:]
        for (query,count) in [("late needle",100),("Corpus 99",100),("aß",10_000),("missing-8c-token",0)] {
            let warmup=try await store.search(query:query,scope:"notes");XCTAssertEqual(warmup.count,count)
            for _ in 0..<20 {
                start = .now;let hits=try await store.search(query:query,scope:"notes")
                search[query,default:[]].append(Self.ms(start));XCTAssertEqual(hits.count,count)
                XCTAssertEqual(hits.map(\.pageID),warmup.map(\.pageID))
            }
        }
        measurements["searchMS"]=search;try recordStage("searched")
        for (query,samples) in search {XCTAssertLessThanOrEqual(samples.sorted()[18],300,"Producer P95: \(query)")}
        } else {measurements["searchNotRepeated"]=true}
        let snapshot=try await store.openNote(id:notes[0].id)
        let editor=EditorSession(store:store,snapshot:snapshot),pageID=snapshot.pages[0].id
        await editor.loadFonts()
        var saves:[Double]=[],savePhases:[[String:Double]]=[]
        for index in 0..<20 {
            await store.startPerformanceMeasurement()
            var content=editor.activeContent;content.textBlocks[0].text+=" \(index)"
            let receipt=expectation(description:"durable autosave")
            start = .now;let began=start
            editor.didCommit={_ in saves.append(Self.ms(began));receipt.fulfill()}
            editor.setDraft(content,pageID:pageID)
            await fulfillment(of:[receipt],timeout:30)
            XCTAssertEqual(editor.saveState,.saved)
            var phases=await store.performancePhases ?? [:];phases["paginationMS"]=editor.lastPaginationMS;savePhases.append(phases)
        }
        measurements["savePhases"]=savePhases
        measurements["debounceInclusiveSaveMS"]=saves;try recordStage("saved20")
        XCTAssertEqual(saves.count,20);if saves.count==20 {XCTAssertLessThanOrEqual(saves.sorted()[18],1_000)}
        editor.didCommit=nil
        // Prepared note/page selection service timing is reported separately from native curl/UI.
        var switches:[Double]=[],resident:[UInt64]=[],currentResident:[UInt64]=[Self.currentResidentBytes()]
        for index in 0..<200 {
            start = .now;editor.select(pageID:snapshot.pages[index%100].id);switches.append(Self.ms(start))
            if index%25==0 {var usage=rusage();getrusage(RUSAGE_SELF,&usage);resident.append(UInt64(usage.ru_maxrss));currentResident.append(Self.currentResidentBytes())}
            if [50,100,150].contains(index) {NotificationCenter.default.post(name:UIApplication.didReceiveMemoryWarningNotification,object:nil)}
            await Task.yield()
        }
        measurements["preparedSelectionOnlyMS"]=switches;measurements["processPeakRSSAt25Switches"]=resident;measurements["currentResidentAt25Selections"]=currentResident;try recordStage("selected200")
        try recordStage("producerComplete")
    }
    func testRetainedCollectionOverlapsOrdinaryAutosave() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_RETAINED_GC"]=="1" else {throw XCTSkip("Dedicated retained collector lane only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task8C-Collector-"+UUID().uuidString)
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/private/tmp/meetingbook-task8c-retained-closed"),to:root)
        // A previous process's abandoned file has no live publication lease in this store.
        let priorProcess=try AssetStore(root:root.appendingPathComponent("assets"),protection:StorageProtection())
        let staged=try await priorProcess.stage(data:Data("eligible synthetic orphan".utf8));let orphan=try await priorProcess.finalize(staged)
        let orphanURL=try await priorProcess.verifiedURL(hash:orphan)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-2*86400)],ofItemAtPath:orphanURL.path)
        let store=try await NotebookStore.open(root:root)
        let notes=try await store.listNotes(),snapshot=try await store.openNote(id:notes[0].id)
        let editor=EditorSession(store:store,snapshot:snapshot);await editor.loadFonts()
        let start=ContinuousClock.now
        let collector=Task {try await store.collectRetention()}
        try await Task.sleep(for:.milliseconds(50))
        var content=editor.activeContent;content.textBlocks[0].text+=" collector overlap e\u{301}"
        let receipt=expectation(description:"ordinary save during eligible collection")
        var saveMS=0.0;let editStart=ContinuousClock.now
        editor.didCommit={_ in saveMS=Self.ms(editStart);receipt.fulfill()}
        editor.setDraft(content,pageID:editor.activePageID);let setDraftMS=Self.ms(editStart)
        await fulfillment(of:[receipt],timeout:120)
        let result=try await collector.value,captureMS=await store.lastRetentionCaptureMS ?? -1
        XCTAssertEqual(editor.saveState,.saved)
        XCTAssertLessThanOrEqual(saveMS,1_000);XCTAssertLessThanOrEqual(setDraftMS,100)
        let idleStart=ContinuousClock.now
        let idle=try await store.collectRetention()
        let idleMS=Self.ms(idleStart)
        XCTAssertEqual(result.removedAssets+idle.removedAssets,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphanURL.path))
        let report:[String:Any]=["root":root.path,"elapsedMS":Self.ms(start),"setDraftMS":setDraftMS,"debounceInclusiveSaveMS":saveMS,"removedAssets":result.removedAssets,"overlapDeferred":result.deferred,"captureMS":captureMS,"idleCollectionMS":idleMS,"idleRemovedAssets":idle.removedAssets,"prunedRevisions":result.prunedRevisions,"currentResidentBytes":Self.currentResidentBytes(),"boundary":"EditorSession and real eligible foreground collector; no native caret/render/physical claim"]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("collector-report.json"))
        print("COLLECTOR REPORT \(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)")
    }
    func testNativeFontProducerTiming() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_FONT_PERFORMANCE"]=="1" else {throw XCTSkip("Dedicated native font timing lane only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task8C-Font-"+UUID().uuidString)
        let assets=try AssetStore(root:root),service=PersonalFontService(assets:assets)
        let project=try await FontServiceTests().makeProject(assets:assets)
        var strokes=0,points=0
        for hash in Set(project.glyphAssetHashes.values) {
            let drawing=try PKDrawing(data:await assets.read(hash:hash));strokes+=drawing.strokes.count
            points+=drawing.strokes.reduce(0){$0+$1.path.count}
        }
        var build:[Double]=[],durable:[Double]=[],registration:[Double]=[]
        for _ in 0..<5 {
            let start=ContinuousClock.now,result=try await service.build(project:project)
            build.append(Self.ms(start));_ = try await assets.finalize(result.asset);durable.append(Self.ms(start))
            let register=ContinuousClock.now;try await service.register(version:result.version);registration.append(Self.ms(register))
        }
        XCTAssertLessThanOrEqual(durable.max() ?? .infinity,15_000)
        let report:[String:Any]=["nativeBuildMS":build,"durableBuildMS":durable,"registerMS":registration,"capturedCodepoints":project.glyphAssetHashes.count,"uniqueDrawings":Set(project.glyphAssetHashes.values).count,"uniqueDrawingStrokes":strokes,"uniqueDrawingControlPoints":points,"fixture":"Existing topology glyph fixtures with repeated-A coverage scaffolding; not personal handwriting quality","currentResidentBytes":Self.currentResidentBytes()]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("font-timing.json"))
        print("FONT TIMING \(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)")
    }
    func testRetainedRecoveryStagedRead() throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_RETAINED_RECOVERY"]=="1" else {throw XCTSkip("Dedicated retained recovery lane only")}
        let start=ContinuousClock.now
        let rows=try NotebookStore.readMigrationEnvelope(at:URL(fileURLWithPath:"/private/tmp/meetingbook-task8c-checkpoints/B6382D4D-7E2E-453D-A0C2-02163B8D5A74.recovery"))
        XCTAssertEqual(rows.filter{$0.kind=="revision"}.count,210062)
        XCTAssertEqual(Self.revisionFingerprint(rows),"33f5e7b52fbaa180f685c3c57b5013262779d2b27708e65a4cf1363c34728687")
        print("RECOVERY VERIFIED rows \(rows.count) ms \(Self.ms(start)) resident \(Self.currentResidentBytes()) fingerprint \(Self.revisionFingerprint(rows))")
    }
    func testRetainedPackageStagedRestoreAndLargeSafety() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_RETAINED_RESTORE"]=="1" else {throw XCTSkip("Dedicated retained restore lane only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task8C-StagedRestore-"+UUID().uuidString)
        let package=URL(fileURLWithPath:"/private/tmp/meetingbook-task8c-full-v2.notebookpkg")
        var report:[String:Any]=["root":root.path]
        func stage(_ phase:String) throws {
            report["stage"]=phase;report["residentBytes"]=Self.currentResidentBytes()
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("report.json"),options:.atomic)
            print("RESTORE STAGE \(phase) root \(root.path) resident \(Self.currentResidentBytes())")
        }
        let destinationRoot=root.appendingPathComponent("destination")
        let store=try await NotebookStore.open(root:destinationRoot)
        let service=RestoreService(store:store,root:root.appendingPathComponent("imports"))
        var start=ContinuousClock.now
        let preview=try await service.inspectImport(url:package,sizePolicy:.large)
        report["inspectMS"]=Self.ms(start);try stage("inspected")
        start = .now;try await service.restore(preview,policy:.replace)
        report["restoreMS"]=Self.ms(start);try stage("restored")
        let reopened=try await NotebookStore.open(root:destinationRoot)
        let fingerprint=try await reopened.revisionFingerprintForAcceptance()
        report["revisionFingerprint"]=fingerprint
        XCTAssertEqual(fingerprint,"33f5e7b52fbaa180f685c3c57b5013262779d2b27708e65a4cf1363c34728687")
        let notes=try await reopened.listNotes();XCTAssertEqual(notes.count,100)
        let revisionCount=try await reopened.revisionCountForAcceptance();XCTAssertEqual(revisionCount,210062)
        report["destinationAfterAuthoring"]=try await reopened.metadataInventoryForAcceptance()
        try stage("reopened")
        start = .now
        let again=try await service.inspectImport(url:package,sizePolicy:.large)
        try await service.restore(again,policy:.replace)
        report["largeSafetyAndRestoreMS"]=Self.ms(start)
        let finalFingerprint=try await store.revisionFingerprintForAcceptance();XCTAssertEqual(finalFingerprint,fingerprint)
        var safetyInventories:[[String:Any]]=[]
        for saved in try NotebookPackage.saved(in:root.appendingPathComponent("SafetyBackups")) {
            let archive=try Archive(url:saved.url,accessMode:.read),entry=try XCTUnwrap(archive["manifest.json"])
            var bytes=Data();_ = try archive.extract(entry){bytes.append($0)}
            let manifest=try JSONDecoder().decode(PackageManifest.self,from:bytes)
            let metadata=manifest.files.filter{$0.path.hasPrefix("records/")}.reduce(UInt64(bytes.count)){$0+$1.size}
            safetyInventories.append(["profile":manifest.profile,"entryCount":manifest.files.count+1,"encodedMetadataIncludingManifestBytes":metadata,"path":saved.url.path])
        }
        XCTAssertTrue(safetyInventories.contains{($0["profile"] as? String)=="zip32-chunked-v2"})
        report["verifiedSafetyPackages"]=safetyInventories
        try stage("largeSafetyComplete")
    }
    nonisolated static func revisionFingerprint(_ rows:[NotebookStore.RecordRow]) -> String {
        var digest=SHA256()
        for row in rows.filter({$0.kind=="revision"}).sorted(by:{$0.key<$1.key}) {digest.update(data:Data(row.key.utf8));digest.update(data:row.payload)}
        return digest.finalize().map{String(format:"%02x",$0)}.joined()
    }
    func testTenThousandPageProducerBaseline() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_PERFORMANCE"]=="1" else {throw XCTSkip("Dedicated performance lane only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Performance-"+UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        try await store.seedPerformancePages(notes:100,pagesPerNote:100)
        let start=ContinuousClock.now
        let reopened=try await NotebookStore.open(root:root)
        let notes=try await reopened.listNotes()
        print("PERF store-open-ms \(Self.ms(start))")
        let searchStart=ContinuousClock.now
        let results=try await reopened.search(query:"late needle",scope:"notes")
        XCTAssertEqual(results.count,100)
        print("PERF ten-thousand-search-ms \(Self.ms(searchStart))")
        let page=try await reopened.openPage(id:notes[0].pageIDs[0])
        var content=page.content;content.textBlocks[0].text+=" changed"
        await reopened.startPerformanceMeasurement()
        let save=ContinuousClock.now
        _ = try await reopened.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        print("PERF ten-thousand-save-ms \(Self.ms(save))")
        print("PERF phases \(await reopened.performancePhases ?? [:])")
    }
    func testPrepareRetainedCorpusInventory() async throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_CORPUS"]=="1" else {throw XCTSkip("Dedicated corpus preparation only")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task8C-Retained-"+UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let assets=await store.assets, importer=ImageImportService(assets:await store.assets)
        var images:[String]=[],drawings:[String]=[]
        // Fixed grid pixels, full native 2048×1536 encoding; 100 live and 100 historical-only images.
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        for index in 0..<200 {
            let bytes=autoreleasepool {UIGraphicsImageRenderer(size:CGSize(width:2048,height:1536),format:format).pngData { context in
                for y in stride(from:0,to:1536,by:16) {for x in stride(from:0,to:2048,by:16) {
                    let v=(x*31+y*17+index*7919)%65536
                    UIColor(red:CGFloat(v%251)/250,green:CGFloat((v/7+index)%251)/250,blue:CGFloat((v/19+index*3)%251)/250,alpha:1).setFill()
                    context.fill(CGRect(x:x,y:y,width:16,height:16))
                }}
            }}
            let image=try await importer.importData(bytes);images.append(image.assetHash)
        }
        for index in 0..<100 {
            var points:[PKStrokePoint]=[]
            for i in 0..<32 {
                let location=CGPoint(x:60+i*4,y:100+(i*7+index)%120)
                points.append(PKStrokePoint(location:location,timeOffset:Double(i)*0.02,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:CGFloat.pi/2))
            }
            let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:0)))])
            let staged=try await assets.stage(data:drawing.dataRepresentation());drawings.append(try await assets.finalize(staged))
        }
        let font=try await FontServiceTests().registrationFixture(assets:assets,id:Self.corpusID(9,1))
        try await store.seedRetainedCorpus(images:images,drawings:drawings,font:font)
        let reopened=try await NotebookStore.open(root:root)
        let notes=try await reopened.listNotes();XCTAssertEqual(notes.count,100)
        let hits=try await reopened.search(query:"late needle",scope:"notes");XCTAssertEqual(hits.count,100)
        print("CORPUS retained-root \(root.path)")
        print("CORPUS inventory \(try String(contentsOf:root.appendingPathComponent("corpus-inventory.json"),encoding:.utf8))")
    }
    static func currentResidentBytes() -> UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) {pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        XCTAssertEqual(result,KERN_SUCCESS);return info.resident_size
    }
    nonisolated static func corpusID(_ kind:Int,_ index:Int) -> UUID {UUID(uuidString:String(format:"80000000-0000-4000-%04X-%012X",kind,index))!}
    static func ms(_ start:ContinuousClock.Instant) -> Double {let c=start.duration(to:.now).components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15}
}

extension NotebookStore {
    /// Test-owned bulk fixture; ordinary public create APIs would benchmark quadratic setup.
    func revisionFingerprintForAcceptance() throws -> String {AcceptancePerformanceTests.revisionFingerprint(try rawRowsForAcceptance())}
    func revisionCountForAcceptance() throws -> Int {try records("revision").count}
    func rawRowsForAcceptance() throws -> [RecordRow] {let context=self.context;return try context.performAndWait {try Self.rows(context:context)}}
    func metadataInventoryForAcceptance() throws -> [String:Int] {
        let context=self.context,rows=try context.performAndWait{try Self.rows(context:context)}
        var result=["rowCount":rows.count,"rawPayloadBytes":0,"rawMetadataIncludingKeyKindBytes":0,"encodedChunkBytes":0,"chunkCount":0]
        var chunk:[RecordRow]=[],payload=0
        func flush() throws {
            guard !chunk.isEmpty else {return}
            let size=try autoreleasepool {try RecordChunks.encode(chunk).values.reduce(0){$0+$1.count}}
            result["encodedChunkBytes",default:0]+=size;result["chunkCount",default:0]+=1;chunk=[];payload=0
        }
        for row in rows.sorted(by:{$0.key<$1.key}) {
            result["kind_"+row.kind,default:0]+=1;result["rawPayloadBytes",default:0]+=row.payload.count
            result["rawMetadataIncludingKeyKindBytes",default:0]+=try RecordChunks.rawSize(row)
            if !chunk.isEmpty && (chunk.count==256 || row.payload.count>16_000_000-payload) {try flush()}
            chunk.append(row);payload+=row.payload.count
        }
        try flush();return result
    }
    func startPerformanceMeasurement() {performancePhases=[:]}
    func seedRetainedCorpus(images:[String],drawings:[String],font:FontVersion) throws {
        let id=AcceptancePerformanceTests.corpusID
        let date=Date(timeIntervalSince1970:1_793_232_000)
        var value=library,rows:[RecordRow]=[]
        value.notes=[];value.fonts=[FontProject(id:id(8,1),name:"Fixed native TTF",versions:[font])]
        var sequence:Int64=0,kindCounts:[String:Int]=[:],kindBytes:[String:Int]=[:],digest=SHA256()
        func append(_ row:RecordRow) {rows.append(row);kindCounts[row.kind,default:0]+=1;kindBytes[row.kind,default:0]+=row.payload.count;digest.update(data:Data((row.kind+"/"+row.key+"\n").utf8));digest.update(data:row.payload)}
        for n in 0..<102 {
            let noteID=id(1,n),count=n<100 ? 100 : 1
            let ids=(0..<count).map{id(2,n*100+$0)}
            var note=Note(id:noteID,title:"Corpus \(n)",orderKey:Int64(n),pageIDs:ids,createdAt:date,modifiedAt:date)
            if n>=100 {note.deletedAt=date}
            value.notes.append(note)
            for (i,pageID) in ids.enumerated() {
                let ordinal=n*100+i
                var parent:UUID?
                for generation in 0...20 {
                    let revisionID=id(3,ordinal*21+generation)
                    var content=PageContent();content.version=2
                    var block=TextBlock(id:id(4,ordinal),text:"Äß e\u{301} 👩🏽‍💻 "+String(repeating:"text ",count:30)+(i==99 ? "late needle" : "ordinary"))
                    if ordinal%10==0 {block.fontVersionID=font.id} else {block.fontCatalogID="bundled.caveat"}
                    content.textBlocks=[block]
                    if ordinal%5==0 {content.images=[ImageElement(id:id(5,ordinal),frame:.init(x:60,y:300,width:400,height:300),assetHash:images[(ordinal/5)%100+(generation<20 ? 100 : 0)],altText:"Synthetic grid \(ordinal%100)")]}
                    if ordinal%10==1 {content.drawingAssetHash=drawings[(ordinal/10)%100]}
                    sequence+=1
                    let revision=PageRevision(id:revisionID,pageID:pageID,parentRevisionIDs:parent.map{[$0]} ?? [],deviceID:value.deviceID,sequence:sequence,createdAt:date.addingTimeInterval(Double(generation)),contentHash:AssetStore.hash(try encoder.encode(content)),content:content,reason:.edit)
                    append(.init(key:revisionID.uuidString,kind:"revision",payload:try encoder.encode(revision)))
                    parent=revisionID
                }
                let page=PageSnapshot(id:pageID,noteID:noteID,orderKey:Int64(i),currentRevisionID:parent!)
                append(.init(key:pageID.uuidString,kind:"page",payload:try encoder.encode(page)))
            }
        }
        value.sequence=sequence
        append(.init(key:"library",kind:"library",payload:try encoder.encode(value)))
        let graph=try Self.validateGraph(rows)
        var assetBytes=0,assetInventory:[String:Int]=[:]
        for hash in graph.assetHashes.sorted() {let bytes=try AssetStore.verifiedData(hash:hash,root:root.appendingPathComponent("assets"));assetInventory[hash]=bytes.count;assetBytes+=bytes.count}
        try replaceRows(rows);library=value
        let context=self.context;try context.performAndWait {try context.save()}
        validatedAssetHashes=graph.assetHashes;searchDocuments=graph.searchDocuments;causalProjection=graph.causalProjection
        protection.committed(graph.assetHashes);cacheEpoch=protection.currentCommitEpoch
        let inventory:[String:Any]=["fixture":"8C-fixed-grid-v1","livePages":10000,"deletedPages":2,"fullAncestorsPerPage":20,"rowCounts":kindCounts,"payloadBytes":kindBytes,"uniqueAssetBytes":assetBytes,"assets":assetInventory,"orderedRowSHA256":digest.finalize().map{String(format:"%02x",$0)}.joined(),"nativeImageDimensions":[2048,1536],"liveImages":100,"historicalOnlyImages":100,"drawings":100,"fontVersions":1,"sourceDeviceID":value.deviceID.uuidString]
        try JSONSerialization.data(withJSONObject:inventory,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("corpus-inventory.json"),options:.atomic)
    }
    func seedPerformancePages(notes count:Int,pagesPerNote:Int) throws {
        var value=library,rows:[RecordRow]=[]
        value.notes=[]
        for n in 0..<count {
            let noteID=UUID(),ids=(0..<pagesPerNote).map{_ in UUID()}
            value.notes.append(Note(id:noteID,title:"Corpus \(n)",orderKey:Int64(n),pageIDs:ids))
            for (i,id) in ids.enumerated() {
                var page=PageSnapshot(id:id,noteID:noteID,orderKey:Int64(i))
                var content=PageContent();content.textBlocks=[TextBlock(text:"Äß e\u{301} 👩🏽‍💻 "+String(repeating:"text ",count:30)+(i==99 ? "late needle" : "ordinary"))]
                let revision=PageRevision(id:page.currentRevisionID,pageID:id,parentRevisionIDs:[],deviceID:value.deviceID,sequence:Int64(n*pagesPerNote+i+1),createdAt:Date(timeIntervalSince1970:100),contentHash:AssetStore.hash(try encoder.encode(content)),content:content,reason:.edit)
                page.content=PageContent()
                rows.append(.init(key:id.uuidString,kind:"page",payload:try encoder.encode(page)))
                rows.append(.init(key:revision.id.uuidString,kind:"revision",payload:try encoder.encode(revision)))
            }
        }
        value.sequence=Int64(count*pagesPerNote)
        rows.append(.init(key:"library",kind:"library",payload:try encoder.encode(value)))
        let graph=try Self.validateGraph(rows)
        try replaceRows(rows);library=value
        let context=self.context;try context.performAndWait {try context.save()}
        validatedAssetHashes=graph.assetHashes;searchDocuments=graph.searchDocuments;causalProjection=graph.causalProjection
        protection.committed(graph.assetHashes);cacheEpoch=protection.currentCommitEpoch
    }
}


extension NotebookFeatureTests {
    func testSearchProjectionTracksExactEditsTrashRestoreAndFailedMutation() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Cafe\u{301} 😀 original")]
        let note=try await store.createNote(title:"Search",contents:[content])
        var hits=try await store.search(query:"CAFÉ",scope:"notes");XCTAssertEqual(hits.map(\.id),note.note.pageIDs)
        let page=try await store.openPage(id:note.pages[0].id)
        content.textBlocks[0].text="Replacement exact e\u{301}"
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        hits=try await store.search(query:"original",scope:"notes");XCTAssertTrue(hits.isEmpty)
        hits=try await store.search(query:"replacement",scope:"notes");XCTAssertEqual(hits.count,1)
        XCTAssertTrue(hits[0].snippet.unicodeScalars.elementsEqual(content.textBlocks[0].text.unicodeScalars))
        try await store.trash(noteID:note.note.id)
        hits=try await store.search(query:"replacement",scope:"notes");XCTAssertTrue(hits.isEmpty)
        hits=try await store.search(query:"replacement",scope:"trash");XCTAssertEqual(hits.count,1)
        try await store.restore(noteID:note.note.id)
        hits=try await store.search(query:"replacement",scope:"notes");XCTAssertEqual(hits.count,1)
        var invalid=content;invalid.textBlocks[0].fontSize = .nan
        let latest=try await store.openPage(id:page.id)
        do {_ = try await store.commit(.init(pageID:page.id,expectedRevisionID:latest.currentRevisionID,content:invalid));XCTFail("invalid delta accepted")} catch {}
        hits=try await store.search(query:"replacement",scope:"notes");XCTAssertEqual(hits.count,1)
        let reopened=try await NotebookStore.open(root:store.root)
        hits=try await reopened.search(query:"replacement",scope:"notes");XCTAssertEqual(hits.count,1)
    }
}


extension NotebookFeatureTests {
    func testSearchAndAuthoredDeltaRejectStaleSameRootActor() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first=try await NotebookStore.open(root:root)
        var content=PageContent();content.textBlocks=[TextBlock(text:"before")]
        let note=try await first.createNote(title:"Shared",contents:[content])
        let second=try await NotebookStore.open(root:root),page=note.pages[0]
        var hits=try await second.search(query:"before",scope:"notes");XCTAssertEqual(hits.count,1)
        content.textBlocks[0].text="other actor committed"
        _ = try await first.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:content))
        hits=try await second.search(query:"other actor",scope:"notes");XCTAssertEqual(hits.count,1)
        var stale=content;stale.textBlocks[0].text="must not overwrite"
        do {_ = try await second.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:stale));XCTFail("stale revision accepted")} catch {XCTAssertEqual(error as? NotebookError,.revisionConflict)}
        let latest=try await first.openPage(id:page.id);XCTAssertEqual(latest.content.textBlocks[0].text,"other actor committed")
        try await second.trash(noteID:note.note.id)
        hits=try await first.search(query:"other actor",scope:"notes");XCTAssertTrue(hits.isEmpty)
        try await first.restore(noteID:note.note.id)
        hits=try await second.search(query:"other actor",scope:"notes");XCTAssertEqual(hits.count,1)
    }
}

extension NotebookFeatureTests {
    func testDismissedKeyboardStaysDismissedDuringTurnPreparation() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"NEXT Ü ✓")]
        let note=try await store.createNote(title:"Dismissed keyboard",contents:[content,PageContent()])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        session.selectedElementID=content.textBlocks[0].id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
        let text=try XCTUnwrap(host.view.findFirstResponder() as? TextBlockView)
        let controller=try XCTUnwrap(text.delegate as? PageCanvasController)
        XCTAssertNotNil(controller.commandBar.window)
        XCTAssertGreaterThanOrEqual(controller.commandBar.bounds.height,44)
        XCTAssertNil(text.inputAccessoryView)
        text.selectedRange=NSRange(location:2,length:3);let selection=text.selectedRange
        XCTAssertTrue(text.resignFirstResponder());try await Task.sleep(for:.milliseconds(100))
        controller.refresh();try await session.leave();controller.refresh()
        XCTAssertFalse(text.isFirstResponder);XCTAssertEqual(text.selectedRange,selection)
        session.retainsTypingFocusDuringTurn=true;session.navigationLocked=true;controller.refresh()
        XCTAssertFalse(text.isFirstResponder)
        session.retainsTypingFocusDuringTurn=false;session.navigationLocked=false;controller.refresh()
        XCTAssertFalse(text.isFirstResponder);XCTAssertEqual(text.selectedRange,selection)
    }
}

extension NotebookFeatureTests {
    func testAccessoryFollowsWindowContentSizeWithoutReplacingEditor() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Large controls Ä 👩🏽‍💻")]
        let note=try await store.createNote(title:"Accessory sizing",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts()
        session.selectedElementID=content.textBlocks[0].id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),host=UIHostingController(rootView:SpreadWorkspace(session:session,notes:[note.note],onSelect:{_ in},onAdd:{}))
        window.rootViewController=host;window.makeKeyAndVisible();defer {window.isHidden=true}
        window.frame=CGRect(x:0,y:0,width:320,height:800)
        host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
        let text=try XCTUnwrap(host.view.findFirstResponder() as? TextBlockView)
        let controller=try XCTUnwrap(text.delegate as? PageCanvasController)
        let accessory=controller.commandBar,originalHeight=accessory.bounds.height
        var responders=[UIResponder](),next: UIResponder?=accessory
        while let current=next,responders.count<20 {responders.append(current);next=current.next}
        print("ACCESSORY_LIFECYCLE children=\(controller.children.map {String(reflecting:type(of:$0))}) chain=\(responders.map {String(reflecting:type(of:$0))}) window=\(String(describing:accessory.window))")
        func hostInView(_ view: UIView) -> UIHostingController<AnyView>? {
            var responder: UIResponder?=view
            while let current=responder {if let host=current as? UIHostingController<AnyView> {return host};responder=current.next}
            return view.subviews.lazy.compactMap {hostInView($0)}.first
        }
        let commands=try XCTUnwrap(hostInView(accessory))
        XCTAssertTrue(commands.parent === controller)
        print("ACCESSORY_PARENT \(String(describing:commands.parent))")
        text.selectedRange=NSRange(location:2,length:3);let selected=text.selectedRange
        defer {window.traitOverrides.preferredContentSizeCategory = .unspecified}
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.layoutIfNeeded();commands.view.setNeedsLayout();commands.view.layoutIfNeeded()
        // Require the rendered bar and hosted content to settle above the native glyph floor.
        let symbolTraits=UITraitCollection(preferredContentSizeCategory:.accessibilityExtraExtraExtraLarge)
        let symbolConfiguration=UIImage.SymbolConfiguration(font:UIFont.preferredFont(forTextStyle:.body,compatibleWith:symbolTraits))
        let requiredHeight=ceil(max(44,(EditorCommandSymbol.allCases.compactMap {UIImage(systemName:$0.rawValue,withConfiguration:symbolConfiguration)?.size.height}.max() ?? 0)+8))
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        var stableSamples=0
        while ContinuousClock.now<deadline && stableSamples<10 {
            try await Task.sleep(for:.milliseconds(50))
            stableSamples=accessory.bounds.height>=requiredHeight && commands.view.bounds.height>=requiredHeight ? stableSamples+1 : 0
        }
        XCTAssertEqual(stableSamples,10,"Accessory and hosted content must retain the glyph floor across settled layouts")
        print("ACCESSORY_SIZED windowOrigin=true window=\(window.traitCollection.preferredContentSizeCategory.rawValue) controller=\(commands.traitCollection.preferredContentSizeCategory.rawValue) view=\(commands.view.traitCollection.preferredContentSizeCategory.rawValue) frame=\(accessory.frame) intrinsic=\(accessory.intrinsicContentSize) preferred=\(commands.preferredContentSize)")
        XCTAssertGreaterThan(accessory.bounds.height,originalHeight)
        let symbolFont=UIFont.preferredFont(forTextStyle:.body,compatibleWith:commands.traitCollection)
        for symbol in EditorCommandSymbol.allCases {
            let symbolHeight=try XCTUnwrap(UIImage(systemName:symbol.rawValue,withConfiguration:UIImage.SymbolConfiguration(font:symbolFont))).size.height
            XCTAssertGreaterThanOrEqual(accessory.bounds.height,ceil(max(44,symbolHeight+8)),"Native \(symbol.rawValue) glyph plus vertical padding must fit")
        }
        XCTAssertEqual(accessory.bounds.width,320,accuracy:0.5)
        let capture=UIGraphicsImageRenderer(bounds:host.view.bounds).image {_ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)}
        let attachment=XCTAttachment(image:capture);attachment.name="Native 320pt AX command bar";attachment.lifetime = .keepAlways;add(attachment)
        let fitted=commands.sizeThatFits(in:CGSize(width:320,height:800))
        print("COMMAND_BAR_320 frame=\(accessory.frame) fitted=\(fitted)")
        XCTAssertLessThanOrEqual(fitted.width,320)
        XCTAssertGreaterThanOrEqual(accessory.bounds.height,ceil(fitted.height))
        XCTAssertGreaterThanOrEqual(commands.sizeThatFits(in:CGSize(width:320,height:1000)).height,commands.preferredContentSize.height)
        XCTAssertNil(text.inputAccessoryView);XCTAssertTrue(text.isFirstResponder)
        XCTAssertEqual(text.selectedRange,selected);XCTAssertEqual(session.activeContent,content)
        let largeHeight=accessory.bounds.height
        let shrank=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in accessory.bounds.height<largeHeight},object:nil)
        window.traitOverrides.preferredContentSizeCategory = .large
        window.layoutIfNeeded();commands.view.setNeedsLayout();commands.view.layoutIfNeeded()
        await fulfillment(of:[shrank],timeout:5)
        XCTAssertLessThan(accessory.bounds.height,largeHeight);XCTAssertGreaterThanOrEqual(accessory.bounds.height,44)
        XCTAssertNil(text.inputAccessoryView);XCTAssertTrue(text.isFirstResponder)
        XCTAssertEqual(text.selectedRange,selected);XCTAssertEqual(session.activeContent,content)
    }
}

extension NotebookFeatureTests {
    func testPaperContextFollowsActiveDraftAndKeepsWindowsIndependent() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var ivory=PageContent();ivory.style.paper="ivory";ivory.textBlocks=[TextBlock(text:"Keep e\u{301} 👩🏽‍💻")]
        var rose=PageContent();rose.style.paper="rose"
        let note=try await store.createNote(title:"Paper",contents:[ivory,rose])
        let first=EditorSession(store:store,snapshot:note),second=EditorSession(store:store,snapshot:note)
        func appearance(_ session: EditorSession?) -> PaperAppearance {PaperAppearance(activePaper:session?.activeContent.style.paper,defaultPaper:"cream")}
        XCTAssertEqual(appearance(nil).paper,"cream")
        XCTAssertEqual(appearance(first).paper,"ivory")
        first.select(pageID:note.pages[1].id)
        XCTAssertEqual(appearance(first).paper,"rose");XCTAssertEqual(appearance(second).paper,"ivory")
        var changed=first.activeContent;changed.style.paper="classic";first.setDraft(changed,pageID:first.activePageID)
        XCTAssertEqual(appearance(first).paper,"classic");XCTAssertEqual(second.activeContent,ivory)
        for paper in ["classic","cream","rose","ivory","unknown"] {
            XCTAssertEqual(PaperAppearance(defaultPaper:paper).uiColor,PageRenderer.paperColor(paper))
        }
        let controller=PageCanvasController(session:second);controller.loadViewIfNeeded()
        let text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? UITextView}.first)
        text.selectedRange=NSRange(location:2,length:3)
        controller.setPaperAppearance(PaperAppearance(defaultPaper:"rose"))
        controller.refresh()
        XCTAssertTrue(controller.page.subviews.contains{$0 === text})
        XCTAssertEqual(text.selectedRange,NSRange(location:2,length:3))
        XCTAssertEqual(second.activeContent,ivory)
    }
}
