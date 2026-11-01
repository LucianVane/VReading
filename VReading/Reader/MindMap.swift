import Foundation

/// 思维导图节点的原文位置: 章节 + 字符偏移 (与字体大小无关, 页码在显示时按当前排版换算)
struct MindLocation: Codable, Hashable {
    var chapter: Int
    var offset: Int
    var chapterLength: Int
    /// 原文锚点句, 跳转时搜索该句定位
    var quote: String

    var ratio: Double { chapterLength > 0 ? min(1, Double(offset) / Double(chapterLength)) : 0 }
}

struct MindNode: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String = ""
    var children: [MindNode] = []
    var location: MindLocation?
}

extension MindNode {
    /// 节点及其子节点中在书中最早出现的位置
    var firstLocation: MindLocation? {
        let all = ([location] + children.map(\.firstLocation)).compactMap { $0 }
        return all.min { ($0.chapter, $0.offset) < ($1.chapter, $1.offset) }
    }

    /// 按原书先后顺序排列子节点 (递归)
    func ordered() -> MindNode {
        var n = self
        n.children = children.map { $0.ordered() }.sorted { a, b in
            guard let la = a.firstLocation else { return false }
            guard let lb = b.firstLocation else { return true }
            return (la.chapter, la.offset) < (lb.chapter, lb.offset)
        }
        return n
    }
}

struct MindMap: Codable {
    var bookId: String
    var lang: String
    var created: Date
    var root: MindNode
}

enum MindMapLanguage: String, CaseIterable, Identifiable {
    case zh, en, fr, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        case .fr: return "Français"
        case .original: return String(localized: "Book's Language")
        }
    }

    /// 默认跟随界面语言
    static var preferred: MindMapLanguage { AppLanguage.isChinese ? .zh : .en }

    /// 提示词中的语言名称
    func promptName(bookLang: String) -> String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        case .fr: return "français"
        case .original:
            switch bookLang {
            case "fr": return "français"
            case "es": return "español"
            case "ja": return "日本語"
            case "zh": return "简体中文"
            default: return "English"
            }
        }
    }
}

/// AI 生成书籍思维导图: 分段提炼要点 (带原文锚点) -> 组织成主题分支
final class MindMapGenerator {
    private let document: ReaderDocument
    private let language: MindMapLanguage
    private let bookLang: String
    var onProgress: ((String) -> Void)?

    init(document: ReaderDocument, language: MindMapLanguage, bookLang: String) {
        self.document = document
        self.language = language
        self.bookLang = bookLang
    }

