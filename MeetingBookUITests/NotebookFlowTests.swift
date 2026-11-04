import XCTest
extension XCTestCase {
    @MainActor func openBookIfNeeded(_ app: XCUIApplication) {
        let open=app.buttons["cover.open"]
        if open.waitForExistence(timeout:3),open.isHittable {open.tap()}
    }
    @MainActor func showLibraryIfNeeded(_ app: XCUIApplication) {
        openBookIfNeeded(app)
        if app.launchArguments.contains("new") { return }
        if app.textFields["Title"].isHittable || app.textFields["Titel"].isHittable {return}
        let sidebar=app.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar' OR label CONTAINS[c] 'Seitenleiste'")).firstMatch
        if sidebar.waitForExistence(timeout:3),sidebar.isHittable {sidebar.tap()}
    }

    @MainActor func openEditorPageMenu(_ app: XCUIApplication) {
        let keyboard=app.buttons["editor.keyboard.pageMenu"],normal=app.buttons["editor.pageMenu"]
        let menu=keyboard.isHittable ? keyboard : normal
        XCTAssertTrue(menu.waitForExistence(timeout:10));XCTAssertTrue(menu.isHittable);menu.tap()
    }
    @MainActor func selectEditorMode(_ title: String,in app: XCUIApplication) {
        let keyboard=app.buttons["editor.keyboard.mode"],normal=app.buttons["editor.mode"]
        let menu=keyboard.isHittable ? keyboard : normal
        XCTAssertTrue(menu.waitForExistence(timeout:10));XCTAssertTrue(menu.isHittable);menu.tap()
        let item=app.buttons[title];XCTAssertTrue(item.waitForExistence(timeout:5));item.tap()
    }
    @MainActor func createNote(_ app: XCUIApplication,title: String) {
        if app.buttons["BackButton"].waitForExistence(timeout:5) { app.buttons["BackButton"].tap() }
        showLibraryIfNeeded(app)
        let field=app.textFields["Title"];XCTAssertTrue(field.waitForExistence(timeout:10));field.tap();field.typeText(title)
        app.buttons["New note"].tap()
        let search=app.searchFields["Name, category or topic"]
        if !search.waitForExistence(timeout:2),app.buttons["Search"].firstMatch.isHittable {app.buttons["Search"].firstMatch.tap()}
        XCTAssertTrue(search.waitForExistence(timeout:10));search.tap();search.typeText("Lined paper")
        let choice=app.buttons["template.meetingbook.lined"].firstMatch
        if choice.waitForExistence(timeout:5) { choice.tap() } else { app.staticTexts["Lined paper"].firstMatch.tap() }
        let use=app.buttons["Use template"];XCTAssertTrue(use.waitForExistence(timeout:10))
        let enabled=NSPredicate(format:"enabled == true");XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:enabled,object:use)],timeout:20),.completed)
        use.tap();XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:15))
    }
}
final class NotebookFlowTests: XCTestCase {
    @MainActor func testFinalGermanEmptyStateAndSingularTemplate() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        if app.buttons["BackButton"].waitForExistence(timeout:3) {app.buttons["BackButton"].tap()}
        XCTAssertTrue(app.staticTexts["Hier sind noch keine Notizen"].waitForExistence(timeout:15))
        capture(app,"DE final empty sidebar complete headline")
        app.terminate();app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","new"];app.launch();showLibraryIfNeeded(app)
        let search=app.searchFields["Name, Kategorie oder Thema"]
        if !search.waitForExistence(timeout:2), app.buttons["Suchen"].firstMatch.isHittable {app.buttons["Suchen"].firstMatch.tap()}
        XCTAssertTrue(search.waitForExistence(timeout:10));search.tap();search.typeText("Liniert")
        let first=app.buttons["template.meetingbook.lined"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:10));first.tap()
        XCTAssertTrue(app.staticTexts["1 Seite"].waitForExistence(timeout:15))
        XCTAssertFalse(app.staticTexts["1 Seiten"].exists)
        capture(app,"DE final template singular and action")
    }
    @MainActor func testBookmarkRemovalRefreshesListAndStartup() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_TRACE_NAVIGATION":"1"];app.launch();showLibraryIfNeeded(app)
        func showIndex() {
            if app.buttons["BackButton"].exists {app.buttons["BackButton"].tap()}
            if app.buttons["Show Sidebar"].exists {app.buttons["Show Sidebar"].tap()}
        }
        createNote(app,title:"Bookmark A");app.buttons["Bookmark"].tap()
        createNote(app,title:"Bookmark B");app.buttons["Bookmark"].tap()
        showIndex()
        app.buttons["notebook.scope"].tap();app.buttons["Bookmarks"].tap()
        let rows=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","notebook.hit."))
        let two=XCTNSPredicateExpectation(predicate:NSPredicate(format:"count == 2"),object:rows)
        XCTAssertEqual(XCTWaiter.wait(for:[two],timeout:5),.completed)
        let noteB=rows.matching(NSPredicate(format:"label BEGINSWITH %@","Bookmark B,")).firstMatch
        XCTAssertTrue(noteB.waitForExistence(timeout:10));noteB.tap()
        app.buttons["Bookmark"].tap();showIndex()
        let one=XCTNSPredicateExpectation(predicate:NSPredicate(format:"count == 1"),object:rows)
        XCTAssertEqual(XCTWaiter.wait(for:[one],timeout:5),.completed)
        app.terminate();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","bookmark"];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.navigationBars["Bookmark A"].waitForExistence(timeout:15))
        capture(app,"Removed latest bookmark falls back to A after relaunch")
    }

    @MainActor func testReadSwipeAndIncompleteDrag() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        createNote(app,title:"Swipe source");createNote(app,title:"Swipe destination")
        selectEditorMode("Read",in:app)
        let page=app.otherElements["Canonical page"]
        let start=page.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.4))
        start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:30,dy:0)))
        XCTAssertTrue(app.navigationBars["Swipe destination"].exists)
        start.press(forDuration:0.05,thenDragTo:page.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.4)))
        XCTAssertTrue(app.navigationBars["Swipe source"].waitForExistence(timeout:10))
        capture(app,"Read swipe returns to previous note")
    }

    @MainActor func testChooserAndFontDraftScreens() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","new"];app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        let search=app.searchFields["Name, category or topic"];XCTAssertTrue(search.waitForExistence(timeout:15))
        capture(app,"Chooser complete catalog")
        search.tap();search.typeText("travel")
        capture(app,"Travel search")
        app.terminate();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"];app.launch();showLibraryIfNeeded(app)
        if app.buttons["BackButton"].waitForExistence(timeout:5) { app.buttons["BackButton"].tap() }
        let studio=app.buttons["Font Studio"];XCTAssertTrue(studio.waitForExistence(timeout:10));studio.tap()
        let name=app.textFields["Name"];XCTAssertTrue(name.waitForExistence(timeout:10));name.tap();let projectName="Handwriting draft";name.typeText(projectName+"\n")
        app.buttons["Create project"].tap();let project=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label == %@","font.project.",projectName)).firstMatch;for _ in 0..<12 where !project.isHittable {app.swipeUp()};guard project.waitForExistence(timeout:10) else { XCTFail("Saved font project not reachable");return };XCTAssertTrue(project.isHittable);project.tap()
        guard app.staticTexts["Draw A"].waitForExistence(timeout:10) else { XCTFail("Glyph editor not opened");return }
        let canvas=app.descendants(matching:.any)["font.glyph.canvas"].firstMatch
        for _ in 0..<4 where !app.buttons["Save character"].isHittable { scrollMargin(app) }
        XCTAssertTrue(canvas.exists)
        let start=canvas.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.75)),top=canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.25)),end=canvas.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.75))
        start.press(forDuration:0.1,thenDragTo:top);top.press(forDuration:0.1,thenDragTo:end)
        capture(app,"Personal font glyph capture")
        app.buttons["Save character"].tap()
        for _ in 0..<3 where !app.staticTexts["Character saved locally"].exists { scrollMargin(app) }
        XCTAssertTrue(app.staticTexts["Character saved locally"].waitForExistence(timeout:10))
        app.buttons["Validate and publish version"].tap()
        let validation=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Missing or invalid characters:")).firstMatch
        XCTAssertTrue(validation.waitForExistence(timeout:10))
        for _ in 0..<4 where !validation.isHittable { scrollMargin(app) }
        capture(app,"Incomplete font validation")
    }
    @MainActor func testLargeTypeChooser() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","new","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.searchFields["Name, category or topic"].waitForExistence(timeout:15))
        let first=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","template.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:10));XCTAssertTrue(first.isHittable)
        XCTAssertFalse(first.label.isEmpty)
        capture(app,"Accessibility XXXL chooser")
        first.tap()
        let create=app.buttons["Use template"]
        for _ in 0..<8 where !create.isHittable {scrollMargin(app)}
        XCTAssertTrue(create.isHittable)
        capture(app,"Accessibility XXXL template detail action")
    }
    @MainActor func testSyntheticFontPublicationAndCancellation() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_FONT_FIXTURE":"1","MEETINGBOOK_FONT_BUILD_PAUSE":"1"]
        app.launch();showLibraryIfNeeded(app);XCTAssertTrue(app.buttons["Font Studio"].waitForExistence(timeout:15));app.buttons["Font Studio"].tap()
        let fixture=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","font.project.")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout:15));fixture.tap()
        let publish=app.buttons["Validate and publish version"]
        for _ in 0..<5 where !publish.isHittable { scrollMargin(app) }
        publish.tap();let cancel=app.buttons["Cancel build"];XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.tap()
        XCTAssertTrue(app.staticTexts["Published versions: 0"].waitForExistence(timeout:10));capture(app,"Synthetic full-glyph build cancelled")
        app.terminate();app.launchEnvironment["MEETINGBOOK_FONT_BUILD_PAUSE"]="0";app.launch();showLibraryIfNeeded(app)
        app.buttons["Font Studio"].tap();XCTAssertTrue(fixture.waitForExistence(timeout:10));fixture.tap()
        for _ in 0..<5 where !publish.isHittable { scrollMargin(app) }
        publish.tap()
        let published=app.staticTexts["Published locally. Existing notes keep their version."]
        XCTAssertTrue(published.waitForExistence(timeout:90));capture(app,"Synthetic full-glyph real TTF published")
        XCTAssertTrue(app.staticTexts["Published versions: 1"].exists)
    }
    @MainActor private func scrollMargin(_ app: XCUIApplication) { app.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.8)).press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.35))) }
    @MainActor private func capture(_ app: XCUIApplication,_ name:String) { let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment) }
}


