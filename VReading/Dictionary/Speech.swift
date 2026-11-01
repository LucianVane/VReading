import AVFoundation

/// 单词发音: 英音/美音使用有道在线发音, 离线发音使用系统 TTS
final class Speech: NSObject {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var player: AVPlayer?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
    }

    func speak(_ text: String, lang: String = "en", accent: PronounceAccent? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let a = accent ?? AppSettings.shared.accent
        // 句子或非英语使用 TTS
        if a == .tts || lang != "en" || t.split(separator: " ").count > 3 {
            tts(t, lang: lang, accent: a)
            return
        }
        let type = a == .uk ? 1 : 2
        guard let url = URL(string: "https://dict.youdao.com/dictvoice?type=\(type)&audio=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)") else { return }
        let item = AVPlayerItem(url: url)
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            self?.tts(t, lang: lang, accent: a)
        }
        player = AVPlayer(playerItem: item)
        player?.play()
        // 网络不可用时回退到 TTS
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if let p = self?.player, p.currentItem === item, item.status == .failed || (item.status == .unknown) {
                p.pause()
                self?.tts(t, lang: lang, accent: a)
            }
        }
    }

    func tts(_ text: String, lang: String = "en", accent: PronounceAccent = .us) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        let code: String
        switch lang {
        case "fr": code = "fr-FR"
        case "es": code = "es-ES"
        case "ja": code = "ja-JP"
        default: code = accent == .uk ? "en-GB" : "en-US"
        }
        u.voice = AVSpeechSynthesisVoice(language: code)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.pause()
    }
}