    // MARK: 缓存
    static var cacheDir: URL {
        let u = Paths.support.appendingPathComponent("MindMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func cacheURL(bookId: String, lang: MindMapLanguage) -> URL {
        cacheDir.appendingPathComponent("\(bookId)_\(lang.rawValue).json")
    }

    static func cached(bookId: String, lang: MindMapLanguage) -> MindMap? {
        guard let d = try? Data(contentsOf: cacheURL(bookId: bookId, lang: lang)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(MindMap.self, from: d)
    }

    private func save(_ m: MindMap) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(m).write(to: Self.cacheURL(bookId: m.bookId, lang: language))
    }

    // MARK: 生成
    private struct Point: Decodable {
        var title: String
        var detail: String?
        var chapter: Int?
        var quote: String?
    }

    func generate() async throws -> MindMap {
        let config = AIConfig.load()
        guard config.isConfigured else { throw ReaderError.network(String(localized: "Set an API key in Settings → AI Settings first.")) }
        let langName = language.promptName(bookLang: bookLang)
        let title = document.book.name

        progress(String(localized: "Reading the whole book..."))
        // 版权声明、许可证、版本说明等不参与总结
        let texts = document.chapters.indices.map { i -> String in
            let t = document.plainText(of: i)
            let title = document.chapters[i].title
            let isLicense = t.contains("Project Gutenberg License") || t.contains("FULL LICENSE")
                || title.range(of: "licen[cs]e|copyright|colophon|imprint|版权", options: [.regularExpression, .caseInsensitive]) != nil
            return isLicense ? "" : t
        }
        let segments = Self.segments(texts.map(\.count))
        let total = segments.count

        // 1. 分段提炼要点 (最多 4 段并发)
        var results: [Int: [Point]] = [:]
        var finished = 0
        try await withThrowingTaskGroup(of: (Int, [Point]).self) { group in
            var next = 0
            func add() {
                guard next < segments.count else { return }
                let i = next
                next += 1
                let input = Self.condense(segments[i], texts: texts, titles: document.chapters.map(\.title))
                group.addTask {
                    let prompt = """
                    Below is part of the book "\(title)". Chapter numbers and titles are given in square brackets. Extract the 3–6 most important points of this part (plot events, ideas, characters or concepts). Ignore copyright notices, publishing information, tables of contents and other non-body text.
                    Return only JSON: {"points":[{"title":"point title, at most 8 words (15 characters in CJK)","detail":"one-sentence explanation, at most 30 words (50 characters in CJK)","chapter":chapter number (integer),"quote":"5-12 consecutive words copied verbatim from the text, unchanged and untranslated"}]}
                    Write title and detail in \(langName). quote must stay in the original language and match the text exactly.

                    \(input)
                    """
                    let raw = try await AIService.complete(config: config, messages: [
                        ["role": "system", "content": "You are a professional reading assistant who extracts the key points of books and builds mind maps. Output JSON only."],
                        ["role": "user", "content": prompt],
                    ], maxTokens: 1500, json: true)
                    struct R: Decodable { var points: [Point] }
                    let r = try? JSONDecoder().decode(R.self, from: Data(Self.extractJSON(raw).utf8))
                    return (i, r?.points ?? [])
                }
            }
            for _ in 0..<min(4, segments.count) { add() }
            while let (i, pts) = try await group.next() {
                results[i] = pts
                finished += 1
                progress(String(localized: "Analyzing the book \(finished)/\(total)..."))
                add()
            }
        }

        // 要点 + 原文定位
        var points: [String: MindNode] = [:]
        var listing = ""
        for i in 0..<total {
            for (j, p) in (results[i] ?? []).enumerated() {
                let id = "p\(i)_\(j)"
                let chapter = min(max(p.chapter ?? segments[i].first ?? 0, 0), texts.count - 1)
                let loc = Self.locate(quote: p.quote ?? "", preferred: chapter, segment: segments[i], texts: texts)
                points[id] = MindNode(id: id, title: p.title, detail: p.detail ?? "", location: loc)
                listing += "\(id) [Ch. \(chapter + 1)] \(p.title): \(p.detail ?? "")\n"
            }
        }
        guard !points.isEmpty else { throw ReaderError.network(String(localized: "The AI returned no usable content. Please try again later.")) }

        // 2. 组织成主题分支
        progress(String(localized: "Building the mind map..."))
        let structPrompt = """
        Below are the key points extracted, in order, from the book "\(title)" (ID + chapter + content). Organize them into a mind map:
        4–7 top-level branches (preferably by plot stage or the book's structure; otherwise by theme, character arc or core concept). Each branch contains several point IDs, and each point may appear only once.
        Order branches as they occur in the book, and order points within each branch the same way (lower IDs first).
        Return only JSON: {"summary":"one-sentence summary of the whole book, at most 40 words (60 characters in CJK)","branches":[{"title":"branch title, at most 6 words (12 characters in CJK)","summary":"branch description, at most 25 words","points":["p0_1","p1_0"]}]}
        Write all text in \(langName).

        \(listing)
        """
        let raw = try await AIService.complete(config: config, messages: [
            ["role": "system", "content": "You are a professional reading assistant who builds clearly structured mind maps. Output JSON only."],
            ["role": "user", "content": structPrompt],
        ], maxTokens: 2000, json: true)
        struct Branch: Decodable { var title: String; var summary: String?; var points: [String]? }
        struct Structure: Decodable { var summary: String?; var branches: [Branch] }
        let structure = try? JSONDecoder().decode(Structure.self, from: Data(Self.extractJSON(raw).utf8))

        var used = Set<String>()
        var branches: [MindNode] = []
        for (bi, b) in (structure?.branches ?? []).enumerated() {
            let kids = (b.points ?? []).compactMap { id -> MindNode? in
                guard !used.contains(id), let n = points[id] else { return nil }
                used.insert(id)
                return n
            }
            guard !kids.isEmpty else { continue }
            branches.append(MindNode(id: "b\(bi)", title: b.title, detail: b.summary ?? "", children: kids,
                                     location: kids.first?.location))
        }
        // 未被分配的要点按顺序放入 "其他"
        let rest = points.keys.filter { !used.contains($0) }.sorted { Self.order($0) < Self.order($1) }.compactMap { points[$0] }
        if branches.isEmpty {
            branches = [MindNode(id: "b0", title: title, children: rest)]
        } else if !rest.isEmpty {
            branches.append(MindNode(id: "bx", title: language == .zh ? "其他要点" : "Other Points", children: rest))
        }
        let root = MindNode(id: "root", title: title, detail: structure?.summary ?? "", children: branches).ordered()
        let map = MindMap(bookId: document.book.id, lang: language.rawValue, created: Date(), root: root)
        save(map)
        return map
    }

    private func progress(_ s: String) {
        DispatchQueue.main.async { self.onProgress?(s) }
    }

    private static func order(_ id: String) -> (Int, Int) {
        let parts = id.dropFirst().split(separator: "_").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }

    /// 把章节按字数切成不超过 14 段
    static func segments(_ lengths: [Int]) -> [[Int]] {
        let total = max(1, lengths.reduce(0, +))
        let count = min(14, max(1, lengths.count))
        let target = total / count
        var out: [[Int]] = [], cur: [Int] = [], acc = 0
        for (i, l) in lengths.enumerated() {
            cur.append(i)
            acc += l
            if acc >= target && out.count < count - 1 {
                out.append(cur)
                cur = []
                acc = 0
            }
        }
        if !cur.isEmpty { out.append(cur) }
        // 过滤几乎没有正文的段 (封面、版权页)
        return out.filter { seg in seg.reduce(0) { $0 + lengths[$1] } > 200 }
    }

    /// 压缩一段内容到约 14000 字符: 每章按比例取开头和均匀分布的若干片段
    static func condense(_ seg: [Int], texts: [String], titles: [String]) -> String {
        let budget = 14_000
        let total = max(1, seg.reduce(0) { $0 + texts[$1].count })
        var out = ""
        for i in seg {
            let t = texts[i].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard t.count > 30 else { continue }
            let share = max(400, budget * t.count / total)
            out += "\n[\(i + 1): \(titles[safe: i] ?? "")]\n"
            if t.count <= share {
                out += t
            } else {
                let pieces = 4
                let len = share / pieces
                for k in 0..<pieces {
                    let start = t.index(t.startIndex, offsetBy: (t.count - len) * k / (pieces - 1))
                    let end = t.index(start, offsetBy: len, limitedBy: t.endIndex) ?? t.endIndex
                    out += String(t[start..<end]) + " … "
                }
            }
        }
        return out
    }

    /// 在原文中定位锚点句: 优先指定章节, 其次本段其他章节, 最后用前几个词模糊匹配
    static func locate(quote: String, preferred: Int, segment: [Int], texts: [String]) -> MindLocation {
        let q = quote.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let order = [preferred] + segment.filter { $0 != preferred } + texts.indices.filter { $0 != preferred && !segment.contains($0) }
        func find(_ needle: String) -> MindLocation? {
            guard needle.count >= 6 else { return nil }
            for c in order {
                let t = texts[c].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if let r = t.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                    return MindLocation(chapter: c, offset: t.distance(from: t.startIndex, to: r.lowerBound), chapterLength: t.count, quote: String(t[r]))
                }
            }
            return nil
        }
        if let l = find(q) { return l }
        let words = q.split(separator: " ")
        if words.count > 4, let l = find(words.prefix(4).joined(separator: " ")) { return l }
        if words.count > 3, let l = find(words.suffix(3).joined(separator: " ")) { return l }
        return MindLocation(chapter: preferred, offset: 0, chapterLength: max(1, texts[preferred].count), quote: "")
    }

    /// 从模型输出中取出 JSON 对象
    static func extractJSON(_ s: String) -> String {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") else { return "{}" }
        return String(s[a...b])
    }
}
