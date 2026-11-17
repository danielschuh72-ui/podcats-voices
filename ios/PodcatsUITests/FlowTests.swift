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
        if !one.waitForExistence(timeout: 20) { snap("02-picker-missing"); dump("picker"); XCTFail("the picker did not show the sample files") }
        snap("02-picker")
        one.tap()
        let two = anything("Ferry Two")
        if two.exists { two.tap() }
        snap("03-picked")
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() } else { dump("no-open-button") }

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
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "the player opened and is playing")
        snap("06-playing")
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
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
}
