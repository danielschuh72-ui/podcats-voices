import Foundation
import JavaScriptCore

/// Takes in `podcats-update.json` (see UpdatePack), from the internet or from a file, and applies it.
///
/// An update can never stop the app from working: it is checked before it is kept, its script is tried once before
/// it is trusted, anything that goes wrong while it is in use falls back to the text as it was, and if the app died
/// while the script was running, the script is left switched off at the next launch. Settings > Remove Update goes
/// back to the app as it was built.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    static let defaultURL = "https://github.com/danielschuh72-ui/podcats-voices/releases/download/ios-update/podcats-update.json"

    enum Outcome: Equatable {
        case installed(Int)      // this version was just installed
        case current(Int?)       // nothing newer than what is installed (nil: no update installed, none published)
        case failed(String)
    }

    @Published private(set) var pack: UpdatePack?
    @Published private(set) var checking = false
    @Published private(set) var lastOutcome: Outcome?
    private(set) var scriptOff = false          // the update's script is not used (it failed, or the app died in it)
    private(set) var lastProblem = ""

    private var rules: TextRules?
    private var context: JSContext?
    private var function: JSValue?
    private let defaults = UserDefaults.standard
    private static let file = Paths.support.appendingPathComponent(UpdatePack.fileName)

    var build: Int { return Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "") ?? 0 }

    var url: URL? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-updateurl"), i + 1 < args.count { return URL(string: args[i + 1]) }
        if let e = ProcessInfo.processInfo.environment["UPDATE_URL"], !e.isEmpty { return URL(string: e) }
        return URL(string: Updates.defaultURL)
    }

    private init() {
        guard let data = try? Data(contentsOf: Updates.file) else { return }
        do {
            let p = try UpdatePack.parse(data)
            if defaults.bool(forKey: "updateScriptRunning") {
                // the app ended while the update's script was running: do not run that script again
                defaults.set(p.version, forKey: "updateScriptBad")
                defaults.set(false, forKey: "updateScriptRunning")
                Log.shared.add("error", "update \(p.version): the app ended inside its script; the script is switched off")
            }
            use(p)
        } catch {
            Log.shared.error("stored update unusable, removed", error)
            try? FileManager.default.removeItem(at: Updates.file)
        }
    }

    // ---- what the update changes ----

    /// A piece of text as it should be handed to the voice.
    func prepare(_ text: String) -> String {
        guard pack != nil else { return text }
        var t = rules?.apply(text) ?? text
        if let f = function, !scriptOff {
            defaults.set(true, forKey: "updateScriptRunning")
            let out = f.call(withArguments: [t])
            defaults.set(false, forKey: "updateScriptRunning")
            if let e = context?.exception {
                context?.exception = nil
                problem("script: \(e)")
                scriptOff = true
            } else if let s = out?.toString(), out?.isString == true, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                t = s
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : t
    }

    var computeUnit: String { return pack?.flags?.computeUnit ?? "cpu" }
    var bitRate: Int { return pack?.flags?.bitRate ?? 64_000 }
    var pickerCopies: Bool { return pack?.flags?.pickerCopies ?? false }

    var describe: [String: Any] {
        var d: [String: Any] = ["installed": pack?.version ?? 0, "scriptOff": scriptOff, "lastProblem": lastProblem, "url": url?.absoluteString ?? "",
                                "rules": rules?.count ?? 0, "hasScript": function != nil, "lastChecked": defaults.double(forKey: "updateChecked")]
        if let p = pack { d["notes"] = p.notes ?? ""; d["flags"] = ["computeUnit": computeUnit, "bitRate": bitRate, "pickerCopies": pickerCopies]; d["moreVoices"] = p.moreVoices ?? [] }
        if let o = lastOutcome { d["lastOutcome"] = String(describing: o) }
        return d
    }

    // ---- taking an update in ----

    /// Check an update file and start using it. `onlyIfNewer`: leave things alone unless it is newer than what is installed.
    @discardableResult
    func install(_ data: Data, from source: String, onlyIfNewer: Bool = false) throws -> UpdatePack {
        let p = try UpdatePack.parse(data)
        if let need = p.minBuild, need > build, build > 0 {
            throw UpdatePack.Invalid(description: "Update \(p.version) needs a newer version of the app (build \(need) or later; this is build \(build)).")
        }
        if onlyIfNewer, let have = pack?.version, p.version <= have { return p }
        try trial(p)
        try data.write(to: Updates.file, options: .atomic)
        defaults.removeObject(forKey: "updateScriptBad")
        use(p)
        Log.shared.add("update", "installed \(p.version) from \(source): \(rules?.count ?? 0) rules, script \(function != nil ? "yes" : "no")")
        return p
    }

    func remove() {
        try? FileManager.default.removeItem(at: Updates.file)
        defaults.removeObject(forKey: "updateScriptBad")
        pack = nil; rules = nil; context = nil; function = nil; scriptOff = false; lastProblem = ""; lastOutcome = nil
        Voices.more = []
        Log.shared.add("update", "removed")
    }

    /// Look for a newer update on the internet and install it.
    @discardableResult
    func check() async -> Outcome {
        guard let url = url else { return .failed("No address to check.") }
        if checking { return lastOutcome ?? .current(pack?.version) }
        checking = true
        defer { checking = false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let outcome: Outcome
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                outcome = .current(pack?.version)   // nothing has been published
            } else if code != 200 {
                outcome = .failed("The update server answered \(code).")
            } else {
                let before = pack?.version
                let p = try install(data, from: "the internet", onlyIfNewer: true)
                outcome = (before == nil || p.version > (before ?? 0)) ? .installed(p.version) : .current(before)
            }
        } catch {
            outcome = .failed(Log.text(error))
        }
        defaults.set(Date().timeIntervalSince1970, forKey: "updateChecked")
        if case .failed(let why) = outcome { Log.shared.add("update", "check failed: \(why)") } else { Log.shared.add("update", "checked: \(outcome)") }
        lastOutcome = outcome
        return outcome
    }

    /// At launch: look once in a while, quietly.
    func checkIfDue() {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.arguments.contains("-reset") { return }
        if Date().timeIntervalSince1970 - defaults.double(forKey: "updateChecked") < 12 * 3600 { return }
        Task { await check() }
    }

    // ---- inside ----

    private func problem(_ what: String) {
        lastProblem = what
        Log.shared.add("error", "update \(pack?.version ?? 0): \(what)")
    }

    /// Build the script of an update and run it once on a sample, before the update is kept.
    private func trial(_ p: UpdatePack) throws {
        guard let js = p.js, !js.isEmpty else { return }
        let (ctx, f) = Updates.makeScript(js)
        if let e = ctx.exception { throw UpdatePack.Invalid(description: "The update's script has an error: \(e)") }
        guard let fn = f else { throw UpdatePack.Invalid(description: "The update's script has no prepareText function.") }
        let out = fn.call(withArguments: ["Revenue was $1,250,000 in 2024. A test."])
        if let e = ctx.exception { throw UpdatePack.Invalid(description: "The update's script fails when run: \(e)") }
        guard out?.isString == true else { throw UpdatePack.Invalid(description: "The update's script does not return text.") }
    }

    private static func makeScript(_ js: String) -> (JSContext, JSValue?) {
        let ctx = JSContext()!
        ctx.exceptionHandler = { c, e in c?.exception = e }
        ctx.evaluateScript(js)
        let f = ctx.objectForKeyedSubscript("prepareText")
        return (ctx, (f != nil && f?.isUndefined == false && f?.isObject == true) ? f : nil)
    }

    private func use(_ p: UpdatePack) {
        pack = p
        rules = try? TextRules(p.rules ?? [])
        context = nil; function = nil
        scriptOff = defaults.integer(forKey: "updateScriptBad") == p.version
        lastProblem = scriptOff ? "the app ended inside this update's script; the script is switched off" : ""
        if let js = p.js, !js.isEmpty, !scriptOff {
            let (ctx, f) = Updates.makeScript(js)
            if ctx.exception == nil, let fn = f { context = ctx; function = fn } else { problem("script could not be loaded"); ctx.exception = nil }
        }
        Voices.more = p.moreVoices ?? []
    }
}
