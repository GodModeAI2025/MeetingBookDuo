import XCTest
extension XCTestCase {
    @MainActor func openBookIfNeeded(_ app: XCUIApplication) {
        let open=app.buttons["cover.open"]
        if open.waitForExistence(timeout:3),open.isHittable {open.tap()}
    }
    @MainActor func showLibraryIfNeeded(_ app: XCUIApplication) {
        openBookIfNeeded(app)
        if app.launchArguments.contains("new") { return }
        if app.descendants(matching:.any)["notebook.index"].exists && app.descendants(matching:.any)["notebook.index"].isHittable {return}
        let index=app.buttons["notebook.showIndex"]
        if index.waitForExistence(timeout:3),index.isHittable {index.tap()}

    }

    @MainActor func openNotebookActions(_ app: XCUIApplication) {
        showLibraryIfNeeded(app)
        let button=app.buttons["notebook.actions"]
        XCTAssertTrue(button.waitForExistence(timeout:10));button.tap()
    }
    @MainActor func beginNamedNote(_ app: XCUIApplication,title:String) {
        showLibraryIfNeeded(app);app.buttons["New note"].tap()
        let field=app.textFields["Title"];XCTAssertTrue(field.waitForExistence(timeout:10));field.tap();field.typeText(title)
        app.alerts.buttons["Choose template"].tap()
    }
    @MainActor func openEditorPageMenu(_ app: XCUIApplication) {
        let keyboard=app.buttons["editor.keyboard.pageMenu"],normal=app.buttons["editor.pageMenu"]
        let menu=keyboard.exists && keyboard.isHittable ? keyboard : normal
        XCTAssertTrue(menu.waitForExistence(timeout:10));XCTAssertTrue(menu.isHittable);menu.tap()
    }
    @MainActor func selectEditorMode(_ title: String,in app: XCUIApplication) {
        let keyboard=app.buttons["editor.keyboard.mode"],normal=app.buttons["editor.mode"]
        let menu=keyboard.exists && keyboard.isHittable ? keyboard : normal
        XCTAssertTrue(menu.waitForExistence(timeout:10));XCTAssertTrue(menu.isHittable);menu.tap()
        let item=app.buttons[title];XCTAssertTrue(item.waitForExistence(timeout:5));item.tap()
    }
    @MainActor func createNote(_ app: XCUIApplication,title: String) {
        if app.buttons["BackButton"].waitForExistence(timeout:5) { app.buttons["BackButton"].tap() }
        showLibraryIfNeeded(app)
        beginNamedNote(app,title:title)
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
            showLibraryIfNeeded(app)
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
        app.terminate();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","bookmark"];app.launch();openBookIfNeeded(app)
        XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:15));showLibraryIfNeeded(app)
        let noteA=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label BEGINSWITH %@","notebook.hit.","Bookmark A,")).firstMatch
        XCTAssertTrue(noteA.waitForExistence(timeout:10));XCTAssertTrue(noteA.isSelected)
        capture(app,"Removed latest bookmark falls back to A after relaunch")
    }

    @MainActor func testReadSwipeAndIncompleteDrag() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        createNote(app,title:"Swipe source");createNote(app,title:"Swipe destination")
        selectEditorMode("Read",in:app)
        let paper=app.otherElements["notebook.paper"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout:10))
        let pager=app.descendants(matching:.any)["notebook.leafPager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout:10))
        let start=paper.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0.4)).withOffset(CGVector(dx:6,dy:0))
        start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:30,dy:0)))
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
        XCTAssertTrue(pager.waitForExistence(timeout:10))
        start.press(forDuration:0.05,thenDragTo:paper.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.4)))
        XCTAssertTrue(app.staticTexts["Page 1"].waitForExistence(timeout:10))
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
        openNotebookActions(app);let studio=app.buttons["Font Studio"];XCTAssertTrue(studio.waitForExistence(timeout:10));studio.tap()
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
        app.launch();showLibraryIfNeeded(app);openNotebookActions(app);XCTAssertTrue(app.buttons["Font Studio"].waitForExistence(timeout:15));app.buttons["Font Studio"].tap()
        let fixture=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","font.project.")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout:15));fixture.tap()
        let publish=app.buttons["Validate and publish version"]
        for _ in 0..<5 where !publish.isHittable { scrollMargin(app) }
        publish.tap();let cancel=app.buttons["Cancel build"];XCTAssertTrue(cancel.waitForExistence(timeout:5));cancel.tap()
        XCTAssertTrue(app.staticTexts["Published versions: 0"].waitForExistence(timeout:10));capture(app,"Synthetic full-glyph build cancelled")
        app.terminate();app.launchEnvironment["MEETINGBOOK_FONT_BUILD_PAUSE"]="0";app.launch();showLibraryIfNeeded(app)
        openNotebookActions(app);app.buttons["Font Studio"].tap();XCTAssertTrue(fixture.waitForExistence(timeout:10));fixture.tap()
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
        openNotebookActions(app);XCTAssertTrue(app.buttons["Font Studio"].waitForExistence(timeout:15));app.buttons["Font Studio"].tap()
        let project=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label == %@","font.project.","QA project 20")).firstMatch
        for _ in 0..<15 where !project.isHittable {app.swipeUp()}
        XCTAssertTrue(project.isHittable);project.tap()
        XCTAssertTrue(app.staticTexts["Draw A"].waitForExistence(timeout:10))
        capture(app,"Twentieth project reachable after actual scrolling")
        app.terminate();app.launch();showLibraryIfNeeded(app);openNotebookActions(app);app.buttons["Font Studio"].tap()
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
        app.terminate();app.launch();XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:20))
        XCTAssertTrue(imported.waitForExistence(timeout:20));selectEditorMode("Type",in:app)
        XCTAssertEqual(app.textViews.firstMatch.value as? String,"Image selection Ω");capture(app,"Image and exact text after relaunch")
        selectEditorMode("Select",in:app)
        let start=imported.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.3))
        start.press(forDuration:0.5,thenDragTo:start.withOffset(CGVector(dx:0,dy:220)))
        XCTAssertTrue(imported.frame.minY>300);capture(app,"Moved image exposes text")
    }
}


