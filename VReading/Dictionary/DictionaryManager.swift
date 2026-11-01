import Foundation

struct DictInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    /// 词典语言, 空字符串表示用户导入 (不限语言)
    var lang: String = ""
    var isBuiltin: Bool { id == DictionaryManager.builtinId }
    /// App 内置词典 (不可删除)
    var isBundled: Bool { id.hasPrefix(DictionaryManager.builtinId) }
}

struct WebDict: Identifiable, Hashable {
    let id: String
    let name: String
    let template: String
    var lang = "en"

    func url(for word: String) -> URL? {
        URL(string: String(format: template, word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word))
    }
}

/// 本地 MDict 词典与网页词典管理
final class DictionaryManager {
    static let shared = DictionaryManager()
    static let builtinId = "builtin"

    static let webDicts: [WebDict] = [
        WebDict(id: "wiktionary", name: "Wiktionary", template: "https://en.m.wiktionary.org/wiki/%@"),
        WebDict(id: "youdao", name: String(localized: "Youdao"), template: "https://m.youdao.com/dict?le=eng&q=%@"),
        WebDict(id: "collins", name: String(localized: "Collins"), template: "https://www.collinsdictionary.com/dictionary/english/%@"),
        WebDict(id: "longman", name: String(localized: "Longman"), template: "https://www.ldoceonline.com/dictionary/%@"),
        WebDict(id: "cambridge", name: String(localized: "Cambridge"), template: "https://dictionary.cambridge.org/dictionary/english-chinese-simplified/%@"),
        WebDict(id: "bing", name: String(localized: "Bing Dictionary"), template: "https://cn.bing.com/dict/search?q=%@"),
        WebDict(id: "frdic", name: String(localized: "Frdic"), template: "https://www.frdic.com/dicts/fr/%@", lang: "fr"),
        WebDict(id: "esdict", name: String(localized: "Esdict"), template: "https://www.esdict.cn/dicts/es/%@", lang: "es"),
        WebDict(id: "hjdict", name: String(localized: "Hujiang Japanese"), template: "https://dict.hjenglish.com/jp/jc/%@", lang: "ja"),
        WebDict(id: "weblio", name: "Weblio", template: "https://www.weblio.jp/content/%@", lang: "ja"),
    ]

    /// 内置的其他语种词典 (FreeDict 开源词典转换而来)
    static let bundledForeign: [(file: String, name: String, lang: String)] = [
        ("fr_zh.mdx", String(localized: "French–Chinese (built-in)"), "fr"),
        ("fr_en.mdx", String(localized: "French–English (built-in)"), "fr"),
        ("es_en.mdx", String(localized: "Spanish–English (built-in)"), "es"),
        ("ja_en.mdx", String(localized: "Japanese–English JMdict (built-in)"), "ja"),
    ]

    static let languageNames = ["en": String(localized: "English"), "fr": String(localized: "French"), "es": String(localized: "Spanish"), "ja": String(localized: "Japanese")]

    /// 某语言可用的网页词典: 英语按用户设置, 其他语言全部显示
    func webDicts(for lang: String) -> [WebDict] {
        Self.webDicts.filter { $0.lang == lang && AppSettings.shared.enabledWebDicts.contains($0.id) }
    }

    private var readers: [String: MDictReader] = [:]
    private var mdds: [String: MDictReader?] = [:]
    private let lock = NSLock()
    /// 串行加载, 避免预加载和查词同时解析同一部大词典
    private let loadLock = NSLock()

    var builtinURL: URL? { Paths.bundled("21_en_zh.mdx") }

    func available() -> [DictInfo] {
        var list: [DictInfo] = []
        if let u = builtinURL { list.append(DictInfo(id: Self.builtinId, name: String(localized: "21st Century English–Chinese (built-in)"), url: u, lang: "en")) }
        for d in Self.bundledForeign {
            if let u = Paths.bundled(d.file) { list.append(DictInfo(id: Self.builtinId + "_" + d.file, name: d.name, url: u, lang: d.lang)) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.dictionaries, includingPropertiesForKeys: nil)) ?? []
        let langs = Self.importedLanguages
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension.lowercased() == "mdx" {
            list.append(DictInfo(id: f.lastPathComponent, name: f.deletingPathExtension().lastPathComponent, url: f,
                                 lang: langs[f.lastPathComponent] ?? ""))
        }
        return list
    }

