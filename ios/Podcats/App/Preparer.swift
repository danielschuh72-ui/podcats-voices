import Foundation
import Combine

/// Voices every episode in the Library that has no audio yet, one after another, without being asked, and keeps
/// going with the app in the background or the phone locked (see Session).
@MainActor
final class Preparer: ObservableObject {
    static let shared = Preparer()

    enum EngineState: Equatable { case idle, loading(firstTime: Bool), ready, failed(String) }

    @Published private(set) var engine: EngineState = .idle
    @Published private(set) var currentID: String?

    private var task: Task<Void, Never>?
    private var cancelled = Set<String>()
    private let library = Library.shared

    private init() {}

    /// Start, or carry on. Safe to call at any time: at launch, after adding or changing an episode.
    func kick() {
        if task != nil { return }
        guard library.nextToPrepare() != nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
            self?.currentID = nil
            Session.shared.setPreparing(false)
            // something may have been added in the last moment
            if self?.library.nextToPrepare() != nil { self?.kick() }
        }
    }

    /// The audio of this episode is no longer wanted as it is (deleted, or its script or voices changed).
    func invalidate(_ id: String) {
        if currentID == id { cancelled.insert(id) }
    }

    /// Give episodes that failed three times another go.
    func retry(_ id: String) {
        library.update(id) { $0.tries = 0; $0.failed = nil }
        kick()
    }

    private func run() async {
        Session.shared.setPreparing(true)
        if engine != .ready {
            engine = .loading(firstTime: Engine.shared.needsCompiling())
            do { try await Engine.shared.load(); engine = .ready } catch {
                engine = .failed(Log.text(error))
                Log.shared.error("engine", error)
                return
            }
        }
        while let next = library.nextToPrepare() {
            if Task.isCancelled { return }
            await prepare(next.id)
        }
    }

    private func prepare(_ id: String) async {
        guard var ep = library.episode(id) else { return }
        let segs = ep.segments()
        let sig = ScriptParser.signature(segs)
        if segs.isEmpty {
            library.update(id) { $0.failed = "There is nothing to read in this script."; $0.tries = 3 }
            return
        }
        if ep.sig != sig || ep.segsDone > segs.count {
            try? FileManager.default.removeItem(at: Paths.pcm(id))
            try? FileManager.default.removeItem(at: Paths.m4a(id))
            library.update(id) { $0.resetAudio(); $0.sig = sig; $0.segsTotal = segs.count }
        } else if ep.segsTotal != segs.count {
            library.update(id) { $0.segsTotal = segs.count }
        }
        guard let fresh = library.episode(id) else { return }
        ep = fresh
        currentID = id
        cancelled.remove(id)
        Log.shared.add("prepare", "start \(ep.title): piece \(ep.segsDone + 1) of \(segs.count)")
        let t0 = Date()
        var made = 0.0
        var bytes = ep.partBytes
        do {
            var i = ep.segsDone
            while i < segs.count {
                if Task.isCancelled || cancelled.contains(id) || library.episode(id) == nil { cancelled.remove(id); Log.shared.add("prepare", "stopped \(ep.title)"); return }
                let s = segs[i]
                let samples = try await Engine.shared.speak(s.text, voice: s.voice)
                if cancelled.contains(id) || library.episode(id) == nil { cancelled.remove(id); Log.shared.add("prepare", "stopped \(ep.title)"); return }
                bytes = try AudioFiles.append(samples, pause: s.pause, to: Paths.pcm(id), keep: bytes)
                made += Double(samples.count) / AudioFiles.rate
                i += 1
                let done = i, size = bytes
                library.update(id) { $0.segsDone = done; $0.partBytes = size }
                if done % 25 == 0 { Log.shared.add("prepare", "\(ep.title): \(done) of \(segs.count)") }
            }
            let pcm = Paths.pcm(id), out = Paths.m4a(id)
            let seconds = try await Task.detached(priority: .userInitiated) { try AudioFiles.encode(pcm: pcm, to: out) }.value
            await AudioFiles.tag(out, title: ep.title)
            try? FileManager.default.removeItem(at: pcm)
            let took = Date().timeIntervalSince(t0)
            let speed = took > 0 ? made / took : 0
            library.update(id) { $0.ready = true; $0.duration = seconds; $0.partBytes = 0; $0.failed = nil; $0.tries = 0; if made > 5 { $0.speed = speed } }
            Log.shared.add("prepare", "done \(ep.title): \(Int(seconds)) s of audio; this run made \(Int(made)) s in \(String(format: "%.1f", took)) s")
            saveToFiles(id)
        } catch {
            let text = Log.text(error)
            Log.shared.add("error", "prepare \(ep.title) (try \(ep.tries + 1)): \(text)")
            library.update(id) { $0.tries += 1; $0.failed = text }
            // start the engine afresh next time: whatever went wrong may have been in it
            await Engine.shared.unload()
            engine = .idle
            do { try await Engine.shared.load(); engine = .ready } catch { engine = .failed(Log.text(error)) }
        }
    }

    /// Put (or refresh) the copy in the Files app, if that is switched on.
    func saveToFiles(_ id: String) {
        guard library.settings.saveToFiles, let ep = library.episode(id), ep.ready else { return }
        do {
            let name = try AudioFiles.saveToFiles(id: id, title: ep.title, previous: ep.fileName)
            library.update(id) { $0.fileName = name }
            Log.shared.add("files", "saved \(name)")
        } catch { Log.shared.error("save to Files", error) }
    }

    /// The switch in Settings was turned on or off.
    func saveToFilesChanged() {
        for ep in library.episodes where ep.ready {
            if library.settings.saveToFiles {
                if ep.fileName == nil { saveToFiles(ep.id) }
            } else if let f = ep.fileName {
                try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(f))
                library.update(ep.id) { $0.fileName = nil }
            }
        }
    }
}
