import XCTest
final class LaunchTests: XCTestCase {
    @MainActor func testLaunchCreateReopen() {
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"];app.launch();showLibraryIfNeeded(app)
        let title="Restart-"+UUID().uuidString
        createNote(app,title:title)
        selectEditorMode("Type",in:app);app.otherElements["Canonical page"].coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15)).tap()
        let editor=app.textViews.firstMatch;editor.typeText("Saved restart evidence")
        openEditorPageMenu(app);app.buttons["Save locally"].tap()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout:10))
        app.terminate();app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.buttons["editor.pageMenu"].waitForExistence(timeout:10))
        XCTAssertEqual(app.textViews.firstMatch.value as? String,"Saved restart evidence")
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Durable local save after restart";attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor func testGermanWelcomeAndCreateButton() {
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last"];app.launch();showLibraryIfNeeded(app)
        if app.buttons["BackButton"].waitForExistence(timeout:5) { app.buttons["BackButton"].tap() }
        XCTAssertTrue(app.buttons["Neue Notiz"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Privat. Auf deinem Gerät."].exists)
    }

}
