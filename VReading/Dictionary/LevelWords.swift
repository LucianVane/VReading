import Foundation

struct WordLevel: Identifiable, Hashable {
    let code: String
    let name: String
    let dayColor: String
    let nightColor: String
    var id: String { code }

    var displayColor: String { AppSettings.shared.levelColors[code] ?? dayColor }
}

struct LevelWordInfo {
    var levels: [String]
    var pronounce: String
    var meaning: String
}

/// 分级词库 (english_words.db / fr_words.db / es_words.db)
final class LevelWordDB {
    static let languages: [(code: String, name: String)] = [("en", String(localized: "English")), ("fr", String(localized: "French")), ("es", String(localized: "Spanish"))]

    let lang: String
    private(set) var name = ""
    private(set) var levels: [WordLevel] = []
    private(set) var wordRegex = "[a-zA-Z'’]"
    private(set) var minChars = 3
    private var map: [String: LevelWordInfo] = [:]

    private static var cache: [String: LevelWordDB] = [:]
    private static let lock = NSLock()

    /// 英语分级词汇的默认颜色 (来自原 App web_reader_style.css)
    private static let englishColors: [String: String] = [
        "CET4": "#FB9851", "CET6": "#B59469", "KaoYan": "#008299", "GRE": "#7D7AFF", "IELTS": "#C91D42",
        "TOEFL": "#475ED1", "TEM4": "#AA3699", "TEM8": "#FCB583", "GAOZHONG": "#43A184", "BEC": "#A078B3",
    ]

    /// 词库中的等级名称为中文, 这里按代码给出本地化名称
    static func displayName(code: String, fallback: String) -> String {
        switch code {
        case "CET4": return String(localized: "CET-4")
        case "CET6": return String(localized: "CET-6")
        case "KaoYan": return String(localized: "Postgraduate Exam")
        case "TEM4": return String(localized: "TEM-4")
        case "TEM8": return String(localized: "TEM-8")
        case "GAOZHONG": return String(localized: "High School")
        case "EEE8": return String(localized: "Spanish Majors Level 8")
        default: return fallback
        }
    }

    static func shared(_ lang: String = "en") -> LevelWordDB {
        lock.lock(); defer { lock.unlock() }
        if let db = cache[lang] { return db }
        let db = LevelWordDB(lang: lang)
        cache[lang] = db
        return db
    }

    private init(lang: String) {
        self.lang = lang
        let file = lang == "en" ? "english_words.db" : "\(lang)_words.db"
        guard let url = Paths.bundled(file), let db = try? SQLiteDB(path: url.path, readonly: true) else { return }
        if let meta = db.query("SELECT * FROM meta_info").first {
            name = meta.str("name") ?? ""
            wordRegex = meta.str("word_regex") ?? wordRegex
            minChars = Int(meta.int("min_word_chars"))
        }
        levels = db.query("SELECT * FROM word_levels").map {
            let code = $0.str("level") ?? ""
            let day = ($0.str("day_text_color") ?? "").isEmpty ? (Self.englishColors[code] ?? "#FB9851") : $0.str("day_text_color")!
            let night = ($0.str("night_text_color") ?? "").isEmpty ? day : $0.str("night_text_color")!
            return WordLevel(code: code, name: Self.displayName(code: code, fallback: $0.str("name") ?? code), dayColor: day, nightColor: night)
        }
        for r in db.query("SELECT word, _level, pronounce, meaning FROM words") {
            let w = (r.str("word") ?? "").lowercased()
            let lv = r.str("_level") ?? ""
            if var info = map[w] {
                if !info.levels.contains(lv) { info.levels.append(lv) }
                map[w] = info
            } else {
                map[w] = LevelWordInfo(levels: [lv], pronounce: r.str("pronounce") ?? "", meaning: r.str("meaning") ?? "")
            }
        }
    }

    func level(named code: String) -> WordLevel? { levels.first { $0.code == code } }

    /// 查询单词所属等级, 自动还原词形
    func info(_ word: String) -> LevelWordInfo? {
        let w = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'’ "))
        if let i = map[w] { return i }
        let candidates: [String]
        switch lang {
        case "en": candidates = Lemmatizer.candidates(w)
        case "fr": candidates = Lemmatizer.frenchCandidates(w)
        default: candidates = []
        }
        for base in candidates { if let i = map[base] { return i } }
        return nil
    }

