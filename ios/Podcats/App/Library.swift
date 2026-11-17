import Foundation
import Combine

/// The episodes and the settings, kept in two small JSON files in Application Support.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var episodes: [Episode] = []
    @Published var settings = AppSettings() { didSet { if settings != oldValue { saveSettings() } } }

    private var pending: Task<Void, Never>?

    private init() {
        if let d = try? Data(contentsOf: Paths.library) {
            do { episodes = try JSONDecoder().decode([Episode].self, from: d) } catch {
                Log.shared.error("library unreadable", error)
                try? FileManager.default.copyItem(at: Paths.library, to: Paths.support.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            }
        }
        if let d = try? Data(contentsOf: Paths.settings), let s = try? JSONDecoder().decode(AppSettings.self, from: d) { settings = s }
    }

    func episode(_ id: String?) -> Episode? {
        guard let id = id else { return nil }
        return episodes.first { $0.id == id }
    }

    @discardableResult
    func add(title: String, script: String, duo: Bool? = nil, host1: String? = nil, host2: String? = nil, pause: Double? = nil) -> Episode {
        var e = Episode(id: Episode.newID(), title: title.isEmpty ? ScriptParser.title(script: script, fileName: nil) : title, script: script)
        e.duo = duo ?? settings.duo
        e.host1 = host1 ?? settings.host1
        e.host2 = host2 ?? settings.host2
        e.pause = pause ?? settings.pause
        episodes.insert(e, at: 0)
        Log.shared.add("added", "\(e.title) (\(ScriptParser.wordCount(script)) words)")
        scheduleSave()
        return e
    }

    /// Episodes from a backup of the web app: ones already here (same id) are left alone.
    func merge(_ incoming: [Episode]) -> Int {
        var n = 0
        for e in incoming where episode(e.id) == nil { episodes.append(e); n += 1 }
        if n > 0 { episodes.sort { $0.createdAt > $1.createdAt }; scheduleSave() }
        Log.shared.add("restored", "\(n) of \(incoming.count)")
        return n
    }

    func update(_ id: String, _ change: (inout Episode) -> Void) {
        guard let i = episodes.firstIndex(where: { $0.id == id }) else { return }
        var e = episodes[i]
        change(&e)
        if e != episodes[i] { episodes[i] = e; scheduleSave() }
    }

    func remove(_ ids: Set<String>) {
        for e in episodes where ids.contains(e.id) {
            try? FileManager.default.removeItem(at: Paths.pcm(e.id))
            try? FileManager.default.removeItem(at: Paths.m4a(e.id))
            if let f = e.fileName { try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(f)) }
        }
        episodes.removeAll { ids.contains($0.id) }
        Log.shared.add("removed", "\(ids.count)")
        scheduleSave()
    }

    /// The next episode that still needs its audio: oldest first, ones that keep failing last.
    func nextToPrepare() -> Episode? {
        return episodes.filter { !$0.ready && $0.tries < 3 }.sorted { ($0.tries, $0.createdAt) < ($1.tries, $1.createdAt) }.first
    }

    private func scheduleSave() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.write()
        }
    }

    func flush() {
        pending?.cancel()
        pending = nil
        write()
    }

    private func write() {
        do { try JSONEncoder().encode(episodes).write(to: Paths.library, options: .atomic) } catch { Log.shared.error("save library", error) }
    }

    private func saveSettings() {
        do { try JSONEncoder().encode(settings).write(to: Paths.settings, options: .atomic) } catch { Log.shared.error("save settings", error) }
    }
}
