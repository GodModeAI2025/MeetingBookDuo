import XCTest

final class BookCoverUITests: XCTestCase {
    @MainActor private func launch(startup:String="last") -> XCUIApplication {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup",startup]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launch();XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:15));print(app.debugDescription);return app
    }
    @MainActor private func capture(_ app:XCUIApplication,_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        let tree=XCTAttachment(string:app.debugDescription);tree.name=name+" hierarchy";tree.lifetime = .keepAlways;add(tree)
    }
    @MainActor func testRealBandShortPullReturnsAndCrossingOpens() {
        let app=launch();capture(app,"Cover resting")
        let band=app.otherElements["cover.band"].exists ? app.otherElements["cover.band"] : app.buttons["cover.band"]
        XCTAssertTrue(band.exists)
        let start=band.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.1,thenDragTo:start.withOffset(CGVector(dx:15,dy:90)),withVelocity:.slow,thenHoldForDuration:0.2)
        XCTAssertTrue(app.buttons["cover.open"].exists);capture(app,"Diagonal short pull returned")
        start.press(forDuration:0.1,thenDragTo:start.withOffset(CGVector(dx:85,dy:0)),withVelocity:.slow,thenHoldForDuration:0.2)
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout:10));XCTAssertFalse(app.buttons["cover.open"].exists)
        app.buttons["cover.close"].tap();XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:5))
        app.buttons.matching(identifier:"cover.open").allElementsBoundByIndex.first(where:{$0.isHittable})!.tap();XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout:5))
    }
    @MainActor func testCoverSettingsSaveCancelAndRelaunch() {
        let app=launch();app.buttons["cover.customize"].tap()
        let title=app.textFields["cover.settings.title"];XCTAssertTrue(title.waitForExistence(timeout:5));title.tap();title.typeText("Gedanken Ω 2026")
        app.buttons["cover.settings.save"].tap();XCTAssertTrue(app.staticTexts["Gedanken Ω 2026"].waitForExistence(timeout:5))
        app.buttons["cover.customize"].tap();title.tap();title.typeText(" CANCELLED")
        app.buttons["cover.settings.cancel"].tap();XCTAssertTrue(app.staticTexts["Gedanken Ω 2026"].exists)
        app.terminate();app.launch();XCTAssertTrue(app.staticTexts["Gedanken Ω 2026"].waitForExistence(timeout:10));capture(app,"Persisted custom title")
    }
    @MainActor func testStartupNewWaitsForAccessibleOpenAndRotationDoesNotOpen() {
        let app=launch(startup:"new")
        XCTAssertFalse(app.buttons["Use template"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["cover.open"].exists);capture(app,"Landscape cover")
        app.buttons.matching(identifier:"cover.open").allElementsBoundByIndex.first(where:{$0.isHittable})!.tap()
        XCTAssertTrue(app.navigationBars["Choose template"].waitForExistence(timeout:10) || app.searchFields.firstMatch.exists)
    }
    @MainActor func testTextAndUndoSurviveManualClose() {
        let app=launch();openBookIfNeeded(app);createNote(app,title:"Cover continuity")
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let text=app.textViews.firstMatch;text.typeText("Größe Äß Ω 👋")
        app.buttons["editor.keyboard.dismiss"].tap()
        app.buttons["Reading and appearance"].tap();app.buttons["cover.close"].tap()
        XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:5));capture(app,"Closed over retained editor")
        app.buttons.matching(identifier:"cover.open").allElementsBoundByIndex.first(where:{$0.isHittable})!.tap()
        XCTAssertEqual(text.value as? String,"Größe Äß Ω 👋")
        XCTAssertTrue(app.buttons["Undo"].isEnabled);app.buttons["Undo"].tap()
        XCTAssertNotEqual(text.value as? String,"Größe Äß Ω 👋")
    }
    @MainActor func testExplicitNewLinkOpensThroughCover() {
        let app=launch()
        app.open(URL(string:"meetingbook://new")!)
        XCTAssertFalse(app.buttons["cover.open"].waitForExistence(timeout:2))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout:10))
    }
    @MainActor func testSyntheticFoldPreservesCoverSettingsDraft() {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_SYNTHETIC_HINGE":"1"]
        app.launch();openBookIfNeeded(app)
        app.buttons["cover.close"].tap();app.buttons["cover.customize"].tap()
        let title=app.textFields["cover.settings.title"];XCTAssertTrue(title.waitForExistence(timeout:5));title.tap();title.typeText("Unfinished draft")
        app.buttons.matching(identifier:"cover.syntheticHinge").allElementsBoundByIndex.last(where:{$0.isHittable})!.tap()
        app.buttons.matching(identifier:"cover.syntheticHinge").allElementsBoundByIndex.last(where:{$0.isHittable})!.tap()
        XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:5));capture(app,"Synthetic fold covers retained settings")
        app.buttons.matching(identifier:"cover.open").allElementsBoundByIndex.first(where:{$0.isHittable})!.tap()
        XCTAssertEqual(title.value as? String,"Unfinished draft")
        app.buttons["cover.settings.cancel"].tap()
    }

    @MainActor func testSyntheticFoldPreservesDirtySymbolSheet() {
        XCUIDevice.shared.orientation = .portrait
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_SYNTHETIC_HINGE":"1"]
        app.launch();openBookIfNeeded(app);showLibraryIfNeeded(app)
        app.buttons["Font Studio"].tap();app.buttons["symbols.open"].tap()
        let pen=app.buttons["symbols.item.pen"]
        XCTAssertTrue(app.collectionViews["symbols.gallery"].waitForExistence(timeout:10))
        for _ in 0..<8 where !pen.isHittable {app.collectionViews["symbols.gallery"].swipeUp()}
        XCTAssertTrue(pen.isHittable);pen.tap()
        let board=app.descendants(matching:.any)["symbols.canvas"];XCTAssertTrue(board.waitForExistence(timeout:5))
        board.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.35)).press(forDuration:0.05,thenDragTo:board.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.65)),withVelocity:.slow,thenHoldForDuration:0.1)
        XCTAssertTrue(app.staticTexts["Unsaved drawing"].waitForExistence(timeout:5))
        app.buttons.matching(identifier:"cover.syntheticHinge").allElementsBoundByIndex.last(where:{$0.isHittable})!.tap()
        XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:5));capture(app,"Synthetic fold covers dirty symbol sheet")
        app.buttons.matching(identifier:"cover.open").allElementsBoundByIndex.first(where:{$0.isHittable})!.tap()
        XCTAssertTrue(app.staticTexts["Unsaved drawing"].waitForExistence(timeout:5))
        app.buttons["symbols.done"].tap();XCTAssertTrue(app.buttons["Save and continue"].waitForExistence(timeout:5))
        app.buttons["Cancel"].tap();capture(app,"Dirty symbol recovered after synthetic unfold")
    }

    @MainActor func testPhotoCropLongTitleAndRelaunch() {
        let app=launch();app.buttons["cover.customize"].tap()
        app.buttons["Choose cover photo"].tap()
        let gridReady=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.collectionViews.cells.allElementsBoundByIndex.contains(where:{$0.isHittable})},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[gridReady],timeout:30),.completed)
        print(app.debugDescription)
        let photo=app.collectionViews.cells.allElementsBoundByIndex.first(where:{$0.isHittable})!
        photo.tap()
        XCTAssertTrue(app.buttons["Remove cover photo"].waitForExistence(timeout:10))
        let preview=app.otherElements["cover.preview"]
        let start=preview.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.1,thenDragTo:start.withOffset(CGVector(dx:45,dy:0)),withVelocity:.slow,thenHoldForDuration:0.1)
        let title=app.textFields["cover.settings.title"];title.tap();title.typeText("Meine Gedanken und Erinnerungen – Ideen für morgen")
        app.buttons["cover.settings.save"].tap();XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:5))
        capture(app,"Photo and long handwritten title portrait")
        XCUIDevice.shared.orientation = .landscapeLeft;capture(app,"Photo and long title landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate();app.launch();XCTAssertTrue(app.buttons["cover.open"].waitForExistence(timeout:10))
        app.buttons["cover.customize"].tap();XCTAssertTrue(app.buttons["Remove cover photo"].waitForExistence(timeout:5))
        app.buttons["cover.settings.cancel"].tap()
    }

    @MainActor func testGermanLargeTextCoverCommandsRemainReachable() {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launch()
        let open=app.buttons["cover.open"],design=app.buttons["cover.customize"]
        XCTAssertTrue(open.waitForExistence(timeout:10));XCTAssertTrue(open.isHittable);XCTAssertTrue(design.isHittable)
        for button in [open,design] {XCTAssertGreaterThanOrEqual(button.frame.width,44);XCTAssertGreaterThanOrEqual(button.frame.height,44)}
        capture(app,"German largest text cover commands")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(open.isHittable);XCTAssertTrue(design.isHittable);capture(app,"German largest text landscape cover")
        open.tap();XCTAssertTrue(app.buttons["cover.close"].waitForExistence(timeout:10))
        XCUIDevice.shared.orientation = .portrait
    }

}
