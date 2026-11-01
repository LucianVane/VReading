import Foundation
import AVFoundation
import Speech

struct TimedWord: Codable, Hashable {
    let text: String
    let start: Double
    let end: Double
}

/// 一句字幕
struct TranscriptCue: Codable, Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    /// 逐词时间 (本地识别时才有)
    var words: [TimedWord]?
}

enum TranscriptSource: String, Codable {
    case feed, speech
}

struct Transcript: Codable {
    var source: TranscriptSource
    var cues: [TranscriptCue]
    var complete: Bool
}

/// 字幕: RSS 自带字幕 (VTT/SRT/JSON) 或本地语音识别生成
enum TranscriptService {
    static var cacheDir: URL {
        let u = Paths.caches.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var audioDir: URL {
        let u = Paths.caches.appendingPathComponent("PodcastAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func cached(_ ep: PodcastEpisode) -> Transcript? {
        guard let d = try? Data(contentsOf: cacheDir.appendingPathComponent(ep.cacheKey + ".json")) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: d)
    }

    static func save(_ t: Transcript, for ep: PodcastEpisode) {
        try? JSONEncoder().encode(t).write(to: cacheDir.appendingPathComponent(ep.cacheKey + ".json"))
    }

    // MARK: RSS 字幕
    static func fetchFeedTranscript(_ ep: PodcastEpisode) async throws -> [TranscriptCue] {
        guard let s = ep.transcriptURL, let url = URL(string: s) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let type = ep.transcriptType ?? ""
        if type.contains("json") { return mergeSentences(parseJSON(data)) }
        let text = String(decoding: data, as: UTF8.self)
        return mergeSentences(parseTimedText(text))
    }

    /// WebVTT / SRT
    static func parseTimedText(_ text: String) -> [TranscriptCue] {
        var cues: [TranscriptCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let start = timestamp(parts[0]), end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            var body = lines[(ti + 1)...].joined(separator: " ")
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).htmlUnescaped
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            cues.append(TranscriptCue(id: cues.count, start: start, end: end, text: body))
        }
        return cues
    }

    /// Podcast namespace JSON: {"segments":[{"startTime","endTime","body"}]}
    static func parseJSON(_ data: Data) -> [TranscriptCue] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let segs = j["segments"] as? [[String: Any]] else { return [] }
        var cues: [TranscriptCue] = []
        for s in segs {
            let body = (s["body"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            cues.append(TranscriptCue(id: cues.count, start: s["startTime"] as? Double ?? 0, end: s["endTime"] as? Double ?? 0, text: body))
        }
        return cues
    }

    /// 节目自带字幕常被切成半句: 按句末标点合并成完整句子 (最长约 35 词 / 20 秒)
    static func mergeSentences(_ cues: [TranscriptCue]) -> [TranscriptCue] {
        var out: [TranscriptCue] = []
        var buf: [TranscriptCue] = []
        func flush() {
            guard let f = buf.first, let l = buf.last else { return }
            let text = buf.map(\.text).joined(separator: " ").replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            out.append(TranscriptCue(id: out.count, start: f.start, end: l.end, text: text))
            buf = []
        }
        for c in cues {
            buf.append(c)
            let t = c.text.trimmingCharacters(in: .whitespaces)
            let ended = t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") || t.hasSuffix("…") || t.hasSuffix("\"") || t.hasSuffix("»")
            let words = buf.reduce(0) { $0 + $1.text.split(separator: " ").count }
            if ended || words >= 35 || (c.end - (buf.first?.start ?? c.start)) > 20 { flush() }
        }
        flush()
        return out
    }