extension NotebookFlowTests {
    @MainActor func testPaperBookShellIndexAndCommands() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last","-paper","ivory"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_FONT_PROJECT_COUNT":"1"]
        app.launch();showLibraryIfNeeded(app)
        capture(app,"Book shell ivory empty index")
        createNote(app,title:"Ink e\u{301} 👩🏽‍💻")
        capture(app,"Book shell ivory active page portrait")
        selectEditorMode("Type",in:app)
        app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let text=app.textViews.firstMatch;XCTAssertTrue(text.waitForExistence(timeout:10));text.typeText("Exact e\u{301} 👩🏽‍💻")
        capture(app,"Book shell native keyboard")
        app.buttons["editor.keyboard.dismiss"].tap()
        app.buttons["notebook.showIndex"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["notebook.index"].waitForExistence(timeout:10))
        capture(app,"Book shell ivory selected index")
        app.buttons["notebook.closeIndex"].tap()
        XCTAssertEqual(text.value as? String,"Exact e\u{301} 👩🏽‍💻")
        app.buttons["editor.more"].tap()
        XCTAssertTrue(app.buttons["Choose template"].waitForExistence(timeout:5));app.buttons["Choose template"].tap()
        let insertSearch=app.searchFields["Name, category or topic"]
        XCTAssertTrue(insertSearch.waitForExistence(timeout:10));insertSearch.tap();insertSearch.typeText("Lined paper")
        app.buttons["template.meetingbook.lined"].firstMatch.tap()
        let insert=app.buttons["Use template"]
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:insert)],timeout:20),.completed)
        insert.tap()
        XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:10))
        app.buttons["editor.more"].tap();app.buttons["Customize"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout:10));capture(app,"Book shell customize reachable");app.buttons["Done"].tap()
        openEditorPageMenu(app);XCTAssertTrue(app.buttons["Copy page"].waitForExistence(timeout:5));capture(app,"Book shell page commands reachable")
        app.buttons["Save locally"].tap()
        openNotebookActions(app);app.buttons["Font Studio"].tap()
        XCTAssertTrue(app.buttons["symbols.open"].waitForExistence(timeout:10));app.buttons["Done"].tap()
        openNotebookActions(app);app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["New writing"].waitForExistence(timeout:10));app.buttons["Done"].tap()
        openNotebookActions(app);app.buttons["Export and recovery"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout:10));capture(app,"Book shell recovery reachable");app.buttons["Done"].tap()
        app.buttons["notebook.closeIndex"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height},object:nil)],timeout:10),.completed)
        capture(app,"Book shell active page landscape")
        app.buttons["notebook.showIndex"].tap();capture(app,"Book shell index landscape")
        app.buttons["notebook.closeIndex"].tap()
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        selectEditorMode("Read",in:app)
        let next=app.buttons["editor.next"]
        if !next.isHittable {app.buttons["editor.more"].tap()}
        app.buttons["Next page"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout:10))
        capture(app,"Book shell true page pair")
        app.terminate()
    }
}

