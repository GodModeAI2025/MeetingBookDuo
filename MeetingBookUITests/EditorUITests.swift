import XCTest
final class EditorUITests: XCTestCase {
    @MainActor func testKeyboardNextAndReturnPreserveNativeText() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_TRACE_NAVIGATION":"1"]
        app.launch();openBookIfNeeded(app)
        let sidebar=app.buttons["notebook.showIndex"]
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
        let reopenedText=app.textViews.firstMatch
        XCTAssertTrue(reopenedText.waitForExistence(timeout:10));reopenedText.tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:softwareKeyboard,object:nil)],timeout:10),.completed)
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
        XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let restored=XCTAttachment(screenshot:XCUIScreen.main.screenshot());restored.name="Landscape navigation restored after keyboard dismissal";restored.lifetime = .keepAlways;add(restored)
        XCUIDevice.shared.orientation = .portrait
        app.terminate();app.launch();openBookIfNeeded(app)
        XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:10))
        XCTAssertTrue(text.waitForExistence(timeout:10));XCTAssertEqual(text.value as? String,"Native Unicode Äß e\u{301} 👩🏽‍💻\nSecond line")
    }
}

extension EditorUITests {
    @MainActor func testNativeLeafForwardBackwardAndCancelledPartialTurn() {nativeLeafFlow(landscape:false)}
    @MainActor func testNativeSpreadForwardBackwardAndCancelledPartialTurn() {nativeLeafFlow(landscape:true)}
    @MainActor private func nativeLeafFlow(landscape: Bool) {
        continueAfterFailure=false;XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_TRACE_NAVIGATION":"1"]
        app.launch();openBookIfNeeded(app);createNote(app,title:"Native leaf evidence")
        if app.buttons["Close index"].exists {app.buttons["Close index"].tap()}
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        let next=app.buttons["editor.next"]
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:next)],timeout:10),.completed)
        next.tap();XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout:10))
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        app.textViews.firstMatch.typeText("Destination Ω")
        selectEditorMode("Read",in:app);app.buttons["editor.previous"].tap()
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout:10))
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let exact="Größe Äß e\u{301} 👩🏽‍💻"
        app.textViews.firstMatch.typeText(exact)
        let originalBytes=Array((app.textViews.firstMatch.value as? String ?? "").utf8)
        if app.buttons["editor.keyboard.dismiss"].exists {app.buttons["editor.keyboard.dismiss"].tap()}
        func capture(_ name:String) {
            let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
            let tree=XCTAttachment(string:app.debugDescription);tree.name=name+" hierarchy";tree.lifetime = .keepAlways;add(tree)
            print("LEAF_EVIDENCE \(Date().timeIntervalSince1970) \(name)")
        }
        Thread.sleep(forTimeInterval:3);capture("Source exact text before curl")
        let paper=app.otherElements["notebook.paper"].firstMatch
        XCTAssertTrue(paper.exists,"Read the actual paper bounds, not the inset editor viewport")
        XCTAssertEqual(paper.frame.minY,app.scrollViews["editor.viewport"].frame.minY,accuracy:0.5,"Paper starts at the live viewport, below system chrome")
        if landscape {XCTAssertGreaterThan(paper.frame.width,1000,"The spread proof needs a wide iPad window")}
        let initialPaperFrame=paper.frame
        let viewport=app.scrollViews["editor.viewport"].frame
        // Reconstruct leaf bounds from the live content and its existing 52pt outer command margin.
        // Reserved system regions can make the leaves smaller than the paper container.
        let leafWidth=viewport.width+52
        let initialLeafFrame=CGRect(x:viewport.minX-(landscape ? leafWidth : 0),y:paper.frame.minY,width:leafWidth*(landscape ? 2 : 1),height:paper.frame.height)
        let nativePager=app.otherElements["notebook.leafPager"].firstMatch
        print("LEAF_WINDOW before=\(app.windows.firstMatch.frame) paper=\(initialPaperFrame) intendedLeaves=\(initialLeafFrame)")
        func corner(right:Bool,lower:Bool) -> XCUICoordinate {
            let bounds=initialLeafFrame,actual=nativePager.frame
            XCTAssertEqual(actual.minX,bounds.minX,accuracy:0.5)
            XCTAssertEqual(actual.minY,bounds.minY,accuracy:0.5)
            XCTAssertEqual(actual.width,bounds.width,accuracy:0.5)
            XCTAssertEqual(actual.height,bounds.height,accuracy:0.5)
            let inset=landscape ? 40.0 : 6.0
            let x=right ? bounds.maxX-inset : bounds.minX+inset,y=lower ? bounds.maxY-inset : bounds.minY+inset
            print("LEAF_CORNER bounds=\(bounds) native=\(actual) start=(\(x),\(y)) right=\(right) lower=\(lower) inset=\(inset)")
            return paper.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x-paper.frame.minX,dy:y-paper.frame.minY))
        }
        let lowerRight=corner(right:true,lower:true)
        print("LEAF_GESTURE partial-lower-right \(Date().timeIntervalSince1970)")
        lowerRight.press(forDuration:0.05,thenDragTo:lowerRight.withOffset(CGVector(dx:-28,dy:-8)),withVelocity:.slow,thenHoldForDuration:1)
        XCTAssertTrue(app.staticTexts["Page 1"].exists);XCTAssertEqual(app.textViews.firstMatch.value as? String,exact)
        capture("Actual lower corner return in Type mode source intact")
        XCTAssertEqual(paper.frame.width,initialPaperFrame.width,accuracy:0.5,"Corner return must not resize the OS window")
        XCTAssertEqual(paper.frame.minX,initialPaperFrame.minX,accuracy:0.5)
        print("LEAF_WINDOW afterReturn=\(app.windows.firstMatch.frame) paper=\(paper.frame)")
        Thread.sleep(forTimeInterval:2)
        let upperRight=corner(right:true,lower:false)
        print("LEAF_GESTURE forward-upper-right \(Date().timeIntervalSince1970)")
        upperRight.press(forDuration:0.05,thenDragTo:upperRight.withOffset(CGVector(dx:-initialLeafFrame.width*0.85,dy:90)),withVelocity:.slow,thenHoldForDuration:0.5)
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout:10))
        XCTAssertEqual(app.textViews.firstMatch.value as? String,"Destination Ω");capture("Actual upper corner forward destination in Type mode")
        if app.buttons["editor.keyboard.dismiss"].exists {app.buttons["editor.keyboard.dismiss"].tap()}
        Thread.sleep(forTimeInterval:2)
        let upperLeft=corner(right:false,lower:false)
        print("LEAF_GESTURE partial-upper-left \(Date().timeIntervalSince1970)")
        upperLeft.press(forDuration:0.05,thenDragTo:upperLeft.withOffset(CGVector(dx:28,dy:8)),withVelocity:.slow,thenHoldForDuration:1)
        XCTAssertTrue(app.staticTexts["Page 2"].exists);XCTAssertEqual(app.textViews.firstMatch.value as? String,"Destination Ω")
        capture("Actual upper reverse corner return destination intact")
        Thread.sleep(forTimeInterval:2)
        let lowerLeft=corner(right:false,lower:true)
        print("LEAF_GESTURE reverse-lower-left \(Date().timeIntervalSince1970)")
        lowerLeft.press(forDuration:0.05,thenDragTo:lowerLeft.withOffset(CGVector(dx:initialLeafFrame.width*0.85,dy:-90)),withVelocity:.slow,thenHoldForDuration:0.5)
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout:10))
        XCTAssertEqual(Array((app.textViews.firstMatch.value as? String ?? "").utf8),originalBytes);capture("Actual lower corner reverse exact source")
        selectEditorMode("Type",in:app);app.textViews.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap();app.textViews.firstMatch.typeText("!")
        XCTAssertEqual(app.textViews.firstMatch.value as? String,exact+"!");capture("Returned editable cursor")
        Thread.sleep(forTimeInterval:5) // Keep the live caret visible for direct simulator capture before teardown.
    }
}

