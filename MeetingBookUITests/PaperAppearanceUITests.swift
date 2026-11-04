import XCTest

final class PaperAppearanceUITests: XCTestCase {
    override func setUp() {super.setUp();continueAfterFailure=false}
    @MainActor private func capture(_ app: XCUIApplication,_ title: String) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name=title;image.lifetime = .keepAlways;add(image)
        let tree=XCTAttachment(string:"Window: \(app.windows.firstMatch.frame)\n"+app.debugDescription);tree.name=title+" hierarchy";tree.lifetime = .keepAlways;add(tree)
    }
    @MainActor func testPaperSurfacesInDarkSystemAppearance() {
        XCUIDevice.shared.orientation = .portrait
        for paper in ["classic","cream","rose"] {
            let app=XCUIApplication()
            app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last","-paper",paper,"-ruling","lined","-AppleInterfaceStyle","Dark"]
            app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_FONT_PROJECT_COUNT":"1"]
            app.launch();showLibraryIfNeeded(app)
            XCTAssertTrue(app.buttons["Font Studio"].waitForExistence(timeout:15));capture(app,paper+" library dark system")
            app.buttons["Font Studio"].tap()
            XCTAssertTrue(app.buttons["symbols.open"].waitForExistence(timeout:10));capture(app,paper+" font studio")
            app.buttons["QA project 1"].tap()
            XCTAssertTrue(app.descendants(matching:.any)["font.glyph.canvas"].waitForExistence(timeout:10));capture(app,paper+" font drawing board")
            app.buttons["Close project"].tap();app.buttons["symbols.open"].tap()
            XCTAssertTrue(app.buttons["symbols.item.pen"].waitForExistence(timeout:10));app.buttons["symbols.item.pen"].tap()
            XCTAssertTrue(app.descendants(matching:.any)["symbols.canvas"].waitForExistence(timeout:10));capture(app,paper+" symbol drawing board")
            app.buttons["symbols.done"].tap();app.buttons["Done"].tap()
            let field=app.textFields["Title"];XCTAssertTrue(field.waitForExistence(timeout:10));field.tap();field.typeText(paper+" paper note")
            app.buttons["New note"].tap()
            let search=app.searchFields["Name, category or topic"]
            if !search.waitForExistence(timeout:2),app.buttons["Search"].firstMatch.isHittable {app.buttons["Search"].firstMatch.tap()}
            XCTAssertTrue(search.waitForExistence(timeout:10));capture(app,paper+" template chooser")
            search.tap();search.typeText("Lined paper")
            let choice=app.buttons["template.meetingbook.lined"].firstMatch;XCTAssertTrue(choice.waitForExistence(timeout:5));choice.tap()
            let use=app.buttons["Use template"];XCTAssertTrue(use.waitForExistence(timeout:10))
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:use)],timeout:20),.completed)
            capture(app,paper+" template preview");use.tap()
            XCTAssertTrue(app.buttons["editor.mode"].waitForExistence(timeout:15))
            capture(app,paper+" book")
            selectEditorMode("Type",in:app)
            app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
            let text=app.textViews.firstMatch;XCTAssertTrue(text.waitForExistence(timeout:10));text.typeText("Paper e\u{301} 👩🏽‍💻")
            XCTAssertEqual(text.value as? String,"Paper e\u{301} 👩🏽‍💻");capture(app,paper+" keyboard")
            app.buttons["editor.keyboard.dismiss"].tap();showLibraryIfNeeded(app)
            app.buttons["Settings"].tap();XCTAssertTrue(app.staticTexts["New writing"].waitForExistence(timeout:10));capture(app,paper+" settings")
            app.terminate()
        }
    }
}
