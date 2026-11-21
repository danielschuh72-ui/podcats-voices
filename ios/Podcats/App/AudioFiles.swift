import Foundation
import AVFoundation

/// The audio of an episode on disk. While it is being prepared: a .pcm file (16-bit, 24 kHz, mono) that grows piece by
/// piece, so a half-done episode carries on where it stopped. When it is complete: one .m4a (AAC), which is what is
/// played, shared and copied to the Files app.
enum AudioFiles {
    static let rate = 24_000.0

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Append one piece and the pause after it. `keep` is how many bytes of the file belong to finished pieces:
    /// anything beyond it is from a piece that was cut off, and is dropped first. Returns the new size.
    static func append(_ samples: [Float], pause: Double, to url: URL, keep: Int) throws -> Int {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(keep))
        try fh.seekToEnd()
        let silence = Int((pause * rate).rounded())
        var out = [Int16](repeating: 0, count: samples.count + silence)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i])) * 32767
            out[i] = Int16(v.rounded())
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        try fh.write(contentsOf: data)
        return keep + data.count
    }

    /// The .pcm as an .m4a. Returns its length in seconds.
    static func encode(pcm: URL, to out: URL, wanting bitRate: Int = 64_000) throws -> Double {
        do { return try encode(pcm: pcm, to: out, bitRate: bitRate) } catch {
            Log.shared.error("encode at \(bitRate) bits per second, trying the encoder's own rate", error)
            return try encode(pcm: pcm, to: out, bitRate: nil)
        }
    }

    private static func encode(pcm: URL, to out: URL, bitRate: Int?) throws -> Double {
        try? FileManager.default.removeItem(at: out)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw Failure(description: "No audio format.")
        }
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        if let b = bitRate { settings[AVEncoderBitRateKey] = b }
        let input = try FileHandle(forReadingFrom: pcm)
        defer { try? input.close() }
        var total = 0
        do {
            let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 48_000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { throw Failure(description: "No audio buffer.") }
            while true {
                let data = input.readData(ofLength: chunk * 2)
                let n = data.count / 2
                if n == 0 { break }
                guard let dst = buffer.floatChannelData?[0] else { throw Failure(description: "No audio buffer.") }
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    for i in 0..<n { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
                }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                total += n
            }
        } // the file is finished when it goes out of scope here
        if total == 0 { throw Failure(description: "There was no audio to save.") }
        return Double(total) / rate
    }

    /// Title, album and artist on an .m4a, so players show more than the file name. Leaves the file as it was if this fails.
    static func tag(_ url: URL, title: String) async {
        let tmp = url.deletingLastPathComponent().appendingPathComponent("tag-" + UUID().uuidString + ".m4a")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        session.metadata = [item(.iTunesMetadataSongName, title), item(.iTunesMetadataAlbum, "Podcats"), item(.iTunesMetadataArtist, "Podcats")]
        session.outputURL = tmp
        session.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if session.status == .completed, let size = try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1000 {
            do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch { Log.shared.error("tag: replace", error) }
        } else {
            Log.shared.add("error", "tag: " + (session.error.map { Log.text($0) } ?? "status \(session.status.rawValue)"))
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// One second of silence as a .wav, for keeping the app running while it prepares (see Session).
    static func silenceFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let n = 24_000
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + n * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(n); u32(n * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n * 2); d.append(Data(count: n * 2))
        try? d.write(to: url)
        return url
    }

    /// Copy a finished episode to the Files app under its title. Returns the file name used.
    static func saveToFiles(id: String, title: String, previous: String?) throws -> String {
        let fm = FileManager.default
        if let p = previous { try? fm.removeItem(at: Paths.documents.appendingPathComponent(p)) }
        let taken = Set((try? fm.contentsOfDirectory(atPath: Paths.documents.path)) ?? [])
        let name = FileNames.unique(FileNames.safe(title), ext: "m4a", taken: taken)
        try fm.copyItem(at: Paths.m4a(id), to: Paths.documents.appendingPathComponent(name))
        return name
    }

    /// A copy under its title for the share sheet, when there is none in the Files app.
    static func shareCopy(id: String, title: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(FileNames.safe(title) + ".m4a")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: Paths.m4a(id), to: url)
        return url
    }
}