    /// 所有等级 -> 单词 (用于页面高亮)
    func words(inLevels codes: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for (w, info) in map {
            if let lv = levelPriority(info.levels).first(where: { codes.contains($0) }) { out[w] = lv }
        }
        return out
    }

    /// 多个等级时优先显示较简单的等级 (按词库顺序)
    func levelPriority(_ lv: [String]) -> [String] {
        let order = levels.map(\.code)
        return lv.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
}

/// 英语词形还原: word_changed.txt (abandoning@@@LINK=abandon) + 简单规则
enum Lemmatizer {
    private static let map: [String: String] = {
        guard let url = Paths.bundled("word_changed.txt"), let s = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var m: [String: String] = [:]
        m.reserveCapacity(40_000)
        for line in s.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "@@@LINK=")
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} ")).lowercased()
                m[k] = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        return m
    }()

    static let stopwords: Set<String> = {
        guard let url = Paths.bundled("stopwords.json"), let d = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }()

    static func lemma(_ word: String) -> String {
        let w = word.lowercased()
        return map[w] ?? w
    }

    /// 法语不规则变化表 (tools/gen_fr_irregular.py 生成): 不规则动词变位、冠词代词变形 -> 原形
    private static let frenchIrregular: [String: String] = {
        guard let url = Paths.bundled("fr_irregular.json"), let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }()

    /// 法语简单词形还原: 不规则变化表 + 复数、阴性、常见动词变位规则, 以及 l' d' 等缩合
    static func frenchCandidates(_ word: String) -> [String] {
        var w = word
        for sep in ["'", "’"] where w.contains(sep) {
            w = w.components(separatedBy: sep).last ?? w
        }
        var c: [String] = w == word ? [] : [w]
        if let base = frenchIrregular[w] { c.append(base) }
        let rules: [(String, String)] = [
            ("aux", "al"), ("eaux", "eau"), ("euses", "eux"), ("euse", "eux"), ("ives", "if"), ("ive", "if"),
            ("elles", "el"), ("elle", "el"), ("ennes", "en"), ("enne", "en"),
            ("ées", "er"), ("és", "er"), ("ée", "er"), ("é", "er"),
            ("aient", "er"), ("ais", "er"), ("ait", "er"), ("ions", "er"), ("iez", "er"), ("ons", "er"), ("ez", "er"),
            ("èrent", "er"), ("ent", "er"), ("ant", "er"), ("es", "er"), ("e", "er"),
            ("eront", "er"), ("erons", "er"), ("erez", "er"), ("erai", "er"), ("eras", "er"), ("era", "er"), ("erait", "er"),
            ("issaient", "ir"), ("issait", "ir"), ("issons", "ir"), ("issez", "ir"), ("issent", "ir"), ("issant", "ir"), ("is", "ir"), ("it", "ir"), ("ies", "ir"), ("ie", "ir"), ("i", "ir"),
            ("es", ""), ("s", ""), ("x", ""), ("e", ""),
        ]
        for (suffix, rep) in rules where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            c.append(String(w.dropLast(suffix.count)) + rep)
        }
        return c
    }

    static func candidates(_ w: String) -> [String] {
        var c: [String] = []
        if let m = map[w] { c.append(m) }
        let rules: [(String, String)] = [("ies", "y"), ("ied", "y"), ("ing", ""), ("ing", "e"), ("ed", ""), ("ed", "e"), ("es", ""), ("s", ""), ("er", ""), ("est", ""), ("ly", "")]
        for (suffix, rep) in rules where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            c.append(String(w.dropLast(suffix.count)) + rep)
        }
        // 双写辅音 stopped -> stop
        if w.hasSuffix("ed") || w.hasSuffix("ing") {
            let stem = w.hasSuffix("ed") ? String(w.dropLast(2)) : String(w.dropLast(3))
            if stem.count > 2, let last = stem.last, stem.dropLast().last == last { c.append(String(stem.dropLast())) }
        }
        return c
    }
}