extension NotebookFlowTests {
    @MainActor func testManyFontProjectsRemainReachableAfterScrollingAndRelaunch() {
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_FONT_PROJECT_COUNT":"20"];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.buttons["Font Studio"].waitForExistence(timeout:15));app.buttons["Font Studio"].tap()
        let project=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label == %@","font.project.","QA project 20")).firstMatch
        for _ in 0..<15 where !project.isHittable {app.swipeUp()}
        XCTAssertTrue(project.isHittable);project.tap()
        XCTAssertTrue(app.staticTexts["Draw A"].waitForExistence(timeout:10))
        capture(app,"Twentieth project reachable after actual scrolling")
        app.terminate();app.launch();showLibraryIfNeeded(app);app.buttons["Font Studio"].tap()
        for _ in 0..<15 where !project.isHittable {app.swipeUp()}
        XCTAssertTrue(project.isHittable);project.tap()
        XCTAssertTrue(app.staticTexts["Draw A"].waitForExistence(timeout:10))
    }
}

extension NotebookFlowTests {
    @MainActor private func photoFresh(_ app:XCUIApplication) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launch();showLibraryIfNeeded(app)
    }
    @MainActor private func photoEnterText(_ app:XCUIApplication,_ value:String) {
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout:10));app.textViews.firstMatch.typeText(value)
    }
    @MainActor private func photoDismissKeyboard(_ app:XCUIApplication) {
        let dismiss=app.buttons["editor.keyboard.dismiss"]
        if dismiss.isHittable {dismiss.tap()}
    }
    @MainActor private func photoPickerCancel(hideKeyboard:Bool) {
        let app=XCUIApplication();photoFresh(app);createNote(app,title:"Photo cancel "+UUID().uuidString);photoEnterText(app,"Picker cancellation Ω")
        if hideKeyboard {photoDismissKeyboard(app)}
        openEditorPageMenu(app);app.buttons["Import image"].tap()
        let cancel=app.buttons["Cancel"].firstMatch;XCTAssertTrue(cancel.waitForExistence(timeout:15));capture(app,"Native picker before cancellation");cancel.tap()
        XCTAssertEqual(app.textViews.firstMatch.value as? String,"Picker cancellation Ω")
    }
    @MainActor func testImagePickerWithoutKeyboardCancellation() {photoPickerCancel(hideKeyboard:true)}
    @MainActor func testImagePickerWithKeyboardCancellation() {photoPickerCancel(hideKeyboard:false)}
    @MainActor func testSeededPhotoImportAndReopen() throws {
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_SEEDED_PHOTO_FIXTURE"] == "1" else {throw XCTSkip("Requires synthetic app icon seeded in an isolated simulator Photos library")}
        let app=XCUIApplication();photoFresh(app);let title="Photo import "+UUID().uuidString;createNote(app,title:title);photoEnterText(app,"Image selection Ω")
        photoDismissKeyboard(app);openEditorPageMenu(app);app.buttons["Import image"].tap()
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.staticTexts["Loading…"])
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:45),.completed);capture(app,"Seeded native photo grid")
        app.buttons["Cancel"].tap();XCTAssertEqual(app.textViews.firstMatch.value as? String,"Image selection Ω")
        let closed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.navigationBars["Photos"])
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:15),.completed)
        if !app.buttons["editor.keyboard.pageMenu"].isHittable {app.textViews.firstMatch.tap()}
        openEditorPageMenu(app);app.buttons["Import image"].tap()
        let seeded=app.images.matching(identifier:"PXGGridLayout-Info").firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout:45));seeded.tap()
        let imported=app.images.matching(NSPredicate(format:"label == %@","Image")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout:30))
        openEditorPageMenu(app);app.buttons["Save locally"].tap()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout:30))
        app.terminate();app.launch();XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:20))
        XCTAssertTrue(imported.waitForExistence(timeout:20));selectEditorMode("Type",in:app)
        XCTAssertEqual(app.textViews.firstMatch.value as? String,"Image selection Ω");capture(app,"Image and exact text after relaunch")
        selectEditorMode("Select",in:app)
        let start=imported.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.3))
        start.press(forDuration:0.5,thenDragTo:start.withOffset(CGVector(dx:0,dy:220)))
        XCTAssertTrue(imported.frame.minY>300);capture(app,"Moved image exposes text")
    }
}
