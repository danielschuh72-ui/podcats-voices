import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var share: ShareItems?
    @State private var options: Episode?

    private var episode: Episode? { return library.episode(player.episodeID) }
    private let rates: [Double] = [0.8, 1, 1.2, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                Image("Cover").resizable().scaledToFit().frame(maxWidth: 240).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)).accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(episode?.title ?? "").font(.title3.bold()).multilineTextAlignment(.center)
                    Text(voicesText).font(.subheadline).foregroundStyle(.secondary)
                }
                scrubber
                controls
                if let p = player.problem { Text(p).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    rateMenu
                    Menu {
                        Button { if let id = player.episodeID { share = ShareItems(urls: Sharing.urls(for: [id])) } } label: { Label("Share Audio", systemImage: "square.and.arrow.up") }
                        Button { options = episode } label: { Label("Title and Voices", systemImage: "slider.horizontal.3") }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
                }
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .sheet(item: $options) { EpisodeOptionsView(episode: $0) }
        .onChange(of: player.episodeID) { _, now in if now == nil { dismiss() } }
    }

    private var voicesText: String {
        guard let e = episode else { return "" }
        return e.duo ? "\(e.host1) and \(e.host2)" : e.host1
    }

    private var scrubber: some View {
        let shown = scrub ?? player.time
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }), in: 0...max(player.duration, 1), onEditingChanged: { moving in
                if !moving, let s = scrub { player.seek(to: s); scrub = nil }
            })
            .accessibilityLabel("Position")
            HStack {
                Text(TimeText.clock(shown))
                Spacer()
                Text("-" + TimeText.clock(max(0, player.duration - shown)))
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 30)) }.accessibilityLabel("Back 15 seconds")
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72)) }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.system(size: 30)) }.accessibilityLabel("Forward 30 seconds")
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach(rates, id: \.self) { r in
                Button { player.setRate(r) } label: {
                    if abs(r - player.rate) < 0.01 { Label(rateText(r), systemImage: "checkmark") } else { Text(rateText(r)) }
                }
            }
        } label: { Text(rateText(player.rate)).monospacedDigit() }
        .accessibilityLabel("Speed")
    }

    private func rateText(_ r: Double) -> String {
        return (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)) + "×"
    }
}

/// A new episode from pasted or typed text.
struct AddView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var script = ""
    @State private var duo = false
    @State private var host1 = Voices.host1
    @State private var host2 = Voices.host2
    @State private var pause = 0.35

    private var words: Int { return ScriptParser.wordCount(script) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                }
                Section {
                    TextEditor(text: $script).frame(minHeight: 180)
                    Button { if let s = UIPasteboard.general.string { script = s; fillTitle() } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                } header: { Text("Script") } footer: {
                    Text(words > 0 ? "\(words) words, about \(TimeText.rough(Double(words) / 2.6)) of audio. Lines that start with a name and a colon are read by that speaker." : "Lines that start with a name and a colon, like ANA: Hello, are read by that speaker.")
                }
                Section("Voices") { VoiceOptions(duo: $duo, host1: $host1, host2: $host2, pause: $pause) }
            }
            .navigationTitle("New Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(words == 0) }
            }
        }
        .onAppear {
            let s = library.settings
            duo = s.duo; host1 = s.host1; host2 = s.host2; pause = s.pause
        }
    }

    private func fillTitle() {
        if title.isEmpty, script.range(of: "^\\s*#{1,3}[ \\t]", options: .regularExpression) != nil { title = ScriptParser.title(script: script, fileName: nil) }
    }

    private func add() {
        library.add(title: title.trimmingCharacters(in: .whitespacesAndNewlines), script: script, duo: duo, host1: host1, host2: host2, pause: pause)
        Preparer.shared.kick()
        dismiss()
    }
}

/// Title and voices of one episode. Changing a voice makes its audio again.
struct EpisodeOptionsView: View {
    let episode: Episode
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var duo = false
    @State private var host1 = Voices.host1
    @State private var host2 = Voices.host2
    @State private var pause = 0.35

    private var changesAudio: Bool {
        let before = ScriptParser.signature(episode.segments())
        var e = episode
        e.duo = duo; e.host1 = host1; e.host2 = host2; e.pause = pause
        return ScriptParser.signature(e.segments()) != before
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Title", text: $title) }
                Section {
                    VoiceOptions(duo: $duo, host1: $host1, host2: $host2, pause: $pause)
                } header: { Text("Voices") } footer: {
                    if changesAudio && (episode.ready || episode.segsDone > 0) { Text("Saving prepares this episode again with the new voices.") }
                }
                if let f = episode.failed {
                    Section("Last Problem") { Text(f).font(.footnote) }
                }
                Section {
                    Text("\(ScriptParser.wordCount(episode.script)) words, \(episode.segments().count) pieces").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .onAppear { title = episode.title; duo = episode.duo; host1 = episode.host1; host2 = episode.host2; pause = episode.pause }
    }

    private func save() {
        let id = episode.id
        let remake = changesAudio
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let renamed = !newTitle.isEmpty && newTitle != episode.title
        if remake {
            Preparer.shared.invalidate(id)
            Player.shared.close(ifPlaying: id)
            try? FileManager.default.removeItem(at: Paths.pcm(id))
            try? FileManager.default.removeItem(at: Paths.m4a(id))
            if let f = episode.fileName { try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(f)) }
        }
        library.update(id) { e in
            if !newTitle.isEmpty { e.title = newTitle }
            e.duo = duo; e.host1 = host1; e.host2 = host2; e.pause = pause
            if remake { e.resetAudio(); e.fileName = nil }
        }
        if renamed && !remake { Preparer.shared.saveToFiles(id) }
        Preparer.shared.kick()
        dismiss()
    }
}

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItems?
    @State private var working = false

    private var version: String {
        let i = Bundle.main.infoDictionary ?? [:]
        return "\(i["CFBundleShortVersionString"] ?? "?") (\(i["CFBundleVersion"] ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VoiceOptions(duo: $library.settings.duo, host1: $library.settings.host1, host2: $library.settings.host2, pause: $library.settings.pause)
                } header: { Text("Voices for New Episodes") }
                Section {
                    Toggle("Save Episodes to Files", isOn: $library.settings.saveToFiles)
                } footer: {
                    Text("Each episode is saved as an .m4a file as soon as it is prepared, with no tap needed. Find them in the Files app under On My iPhone, Podcats, and open them from there in VLC or any other player.")
                }
                Section {
                    Button {
                        working = true
                        Task {
                            if let url = await Report.build() { share = ShareItems(urls: [url]) }
                            working = false
                        }
                    } label: { Label(working ? "Collecting…" : "Share Diagnostic Report", systemImage: "stethoscope") }
                    .disabled(working)
                } header: { Text("Help") } footer: {
                    Text("A file describing what this iPhone did: the voices, preparing, the background, the last errors. Nothing is sent anywhere; you choose where the file goes.")
                }
                Section {
                    LabeledContent("Version", value: version)
                } footer: {
                    Text("Voices: Phonon 31m by Gradium, Apache 2.0. Everything runs on this iPhone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .onChange(of: library.settings.saveToFiles) { _, _ in Preparer.shared.saveToFilesChanged() }
    }
}
