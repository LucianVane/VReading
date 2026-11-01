import Foundation
import Observation

/// 一句字幕的翻译 + 地道表达注释
struct CueTranslation: Codable, Hashable {
    struct Note: Codable, Hashable {
        /// 原文中的习语 / 俚语
        var phrase: String
        /// 解释 (目标语言)
        var note: String
    }
    var text: String
    var notes: [Note] = []
}

/// 字幕翻译: AI 按批翻译并标注习语俚语, 只翻译正在收听 / 浏览附近的句子, 结果按单集 + 语言缓存
@Observable
final class CueTranslator {
    static let shared = CueTranslator()

    private(set) var translations: [Int: CueTranslation] = [:]
    private(set) var busy = false
    var error: String?

    @ObservationIgnored private var episodeKey = ""
    @ObservationIgnored private var target = ""
    @ObservationIgnored private var sourceLang = "en"
    @ObservationIgnored private var cues: [TranscriptCue] = []
    @ObservationIgnored private var pending = Set<Int>()
    @ObservationIgnored private var inFlight = Set<Int>()
    @ObservationIgnored private var flushWork: DispatchWorkItem?

    private static let batchSize = 16

    private var cacheURL: URL {
        let dir = Paths.caches.appendingPathComponent("CueTranslations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("v2_\(episodeKey)_\(target).json")
    }

    /// 切换单集或目标语言时调用
    func configure(episode: PodcastEpisode, cues: [TranscriptCue], sourceLang: String, target: String) {
        let key = episode.cacheKey
        self.cues = cues
        guard key != episodeKey || target != self.target else { return }
        episodeKey = key
        self.target = target
        self.sourceLang = sourceLang
        pending = []
        inFlight = []
        error = nil
        translations = (try? JSONDecoder().decode([Int: CueTranslation].self, from: Data(contentsOf: cacheURL))) ?? [:]
    }

    func updateCues(_ c: [TranscriptCue]) { cues = c }

    /// 请求翻译某些句子 (会合并成批次)
    func request(_ ids: [Int]) {
        let missing = ids.filter { translations[$0] == nil && !inFlight.contains($0) && $0 >= 0 && $0 < cues.count }
        guard !missing.isEmpty else { return }
        pending.formUnion(missing)
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func flush() {
        let ids = pending.sorted()
        pending = []
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: Self.batchSize).map({ Array(ids[$0..<min($0 + Self.batchSize, ids.count)]) }) {
            inFlight.formUnion(chunk)
            let key = episodeKey, tgt = target
            let batch = chunk.compactMap { i in cues.first { $0.id == i } }
            busy = true
            Task {
                let result = await translate(batch)
                await MainActor.run {
                    self.inFlight.subtract(chunk)
                    self.busy = !self.inFlight.isEmpty
                    guard key == self.episodeKey, tgt == self.target else { return }
                    for (i, t) in result { self.translations[i] = t }
                    try? JSONEncoder().encode(self.translations).write(to: self.cacheURL)
                }
            }
        }
    }

    private func targetName() -> String {
        TranslateLanguage(rawValue: target)?.englishName ?? "Simplified Chinese"
    }

    private func sourceName() -> String {
        ["en": "English", "fr": "French", "es": "Spanish", "ja": "Japanese"][sourceLang] ?? "foreign-language"
    }

    private func translate(_ batch: [TranscriptCue]) async -> [Int: CueTranslation] {
        guard !batch.isEmpty else { return [:] }
        let config = AIConfig.load()
        if config.isConfigured {
            let lines = batch.map { "\($0.id)\t\($0.text)" }.joined(separator: "\n")
            let prompt = """
            Below are subtitles from a \(sourceName()) podcast. Each line has the format "ID<TAB>text".
            1. Translate each line into \(targetName()). Translate only that line's own content for each ID. Do not merge, split or move content between IDs, even if a sentence is split across two lines.
            2. In each line, find idiomatic expressions, slang, colloquialisms or set phrases (do not mark ordinary words). The expression must appear verbatim in that line's original text. Explain its meaning briefly in \(targetName()) (under 15 words).
            Return only JSON: {"items":[{"id":ID,"t":"translation of the line","notes":[{"p":"expression from the original line","n":"explanation"}]}]}

            \(lines)
            """
            if let raw = try? await AIService.complete(config: config, messages: [
                ["role": "system", "content": "You are a professional subtitle translator and language teacher. Output JSON only."],
                ["role": "user", "content": prompt],
            ], maxTokens: 3000, json: true, temperature: 0.2) {
                struct Note: Decodable { var p: String; var n: String }
                struct Item: Decodable { var id: Int; var t: String; var notes: [Note]? }
                struct R: Decodable { var items: [Item] }
                if let r = try? JSONDecoder().decode(R.self, from: Data(MindMapGenerator.extractJSON(raw).utf8)) {
                    var out: [Int: CueTranslation] = [:]
                    let source = Dictionary(batch.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                    for it in r.items {
                        guard let original = source[it.id] else { continue }
                        // 只保留确实出现在该句原文中的表达
                        let notes = (it.notes ?? []).filter { original.range(of: $0.p, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                        out[it.id] = CueTranslation(text: it.t, notes: notes.map { .init(phrase: $0.p, note: $0.n) })
                    }
                    if !out.isEmpty { return out }
                }
            }
        }
        // AI 不可用时: 免费在线翻译 (无习语标注)
        var out: [Int: CueTranslation] = [:]
        for c in batch {
            if let r = try? await FreeTranslator.translate(c.text, from: sourceLang, to: target) {
                out[c.id] = CueTranslation(text: r.text)
            }
        }
        if out.isEmpty { await MainActor.run { self.error = String(localized: "Translation failed. Check your network or AI settings.") } }
        return out
    }
}
