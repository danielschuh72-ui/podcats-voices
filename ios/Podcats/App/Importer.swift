import Foundation

/// Scripts coming in: pasted text, files picked in the app, files sent to the app from another one, or a backup
/// made by the web app.
@MainActor
enum Importer {
    struct Result { var added = 0; var restored = 0; var problems: [String] = [] }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    static func add(files: [URL]) -> Result {
        var r = Result()
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if ext == "zip" || ext == "json" {
                do { r.restored += Library.shared.merge(try Backup.episodes(fromFile: url)) } catch { r.problems.append("\(name): \(Log.text(error))") }
                continue
            }
            guard let text = readText(url) else { r.problems.append("\(name) could not be read."); continue }
            if ScriptParser.parse(text).isEmpty { r.problems.append("\(name) has nothing to read in it."); continue }
            Library.shared.add(title: ScriptParser.title(script: text, fileName: name), script: text)
            r.added += 1
        }
        Log.shared.add("import", "\(r.added) added, \(r.restored) restored, \(r.problems.count) problems")
        Preparer.shared.kick()
        return r
    }

    static func summary(_ r: Result) -> String? {
        var parts: [String] = []
        if r.restored > 0 { parts.append("\(r.restored) episode\(r.restored == 1 ? "" : "s") restored from the backup. Their audio is being prepared again.") }
        parts.append(contentsOf: r.problems)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
