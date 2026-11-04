import XCTest
final class EditorUITests: XCTestCase {
    @MainActor func testKeyboardNextAndReturnPreserveNativeText() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_TRACE_NAVIGATION":"1"]
        app.launch();openBookIfNeeded(app)
        let sidebar=app.buttons["Show Sidebar"]
        if sidebar.waitForExistence(timeout:5) {sidebar.tap()}
        createNote(app,title:"Keyboard navigation "+UUID().uuidString)
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        let neighborReady=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:app.buttons["Next page"])
        XCTAssertEqual(XCTWaiter.wait(for:[neighborReady],timeout:10),.completed)
        app.buttons["Next page"].tap()
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout:10))
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let neighborText="Neighbor target Ω"
        app.textViews.firstMatch.typeText(neighborText)
        selectEditorMode("Read",in:app)
        app.buttons["Previous page"].tap()
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout:10))
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let text=app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout:10))
        let value="Größe ÄÖÜ ß Ω ✓\nUntere Zeile Café 👋"
        text.typeText(value)
        let keyboard=app.keyboards.firstMatch
        let softwareKeyboard=NSPredicate {_,_ in keyboard.exists && keyboard.frame.height>100 && app.windows.firstMatch.frame.intersects(keyboard.frame)}
        guard XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:softwareKeyboard,object:nil)],timeout:10) == .completed else {XCTFail("A real software keyboard must intersect the app window");return}
        XCTAssertEqual(text.value as? String,value)
        func capture(_ name: String) {
            let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
            let tree=XCTAttachment(string:app.debugDescription);tree.name=name+" hierarchy";tree.lifetime = .keepAlways;add(tree)
        }
        capture("Keyboard and commands before Next")
        for button in [app.buttons["editor.keyboard.dismiss"],app.buttons["editor.keyboard.mode"],app.buttons["Previous page"],app.buttons["Next page"],app.buttons["Undo"],app.buttons["editor.keyboard.pageMenu"]] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width,44);XCTAssertGreaterThanOrEqual(button.frame.height,44)
            XCTAssertLessThanOrEqual(button.frame.maxY,app.keyboards.firstMatch.frame.minY+1)
        }
        XCTAssertFalse(app.buttons["editor.mode"].isHittable)
        let next=app.buttons["Next page"]
        XCTAssertTrue(next.isEnabled);XCTAssertTrue(next.isHittable);next.tap()
        let neighborSelected=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.textViews.firstMatch.value as? String == neighborText},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[neighborSelected],timeout:10),.completed)
        capture("Existing neighbor selected after Next")
        let previous=app.buttons["Previous page"]
        XCTAssertTrue(previous.isHittable);previous.tap()
        let sourceSelected=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in text.value as? String == value},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[sourceSelected],timeout:10),.completed)
        XCTAssertTrue(text.waitForExistence(timeout:10));XCTAssertEqual(text.value as? String,value)
        text.tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:softwareKeyboard,object:nil)],timeout:10),.completed)
        capture("Returned exact Unicode and native caret")
        app.terminate();app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last"];app.launch();openBookIfNeeded(app)
        selectEditorMode("Schreiben",in:app)
        let dismiss=app.buttons["editor.keyboard.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout:10));XCTAssertEqual(dismiss.label,"Tastatur ausblenden")
        capture("German keyboard dismissal accessibility label")
    }
    @MainActor func testNativeTypingResizeAndReopen() {
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"];app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();openBookIfNeeded(app)
        let title="Native-"+UUID().uuidString
        createNote(app,title:title)
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let text=app.textViews.firstMatch;XCTAssertTrue(text.waitForExistence(timeout:10));text.typeText("Native Unicode Äß e\u{301} 👩🏽‍💻\nSecond line")
        let typed=XCTAttachment(screenshot:app.screenshot());typed.name="Native text hardware-input caret";typed.lifetime = .keepAlways;add(typed)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(text.exists)
        openEditorPageMenu(app);app.buttons["Save locally"].tap()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout:10))
        let landscape=NSPredicate { _,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landscape,object:nil)],timeout:10),.completed)
        Thread.sleep(forTimeInterval:2)
        let viewport=app.scrollViews["editor.viewport"].frame
        XCTAssertGreaterThanOrEqual(viewport.height,110)
        XCTAssertGreaterThan(text.frame.intersection(viewport).height,0)
        text.typeText("!");text.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(text.value as? String,"Native Unicode Äß e\u{301} 👩🏽‍💻\nSecond line")
        let state=XCTAttachment(string:"Window: \(app.windows.firstMatch.frame); viewport: \(viewport); text: \(text.frame); software keyboard: \(app.keyboards.firstMatch.exists)")
        state.name="Stable landscape viewport readback";state.lifetime = .keepAlways;add(state)
        let rotated=XCTAttachment(screenshot:XCUIScreen.main.screenshot());rotated.name="Stable full-screen landscape after save";rotated.lifetime = .keepAlways;add(rotated)
        app.buttons["editor.keyboard.dismiss"].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let restored=XCTAttachment(screenshot:XCUIScreen.main.screenshot());restored.name="Landscape navigation restored after keyboard dismissal";restored.lifetime = .keepAlways;add(restored)
        XCUIDevice.shared.orientation = .portrait
        app.terminate();app.launch();openBookIfNeeded(app)
        XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:10))
        XCTAssertTrue(text.waitForExistence(timeout:10));XCTAssertEqual(text.value as? String,"Native Unicode Äß e\u{301} 👩🏽‍💻\nSecond line")
    }
}
