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
}
