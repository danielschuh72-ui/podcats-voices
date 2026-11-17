import Foundation
import UIKit

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Podcats", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let audio: URL = {
        let d = support.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// Shown in the Files app as "On My iPhone > Podcats".
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let library = support.appendingPathComponent("library.json")
    static let settings = support.appendingPathComponent("settings.json")
    static let log = support.appendingPathComponent("log.jsonl")
    static func pcm(_ id: String) -> URL { return audio.appendingPathComponent(id + ".pcm") }
    static func m4a(_ id: String) -> URL { return audio.appendingPathComponent(id + ".m4a") }
}

/// A timeline of what the app did, kept across launches, for Settings > Share Diagnostic Report.
/// Every entry says whether the app was in front and whether the phone was locked at that moment.
final class Log {
    static let shared = Log()

    struct Entry: Codable {
        var t: String
        var ev: String
        var d: String?
        var app: String   // front, inactive, back
        var locked: Bool?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var phase = "front"
    private var locked = false
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let io = DispatchQueue(label: "podcats.log")
    private let keep = 1200

    private init() {
        if let text = try? String(contentsOf: Paths.log, encoding: .utf8) {
            let dec = JSONDecoder()
            let lines = text.split(separator: "\n").suffix(keep)
            entries = lines.compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
            if text.utf8.count > 600_000 { rewrite() }
        }
    }

    func setPhase(_ p: String) { lock.lock(); phase = p; lock.unlock() }
    func setLocked(_ l: Bool) { lock.lock(); locked = l; lock.unlock() }
    var isLocked: Bool { lock.lock(); defer { lock.unlock() }; return locked }
    var currentPhase: String { lock.lock(); defer { lock.unlock() }; return phase }

    func add(_ ev: String, _ detail: String? = nil) {
        lock.lock()
        let e = Entry(t: stamp.string(from: Date()), ev: ev, d: detail.map { String($0.prefix(400)) }, app: phase, locked: locked ? true : nil)
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        lock.unlock()
        io.async {
            guard let data = try? JSONEncoder().encode(e) else { return }
            var line = data
            line.append(0x0A)
            if let fh = try? FileHandle(forWritingTo: Paths.log) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: line)
            } else {
                try? line.write(to: Paths.log)
            }
        }
    }

    func error(_ what: String, _ err: Error) { add("error", what + ": " + Log.text(err)) }

    static func text(_ err: Error) -> String {
        if type(of: err) is NSError.Type || err is CocoaError {
            let n = err as NSError
            return "\(n.domain) \(n.code): \(n.localizedDescription)"
        }
        if let s = err as? CustomStringConvertible { return s.description }
        return "\(type(of: err)): \(err.localizedDescription)"
    }

    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    var recentErrors: [Entry] { return all.filter { $0.ev == "error" }.suffix(12).map { $0 } }

    private func rewrite() {
        let snapshot = entries
        io.async {
            let enc = JSONEncoder()
            var out = Data()
            for e in snapshot { if let d = try? enc.encode(e) { out.append(d); out.append(0x0A) } }
            try? out.write(to: Paths.log, options: .atomic)
        }
    }
}