    /// 用户导入词典的语言设置 (文件名 -> 语言, 不设置表示通用)
    static var importedLanguages: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "dictLanguages") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "dictLanguages") }
    }

    /// 内置词典默认全部启用
    static var defaultEnabledIds: [String] { [builtinId] + bundledForeign.map { builtinId + "_" + $0.file } }

    /// 用户启用的词典 (按用户排序)
    func enabled() -> [DictInfo] {
        let all = available()
        return AppSettings.shared.enabledDicts.compactMap { id in all.first { $0.id == id } }
    }

    /// 查某语言单词时使用的词典: 已启用且语言匹配 (或通用) 的词典, 按用户排序
    func enabled(lang: String) -> [DictInfo] {
        enabled().filter { $0.lang.isEmpty || $0.lang == lang }
    }

    func reader(for id: String) -> MDictReader? {
        lock.lock()
        if let r = readers[id] { lock.unlock(); return r }
        lock.unlock()
        loadLock.lock(); defer { loadLock.unlock() }
        lock.lock()
        if let r = readers[id] { lock.unlock(); return r }
        lock.unlock()
        guard let info = available().first(where: { $0.id == id }), let r = try? MDictReader(url: info.url) else { return nil }
        lock.lock(); readers[id] = r; lock.unlock()
        return r
    }

    private func mdd(for id: String) -> MDictReader? {
        lock.lock()
        if let m = mdds[id] { lock.unlock(); return m }
        lock.unlock()
        var r: MDictReader?
        if !id.hasPrefix(Self.builtinId) {
            let u = Paths.dictionaries.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("mdd")
            r = try? MDictReader(url: u)
        }
        lock.lock(); mdds[id] = r; lock.unlock()
        return r
    }

    func preload() {
        DispatchQueue.global(qos: .utility).async {
            for d in self.enabled() { _ = self.reader(for: d.id) }
            _ = LevelWordDB.shared("en")
            _ = Lemmatizer.lemma("loading")
        }
    }

    static let freeDictCSS = """
    .fd-head{font-size:1.15em;margin-bottom:6px} .fd-pos{color:#8B008B;font-style:italic;margin-top:4px}
    .fd-num{color:#2E7D32;margin-top:6px;font-weight:600} .fd-def{margin:2px 0 2px 12px}
    """

    func css(for id: String) -> String {
        if id.hasPrefix(Self.builtinId + "_") { return Self.freeDictCSS }
        let url: URL? = id == Self.builtinId
            ? Paths.bundled("21_en_zh.css")
            : Paths.dictionaries.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("css")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// 去掉首尾标点空白, 保留词中的 ' 和 -
    static func clean(_ word: String) -> String {
        var set = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        set.insert(charactersIn: "‘’“”«»")
        return word.trimmingCharacters(in: set)
    }

    /// 法语等去掉冠词/代词缩合: l'éducation -> éducation, qu'il -> il
    static func stripElision(_ word: String, lang: String) -> String {
        guard lang == "fr" || lang == "it" else { return word }
        for sep in ["'", "’"] {
            let parts = word.components(separatedBy: sep)
            if parts.count == 2, parts[0].count <= 3, !parts[1].isEmpty { return parts[1] }
        }
        return word
    }

    /// 不同语言的查词候选: 法语去掉 l' d' 等缩合, 日语逐步缩短 (简单的词形还原)
    static func candidates(_ word: String, lang: String) -> [String] {
        var c = [word]
        switch lang {
        case "fr", "es":
            for sep in ["'", "’"] where word.contains(sep) {
                if let last = word.components(separatedBy: sep).last, !last.isEmpty { c.append(last) }
            }
        case "ja":
            var w = word
            while w.count > 2 { w.removeLast(); c.append(w) }
        default: break
        }
        return c
    }

    /// 查询单词: 原词 -> 小写 -> 词形还原
    func lookup(_ raw: String, in id: String, lang: String = "en") -> [String] {
        let word = Self.clean(raw)
        guard !word.isEmpty, let r = reader(for: id) else { return [] }
        if lang != "en" {
            for c in Self.candidates(word, lang: lang) {
                let res = r.lookup(c)
                if !res.isEmpty { return res }
            }
            return []
        }
        var res = r.lookup(word)
        if res.isEmpty {
            for c in Lemmatizer.candidates(word.lowercased()) where r.contains(c) {
                res = r.lookup(c)
                if !res.isEmpty { break }
            }
        }
        return res
    }

    /// 资源: mdd 内资源或词典目录下的文件 (css/js/图片)
    func resource(dictId: String, path: String) -> Data? {
        let clean = path.removingPercentEncoding ?? path
        if dictId.hasPrefix(Self.builtinId) {
            if clean.hasSuffix(".css") { return css(for: dictId).data(using: .utf8) }
            return nil
        }
        let local = Paths.dictionaries.appendingPathComponent((clean as NSString).lastPathComponent)
        if let d = try? Data(contentsOf: local) { return d }
        return mdd(for: dictId)?.resource(clean)
    }

    /// 从释义 html 中提取简短的纯文本释义
    func shortExplain(_ word: String, lang: String = "en") -> String {
        if let info = LevelWordDB.shared(lang).info(word), !info.meaning.isEmpty {
            return info.meaning.replacingOccurrences(of: ";", with: "; ").trimmingCharacters(in: .whitespaces)
        }
        for d in enabled(lang: lang) {
            if let html = lookup(word, in: d.id, lang: lang).first {
                return String(html.strippingHTML.replacingOccurrences(of: "\n", with: " ").prefix(160))
            }
        }
        return ""
    }

    func importFile(_ src: URL) throws -> String {
        let dest = Paths.dictionaries.appendingPathComponent(src.lastPathComponent)
        if src.standardizedFileURL != dest.standardizedFileURL {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
        }
        lock.lock(); readers.removeValue(forKey: dest.lastPathComponent); lock.unlock()
        if dest.pathExtension.lowercased() == "mdx" {
            _ = try MDictReader(url: dest)
            var list = AppSettings.shared.enabledDicts
            if !list.contains(dest.lastPathComponent) {
                list.append(dest.lastPathComponent)
                AppSettings.shared.enabledDicts = list
            }
        }
        lock.lock(); mdds.removeValue(forKey: dest.lastPathComponent); lock.unlock()
        return dest.lastPathComponent
    }

    func delete(_ id: String) {
        guard !id.hasPrefix(Self.builtinId) else { return }
        let base = Paths.dictionaries.appendingPathComponent(id).deletingPathExtension()
        for ext in ["mdx", "mdd", "css"] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
        }
        lock.lock(); readers.removeValue(forKey: id); mdds.removeValue(forKey: id); lock.unlock()
        AppSettings.shared.enabledDicts.removeAll { $0 == id }
    }

    /// 生成在 WebView 中展示的释义页面
    func html(for word: String, dictId: String, night: Bool, lang: String = "en") -> String? {
        let entries = lookup(word, in: dictId, lang: lang)
        guard !entries.isEmpty else { return nil }
        var body = entries.joined(separator: "<hr/>")
        // 原 App 内置词典引用了 21century_dict.css, 统一内联样式
        body = body.replacingOccurrences(of: "<link[^>]*?\\.css\"?[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        let colors = night
            ? "body{background:#1c1c1e;color:#bbb} a{color:#6fa8dc}"
            : "body{background:transparent;color:#222}"
        return """
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>\(css(for: dictId))</style>
        <style>body{font-family:-apple-system,'PingFang SC';font-size:15px;line-height:1.5;margin:8px 12px;word-wrap:break-word}
        img{max-width:100%} .hide,.more-collapse{display:block!important} hr{border:none;border-top:1px solid #ddd;margin:12px 0} \(colors)</style>
        </head><body>\(body)</body></html>
        """
    }
}
