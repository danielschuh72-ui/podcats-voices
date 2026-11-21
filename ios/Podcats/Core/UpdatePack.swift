import Foundation

/// An update the app can take in without being reinstalled: one small JSON file, `podcats-update.json`.
///
/// It can change what is data, not what is compiled: how words are respelled before they are voiced (`rules`), a
/// JavaScript function run on every piece of text (`js`), further voices offered (`moreVoices`), and a few switches
/// between ways of working that are already in the app (`flags`). New screens and fixes to the app's own code still
/// need a new .ipa. Keys this build does not know are ignored, so a newer file does not break an older app.
struct UpdatePack: Codable, Equatable {
    struct Rule: Codable, Equatable {
        var find: String          // a regular expression (ICU)
        var replace: String       // its replacement; $1 … refer to groups
        var ignoreCase: Bool?
    }

    struct Flags: Codable, Equatable {
        var computeUnit: String?  // "cpu" (default) or "neuralEngine"
        var bitRate: Int?         // of the .m4a, bits per second
        var pickerCopies: Bool?   // ask the file picker for copies instead of opening files in place
    }

    var app: String
    var format: Int
    var version: Int
    var minBuild: Int?
    var notes: String?
    var rules: [Rule]?
    var js: String?
    var moreVoices: [String]?
    var flags: Flags?

    static let fileName = "podcats-update.json"

    struct Invalid: Error, CustomStringConvertible { let description: String }

    /// Reads and checks an update file. Throws with the reason if anything in it could not be used.
    static func parse(_ data: Data) throws -> UpdatePack {
        let pack: UpdatePack
        do { pack = try JSONDecoder().decode(UpdatePack.self, from: data) } catch {
            throw Invalid(description: "This is not a Podcats update file.")
        }
        guard pack.app == "podcats-update" else { throw Invalid(description: "This is not a Podcats update file.") }
        guard pack.format == 1 else { throw Invalid(description: "This update needs a newer version of the app.") }
        guard pack.version >= 1 else { throw Invalid(description: "The update has no version number.") }
        guard (pack.rules?.count ?? 0) <= 1000 else { throw Invalid(description: "The update has too many rules.") }
        guard (pack.js?.utf8.count ?? 0) <= 300_000 else { throw Invalid(description: "The update's script is too large.") }
        _ = try TextRules(pack.rules ?? [])
        if let u = pack.flags?.computeUnit, u != "cpu", u != "neuralEngine" { throw Invalid(description: "The update names an unknown compute unit: \(u).") }
        if let b = pack.flags?.bitRate, b < 16_000 || b > 128_000 { throw Invalid(description: "The update asks for a bit rate out of range: \(b).") }
        for v in pack.moreVoices ?? [] where v.isEmpty || v.utf8.count > 80 { throw Invalid(description: "The update lists a voice with no usable name.") }
        return pack
    }

    static func looksLikeUpdate(_ data: Data) -> Bool {
        return String(decoding: data.prefix(400), as: UTF8.self).contains("podcats-update")
    }
}

/// The respelling rules of an update, ready to use: applied in order, each to the result of the one before.
struct TextRules {
    private let compiled: [(NSRegularExpression, String)]

    init(_ rules: [UpdatePack.Rule]) throws {
        var out: [(NSRegularExpression, String)] = []
        for (i, r) in rules.enumerated() {
            guard !r.find.isEmpty else { throw UpdatePack.Invalid(description: "Rule \(i + 1) of the update is empty.") }
            do {
                out.append((try NSRegularExpression(pattern: r.find, options: r.ignoreCase == true ? [.caseInsensitive] : []), r.replace))
            } catch {
                throw UpdatePack.Invalid(description: "Rule \(i + 1) of the update is not a valid pattern: \(r.find)")
            }
        }
        compiled = out
    }

    var count: Int { return compiled.count }

    func apply(_ text: String) -> String {
        var t = text
        for (rx, with) in compiled {
            t = rx.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: t.utf16.count), withTemplate: with)
        }
        return t
    }
}