    private static func timestamp(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: 下载音频 (语音识别需要本地文件)
    static func localAudio(_ ep: PodcastEpisode) -> URL? {
        let u = audioDir.appendingPathComponent(ep.cacheKey + "." + ((URL(string: ep.audioURL)?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp3"))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func downloadAudio(_ ep: PodcastEpisode, progress: @escaping (Double) -> Void) async throws -> URL {
        if let u = localAudio(ep) { return u }
        guard let url = URL(string: ep.audioURL) else { throw ReaderError.network(String(localized: "Invalid audio URL")) }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let dest = audioDir.appendingPathComponent(ep.cacheKey + "." + ext)
        let delegate = ProgressDelegate(progress)
        let (tmp, _) = try await URLSession.shared.download(from: url, delegate: delegate)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        init(_ p: @escaping (Double) -> Void) { progress = p }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: 本地语音识别
    static func speechLocale(_ lang: String) -> Locale {
        switch lang {
        case "en": return Locale(identifier: "en-US")
        case "es": return Locale(identifier: "es-ES")
        case "ja": return Locale(identifier: "ja-JP")
        default: return Locale(identifier: "fr-FR")
        }
    }

    /// 识别音频生成带时间轴的字幕, 识别过程中通过 onUpdate 返回已识别的部分
    static func transcribe(file: URL, lang: String, onUpdate: @escaping ([TranscriptCue]) -> Void) async throws -> [TranscriptCue] {
        if #available(iOS 26.0, *) {
            return try await transcribeModern(file: file, lang: lang, onUpdate: onUpdate)
        }
        return try await transcribeLegacy(file: file, lang: lang, onUpdate: onUpdate)
    }

    @available(iOS 26.0, *)
    private static func transcribeModern(file: URL, lang: String, onUpdate: @escaping ([TranscriptCue]) -> Void) async throws -> [TranscriptCue] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: speechLocale(lang)) else {
            throw ReaderError.unsupported(String(localized: "Speech recognition for this language is not supported on this device"))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audio = try AVAudioFile(forReading: file)
        let collector = Task { () throws -> [TranscriptCue] in
            var cues: [TranscriptCue] = []
            for try await result in transcriber.results where result.isFinal {
                var words: [TimedWord] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let w = String(result.text[run.range].characters)
                    if !w.trimmingCharacters(in: .whitespaces).isEmpty {
                        words.append(TimedWord(text: w, start: range.start.seconds, end: range.end.seconds))
                    }
                }
                cues.append(contentsOf: makeCues(words, startId: cues.count))
                onUpdate(cues)
            }
            return cues
        }
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    private static func transcribeLegacy(file: URL, lang: String, onUpdate: @escaping ([TranscriptCue]) -> Void) async throws -> [TranscriptCue] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw ReaderError.unsupported(String(localized: "Allow VReading to use Speech Recognition in iOS Settings")) }
        guard let recognizer = SFSpeechRecognizer(locale: speechLocale(lang)), recognizer.isAvailable else {
            throw ReaderError.unsupported(String(localized: "Speech recognition for this language is not supported on this device"))
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map {
                        TimedWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    let cues = makeCues(words, startId: 0)
                    onUpdate(cues)
                    cont.resume(returning: cues)
                } else if let error {
                    finished = true
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 把逐词结果切成句子: 遇到句末标点或停顿较长时断句, 每句不超过 20 个词
    static func makeCues(_ words: [TimedWord], startId: Int) -> [TranscriptCue] {
        var cues: [TranscriptCue] = []
        var cur: [TimedWord] = []
        func flush() {
            guard let first = cur.first, let last = cur.last else { return }
            let text = cur.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ([,.!?;:…])", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            cues.append(TranscriptCue(id: startId + cues.count, start: first.start, end: last.end, text: text, words: cur))
            cur = []
        }
        for (i, w) in words.enumerated() {
            cur.append(w)
            let t = w.text.trimmingCharacters(in: .whitespaces)
            let sentenceEnd = t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") || t.hasSuffix("…")
            let pause = i + 1 < words.count ? words[i + 1].start - w.end : 0
            if sentenceEnd || pause > 0.9 || cur.count >= 20 { flush() }
        }
        flush()
        return cues
    }
}
