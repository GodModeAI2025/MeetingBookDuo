import XCTest

final class PersonalSymbolUITests: XCTestCase {
    override func setUp() {super.setUp();continueAfterFailure=false}
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launch();showLibraryIfNeeded(app)
        return app
    }
    @MainActor private func openStudio(_ app: XCUIApplication,settings: Bool=false) {
        let entry=app.buttons[settings ? "Settings" : "Font Studio"]
        XCTAssertTrue(entry.waitForExistence(timeout:15));entry.tap()
        let open=app.buttons["symbols.open"]
        for _ in 0..<8 where !open.isHittable {app.swipeUp()}
        XCTAssertTrue(open.waitForExistence(timeout:10));open.tap()
        XCTAssertTrue(app.collectionViews["symbols.gallery"].waitForExistence(timeout:10))
    }
    @MainActor private func choose(_ symbol: String,in app: XCUIApplication) {
        let item=app.buttons["symbols.item."+symbol]
        for _ in 0..<8 where !item.isHittable {app.collectionViews["symbols.gallery"].swipeUp()}
        XCTAssertTrue(item.isHittable);item.tap()
        XCTAssertTrue(app.descendants(matching:.any)["symbols.canvas"].waitForExistence(timeout:5))
    }
    // A real XCTest finger drag, not an injected PKDrawing or a Pencil simulation.
    @MainActor private func draw(_ app: XCUIApplication,title: String?=nil) {
        if let title {
            let selected=NSPredicate {_,_ in app.staticTexts["symbols.title"].label==title && app.buttons["symbols.pen"].isEnabled}
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:selected,object:nil)],timeout:10),.completed)
        }
        let board=app.descendants(matching:.any)["symbols.canvas"]
        XCTAssertTrue(board.isHittable)
        board.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.35)).press(forDuration:0.05,thenDragTo:board.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.65)),withVelocity:.slow,thenHoldForDuration:0.1)
        let use=app.buttons["symbols.use"]
        reveal(use,in:app)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:use)],timeout:10),.completed)
    }
    @MainActor private func reveal(_ element: XCUIElement,in app: XCUIApplication,minimumVisibleHeight: CGFloat=0) {
        let scroll=app.scrollViews["symbols.editor"]
        for _ in 0..<8 where !element.isHittable || element.frame.intersection(scroll.frame).intersection(app.windows.firstMatch.frame).height<minimumVisibleHeight {
            // The center is the drawing board: scroll on the surrounding margin.
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.85)).press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.2)))
        }
    }
    @MainActor private func capture(_ app: XCUIApplication,_ title: String) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name=title;image.lifetime = .keepAlways;add(image)
        let tree=XCTAttachment(string:app.debugDescription);tree.name=title+" hierarchy";tree.lifetime = .keepAlways;add(tree)
    }
    @MainActor func testFingerDrawingUseRelaunchToggleEditAndReset() {
        let app=launch();openStudio(app);capture(app,"Symbol gallery")
        choose("pen",in:app);draw(app);capture(app,"Real finger drawing and 24 point preview")
        app.buttons["symbols.use"].tap()
        XCTAssertTrue(app.staticTexts["Saved drawing"].waitForExistence(timeout:10))
        app.terminate();app.launch();showLibraryIfNeeded(app);openStudio(app)
        XCTAssertTrue(app.buttons["symbols.item.pen"].label.contains("Own drawing"))
        let toggle=app.switches["symbols.enabled"]
        // In this English test, tap the native switch at the labeled row's trailing edge.
        XCTAssertEqual(toggle.value as? String,"1");toggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '0'"),object:toggle)],timeout:10),.completed)
        XCTAssertTrue(app.buttons["symbols.item.pen"].label.contains("Own drawing"));toggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == '1'"),object:toggle)],timeout:10),.completed)
        choose("pen",in:app)
        XCTAssertTrue(app.staticTexts["Saved drawing"].waitForExistence(timeout:5))
        let clear=app.buttons["symbols.clear"];reveal(clear,in:app);XCTAssertTrue(clear.isEnabled)
        clear.tap();app.buttons["symbols.undo"].tap();XCTAssertFalse(app.buttons["symbols.use"].isEnabled)
        let reset=app.buttons["symbols.reset"];reveal(reset,in:app,minimumVisibleHeight:44)
        XCTAssertTrue(reset.isEnabled);XCTAssertGreaterThanOrEqual(reset.frame.height,44)
        let visibleReset=reset.frame.intersection(app.scrollViews["symbols.editor"].frame).intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThanOrEqual(visibleReset.width,44);XCTAssertGreaterThanOrEqual(visibleReset.height,44)
        capture(app,"Enabled reset has a visible 44 point target")
        reset.tap()
        app.buttons.matching(identifier:"Reset to standard").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts["Standard symbol"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["symbols.reset"].isEnabled)
        capture(app,"Individual reset keeps studio usable")
    }
    @MainActor func testGalleryOffersOnlyConnectedSymbols() {
        let app=launch();openStudio(app)
        let gallery=app.collectionViews["symbols.gallery"]
        for _ in 0..<8 {
            XCTAssertFalse(app.buttons["symbols.item.library"].exists);XCTAssertFalse(app.buttons["symbols.item.search"].exists)
            if ["openBook","closeBook","designCover"].allSatisfy({app.buttons["symbols.item."+$0].exists}) {break}
            gallery.swipeUp()
        }
        for symbol in ["openBook","closeBook","designCover"] {XCTAssertTrue(app.buttons["symbols.item."+symbol].exists)}
    }
    @MainActor func testClearUndoAndProtectedExitAndNavigation() {
        let app=launch();openStudio(app);choose("pen",in:app);draw(app)
        let clear=app.buttons["symbols.clear"];reveal(clear,in:app);clear.tap()
        XCTAssertFalse(app.buttons["symbols.use"].isEnabled)
        app.buttons["symbols.undo"].tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:app.buttons["symbols.use"])],timeout:10),.completed)
        app.buttons["symbols.done"].tap();XCTAssertTrue(app.buttons["Save and continue"].waitForExistence(timeout:5))
        capture(app,"Unsaved exit offers save discard and cancel")
        app.buttons["Cancel"].tap();XCTAssertTrue(app.buttons["symbols.use"].isEnabled)
        if app.buttons["symbols.back"].exists {
            app.buttons["symbols.back"].tap();app.buttons["Save and continue"].tap()
            choose("eraser",in:app)
        } else {
            choose("eraser",in:app);app.buttons["Save and continue"].tap()
        }
        draw(app,title:"Eraser")
        if app.buttons["symbols.back"].exists {app.buttons["symbols.back"].tap()}
        else {choose("pen",in:app)}
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(app.buttons["symbols.item.eraser"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["symbols.item.eraser"].label.contains("Standard"))
        choose("pen",in:app);XCTAssertTrue(app.staticTexts["Saved drawing"].waitForExistence(timeout:5))
        capture(app,"Navigating preserves saved per-symbol drawing")
    }
    @MainActor func testDirtyDraftSurvivesWindowRotationAndSaves() {
        let app=launch();openStudio(app);choose("pen",in:app);draw(app,title:"Pen")
        let portrait=app.windows.firstMatch.frame
        XCTAssertLessThan(portrait.width,portrait.height)
        capture(app,"Dirty draft portrait before rotation")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=NSPredicate {_,_ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landscape,object:nil)],timeout:10),.completed)
        Thread.sleep(forTimeInterval:2)
        XCTAssertEqual(app.staticTexts["symbols.title"].label,"Pen")
        XCTAssertTrue(app.buttons["symbols.use"].isEnabled)
        let screen=XCTAttachment(screenshot:XCUIScreen.main.screenshot());screen.name="Dirty draft landscape after rotation";screen.lifetime = .keepAlways;add(screen)
        let bounds=XCTAttachment(string:"Portrait: \(portrait), landscape: \(app.windows.firstMatch.frame)");bounds.name="Width transition bounds";bounds.lifetime = .keepAlways;add(bounds)
        reveal(app.buttons["symbols.use"],in:app,minimumVisibleHeight:44)
        app.buttons["symbols.use"].tap()
        XCTAssertTrue(app.staticTexts["Saved drawing"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .portrait
    }
    @MainActor func testSettingsEntryRotationAndLargeTextKeepDraft() {
        let app=launch();app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();showLibraryIfNeeded(app);openStudio(app,settings:true);choose("pen",in:app)
        draw(app);XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=NSPredicate {_,_ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landscape,object:nil)],timeout:10),.completed)
        Thread.sleep(forTimeInterval:2)
        let use=app.buttons["symbols.use"], exit=app.buttons["symbols.done"], window=app.windows.firstMatch.frame
        reveal(use,in:app,minimumVisibleHeight:use.frame.height)
        let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name="Settled large text landscape";image.lifetime = .keepAlways;add(image)
        let bounds=XCTAttachment(string:"Window: \(window), Use: \(use.frame), exit: \(exit.frame)");bounds.name="Landscape bounds";bounds.lifetime = .keepAlways;add(bounds)
        XCTAssertTrue(use.isEnabled);XCTAssertTrue(use.isHittable)
        let visible=use.frame.intersection(app.scrollViews["symbols.editor"].frame).intersection(window)
        XCTAssertGreaterThanOrEqual(visible.width,44);XCTAssertGreaterThanOrEqual(visible.height,use.frame.height-1)
        XCTAssertTrue(exit.isHittable)
        use.tap();XCTAssertTrue(app.staticTexts["Saved drawing"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .portrait
    }
}
