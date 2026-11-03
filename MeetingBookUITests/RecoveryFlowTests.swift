import XCTest

final class RecoveryFlowTests: XCTestCase {
    @MainActor func testSavedBackupShareCancellationReturnsToRecovery() {
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString];app.launch();showLibraryIfNeeded(app)
        let recovery=app.buttons["Export and recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout:15));recovery.tap()
        let backup=app.buttons["Back up saved library"]
        XCTAssertTrue(backup.waitForExistence(timeout:10));backup.tap()
        let close=app.buttons["header.closeButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout:20))
        let share=XCTAttachment(screenshot:app.screenshot());share.name="Native package share sheet, no recipient selected";share.lifetime = .keepAlways;add(share)
        close.tap()
        XCTAssertTrue(backup.waitForExistence(timeout:10));XCTAssertTrue(backup.isEnabled)
        let recoveryImage=XCTAttachment(screenshot:app.screenshot());recoveryImage.name="Recovery after share cancellation";recoveryImage.lifetime = .keepAlways;add(recoveryImage)
    }
}


extension RecoveryFlowTests {
    @MainActor func testDeterministicConflictPreviewAndBothChoice() {
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_SYNC_FIXTURE":"conflict"]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.buttons["sync.settings"].waitForExistence(timeout:10));app.buttons["sync.settings"].tap()
        let conflict=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","sync.conflict.")).firstMatch
        if !conflict.isHittable {app.swipeUp()}
        XCTAssertTrue(conflict.waitForExistence(timeout:10));conflict.tap()
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Deterministic page conflict with native previews";image.lifetime = .keepAlways;add(image)
        for _ in 0..<6 where !app.buttons["Keep both versions"].isHittable {app.swipeUp()}
        XCTAssertTrue(app.buttons["Keep both versions"].exists);XCTAssertTrue(app.buttons["Keep both versions"].isHittable)
        XCTAssertTrue(app.buttons["Keep version A"].exists);XCTAssertTrue(app.buttons["Keep version B"].exists)
        let choices=XCTAttachment(screenshot:app.screenshot());choices.name="Both conflict branches and explicit actions";choices.lifetime = .keepAlways;add(choices)
        app.buttons["Keep both versions"].tap()
        XCTAssertTrue(app.navigationBars["iCloud"].waitForExistence(timeout:10))
    }
    @MainActor func testGermanQuotaAtAccessibilitySize() {
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_SYNC_FIXTURE":"quota"]
        app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.buttons["sync.settings"].waitForExistence(timeout:10));app.buttons["sync.settings"].tap()
        XCTAssertTrue(app.staticTexts["iCloud-Speicher voll; lokales Arbeiten ist möglich"].waitForExistence(timeout:10))
        let image=XCTAttachment(screenshot:app.screenshot());image.name="German quota state at accessibility size";image.lifetime = .keepAlways;add(image)
    }
}

extension RecoveryFlowTests {
    @MainActor func testGermanConflictActions() {
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString,"MEETINGBOOK_SYNC_FIXTURE":"conflict"]
        app.launchArguments=["-AppleLanguages","(de)","-AppleLocale","de_DE","-startup","last"];app.launch();showLibraryIfNeeded(app)
        XCTAssertTrue(app.buttons["sync.settings"].waitForExistence(timeout:10));app.buttons["sync.settings"].tap()
        let conflict=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","sync.conflict.")).firstMatch
        if !conflict.isHittable {app.swipeUp()}
        XCTAssertTrue(conflict.waitForExistence(timeout:10));conflict.tap()
        for _ in 0..<6 where !app.buttons["Beide Fassungen behalten"].isHittable {app.swipeUp()}
        XCTAssertTrue(app.buttons["Beide Fassungen behalten"].exists);XCTAssertTrue(app.buttons["Beide Fassungen behalten"].isHittable)
        XCTAssertTrue(app.buttons["Fassung A behalten"].exists);XCTAssertTrue(app.buttons["Fassung B behalten"].exists)
        let actions=XCTAttachment(screenshot:app.screenshot());actions.name="German conflict actions after scrolling";actions.lifetime = .keepAlways;add(actions)
        app.buttons["Beide Fassungen behalten"].tap()
        XCTAssertTrue(app.navigationBars["iCloud"].waitForExistence(timeout:10))
    }
}


extension RecoveryFlowTests {
    @MainActor func testConfiguredInspectionRequiresExplicitConsent() {
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication();app.launchEnvironment=["MEETINGBOOK_TEST_LIBRARY":UUID().uuidString]
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-startup","last"]
        app.launch();showLibraryIfNeeded(app);XCTAssertTrue(app.buttons["sync.settings"].waitForExistence(timeout:10));app.buttons["sync.settings"].tap()
        XCTAssertTrue(app.staticTexts["On this device"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["Merge all local content"].exists)
        app.buttons["Inspect iCloud library"].tap()
        let settled=NSPredicate { _,_ in
            app.switches["sync.consent"].exists || app.staticTexts["Sign in to iCloud in Settings to use transfer. Local work remains available."].exists || app.staticTexts["iCloud access is restricted. Local work remains available."].exists || app.staticTexts["iCloud account availability could not be confirmed. Try again later."].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:settled,object:nil)],timeout:45),.completed,"Unsupported or unfinished inspection state: "+app.debugDescription)
        if app.switches["sync.consent"].exists {
            XCTAssertEqual(app.switches["sync.consent"].value as? String,"0")
            XCTAssertFalse(app.buttons["Merge all local content"].isEnabled)
            XCTAssertFalse(app.buttons["Keep libraries separate"].isEnabled)
        } else {XCTAssertFalse(app.buttons["Merge all local content"].exists)}
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Actual configured inspection result without consent";shot.lifetime = .keepAlways;add(shot)
        let tree=XCTAttachment(string:app.debugDescription);tree.name="Configured inspection hierarchy";tree.lifetime = .keepAlways;add(tree)
    }
}
