import Foundation

/// The ten Natural voices, as the Phonon model bundle names them.
enum Voices {
    static let female = ["Zoey", "Harper", "Everly", "Juniper", "Maeve"]
    static let male = ["Easton", "Trevor", "Russell", "Micah", "Hugh"]
    static let all = female + male
    /// Further voices an update has added (see UpdatePack). They are in the model folder already.
    static var more: [String] = []
    static let host1 = "Easton"
    static let host2 = "Zoey"

    /// A voice id from the web app ("p_zoey") or a name ("Zoey") -> a name this app has; anything else -> the default for that host.
    static func resolve(_ any: String?, host: Int) -> String {
        let fallback = host == 2 ? host2 : host1
        guard var v = any, !v.isEmpty else { return fallback }
        if v.hasPrefix("p_") { v = String(v.dropFirst(2)) }
        if let hit = (all + more).first(where: { $0.lowercased() == v.lowercased() }) { return hit }
        return fallback
    }
}

struct Episode: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var script: String
    var duo: Bool = false
    var host1: String = Voices.host1
    var host2: String = Voices.host2
    var pause: Double = 0.35
    var createdAt: Date = Date()

    // listening
    var position: Double = 0
    var finished: Bool = false
    var lastPlayed: Date?

    // preparing: audio is appended to a .pcm file piece by piece, then encoded once into .m4a
    var sig: String = ""          // what the stored audio was made from
    var segsDone: Int = 0
    var segsTotal: Int = 0
    var partBytes: Int = 0        // bytes of the .pcm file that belong to finished pieces
    var ready: Bool = false
    var duration: Double = 0
    var tries: Int = 0
    var failed: String?
    var speed: Double?            // seconds of audio made per second, last time
    var fileName: String?         // its copy in the Files app, if any
    var update: Int?              // the update that was in use when it was prepared (nil: none)

    var progress: Double { return ready ? 1 : (segsTotal > 0 ? Double(segsDone) / Double(segsTotal) : 0) }

    func segments() -> [Segment] {
        return ScriptParser.segments(script: script, duo: duo, host1: host1, host2: host2, pause: pause)
    }

    static func newID() -> String {
        return String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UInt32.random(in: 0..<1_679_616), radix: 36)
    }

    /// Forget the audio: after the script or the voices changed.
    mutating func resetAudio() {
        sig = ""; segsDone = 0; segsTotal = 0; partBytes = 0; ready = false; duration = 0; tries = 0; failed = nil; speed = nil; update = nil
    }
}

struct AppSettings: Codable, Equatable {
    var duo: Bool = false
    var host1: String = Voices.host1
    var host2: String = Voices.host2
    var pause: Double = 0.35
    var rate: Double = 1
    var saveToFiles: Bool = true
    var autoUpdate: Bool?         // nil means yes: look for an update file about twice a day
}

enum FileNames {
    /// A title as a file name: no path or reserved characters, at most 80 characters.
    static func safe(_ title: String) -> String {
        var t = title.unicodeScalars.map { s -> String in
            if s.value < 32 || "/\\:*?\"<>|".unicodeScalars.contains(s) { return " " }
            return String(s)
        }.joined()
        t = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        while let f = t.first, f == " " || f == "." { t.removeFirst() }
        while let l = t.last, l == " " || l == "." { t.removeLast() }
        t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Episode" : t
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext` … : the first that `taken` does not hold (compared without case).
    static func unique(_ base: String, ext: String, taken: Set<String>) -> String {
        let low = Set(taken.map { $0.lowercased() })
        var name = "\(base).\(ext)"
        var n = 2
        while low.contains(name.lowercased()) { name = "\(base) \(n).\(ext)"; n += 1 }
        return name
    }
}

enum TimeText {
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func rough(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "under a minute" }
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}
