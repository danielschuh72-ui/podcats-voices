import Foundation
import AVFoundation
import MediaPlayer
import UIKit

private final class FinishWatcher: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    var onError: ((Error?) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onError?(error) }
}

/// Plays one prepared episode, with the lock screen controls.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var episodeID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var problem: String?

    private var player: AVAudioPlayer?
    private let watcher = FinishWatcher()
    private var timer: Timer?
    private var lastSaved = Date.distantPast
    private var resumeAfterInterruption = false
    private let library = Library.shared

    private init() {
        watcher.onFinish = { [weak self] in Task { @MainActor in self?.finished() } }
        watcher.onError = { [weak self] e in Task { @MainActor in self?.problem = e.map { Log.text($0) } ?? "The audio could not be read." } }
        Session.shared.onInterruption = { [weak self] began, shouldResume in self?.interruption(began: began, shouldResume: shouldResume) }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor in self?.routeChanged(reason) }
        }
        commands()
    }

    var rate: Double { return library.settings.rate }

    func setRate(_ r: Double) {
        library.settings.rate = r
        player?.rate = Float(r)
        nowPlaying()
    }

    /// Open an episode at the place it was left, and start it unless told not to.
    func open(_ id: String, play start: Bool = true) {
        guard let ep = library.episode(id), ep.ready else { return }
        if episodeID == id, player != nil {
            if start && !isPlaying { play() }
            return
        }
        pause()
        do {
            let p = try AVAudioPlayer(contentsOf: Paths.m4a(id))
            p.delegate = watcher
            p.enableRate = true
            p.rate = Float(rate)
            p.prepareToPlay()
            player = p
            episodeID = id
            duration = p.duration
            let at = (ep.finished || ep.position >= p.duration - 2) ? 0 : ep.position
            p.currentTime = at
            time = at
            problem = nil
            Log.shared.add("player", "opened \(ep.title) at \(Int(at)) s")
            if start { play() } else { nowPlaying() }
        } catch {
            problem = Log.text(error)
            Log.shared.error("open \(ep.title)", error)
        }
    }

    func toggle() { if isPlaying { pause() } else { play() } }

    func play() {
        guard let p = player else { return }
        do {
            try Session.shared.beginPlayback()
            if p.currentTime >= p.duration - 0.2 { p.currentTime = 0 }
            p.rate = Float(rate)
            guard p.play() else { problem = "Playback did not start."; Session.shared.endPlayback(); return }
            isPlaying = true
            if let id = episodeID { library.update(id) { $0.finished = false; $0.lastPlayed = Date() } }
            startTimer()
            nowPlaying()
        } catch {
            problem = Log.text(error)
            Log.shared.error("play", error)
        }
    }

    func pause() {
        guard let p = player, isPlaying else { return }
        p.pause()
        isPlaying = false
        time = p.currentTime
        savePosition(force: true)
        stopTimer()
        nowPlaying()
        Session.shared.endPlayback()
    }

    func seek(to t: Double) {
        guard let p = player else { return }
        let x = max(0, min(p.duration - 0.1, t))
        p.currentTime = x
        time = x
        savePosition(force: true)
        nowPlaying()
    }

    func skip(_ by: Double) { seek(to: (player?.currentTime ?? 0) + by) }

    /// The episode was deleted or is being prepared again.
    func close(ifPlaying id: String) {
        guard episodeID == id else { return }
        pause()
        player = nil
        episodeID = nil
        time = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func finished() {
        isPlaying = false
        stopTimer()
        time = duration
        if let id = episodeID { library.update(id) { $0.finished = true; $0.position = 0 } }
        Log.shared.add("player", "finished")
        nowPlaying()
        Session.shared.endPlayback()
    }

    private func interruption(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
            if isPlaying {
                isPlaying = false
                time = player?.currentTime ?? time
                savePosition(force: true)
                stopTimer()
                nowPlaying()
            }
        } else if resumeAfterInterruption && shouldResume {
            resumeAfterInterruption = false
            play()
        }
    }

    private func routeChanged(_ reason: UInt) {
        // headphones came out: iOS has stopped the sound, show it
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, isPlaying {
            Log.shared.add("player", "output went away")
            pause()
        }
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let p = player, isPlaying else { return }
        time = p.currentTime
        savePosition(force: false)
    }

    private func savePosition(force: Bool) {
        guard let id = episodeID, let p = player else { return }
        if !force && Date().timeIntervalSince(lastSaved) < 5 { return }
        lastSaved = Date()
        let at = p.currentTime
        library.update(id) { $0.position = at }
    }

    // ---- lock screen ----
    private func commands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(30) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func nowPlaying() {
        guard let id = episodeID, let ep = library.episode(id), let p = player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: "Podcats",
            MPMediaItemPropertyPlaybackDuration: p.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if let art = Player.artwork() { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Not on the main actor: iOS calls the artwork block from its own thread.
    private nonisolated static func artwork() -> MPMediaItemArtwork? {
        guard let img = UIImage(named: "Cover") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}