extension EditorUITests {
    @MainActor func testNativeLargeTypeFolioAndSavedStatus() {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_TRACE_NAVIGATION":"1"]
        app.launch();openBookIfNeeded(app);createNote(app,title:"Large folio evidence")
        if app.buttons["Close index"].exists {app.buttons["Close index"].tap()}
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout:10))
        app.terminate();app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();openBookIfNeeded(app)
        let folio=app.staticTexts["Page 1"],status=app.staticTexts["Saved locally"]
        XCTAssertTrue(folio.waitForExistence(timeout:10));XCTAssertTrue(status.exists)
        print("LARGE_FOLIO frame=\(folio.frame) savedStatus=\(status.frame)")
        XCTAssertGreaterThan(folio.frame.height,25,"The native accessibility size must actually be active")
        XCTAssertGreaterThan(status.frame.width,150,"The full saved label must be visible, not the earlier Sav… truncation")
        XCTAssertFalse(folio.frame.intersects(status.frame),"The enlarged folio and truthful save status must remain separate")
        func capture(_ name:String) {
            let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
            let tree=XCTAttachment(string:app.debugDescription);tree.name=name+" hierarchy";tree.lifetime = .keepAlways;add(tree)
        }
        Thread.sleep(forTimeInterval:3);capture("Narrow phone accessibility5 live folio and saved status")
        let paper=app.otherElements["notebook.paper"].firstMatch,bounds=app.otherElements["notebook.paper"].firstMatch.frame
        let corner=paper.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:bounds.width-6,dy:bounds.height-6))
        print("LEAF_CORNER_AX bounds=\(bounds) start=(\(bounds.maxX-6),\(bounds.maxY-6)) inset=6")
        print("LEAF_GESTURE large-type-lower-right \(Date().timeIntervalSince1970)")
        corner.press(forDuration:0.05,thenDragTo:corner.withOffset(CGVector(dx:-28,dy:-8)),withVelocity:.slow,thenHoldForDuration:1)
        XCTAssertTrue(folio.exists);XCTAssertTrue(status.exists)
        capture("Narrow phone accessibility5 after native corner return")
        XCTAssertGreaterThanOrEqual(status.frame.minY,folio.frame.maxY)
        XCTAssertLessThanOrEqual(status.frame.maxY,paper.frame.maxY+0.5)
        app.terminate()
        app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();openBookIfNeeded(app)
        let germanFolio=app.staticTexts["Seite 1"],germanStatus=app.staticTexts["Lokal gespeichert"]
        XCTAssertTrue(germanFolio.waitForExistence(timeout:10));XCTAssertTrue(germanStatus.exists)
        print("LARGE_FOLIO_DE frame=\(germanFolio.frame) savedStatus=\(germanStatus.frame)")
        XCTAssertGreaterThan(germanStatus.frame.width,200,"The complete German status must fit")
        XCTAssertGreaterThanOrEqual(germanStatus.frame.minY,germanFolio.frame.maxY)
        XCTAssertLessThanOrEqual(germanStatus.frame.maxY,paper.frame.maxY+0.5)
        capture("Narrow phone accessibility5 full German folio and saved status")
    }
}
