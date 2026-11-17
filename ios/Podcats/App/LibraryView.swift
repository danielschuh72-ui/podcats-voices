import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var preparer: Preparer
    @EnvironmentObject var player: Player

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showAdd = false
    @State private var showImport = false
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var share: ShareItems?
    @State private var options: Episode?
    @State private var message: String?
    @State private var confirmDelete = false

    private var editing: Bool { return editMode == .active }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(editing ? selectionText : "Podcats")
                .toolbar { toolbar }
                .environment(\.editMode, $editMode)
                .safeAreaInset(edge: .bottom) { if !editing && player.episodeID != nil { MiniPlayer(open: { showPlayer = true }) } }
        }
        .sheet(isPresented: $showAdd) { AddView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPlayer) { PlayerView() }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .sheet(item: $options) { EpisodeOptionsView(episode: $0) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .text, .zip, .json], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): message = Importer.summary(Importer.add(files: urls))
            case .failure(let error): message = Log.text(error)
            }
        }
        .onOpenURL { url in message = Importer.summary(Importer.add(files: [url])) }
        .alert("Podcats", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog("Delete \(selection.count) episode\(selection.count == 1 ? "" : "s")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(selection) }
        } message: { Text("Their audio and their copies in the Files app are deleted too.") }
        .onAppear { openForScreenshot() }
    }

    @ViewBuilder private var content: some View {
        if library.episodes.isEmpty {
            EmptyLibrary(paste: { showAdd = true }, files: { showImport = true })
        } else {
            List(selection: $selection) {
                EngineBanner()
                ForEach(library.episodes) { ep in row(ep) }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func row(_ ep: Episode) -> some View {
        if editing {
            EpisodeRow(episode: ep).tag(ep.id)
        } else {
            Button { tap(ep) } label: { EpisodeRow(episode: ep) }
                .buttonStyle(.plain)
                .tag(ep.id)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete([ep.id]) } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    if ep.ready { Button { share = ShareItems(urls: Sharing.urls(for: [ep.id])) } label: { Label("Share Audio", systemImage: "square.and.arrow.up") } }
                    Button { options = ep } label: { Label("Title and Voices", systemImage: "slider.horizontal.3") }
                    Button(role: .destructive) { delete([ep.id]) } label: { Label("Delete", systemImage: "trash") }
                }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editing {
                Button("Done") { editMode = .inactive; selection.removeAll() }
            } else {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editing {
                Button(selection.count == library.episodes.count ? "Select None" : "Select All") {
                    selection = selection.count == library.episodes.count ? [] : Set(library.episodes.map { $0.id })
                }
            } else {
                if !library.episodes.isEmpty { Button("Select") { editMode = .active } }
                Menu {
                    Button { showAdd = true } label: { Label("Paste or Type a Script", systemImage: "doc.on.clipboard") }
                    Button { showImport = true } label: { Label("Add Files", systemImage: "folder") }
                } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if editing {
                Button { shareSelected() } label: { Label("Share", systemImage: "square.and.arrow.up") }.disabled(readySelected.isEmpty)
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.disabled(selection.isEmpty)
            }
        }
    }

    private var readySelected: [String] { return library.episodes.filter { selection.contains($0.id) && $0.ready }.map { $0.id } }

    private var selectionText: String {
        return selection.isEmpty ? "Select Episodes" : "\(selection.count) Selected"
    }

    private func tap(_ ep: Episode) {
        if ep.ready { player.open(ep.id); showPlayer = true }
        else if ep.tries >= 3 { preparer.retry(ep.id) }
        else { options = ep }
    }

    private func shareSelected() {
        let urls = Sharing.urls(for: readySelected)
        if !urls.isEmpty { share = ShareItems(urls: urls) }
    }

    private func delete(_ ids: Set<String>) {
        for id in ids { preparer.invalidate(id); player.close(ifPlaying: id) }
        library.remove(ids)
        selection.subtract(ids)
        if library.episodes.isEmpty { editMode = .inactive }
    }

    private func openForScreenshot() {
        switch Demo.open {
        case "settings": showSettings = true
        case "add": showAdd = true
        case "select": editMode = .active; selection = Set(library.episodes.prefix(1).map { $0.id })
        case "player":
            Task {
                for _ in 0..<240 {
                    if let ep = library.episodes.first(where: { $0.ready }) { player.open(ep.id, play: false); showPlayer = true; return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        default: break
        }
    }
}

struct EmptyLibrary: View {
    let paste: () -> Void
    let files: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No Episodes Yet").font(.title2.bold())
            Text("Add a script and Podcats reads it aloud. Episodes are prepared on this iPhone, also while it is locked, and saved to the Files app.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(action: files) { Label("Add Files", systemImage: "folder").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
            Button(action: paste) { Label("Paste or Type a Script", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
        }
        .padding(32)
    }
}

/// Says so while the voices are loading, and why if they could not be.
struct EngineBanner: View {
    @EnvironmentObject var preparer: Preparer

    var body: some View {
        switch preparer.engine {
        case .loading(let first):
            HStack(spacing: 12) {
                ProgressView()
                Text(first ? "Setting up the voices. This takes a few seconds the first time." : "Loading the voices…").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Label("The voices could not be loaded", systemImage: "exclamationmark.triangle").font(.subheadline.bold())
                Text(why).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { preparer.kick() }.font(.footnote)
            }
        default:
            EmptyView()
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    @EnvironmentObject var preparer: Preparer
    @EnvironmentObject var player: Player

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.body).lineLimit(2)
                    .foregroundStyle(episode.finished ? .secondary : .primary)
                status
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        if episode.ready {
            Text(readyText).font(.footnote).foregroundStyle(.secondary)
        } else if episode.tries >= 3 {
            Text("Could not be prepared. Tap to try again.\n\(episode.failed ?? "")").font(.footnote).foregroundStyle(.red).lineLimit(3)
        } else if preparer.currentID == episode.id {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: episode.progress)
                Text("Preparing \(Int(episode.progress * 100))%").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text(episode.segsDone > 0 ? "Waiting to carry on (\(Int(episode.progress * 100))%)" : "Waiting to be prepared").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var readyText: String {
        let voices = episode.duo ? "\(episode.host1) and \(episode.host2)" : episode.host1
        if episode.finished { return "Played · \(TimeText.rough(episode.duration)) · \(voices)" }
        if episode.position > 5 { return "\(TimeText.rough(max(0, episode.duration - episode.position))) left · \(voices)" }
        return "\(TimeText.rough(episode.duration)) · \(voices)"
    }

    @ViewBuilder private var trailing: some View {
        if player.episodeID == episode.id && player.isPlaying {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
        } else if episode.ready {
            Image(systemName: "play.circle").font(.title2).foregroundStyle(.tint)
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.episode(player.episodeID)?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(TimeText.clock(player.time)) of \(TimeText.clock(player.duration))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title3) }.accessibilityLabel("Back 15 seconds")
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 36) }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
