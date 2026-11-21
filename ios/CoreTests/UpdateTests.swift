import XCTest
@testable import PodcatsCore

final class UpdateTests: XCTestCase {
    private func pack(_ json: String) throws -> UpdatePack { return try UpdatePack.parse(Data(json.utf8)) }

    func testReadsAnUpdateAndIgnoresWhatItDoesNotKnow() throws {
        let p = try pack(#"{"app":"podcats-update","format":1,"version":7,"notes":"n","somethingNew":{"a":1},"rules":[{"find":"\\bIFRS\\b","replace":"I F R S"},{"find":"colou?r","replace":"hue","ignoreCase":true}],"flags":{"bitRate":48000,"later":true},"moreVoices":["Freya"]}"#)
        XCTAssertEqual(p.version, 7)
        XCTAssertEqual(p.flags?.bitRate, 48000)
        XCTAssertEqual(p.moreVoices ?? [], ["Freya"])
        let rules = try TextRules(p.rules ?? [])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.apply("Under IFRS 15 the COLOR is IFRSX."), "Under I F R S 15 the hue is IFRSX.")
        XCTAssertTrue(UpdatePack.looksLikeUpdate(Data(#"{"app":"podcats-update""#.utf8)))
        XCTAssertFalse(UpdatePack.looksLikeUpdate(Data(#"{"app":"podcats","episodes":[]}"#.utf8)))
    }

    func testRefusesWhatItCannotUse() {
        let bad = [
            "not json",
            #"{"app":"podcats","format":1,"version":1}"#,
            #"{"app":"podcats-update","format":2,"version":1}"#,
            #"{"app":"podcats-update","format":1,"version":0}"#,
            #"{"app":"podcats-update","format":1,"version":1,"rules":[{"find":"(unclosed","replace":"x"}]}"#,
            #"{"app":"podcats-update","format":1,"version":1,"rules":[{"find":"","replace":"x"}]}"#,
            #"{"app":"podcats-update","format":1,"version":1,"flags":{"computeUnit":"gpu"}}"#,
            #"{"app":"podcats-update","format":1,"version":1,"flags":{"bitRate":5}}"#,
            #"{"app":"podcats-update","format":1,"version":1,"moreVoices":[""]}"#,
        ]
        for b in bad { XCTAssertThrowsError(try pack(b), b) }
    }

    /// The update file kept in this repository (ios/update/podcats-update.json) is one the app will accept, and its
    /// rules do what its notes say. This is the check that runs before the file is published.
    func testThePublishedUpdate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("update/podcats-update.json")
        let p = try UpdatePack.parse(Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(p.version, 1)
        XCTAssertFalse((p.notes ?? "").isEmpty, "an update says what it changes")
        let rules = try TextRules(p.rules ?? [])
        let said = rules.apply("Under IFRS and US GAAP, LIFO and FIFO differ. EBITDA rose; A/R and A/P fell. SG&A, COGS, the 10-K and 10-Q for FY2024, up 5% YoY.")
        XCTAssertEqual(said, "Under I F R S and US gap, lie-foe and fie-foe differ. ee-bit-dah rose; accounts receivable and accounts payable fell. S G and A, cogs, the ten K and ten Q for fiscal year 2024, up 5% year over year.")
        // ordinary words are left alone
        let plain = "A gap in the fifo queue of Lifo Ltd, and a/r in lower case."
        XCTAssertEqual(rules.apply(plain), plain)
    }
}
