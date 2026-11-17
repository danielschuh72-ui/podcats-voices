import XCTest
@testable import PodcatsCore

final class ParserTests: XCTestCase {
    struct Case: Decodable {
        let name: String, duo: Bool, pause: Double, script: String
        let lines: [[String?]]
        let segs: [[Value]]
    }
    enum Value: Decodable, Equatable {
        case n(Double), s(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let x = try? c.decode(Double.self) { self = .n(x) } else { self = .s(try c.decode(String.self)) }
        }
    }

    /// Every sample script comes out in the same pieces, voices and pauses as the web app made of it.
    func testSameAsWebApp() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "parser", withExtension: "json", subdirectory: "fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 20)
        var segments = 0
        for c in cases {
            let lines = ScriptParser.parse(c.script)
            XCTAssertEqual(lines.map { [$0.speaker, $0.text] }, c.lines, "lines of \(c.name)")
            let got = ScriptParser.segments(script: c.script, duo: c.duo, host1: "A", host2: "B", pause: c.pause)
            let want = c.segs.map { v -> Segment in
                guard case .n(let line) = v[0], case .s(let text) = v[1], case .s(let voice) = v[2], case .n(let pause) = v[3] else { fatalError() }
                return Segment(line: Int(line), text: text, voice: voice, pause: pause)
            }
            XCTAssertEqual(got.count, want.count, "piece count of \(c.name) duo=\(c.duo)")
            for (g, w) in zip(got, want) where g != w { XCTFail("\(c.name) duo=\(c.duo): got \(g) want \(w)"); break }
            segments += got.count
        }
        XCTAssertGreaterThan(segments, 3000)
    }

    func testSignatureFollowsTheAudio() {
        let a = ScriptParser.segments(script: "ANA: Hello there. BEN: no", duo: true, host1: "Easton", host2: "Zoey", pause: 0.35)
        let b = ScriptParser.segments(script: "ANA: Hello there. BEN: no", duo: true, host1: "Hugh", host2: "Zoey", pause: 0.35)
        XCTAssertEqual(ScriptParser.signature(a), ScriptParser.signature(a))
        XCTAssertNotEqual(ScriptParser.signature(a), ScriptParser.signature(b))
    }

    func testTitles() {
        XCTAssertEqual(ScriptParser.title(script: "\n## My Show ##\nANA: hi", fileName: "x.txt"), "My Show")
        XCTAssertEqual(ScriptParser.title(script: "ANA: hi", fileName: "Part 3 - A Short Walk - Ana.txt"), "Part 3 - A Short Walk - Ana")
        XCTAssertEqual(ScriptParser.title(script: "Just some words to read aloud.", fileName: nil), "Just some words to read aloud.")
    }

    func testFileNames() {
        XCTAssertEqual(FileNames.safe("  a/b:c*  d?.  "), "a b c d")
        XCTAssertEqual(FileNames.safe("..."), "Episode")
        XCTAssertEqual(FileNames.unique("Show", ext: "m4a", taken: ["show.m4a", "Show 2.m4a"]), "Show 3.m4a")
        XCTAssertEqual(TimeText.clock(3725), "1:02:05")
        XCTAssertEqual(TimeText.clock(65), "1:05")
    }

    func testVoices() {
        XCTAssertEqual(Voices.resolve("p_hugh", host: 1), "Hugh")
        XCTAssertEqual(Voices.resolve("k_bella", host: 2), "Zoey")
        XCTAssertEqual(Voices.resolve(nil, host: 1), "Easton")
        XCTAssertEqual(Voices.all.count, 10)
    }

    /// A backup from the web app: zip with stored entries, and the bare json.
    func testBackup() throws {
        let json = #"{"app":"podcats","v":1,"made":1,"settings":{},"episodes":[{"id":"abc","title":"One","script":"ANA: Hello.","format":"duo","host1":"p_micah","host2":"k_bella","pause":0.2,"createdAt":1794805946246,"pos":12.5,"finished":true,"lens":[1,2]},{"id":"e","title":"","script":""}]}"#
        let data = Data(json.utf8)
        let eps = try Backup.episodes(fromJSON: data)
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].id, "abc"); XCTAssertEqual(eps[0].host1, "Micah"); XCTAssertEqual(eps[0].host2, "Zoey")
        XCTAssertTrue(eps[0].duo); XCTAssertEqual(eps[0].pause, 0.2); XCTAssertEqual(eps[0].position, 12.5); XCTAssertTrue(eps[0].finished)
        XCTAssertFalse(eps[0].ready)

        // a stored zip: another file first, then backup.json
        func put(_ out: inout [UInt8], _ fields: [(Int, Int)]) { for (v, n) in fields { for k in 0..<n { out.append(UInt8((v >> (8 * k)) & 255)) } } }
        var zip = [UInt8](), central = [UInt8](), count = 0
        let entries: [(String, Data)] = [("audio/abc.pcm", Data(repeating: 7, count: 1000)), ("backup.json", data)]
        for (name, body) in entries {
            let at = zip.count
            let n = Array(name.utf8)
            put(&zip, [(0x04034b50, 4), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (body.count, 4), (body.count, 4), (n.count, 2), (0, 2)])
            zip.append(contentsOf: n)
            zip.append(contentsOf: body)
            put(&central, [(0x02014b50, 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (body.count, 4), (body.count, 4), (n.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (at, 4)])
            central.append(contentsOf: n)
            count += 1
        }
        let cdAt = zip.count
        zip.append(contentsOf: central)
        put(&zip, [(0x06054b50, 4), (0, 2), (0, 2), (count, 2), (count, 2), (central.count, 4), (cdAt, 4), (0, 2)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).zip")
        try Data(zip).write(to: url)
        let fromZip = try Backup.episodes(fromFile: url)
        XCTAssertEqual(fromZip, eps.map { var e = $0; e.createdAt = fromZip[0].createdAt; return e })
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).json")
        try data.write(to: bare)
        XCTAssertEqual(try Backup.episodes(fromFile: bare).count, 1)
        XCTAssertThrowsError(try Backup.episodes(fromJSON: Data("{}".utf8)))
    }
}