extension NotebookFlowTests {
    @MainActor func testPaperIndexPaletteAndLargeType() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        defer {XCUIDevice.shared.orientation = .portrait}
        for paper in ["classic","cream","rose","ivory"] {
            let app=XCUIApplication(),libraryID=UUID().uuidString
            app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last","-paper",paper]
            app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":libraryID]
            app.launch();createNote(app,title:"Selected \(paper) e\u{301}")
            app.buttons["notebook.showIndex"].tap()
            let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","notebook.hit.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout:10));XCTAssertTrue(row.isSelected)
            capture(app,"Paper index selected ink \(paper)")
            if paper == "ivory" {
                createNote(app,title:"Second ivory note")
                app.buttons["notebook.showIndex"].tap()
                capture(app,"Ivory selected and unselected rows")
                app.terminate()
                app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
                app.launch();showLibraryIfNeeded(app)
                capture(app,"Ivory index accessibility XXXL")
                let close=app.buttons["notebook.closeIndex"]
                XCTAssertTrue(close.isHittable);close.tap()
                XCTAssertTrue(app.buttons["editor.more"].isHittable)
                capture(app,"Ivory page accessibility XXXL")
            }
            app.terminate()
        }
    }
}

extension NotebookFlowTests {
    @MainActor func testPaperIndexAndTruePairLayout() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        defer {XCUIDevice.shared.orientation = .portrait}
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last","-paper","ivory"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launch();showLibraryIfNeeded(app)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.buttons["New note"].isHittable && !app.buttons["cover.open"].exists},object:nil)],timeout:10),.completed)
        capture(app,"iPad actual open empty paper index")
        createNote(app,title:"Paper index and actual pair")
        app.buttons["notebook.showIndex"].tap()
        capture(app,"iPad index and live active page portrait")
        app.buttons["notebook.closeIndex"].tap()
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        openEditorPageMenu(app);app.buttons["Insert page"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height},object:nil)],timeout:10),.completed)
        let next=app.buttons["editor.next"]
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:next)],timeout:10),.completed)
        next.tap()
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Page 3"].waitForExistence(timeout:10))
        capture(app,"iPad actual numbered pages 2 and 3 landscape")
        app.buttons["notebook.showIndex"].tap()
        XCTAssertFalse(app.staticTexts["Page 3"].exists)
        capture(app,"iPad unnumbered index and active page 2 landscape")
        app.buttons["notebook.closeIndex"].tap()
        XCTAssertTrue(app.staticTexts["Page 3"].waitForExistence(timeout:10))
        app.terminate()
    }
}


extension NotebookFlowTests {
    @MainActor func testLargeTypeEdgeCommandsFitReservedMargin() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last","-paper","ivory"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launch();createNote(app,title:"Large type edge controls")
        app.terminate();app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();openBookIfNeeded(app)
        let more=app.buttons["editor.more"]
        XCTAssertTrue(more.waitForExistence(timeout:15));XCTAssertTrue(more.isHittable)
        for id in ["notebook.showIndex","editor.mode","editor.more"] {
            let frame=app.buttons[id].frame
            XCTAssertGreaterThanOrEqual(frame.width,44);XCTAssertLessThanOrEqual(frame.width,52)
            XCTAssertGreaterThanOrEqual(frame.height,44)
            XCTAssertLessThanOrEqual(frame.maxX,app.windows.firstMatch.frame.maxX)
        }
        XCTAssertFalse(app.buttons["editor.next"].exists)
        capture(app,"Ivory accessibility XXXL compact edge rail")
        more.tap();XCTAssertTrue(app.buttons["Next page"].waitForExistence(timeout:5))
        capture(app,"Ivory accessibility XXXL labelled overflow")
        app.terminate();XCUIDevice.shared.orientation = .landscapeLeft
        app.launch();openBookIfNeeded(app)
        XCTAssertTrue(more.waitForExistence(timeout:15))
        let window=app.windows.firstMatch
        let landscape=NSPredicate {_,_ in window.frame.width>window.frame.height}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landscape,object:nil)],timeout:10),.completed)
        for id in ["notebook.showIndex","editor.mode","editor.more"] {
            let button=app.buttons[id],frame=button.frame
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(frame.width,44);XCTAssertLessThanOrEqual(frame.width,52)
            XCTAssertGreaterThanOrEqual(frame.height,44)
            XCTAssertTrue(window.frame.contains(frame),"The short landscape window must contain \(id)")
            XCTAssertGreaterThanOrEqual(frame.minY,app.otherElements["notebook.paper"].firstMatch.frame.minY+80)
        }
        capture(app,"Ivory accessibility XXXL short landscape edge rail")
        Thread.sleep(forTimeInterval:3)
        app.terminate()
    }
}
