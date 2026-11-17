import SwiftUI
import UIKit

@main
struct PodcatsApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var library = Library.shared
    @StateObject private var preparer = Preparer.shared
    @StateObject private var player = Player.shared

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        Log.shared.add("launch", "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            Log.shared.setLocked(true); Log.shared.add("phone", "locked")
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Log.shared.setLocked(false); Log.shared.add("phone", "unlocked")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Log.shared.add("memory", "warning")
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Log.shared.add("app", "terminating")
        }
        Demo.seedIfAsked()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(preparer)
                .environmentObject(player)
                .onAppear {
                    Log.shared.setLocked(!UIApplication.shared.isProtectedDataAvailable)
                    preparer.kick()
                }
                .onChange(of: phase) { _, now in phaseChanged(now) }
        }
    }

    private func phaseChanged(_ now: ScenePhase) {
        switch now {
        case .active:
            Log.shared.setPhase("front"); Log.shared.add("app", "in front")
            Session.shared.enteredForeground()
            preparer.kick()
        case .inactive:
            Log.shared.setPhase("inactive")
        case .background:
            Log.shared.setPhase("back"); Log.shared.add("app", "in the background")
            library.flush()
            Session.shared.enteredBackground()
        @unknown default:
            break
        }
    }
}

/// For the screenshots taken on the build machine: `-seed` puts two short episodes in an empty Library,
/// `-open player|settings|add` goes straight to that screen.
@MainActor
enum Demo {
    static var open: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-open"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func seedIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-seed"), Library.shared.episodes.isEmpty else { return }
        Library.shared.add(title: "The Ferry and the Market", script: "ANA: The ferry leaves the island at six in the morning. By the time it reaches the mainland, the market has already opened.\nBEN: And the bread has already sold out at the first stall. What happens next?\nANA: The flower seller decides, as she does every day, that this is her last year. That's the whole episode in one line.", duo: true)
        Library.shared.add(title: "A Short Walk", script: "It is early, and the street is still wet from the night. A bakery door opens, and the smell reaches the corner before the light does. Somebody is already waiting for the first bus.")
    }
}
