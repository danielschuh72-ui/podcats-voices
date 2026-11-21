import Foundation
import UIKit
import AVFoundation

/// Settings > Share Diagnostic Report: one .json describing what this iPhone did, to send back.
@MainActor
enum Report {
    static func build() async -> URL? {
        var r: [String: Any] = [:]
        let info = Bundle.main.infoDictionary ?? [:]
        r["app"] = "Podcats (native) diagnostic report"
        r["version"] = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        r["t"] = ISO8601DateFormatter().string(from: Date())
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        let dev = UIDevice.current
        r["device"] = ["model": machine, "system": "\(dev.systemName) \(dev.systemVersion)", "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                       "thermal": ProcessInfo.processInfo.thermalState.rawValue, "memoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)]
        let free = (try? Paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        r["storage"] = ["freeMB": Int((free ?? 0) / 1_048_576), "audioMB": folderMB(Paths.audio), "filesMB": folderMB(Paths.documents)]
        let voices = await Engine.shared.voices
        let loaded = await Engine.shared.isLoaded
        let loadSeconds = await Engine.shared.loadSeconds
        let compiled = await Engine.shared.compiled
        let hasTen = Voices.all.allSatisfy { voices.contains($0) }
        let engine: [String: Any] = ["state": String(describing: Preparer.shared.engine), "loaded": loaded, "loadSeconds": loadSeconds,
                                     "compiledThisLaunch": compiled, "voices": voices.count, "hasAllTen": hasTen]
        r["engine"] = engine
        r["session"] = Session.shared.describe
        r["update"] = Updates.shared.describe
        let s = Library.shared.settings
        r["settings"] = ["duo": s.duo, "host1": s.host1, "host2": s.host2, "pause": s.pause, "rate": s.rate, "saveToFiles": s.saveToFiles]
        r["preparing"] = Preparer.shared.currentID.flatMap { Library.shared.episode($0)?.title } ?? NSNull()
        r["episodes"] = Library.shared.episodes.map { e -> [String: Any] in
            var d: [String: Any] = ["title": String(e.title.prefix(60)), "pieces": e.segsTotal, "done": e.segsDone, "ready": e.ready, "secs": Int(e.duration), "tries": e.tries,
                                    "voices": e.duo ? [e.host1, e.host2] : [e.host1], "file": e.fileName ?? "", "audioOnDisk": FileManager.default.fileExists(atPath: Paths.m4a(e.id).path)]
            if let f = e.failed { d["failed"] = f }
            if let sp = e.speed { d["timesRealTime"] = (sp * 10).rounded() / 10 }
            return d
        }
        r["filesFolder"] = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.documents.path)) ?? []).sorted()
        r["errors"] = Log.shared.recentErrors.map { "\($0.t) \($0.d ?? "")" }
        r["timeline"] = Log.shared.all.map { e -> [String: Any] in
            var d: [String: Any] = ["t": e.t, "ev": e.ev, "app": e.app]
            if let x = e.d { d["d"] = x }
            if e.locked == true { d["locked"] = true }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Podcats Report \(f.string(from: Date())).json")
        do { try data.write(to: url) } catch { return nil }
        Log.shared.add("report", "made")
        return url
    }

    private static func folderMB(_ dir: URL) -> Double {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (Double(bytes) / 104_857.6).rounded() / 10
    }
}
