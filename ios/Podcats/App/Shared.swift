import SwiftUI
import UIKit

/// The iOS share sheet: Save to Files, VLC, AirDrop and the rest.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
enum Sharing {
    /// The files to hand over for these episodes: the copies in the Files app where there are any, else fresh ones.
    static func urls(for ids: [String]) -> [URL] {
        var out: [URL] = []
        for id in ids {
            guard let ep = Library.shared.episode(id), ep.ready else { continue }
            if let f = ep.fileName {
                let u = Paths.documents.appendingPathComponent(f)
                if FileManager.default.fileExists(atPath: u.path) { out.append(u); continue }
            }
            if let u = try? AudioFiles.shareCopy(id: id, title: ep.title) { out.append(u) }
        }
        Log.shared.add("share", "\(out.count) file(s)")
        return out
    }
}

/// One or two speakers, which voices, and the pause between speakers.
struct VoiceOptions: View {
    @Binding var duo: Bool
    @Binding var host1: String
    @Binding var host2: String
    @Binding var pause: Double

    var body: some View {
        Picker("Speakers", selection: $duo) {
            Text("One Speaker").tag(false)
            Text("Two Speakers").tag(true)
        }
        .pickerStyle(.segmented)
        VoicePicker(title: duo ? "Host 1" : "Voice", voice: $host1)
        if duo {
            VoicePicker(title: "Host 2", voice: $host2)
            Stepper(value: $pause, in: 0.1...1.0, step: 0.05) {
                Text("Pause Between Speakers: \(String(format: "%.2f", pause)) s")
            }
        }
    }
}

struct VoicePicker: View {
    let title: String
    @Binding var voice: String

    /// Voices an update added, and the one in use if it is none of the listed ones (so the picker can show it).
    private var more: [String] {
        var m = Voices.more.filter { !Voices.all.contains($0) }
        if !Voices.all.contains(voice) && !m.contains(voice) { m.append(voice) }
        return m
    }

    var body: some View {
        Picker(title, selection: $voice) {
            Section("Female") { ForEach(Voices.female, id: \.self) { Text($0).tag($0) } }
            Section("Male") { ForEach(Voices.male, id: \.self) { Text($0).tag($0) } }
            if !more.isEmpty { Section("More") { ForEach(more, id: \.self) { Text($0).tag($0) } } }
        }
    }
}
