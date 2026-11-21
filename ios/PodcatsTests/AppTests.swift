import XCTest
import AVFoundation
@testable import Podcats

/// Runs inside the app on the simulator of the build machine: the real voices, the real preparing, the real files.
/// What it makes is left in the app's Documents folder, and the build copies it out to be checked again elsewhere
/// (ffprobe, VLC, a speech recogniser).
@MainActor
final class AppTests: XCTestCase {
    private func wait(_ seconds: Double, _ what: String, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertTrue(done(), "timed out: \(what)")
    }

    func testPrepareTwoEpisodesAndSaveThem() async throws {
        let lib = Library.shared
        lib.remove(Set(lib.episodes.map { $0.id }))
        lib.settings.saveToFiles = true
        let t0 = Date()
        let duo = lib.add(title: "CI Two Voices", script: "ANA: Hello from the native Podcats app. This sentence is read by the first voice.\nBEN: And this one by the second. It cost $1,250,000 in 2024, which is 68.4% more.\nANA: That is where I'll leave it. Until next time, thanks for listening.", duo: true, host1: "Easton", host2: "Zoey", pause: 0.35)
        let solo = lib.add(title: "CI: One/Voice?", script: "It is early, and the street is still wet from the night. A bakery door opens before the light reaches the corner. Somebody is already waiting for the first bus.", duo: false, host1: "Hugh", host2: "Zoey", pause: 0.35)
        Preparer.shared.kick()
        await wait(600, "both episodes prepared") { lib.episode(duo.id)?.ready == true && lib.episode(solo.id)?.ready == true }
        let took = Date().timeIntervalSince(t0)

        var result: [String: Any] = ["seconds": took, "engine": String(describing: Preparer.shared.engine)]
        let voices = await Engine.shared.voices
        result["voices"] = voices
        XCTAssertTrue(Voices.all.allSatisfy { voices.contains($0) }, "the ten voices are in the model folder: \(voices)")

        for id in [duo.id, solo.id] {
            let ep = try XCTUnwrap(lib.episode(id))
            XCTAssertTrue(ep.ready, "\(ep.title): \(ep.failed ?? "not ready")")
            XCTAssertEqual(ep.segsDone, ep.segments().count)
            XCTAssertGreaterThan(ep.duration, 5)
            XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.pcm(id).path), "the working file is removed")
            let p = try AVAudioPlayer(contentsOf: Paths.m4a(id))
            XCTAssertEqual(p.duration, ep.duration, accuracy: 0.3)
            let name = try XCTUnwrap(ep.fileName, "saved to Files")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent(name).path))
            result[ep.title] = ["duration": ep.duration, "pieces": ep.segsDone, "file": name, "timesRealTime": ep.speed ?? 0]
        }
        XCTAssertEqual(lib.episode(duo.id)?.fileName, "CI Two Voices.m4a")
        XCTAssertEqual(lib.episode(solo.id)?.fileName, "CI One Voice.m4a")

        // a rename moves the copy in Files; a voice change makes the audio again
        lib.update(solo.id) { $0.title = "CI Renamed" }
        Preparer.shared.saveToFiles(solo.id)
        XCTAssertEqual(lib.episode(solo.id)?.fileName, "CI Renamed.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.documents.appendingPathComponent("CI One Voice.m4a").path))

        // playing: recorded, not asserted, because a build machine may have no sound output
        Player.shared.open(duo.id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        result["player"] = ["playing": Player.shared.isPlaying, "time": Player.shared.time, "duration": Player.shared.duration, "problem": Player.shared.problem ?? ""]
        XCTAssertEqual(Player.shared.duration, lib.episode(duo.id)?.duration ?? 0, accuracy: 0.3)
        Player.shared.seek(to: 3)
        Player.shared.pause()
        XCTAssertEqual(lib.episode(duo.id)?.position ?? 0, 3, accuracy: 0.5)
        result["session"] = Session.shared.describe

        if let url = await Report.build() {
            try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent("report.json"))
            try FileManager.default.copyItem(at: url, to: Paths.documents.appendingPathComponent("report.json"))
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Paths.documents.appendingPathComponent("ci-result.json"))
    }

    /// An episode cut off half way carries on from the piece it stopped at, and a leftover half piece is dropped.
    func testCarriesOnAfterBeingCutOff() async throws {
        let lib = Library.shared
        let script = "One. Two is a longer sentence than one was. Three is the third sentence of this script. Four comes after three. Five is the last one here."
        let ep = lib.add(title: "CI Resume", script: script, duo: false, host1: "Maeve", host2: "Zoey", pause: 0.3)
        Preparer.shared.kick()
        await wait(600, "resume episode prepared") { lib.episode(ep.id)?.ready == true }
        let whole = try XCTUnwrap(lib.episode(ep.id)).duration
        let segs = try XCTUnwrap(lib.episode(ep.id)).segments()
        XCTAssertGreaterThanOrEqual(segs.count, 3)

        // the same script again, pretending it stopped after two pieces with rubbish after them in the file
        let again = lib.add(title: "CI Resume 2", script: script, duo: false, host1: "Maeve", host2: "Zoey", pause: 0.3)
        var bytes = 0
        for s in segs.prefix(2) {
            let samples = try await Engine.shared.speak(s.text, voice: s.voice)
            bytes = try AudioFiles.append(samples, pause: s.pause, to: Paths.pcm(again.id), keep: bytes)
        }
        let fh = try FileHandle(forWritingTo: Paths.pcm(again.id))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(repeating: 0x55, count: 48_000))
        try fh.close()
        let kept = bytes
        lib.update(again.id) { $0.sig = ScriptParser.signature(segs); $0.segsTotal = segs.count; $0.segsDone = 2; $0.partBytes = kept }
        Preparer.shared.kick()
        await wait(600, "second resume episode prepared") { lib.episode(again.id)?.ready == true }
        let resumed = try XCTUnwrap(lib.episode(again.id)).duration
        // the voice does not say a sentence the same way twice, so lengths differ a little; a second of rubbish would not hide
        XCTAssertEqual(resumed, whole, accuracy: whole * 0.25, "resumed \(resumed) s against \(whole) s")
        lib.remove([ep.id, again.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.m4a(again.id).path))
    }

    /// Files handed over by the picker or by another app, and files put into the Files folder, become episodes.
    func testScriptsComeIn() async throws {
        let lib = Library.shared
        let fm = FileManager.default
        let before = Set(lib.episodes.map { $0.id })
        let tmp = fm.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("Picked A.txt"), b = tmp.appendingPathComponent("Picked B.md"), c = tmp.appendingPathComponent("empty.txt"), d = tmp.appendingPathComponent("No Extension")
        try Data("ANA: Hello.\nBEN: Hi there.".utf8).write(to: a)
        try "# Its Own Title\n\nOne voice reads this.".data(using: .utf16)!.write(to: b)
        try Data("---\n".utf8).write(to: c)
        try Data("A file with no extension still reads.".utf8).write(to: d)
        let r = Importer.add(files: [a, b, c, d])
        XCTAssertEqual(r.added, 3)
        XCTAssertEqual(r.problems.count, 1)
        let titles = Set(lib.episodes.filter { !before.contains($0.id) }.map { $0.title })
        XCTAssertEqual(titles, ["Picked A", "Its Own Title", "No Extension"])

        // the Files folder: scripts in it are added once and moved aside; audio files there are left alone
        try Data("Dropped into the folder. It is read aloud.".utf8).write(to: Paths.documents.appendingPathComponent("Dropped.txt"))
        try Data([0, 1, 2]).write(to: Paths.documents.appendingPathComponent("not a script.m4a"))
        let r2 = Importer.addFromFilesFolder()
        XCTAssertEqual(r2.added, 1)
        XCTAssertTrue(lib.episodes.contains { $0.title == "Dropped" })
        XCTAssertFalse(fm.fileExists(atPath: Paths.documents.appendingPathComponent("Dropped.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: Paths.documents.appendingPathComponent(Importer.addedFolder).appendingPathComponent("Dropped.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: Paths.documents.appendingPathComponent("not a script.m4a").path))
        XCTAssertEqual(Importer.addFromFilesFolder().added, 0, "not added a second time")

        let mine = Set(lib.episodes.filter { !before.contains($0.id) }.map { $0.id })
        for id in mine { Preparer.shared.invalidate(id) }
        lib.remove(mine)
        try? fm.removeItem(at: Paths.documents.appendingPathComponent("not a script.m4a"))
        try? fm.removeItem(at: Paths.documents.appendingPathComponent(Importer.addedFolder))
    }

    /// An update file: taken in, applied to what is voiced, refused when it is no good, fetched from the internet, removed.
    func testUpdates() async throws {
        let up = Updates.shared
        let lib = Library.shared
        up.remove()
        XCTAssertNil(up.pack)
        XCTAssertEqual(up.prepare("Under IFRS it was (500)."), "Under IFRS it was (500).")

        // the same script before and after an update, left in the Files folder to be listened to elsewhere
        let script = "Under IFRS and US GAAP, LIFO and FIFO differ. EBITDA rose, and A/R fell to ($3,400,000) in FY2024."
        let off = lib.add(title: "CI Update Off", script: script, duo: false, host1: "Easton", host2: "Zoey", pause: 0.35)
        Preparer.shared.kick()
        await wait(600, "episode without an update prepared") { lib.episode(off.id)?.ready == true }
        XCTAssertNil(lib.episode(off.id)?.update)

        func json(_ version: Int, js: String? = nil, extra: String = "") -> Data {
            let script = js.map { ",\"js\":\"\($0)\"" } ?? ""
            return Data("{\"app\":\"podcats-update\",\"format\":1,\"version\":\(version),\"notes\":\"n\",\"rules\":[{\"find\":\"\\\\bIFRS\\\\b\",\"replace\":\"I F R S\"}]\(script)\(extra)}".utf8)
        }
        let good = "function prepareText(t) { return t.replace(/\\\\((\\\\d+)\\\\)/g, 'minus $1'); }"
        try up.install(json(5, js: good, extra: ",\"moreVoices\":[\"Freya\"],\"flags\":{\"bitRate\":48000}"), from: "a test")
        XCTAssertEqual(up.pack?.version, 5)
        XCTAssertEqual(up.prepare("Under IFRS it was (500)."), "Under I F R S it was minus 500.")
        XCTAssertEqual(up.bitRate, 48000)
        XCTAssertEqual(Voices.more, ["Freya"])
        XCTAssertEqual(Voices.resolve("freya", host: 1), "Freya")

        // refused, and what was installed stays
        XCTAssertThrowsError(try up.install(Data("{}".utf8), from: "a test"))
        XCTAssertThrowsError(try up.install(json(6, js: "function prepareText(t) { return t.replace(/(/g, ''); }"), from: "a test"), "a script that does not parse")
        XCTAssertThrowsError(try up.install(json(6, js: "var x = 1;"), from: "a test"), "a script without the function")
        XCTAssertThrowsError(try up.install(json(6, js: "function prepareText(t) { return 5; }"), from: "a test"), "a script that returns no text")
        XCTAssertThrowsError(try up.install(json(6, extra: ",\"minBuild\":999999"), from: "a test"), "an update for a later app")
        XCTAssertEqual(up.pack?.version, 5)
        try up.install(json(4), from: "a test", onlyIfNewer: true)
        XCTAssertEqual(up.pack?.version, 5, "an older one does not replace a newer one when only looking for newer")

        // a script that passes its trial but fails later is switched off; the rules still apply
        try up.install(json(7, js: "function prepareText(t) { if (t.indexOf('boom') >= 0) { throw new Error('x'); } return t; }"), from: "a test")
        XCTAssertEqual(up.prepare("IFRS boom"), "I F R S boom")
        XCTAssertTrue(up.scriptOff)
        XCTAssertEqual(up.prepare("IFRS again"), "I F R S again")

        // a voice an update added really speaks
        try up.install(json(8, extra: ",\"moreVoices\":[\"Freya\"]"), from: "a test")
        let freya = try await Engine.shared.speak("A voice added by an update.", voice: "Freya")
        XCTAssertGreaterThan(freya.count, 12_000)

        // from the internet: the update file of this very commit
        up.remove()
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["UPDATE_URL"], "UPDATE_URL is passed to the tests")
        XCTAssertEqual(up.url?.absoluteString, address)
        let first = await up.check()
        XCTAssertEqual(first, .installed(1), "\(first)")
        XCTAssertEqual(up.pack?.version, 1)
        XCTAssertFalse(up.scriptOff)
        XCTAssertEqual(up.prepare("US GAAP: A/R was ($3,400,000) in FY2024."), "US gap: accounts receivable was minus $3,400,000 in fiscal year 2024.")
        let second = await up.check()
        XCTAssertEqual(second, .current(1), "\(second)")

        let on = lib.add(title: "CI Update On", script: script, duo: false, host1: "Easton", host2: "Zoey", pause: 0.35)
        Preparer.shared.kick()
        await wait(600, "episode with the update prepared") { lib.episode(on.id)?.ready == true }
        XCTAssertEqual(lib.episode(on.id)?.update, 1)

        // Prepare Again makes the audio afresh (the first version is kept under another name to be compared)
        try? FileManager.default.copyItem(at: Paths.m4a(off.id), to: Paths.documents.appendingPathComponent("CI Update Off (kept).m4a"))
        Preparer.shared.prepareAgain(off.id)
        XCTAssertEqual(lib.episode(off.id)?.ready, false)
        await wait(600, "prepared again") { lib.episode(off.id)?.ready == true }
        XCTAssertEqual(lib.episode(off.id)?.update, 1)
        lib.update(off.id) { $0.title = "CI Update Again" }
        Preparer.shared.saveToFiles(off.id)

        up.remove()
        XCTAssertEqual(up.prepare("IFRS"), "IFRS")
        XCTAssertEqual(Voices.more, [])
    }
}
