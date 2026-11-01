import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// 播客播放器 (全局单例): 支持后台播放、锁屏控制、倍速、字幕生成
@Observable
final class PodcastPlayer {
    static let shared = PodcastPlayer()

    var episode: PodcastEpisode?
    var show: PodcastShow?
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Float = 1.0

    // 字幕
    var cues: [TranscriptCue] = []
    var transcriptStatus = "" {
        didSet {
            #if DEBUG
            if transcriptStatus != oldValue && !transcriptStatus.contains("%") { print("TRANSCRIPT", transcriptStatus, "cues:", cues.count) }
            #endif
        }
    }
    var transcriptComplete = false
    var transcriptError: String? {
        didSet {
            #if DEBUG
            if let e = transcriptError { print("TRANSCRIPT ERROR", e) }
            #endif
        }
    }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSaved: Double = 0

    private init() { setupRemoteCommands() }

    // MARK: 播放
    func play(_ ep: PodcastEpisode, show: PodcastShow) {
        if episode?.id == ep.id, player != nil {
            if !isPlaying { resume() }
            return
        }
        stop()
        episode = ep
        self.show = show
        duration = ep.duration
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let url = TranscriptService.localAudio(ep) ?? URL(string: ep.audioURL)
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.tick(t.seconds)
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
            self?.savePosition(0)
        }
        let saved = UserDefaults.standard.double(forKey: "podpos_\(ep.cacheKey)")
        if saved > 5 { p.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
        p.playImmediately(atRate: rate)
        isPlaying = true
        loadTranscript()
        updateNowPlaying()
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if abs(t - lastSaved) > 5 { savePosition(t) }
    }

    private func savePosition(_ t: Double) {
        guard let ep = episode else { return }
        lastSaved = t
        UserDefaults.standard.set(t, forKey: "podpos_\(ep.cacheKey)")
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        player?.pause()
        isPlaying = false
        savePosition(currentTime)
        updateNowPlaying()
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func seek(to t: Double) {
        let target = max(0, min(t, duration > 0 ? duration - 0.5 : t))
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(_ s: Double) { seek(to: currentTime + s) }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player?.rate = r }
        updateNowPlaying()
    }

    func stop() {
        transcriptTask?.cancel()
        transcriptTask = nil
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        savePosition(currentTime)
        player?.pause()
        player = nil
        timeObserver = nil
        isPlaying = false
        cues = []
        transcriptStatus = ""
        transcriptComplete = false
        transcriptError = nil
        currentTime = 0
    }

    /// 当前句索引
    var currentCueIndex: Int? {
        guard !cues.isEmpty else { return nil }
        var lo = 0, hi = cues.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= currentTime + 0.05 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    // MARK: 字幕
    func loadTranscript() {
        guard let ep = episode else { return }
        let lang = show?.lang ?? "fr"
        if let t = TranscriptService.cached(ep), t.complete, !t.cues.isEmpty {
            // 旧版本缓存的节目字幕也合并成整句
            cues = t.source == .feed ? TranscriptService.mergeSentences(t.cues) : t.cues
            transcriptComplete = true
            transcriptStatus = t.source == .feed ? String(localized: "Show Transcript") : String(localized: "On-Device Transcript")
            return
        }
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            // 1. RSS 自带字幕
            if ep.transcriptURL != nil {
                await MainActor.run { self.transcriptStatus = String(localized: "Loading transcript...") }
                if let c = try? await TranscriptService.fetchFeedTranscript(ep), !c.isEmpty {
                    TranscriptService.save(Transcript(source: .feed, cues: c, complete: true), for: ep)
                    await MainActor.run {
                        guard self.episode?.id == ep.id else { return }
                        self.cues = c
                        self.transcriptComplete = true
                        self.transcriptStatus = String(localized: "Show Transcript")
                    }
                    return
                }
            }
            // 2. 本地语音识别
            do {
                await MainActor.run { self.transcriptStatus = String(localized: "Downloading audio to generate subtitles...") }
                let file = try await TranscriptService.downloadAudio(ep) { p in
                    Task { @MainActor in
                        if self.episode?.id == ep.id { self.transcriptStatus = String(localized: "Downloading audio to generate subtitles \(Int(p * 100))%") }
                    }
                }
                if Task.isCancelled { return }
                await MainActor.run { self.transcriptStatus = String(localized: "Transcribing on device...") }
                let cues = try await TranscriptService.transcribe(file: file, lang: lang) { partial in
                    Task { @MainActor in
                        guard self.episode?.id == ep.id else { return }
                        self.cues = partial
                        let t = partial.last?.end ?? 0
                        self.transcriptStatus = String(localized: "Transcribing on device... \(Self.format(t)) done")
                    }
                }
                if Task.isCancelled { return }
                TranscriptService.save(Transcript(source: .speech, cues: cues, complete: true), for: ep)
                await MainActor.run {
                    guard self.episode?.id == ep.id else { return }
                    self.cues = cues
                    self.transcriptComplete = true
                    self.transcriptStatus = String(localized: "On-Device Transcript")
                }
            } catch {
                await MainActor.run {
                    guard self.episode?.id == ep.id else { return }
                    self.transcriptError = String(localized: "Failed to generate subtitles: \(error.localizedDescription)")
                    self.transcriptStatus = ""
                }
            }
        }
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 锁屏 / 控制中心
    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(15); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let ep = episode else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: ep.title,
            MPMediaItemPropertyArtist: show?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let art = ep.artwork.isEmpty ? (show?.artwork ?? "") : ep.artwork
        if let u = URL(string: art) {
            Task {
                if let (d, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: d) {
                    var withArt = info
                    withArt[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    let final = withArt
                    await MainActor.run { MPNowPlayingInfoCenter.default().nowPlayingInfo = final }
                }
            }
        }
    }
}
