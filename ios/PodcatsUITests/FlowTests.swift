import XCTest

/// Drives the app the way a person does, in the simulator: the real file picker, the real buttons.
/// Every step leaves a screenshot in the result, which the build publishes.
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name + ".txt"
        a.lifetime = .keepAlways
        add(a)
    }

    private func anything(_ text: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Add Files -> pick two files in the iOS picker -> Open -> two episodes, prepared, playable, shareable.
    func testPickFilesThenPlayAndShare() {
        app.launchArguments = ["-reset", "-pickerdir"]
        app.launch()
        XCTAssertTrue(app.staticTexts["No Episodes Yet"].waitForExistence(timeout: 20))
        snap("01-empty")
        app.buttons["Add Files"].firstMatch.tap()

        let one = anything("Ferry One")
        // the picker now and then opens one folder up from the one it was pointed at: step into it, as a person would
        let folder = anything("Picker Test")
        if !one.waitForExistence(timeout: 10), folder.waitForExistence(timeout: 5) { folder.tap() }
        if !one.waitForExistence(timeout: 20) { snap("02-picker-missing"); dump("picker"); XCTFail("the picker did not show the sample files") }
        snap("02-picker")
        one.tap()
        // the first tap puts the picker into selecting; its own Select All then takes the second file too
        let all = app.buttons["Select All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "the picker allows several files")
        all.tap()
        sleep(1)
        snap("03-picked")
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { sleep(1); open.tap() } else { dump("no-open-button") }
        // a tap made while the picker's bar is still changing can be swallowed by it: tap again if it is still there
        var again = 0
        while again < 3 && !app.buttons["Select"].firstMatch.waitForExistence(timeout: 6) && open.exists { open.tap(); again += 1 }
        if again > 0 { let note = XCTAttachment(string: "Open needed \(again) more tap(s)"); note.name = "open-retaps"; note.lifetime = .keepAlways; add(note) }

        // back in the Library (the picker is gone), with a row for each picked file
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: 20), "back in the Library")
        func row(_ title: String) -> XCUIElement { return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch }
        let row1 = row("Ferry One")
        if !row1.waitForExistence(timeout: 20) { snap("04-not-added"); dump("after-open"); XCTFail("the picked files did not become episodes") }
        if !row("Ferry Two").waitForExistence(timeout: 10) { snap("04-second-missing"); dump("after-open"); XCTFail("the second picked file did not become an episode") }
        snap("04-added")

        // both prepared without being asked
        let ready = NSPredicate(format: "label CONTAINS[c] 'under a minute'")
        let both = expectation(for: NSPredicate(block: { _, _ in self.app.staticTexts.matching(ready).count >= 2 }), evaluatedWith: nil)
        wait(for: [both], timeout: 300)
        snap("05-prepared")

        // play
        row1.tap()
        // the big button of the player sheet (the small one of the bar underneath has the same name)
        let pause = app.buttons["pause.circle.fill"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "the player opened and is playing")
        snap("06-playing")
        pause.tap()
        XCTAssertTrue(app.buttons["play.circle.fill"].firstMatch.waitForExistence(timeout: 5), "pausing shows the play button")
        app.buttons["goforward.30"].firstMatch.tap()
        snap("06b-paused")
        app.buttons["Done"].firstMatch.tap()

        // select both, share
        app.buttons["Select"].firstMatch.tap()
        app.buttons["Select All"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 5))
        snap("07-selected")
        app.buttons["Share"].firstMatch.tap()
        let sheet = app.otherElements["ActivityListView"].firstMatch
        let saveToFiles = anything("Save to Files")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || saveToFiles.waitForExistence(timeout: 5), "the share sheet came up")
        snap("08-share-sheet")
    }

    /// A text file put into the app's folder in the Files app is added when the app comes to the front.
    func testFileDroppedIntoTheFolder() {
        app.launchArguments = ["-reset", "-dropfile"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dropped In"].waitForExistence(timeout: 30))
        snap("10-dropped-in")
    }

    /// Paste or Type a Script -> type -> Add -> an episode.
    func testTypeAScript() {
        app.launchArguments = ["-reset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["No Episodes Yet"].waitForExistence(timeout: 20))
        app.buttons["Paste or Type a Script"].firstMatch.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Typed Here")
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText("This script was typed in. It has two sentences.")
        snap("20-typed")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Typed Here"].waitForExistence(timeout: 15))
        let ready = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'under a minute'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 200), "the typed episode was prepared")
        snap("21-typed-prepared")
        // title and voices
        app.staticTexts["Typed Here"].press(forDuration: 1.2)
        let edit = app.buttons["Title and Voices"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Episode"].waitForExistence(timeout: 10))
        snap("22-options")
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// An update file put into the app's folder is installed; Settings shows it and can remove it.
    func testUpdateFileDroppedIn() {
        app.launchArguments = ["-reset", "-dropupdate"]
        app.launch()
        let told = app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Update 99 installed'")).firstMatch
        XCTAssertTrue(told.waitForExistence(timeout: 30), "the app says the update was installed")
        snap("30-update-installed")
        app.alerts.buttons["OK"].firstMatch.tap()
        app.buttons["Settings"].firstMatch.tap()
        let installed = anything("Installed, Update 99")
        var swipes = 0
        while !installed.exists && swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(installed.waitForExistence(timeout: 5), "Settings shows the installed update")
        snap("31-settings-update")
        let remove = app.buttons["Remove Update"].firstMatch
        if !remove.isHittable { app.swipeUp() }
        remove.tap()
        XCTAssertTrue(anything("Installed, None installed").waitForExistence(timeout: 5), "removed")
        snap("32-update-removed")
    }

    /// Settings > Check for Updates fetches the update file from the internet and installs it.
    func testCheckForUpdates() throws {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["UPDATE_URL"], "UPDATE_URL is passed to the tests")
        app.launchArguments = ["-reset", "-updateurl", address]
        app.launch()
        XCTAssertTrue(app.staticTexts["No Episodes Yet"].waitForExistence(timeout: 20))
        app.buttons["Settings"].firstMatch.tap()
        let check = app.buttons["Check for Updates"].firstMatch
        var swipes = 0
        while !(check.exists && check.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(anything("Installed, None installed").exists, "nothing installed to begin with")
        check.tap()
        XCTAssertTrue(anything("Update 1 installed").waitForExistence(timeout: 40), "the update came down and was installed, and the screen says so")
        snap("40-update-downloaded")
        XCTAssertTrue(anything("Installed, Update 1").waitForExistence(timeout: 5), "Settings shows the downloaded update")
        check.tap()
        XCTAssertTrue(anything("Update 1 is the newest").waitForExistence(timeout: 40), "a second check finds nothing newer")
        snap("41-settings-after-update")
    }
}
