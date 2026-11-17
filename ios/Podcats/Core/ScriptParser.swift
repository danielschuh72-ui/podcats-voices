import Foundation

// Turns a script into the sentence-sized pieces that are voiced one by one.
// A port of parseScript / splitSentences / splitLong / buildSegments from the web app (app/page.html), kept
// unit for unit the same (it works on UTF-16 units, as JavaScript strings do). CoreTests compares the two.

struct ScriptLine: Equatable {
    var speaker: String?
    var text: String
}

struct Segment: Equatable {
    var line: Int
    var text: String
    var voice: String
    var pause: Double
}

enum ScriptParser {
    // JavaScript's \s, spelled out: ICU's own \s leaves out \v and U+FEFF.
    private static let S = "[\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
    private static let NS = "[^\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: p.replacingOccurrences(of: "\\s", with: S).replacingOccurrences(of: "\\S", with: NS), options: o)
    }

    private static let speakerRE = rx("^\\s*(?:[-*•>]\\s+)?[*_]*\\s*([A-Za-z][A-Za-z0-9.'_-]*(?: [A-Za-z0-9.'_-]+){0,2})\\s*(?:\\([^)]{0,40}\\))?\\s*[*_]*\\s*:\\s*[*_]*\\s*(.*)$")
    private static let notSpeakers = rx("^(https?|note|notes|sources?|tip|warning|step [0-9]+|chapter [0-9]+|part [0-9]+)$", [.caseInsensitive])
    private static let headingRE = rx("^\\s*#")
    private static let ruleRE = rx("^\\s*[-=_*~]{3,}\\s*$")
    private static let urlRE = rx("https?://\\S+")
    private static let mdLinkRE = rx("\\[([^\\]]*)\\]\\([^)]*\\)")
    private static let markupRE = rx("[*_`#~]+")
    private static let bracketRE = rx("\\[[^\\]]*\\]")
    private static let emojiRE = rx("[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}\\x{FE0F}]")
    private static let spacesRE = rx("\\s+")
    private static let speakableRE = rx("[A-Za-z0-9\\x{C0}-\\x{24F}]")
    private static let abbrRE = rx("(?:^|\\s)(Mr|Mrs|Ms|Dr|St|Jr|Sr|vs|etc|e\\.g|i\\.e|No|Vol|approx)$", [.caseInsensitive])
    private static let pieceRE = rx("[^,;:—]+[,;:—]*\\s*")

    // ---- UTF-16 helpers ----
    private static func len(_ s: String) -> Int { return s.utf16.count }
    private static func full(_ s: String) -> NSRange { return NSRange(location: 0, length: s.utf16.count) }
    private static func test(_ r: NSRegularExpression, _ s: String) -> Bool { return r.firstMatch(in: s, options: [], range: full(s)) != nil }
    private static func replace(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        return r.stringByReplacingMatches(in: s, options: [], range: full(s), withTemplate: with)
    }
    private static func isSpace(_ c: UInt16) -> Bool {
        switch c {
        case 9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return c >= 0x2000 && c <= 0x200A
        }
    }
    private static func str<C: Collection>(_ u: C) -> String where C.Element == UInt16 { return String(decoding: u, as: UTF16.self) }
    static func trim(_ s: String) -> String {
        let u = Array(s.utf16)
        var a = 0, b = u.count
        while a < b && isSpace(u[a]) { a += 1 }
        while b > a && isSpace(u[b - 1]) { b -= 1 }
        return a == 0 && b == u.count ? s : str(u[a..<b])
    }

    static func cleanForSpeech(_ s: String) -> String {
        var t = replace(urlRE, s, "link")
        t = replace(mdLinkRE, t, "$1")
        t = replace(markupRE, t, "")
        t = replace(bracketRE, t, "")
        t = replace(emojiRE, t, "")
        t = replace(spacesRE, t, " ")
        return trim(t)
    }

    static func parse(_ text: String) -> [ScriptLine] {
        var lines: [ScriptLine] = []
        var seen: [String: String] = [:]
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if test(headingRE, raw) || test(ruleRE, raw) { continue }
            var speaker: String?
            var body = raw
            if let m = speakerRE.firstMatch(in: raw, options: [], range: full(raw)) {
                let ns = NSString(string: raw)
                let name = trim(ns.substring(with: m.range(at: 1)))
                let rest = ns.substring(with: m.range(at: 2))
                if !trim(rest).isEmpty && !test(notSpeakers, name) { speaker = name; body = rest }
            }
            body = cleanForSpeech(body)
            if body.isEmpty || !test(speakableRE, body) { continue }
            var shown: String?
            if let sp = speaker {
                let key = sp.lowercased()
                if seen[key] == nil { seen[key] = sp == key ? sp.prefix(1).uppercased() + sp.dropFirst() : sp }
                shown = seen[key]
            }
            lines.append(ScriptLine(speaker: shown, text: body))
        }
        return lines
    }

    static func speakers(of lines: [ScriptLine]) -> [String] {
        var s: [String] = []
        for l in lines { if let sp = l.speaker, !s.contains(sp) { s.append(sp) } }
        return s
    }

    static func splitSentences(_ t: String) -> [String] {
        let u = Array(t.utf16)
        var out: [String] = []
        var start = 0, i = 0
        let P = Set(".!?…".utf16), close = Set(".!?…\"'”’)]".utf16)
        func opens(_ c: UInt16) -> Bool { // ["'“‘(\[A-Z0-9À-Þ]
            return c == 34 || c == 39 || c == 0x201C || c == 0x2018 || c == 40 || c == 91 || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || (c >= 0xC0 && c <= 0xDE)
        }
        while i < u.count {
            if P.contains(u[i]) {
                var j = i + 1
                while j < u.count && close.contains(u[j]) { j += 1 }
                if j >= u.count { break }
                if isSpace(u[j]) {
                    var k = j
                    while k < u.count && isSpace(u[k]) { k += 1 }
                    if k < u.count && opens(u[k]) && !(u[i] == 46 && test(abbrRE, str(u[start..<i]))) {
                        out.append(trim(str(u[start..<j]))); start = k; i = k; continue
                    }
                }
                i = j; continue
            }
            i += 1
        }
        if start < u.count { out.append(trim(str(u[start...]))) }
        return out.filter { !$0.isEmpty }
    }

    static func splitLong(_ s: String) -> [String] {
        if len(s) <= 240 { return [s] }
        let ns = NSString(string: s)
        var pieces = pieceRE.matches(in: s, options: [], range: full(s)).map { ns.substring(with: $0.range) }
        if pieces.isEmpty { pieces = [s] }
        var out: [String] = []
        var buf = ""
        for p in pieces {
            if !buf.isEmpty && len(buf) + len(p) > 220 { out.append(trim(buf)); buf = p } else { buf += p }
        }
        if !trim(buf).isEmpty { out.append(trim(buf)) }
        var fin: [String] = []
        for piece in out {
            var o = Array(piece.utf16)
            while o.count > 280 {
                var cut = -1
                var x = min(260, o.count - 1)
                while x >= 0 { if o[x] == 32 { cut = x; break }; x -= 1 }
                if cut < 80 { cut = 260 }
                fin.append(str(o[0..<cut]))
                o = Array(trim(str(o[cut...])).utf16)
            }
            if !o.isEmpty { fin.append(str(o)) }
        }
        return fin
    }

    /// The pieces to voice, in order. `host1`/`host2` are whatever identifies a voice; two-speaker scripts give the
    /// first named speaker host 1, the second host 2, and further ones alternate. Unnamed lines are host 1.
    static func segments(script: String, duo: Bool, host1: String, host2: String, pause: Double) -> [Segment] {
        let lines = parse(script)
        let order = speakers(of: lines)
        func voice(_ speaker: String?) -> String {
            guard duo, let sp = speaker, let i = order.firstIndex(of: sp) else { return host1 }
            return i % 2 == 1 ? host2 : host1
        }
        var segs: [Segment] = []
        for (li, l) in lines.enumerated() {
            var parts: [String] = []
            for s in splitSentences(l.text) { parts += splitLong(s) }
            var merged: [String] = []
            for p in parts {
                if let last = merged.last, len(last) < 30, len(last) + 1 + len(p) < 200 { merged[merged.count - 1] = last + " " + p } else { merged.append(p) }
            }
            let v = voice(l.speaker)
            let nextVoice: String? = li + 1 < lines.count ? voice(lines[li + 1].speaker) : nil
            for (pi, p) in merged.enumerated() {
                let last = pi == merged.count - 1
                let gap = last ? ((nextVoice != nil && nextVoice != v) ? pause : min(pause, 0.3)) : 0.12
                segs.append(Segment(line: li, text: p, voice: v, pause: gap))
            }
        }
        return segs
    }

    /// Changes when anything that affects the audio changes.
    static func signature(_ segs: [Segment]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }; h ^= 0xff; h = h &* 0x100000001b3 }
        for s in segs { mix(s.text); mix(s.voice); mix(String(format: "%.3f", s.pause)) }
        return "\(segs.count):" + String(h, radix: 16)
    }

    /// A script that names itself in a first-line heading keeps that name; otherwise the file name without its extension.
    static func title(script: String, fileName: String?) -> String {
        let own = rx("^\\s*#{1,3}[ \\t]+([^\\r\\n]+?)[ \\t#]*(\\r?\\n|$)")
        if let m = own.firstMatch(in: script, options: [], range: full(script)) {
            return String(NSString(string: script).substring(with: m.range(at: 1)).prefix(120))
        }
        if let f = fileName, !f.isEmpty {
            let base = (f as NSString).deletingPathExtension
            return base.isEmpty ? f : base
        }
        let first = parse(script).first?.text ?? "Untitled"
        return String(first.prefix(60))
    }

    static func wordCount(_ script: String) -> Int {
        return parse(script).reduce(0) { $0 + $1.text.split(separator: " ").count }
    }
}
