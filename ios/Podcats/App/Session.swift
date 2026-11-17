import Foundation
import AVFoundation
import UIKit

/// The audio session, and keeping the app running while it prepares episodes.
///
/// iOS lets an app keep running in the background while it plays audio (the "audio" background mode). Playing an
/// episode does that by itself. When nothing is playing but episodes are still being prepared, a silent sound is
/// looped instead; it mixes with other apps' audio, so music or another podcast is not stopped by it.
@MainActor
final class Session {
    static let shared = Session()

    private var keeper: AVAudioPlayer?
    private var playing = false       // an episode is playing
    private var preparing = false
    private var task: UIBackgroundTaskIdentifier = .invalid
    private(set) var lastError = ""

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in self?.interrupted(began: raw == AVAudioSession.InterruptionType.began.rawValue, shouldResume: opts & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0) }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in Log.shared.add("session", "media services reset"); self?.keeper = nil; self?.refresh() }
        }
    }

    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?

    var describe: [String: Any] {
        let s = AVAudioSession.sharedInstance()
        return ["category": s.category.rawValue, "mixing": s.categoryOptions.contains(.mixWithOthers), "otherAudio": s.isOtherAudioPlaying,
                "keeperPlaying": keeper?.isPlaying ?? false, "episodePlaying": playing, "preparing": preparing, "lastError": lastError,
                "route": s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")]
    }

    /// Call before an episode starts playing. Takes over the audio (other apps pause), which is what puts the
    /// controls on the lock screen.
    func beginPlayback() throws {
        keeper?.stop()
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .spokenAudio, options: [])
        try s.setActive(true)
        playing = true
    }

    func endPlayback() {
        playing = false
        refresh()
    }

    func setPreparing(_ on: Bool) {
        if preparing == on { return }
        preparing = on
        Log.shared.add("keepalive", on ? "wanted" : "not needed")
        refresh()
    }

    private func refresh() {
        if playing { keeper?.stop(); return }
        let s = AVAudioSession.sharedInstance()
        if preparing {
            if keeper?.isPlaying == true { return }
            do {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setActive(true)
                if keeper == nil {
                    let k = try AVAudioPlayer(contentsOf: AudioFiles.silenceFile())
                    k.numberOfLoops = -1
                    k.volume = 0
                    keeper = k
                }
                let ok = keeper?.play() ?? false
                lastError = ok ? "" : "silent sound did not start"
                Log.shared.add("keepalive", ok ? "on" : "did not start")
            } catch {
                lastError = Log.text(error)
                Log.shared.error("keepalive", error)
            }
        } else {
            if keeper?.isPlaying == true { keeper?.stop(); Log.shared.add("keepalive", "off") }
            try? s.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        Log.shared.add("interruption", began ? "began" : "ended" + (shouldResume ? " (resume)" : ""))
        onInterruption?(began, shouldResume)
        if began { playing = false }
        // The silent sound is stopped by an interruption like any other; start it again as soon as iOS allows.
        if preparing {
            let wait: UInt64 = began ? 1_500_000_000 : 200_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                self?.refresh()
            }
        }
    }

    /// Going to the background: ask for the short grace period too, in case the silent sound is refused.
    func enteredBackground() {
        guard preparing, task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "prepare") { [weak self] in
            Log.shared.add("background", "grace period ended")
            Task { @MainActor in self?.endTask() }
        }
    }

    func enteredForeground() { endTask(); if preparing { refresh() } }

    private func endTask() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
}
