import Foundation
import PhononTTS

/// Text to speech with Phonon 31m (Gradium, Apache 2.0) through its Core ML Swift package.
/// It runs on the CPU, not the Neural Engine: a little slower (about 10x real time against 12x on an iPhone 16 Pro by
/// Gradium's figures) but it is the path that can be relied on with the phone locked, and the same one the tests run.
actor Engine {
    static let shared = Engine()

    struct Failure: Error, CustomStringConvertible { let description: String }

    private var tts: Phonon?
    private var voice = ""
    private(set) var voices: [String] = []
    private(set) var loadSeconds: Double = 0
    private(set) var compiled = false
    private(set) var usedUnit = ""

    var isLoaded: Bool { return tts != nil }

    /// Whether the next load has to compile the models for this phone first (about 10 s, once after an install).
    nonisolated func needsCompiling() -> Bool {
        return !PhononModels.isInstalled() || Phonon.needsCompiling(PhononModels.defaultDirectory)
    }

    func load(unit: String = "cpu") async throws {
        if tts != nil { return }
        guard let bundled = Bundle.main.url(forResource: "Models", withExtension: nil) else {
            throw Failure(description: "The voices are missing from this copy of the app.")
        }
        let t0 = Date()
        compiled = needsCompiling()
        let dir = try PhononModels.install(bundled: bundled)
        var p: Phonon
        if unit == "neuralEngine" {
            do { p = try await Phonon.load(models: dir, language: .english, computeUnit: .neuralEngine); usedUnit = "neuralEngine" } catch {
                Log.shared.error("engine on the Neural Engine, falling back to the CPU", error)
                p = try await Phonon.load(models: dir, language: .english, computeUnit: .cpu); usedUnit = "cpu"
            }
        } else {
            p = try await Phonon.load(models: dir, language: .english, computeUnit: .cpu); usedUnit = "cpu"
        }
        tts = p
        voices = p.voices
        voice = p.voice
        loadSeconds = Date().timeIntervalSince(t0)
        Log.shared.add("engine", "ready in \(String(format: "%.1f", loadSeconds)) s" + (compiled ? " (compiled)" : "") + ", \(voices.count) voices, on \(usedUnit)")
    }

    /// One piece of text in one voice: mono Float32 samples at 24 kHz.
    func speak(_ text: String, voice want: String) async throws -> [Float] {
        if tts == nil { try await load() }
        guard let p = tts else { throw Failure(description: "The voices did not load.") }
        if want != voice {
            guard voices.contains(want) else { throw Failure(description: "This copy of the app has no voice named \(want).") }
            try await p.setVoice(want)
            voice = want
        }
        return try await p.synthesize(text)
    }

    func unload() { tts = nil; voice = "" }
}
