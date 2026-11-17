import Foundation

/// Reads what the web app's "Back Up" wrote: a .zip (stored, not compressed) holding backup.json, or that .json alone.
/// Only the scripts, titles, voices and positions are taken; the audio is made again here.
enum Backup {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func episodes(fromFile url: URL) throws -> [Episode] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 4)
        if head.count == 4 && head[0] == 0x50 && head[1] == 0x4B {
            guard let json = try zipEntry(named: "backup.json", in: fh) else { throw Failure(description: "This is not a Podcats backup file.") }
            return try episodes(fromJSON: json)
        }
        fh.seek(toFileOffset: 0)
        return try episodes(fromJSON: fh.readDataToEndOfFile())
    }

    static func looksLikeBackup(_ data: Data) -> Bool {
        if data.count >= 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B { return true }
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        return head.contains("\"app\"") && head.contains("podcats")
    }

    static func episodes(fromJSON data: Data) throws -> [Episode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["app"] as? String) == "podcats", let list = root["episodes"] as? [[String: Any]] else {
            throw Failure(description: "This is not a Podcats backup file.")
        }
        func num(_ v: Any?) -> Double? { return (v as? NSNumber)?.doubleValue }
        return list.compactMap { r -> Episode? in
            guard let script = r["script"] as? String, !script.isEmpty else { return nil }
            var e = Episode(id: (r["id"] as? String) ?? Episode.newID(), title: (r["title"] as? String) ?? "", script: script)
            if e.title.isEmpty { e.title = ScriptParser.title(script: script, fileName: nil) }
            e.duo = (r["format"] as? String) == "duo"
            e.host1 = Voices.resolve(r["host1"] as? String, host: 1)
            e.host2 = Voices.resolve(r["host2"] as? String, host: 2)
            if let p = num(r["pause"]), p >= 0, p <= 3 { e.pause = p }
            if let c = num(r["createdAt"]), c > 0 { e.createdAt = Date(timeIntervalSince1970: c / 1000) }
            if let p = num(r["pos"]), p > 0 { e.position = p }
            e.finished = (r["finished"] as? Bool) ?? false
            return e
        }
    }

    // ---- the least of zip: find one stored entry by name ----
    private static func le16(_ d: Data, _ o: Int) -> Int { return Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func le32(_ d: Data, _ o: Int) -> Int { return le16(d, o) | le16(d, o + 2) << 16 }

    static func zipEntry(named name: String, in fh: FileHandle) throws -> Data? {
        let size = Int(fh.seekToEndOfFile())
        let tailLen = min(size, 66_000)
        fh.seek(toFileOffset: UInt64(size - tailLen))
        let tail = fh.readData(ofLength: tailLen)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[tail.startIndex + i] == 0x50 && tail[tail.startIndex + i + 1] == 0x4B && tail[tail.startIndex + i + 2] == 5 && tail[tail.startIndex + i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure(description: "This zip file cannot be read.") }
        let count = le16(tail, eocd + 10), cdSize = le32(tail, eocd + 12), cdAt = le32(tail, eocd + 16)
        guard cdAt + cdSize <= size else { throw Failure(description: "This zip file cannot be read.") }
        fh.seek(toFileOffset: UInt64(cdAt))
        let cd = fh.readData(ofLength: cdSize)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, le32(cd, p) == 0x02014b50 else { break }
            let method = le16(cd, p + 10), csize = le32(cd, p + 20), nl = le16(cd, p + 28), xl = le16(cd, p + 30), cl = le16(cd, p + 32), at = le32(cd, p + 42)
            let entry = String(decoding: cd.subdata(in: cd.startIndex + p + 46 ..< cd.startIndex + p + 46 + nl), as: UTF8.self)
            if entry == name {
                guard method == 0 else { throw Failure(description: "This backup was changed by another program and cannot be read.") }
                fh.seek(toFileOffset: UInt64(at))
                let lh = fh.readData(ofLength: 30)
                guard lh.count == 30 else { return nil }
                fh.seek(toFileOffset: UInt64(at + 30 + le16(lh, 26) + le16(lh, 28)))
                return fh.readData(ofLength: csize)
            }
            p += 46 + nl + xl + cl
        }
        return nil
    }
}
