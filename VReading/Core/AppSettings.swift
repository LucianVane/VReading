import SwiftUI
import Observation

enum PageAnimation: String, CaseIterable, Codable {
    case cover, slide, curl, none
    var title: String {
        switch self {
        case .cover: return String(localized: "Cover")
        case .slide: return String(localized: "Slide")
        case .curl: return String(localized: "Curl")
        case .none: return String(localized: "No Animation")
        }
    }
}

enum PronounceAccent: String, CaseIterable, Codable {
    case uk, us, tts
    var title: String {
        switch self {
        case .uk: return String(localized: "UK")
        case .us: return String(localized: "US")
        case .tts: return String(localized: "Offline TTS")
        }
    }
}

struct ReaderTheme: Identifiable, Hashable {
    let id: Int
    let background: String
    let text: String
    var isDark: Bool { id == ReaderTheme.nightIndex }

    static let all: [ReaderTheme] = [
        ReaderTheme(id: 0, background: "#FFFFFF", text: "#2B2B2B"),
        ReaderTheme(id: 1, background: "#F6EFDC", text: "#3B3022"),
        ReaderTheme(id: 2, background: "#CCE8CF", text: "#24342A"),
        ReaderTheme(id: 3, background: "#E9E4F0", text: "#2E2A36"),
        ReaderTheme(id: 4, background: "#DCE6F2", text: "#22303F"),
        ReaderTheme(id: 5, background: "#131313", text: "#767676"),
    ]
    static let nightIndex = 5
}

/// 网页阅读收藏的网站
struct Website: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var url: String
    var iconUrl: String = ""
}

/// 第三方图书源
struct BookSource: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case opds, webdav, web
        var title: String {
            switch self {
            case .opds: return "OPDS"
            case .webdav: return "WebDav"
            case .web: return "Web"
            }
        }
    }
    var id = UUID().uuidString
    var type: Kind
    var name: String
    var url: String
    var iconUrl: String = ""
    var desc: String = ""
    var username: String = ""
    var password: String = ""
}

/// 全局配置, 持久化到 UserDefaults
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let ud = UserDefaults.standard

    // 阅读
    var fontSize: Int { didSet { ud.set(fontSize, forKey: "fontSize") } }
    var lineHeight: Double { didSet { ud.set(lineHeight, forKey: "lineHeight") } }
    var fontFamily: String { didSet { ud.set(fontFamily, forKey: "fontFamily") } }
    var pageAnimation: PageAnimation { didSet { ud.set(pageAnimation.rawValue, forKey: "pageAnimation") } }
    var themeIndex: Int { didSet { ud.set(themeIndex, forKey: "themeIndex") } }
    var dayThemeIndex: Int { didSet { ud.set(dayThemeIndex, forKey: "dayThemeIndex") } }
    var texture: String { didSet { ud.set(texture, forKey: "texture") } }
    var followSystemBrightness: Bool { didSet { ud.set(followSystemBrightness, forKey: "followSystemBrightness") } }
    var brightness: Double { didSet { ud.set(brightness, forKey: "brightness") } }

    // 阅读设置
    var tapToLookup: Bool { didSet { ud.set(tapToLookup, forKey: "tapToLookup") } }
    var levelHighlightEnabled: Bool { didSet { ud.set(levelHighlightEnabled, forKey: "levelHighlightEnabled") } }
    /// 生词本中的单词在阅读时单独高亮
    var vocabHighlightEnabled: Bool { didSet { ud.set(vocabHighlightEnabled, forKey: "vocabHighlightEnabled") } }
    var highlightLevels: [String] { didSet { ud.set(highlightLevels, forKey: "highlightLevels") } }
    var levelColors: [String: String] { didSet { ud.set(levelColors, forKey: "levelColors") } }
    var examName: String { didSet { ud.set(examName, forKey: "examName") } }
    var hideStoreTab: Bool { didSet { ud.set(hideStoreTab, forKey: "hideStoreTab") } }
    var disableExternalLinks: Bool { didSet { ud.set(disableExternalLinks, forKey: "disableExternalLinks") } }
    var einkMode: Bool { didSet { ud.set(einkMode, forKey: "einkMode") } }

    // 发音
    var speakWhenQuery: Bool { didSet { ud.set(speakWhenQuery, forKey: "speakWhenQuery") } }
    var speakWhenLearn: Bool { didSet { ud.set(speakWhenLearn, forKey: "speakWhenLearn") } }
    var accent: PronounceAccent { didSet { ud.set(accent.rawValue, forKey: "accent") } }

    // 词典: 启用的本地词典 (文件名, "builtin" 表示内置词典) 与网页词典
    var enabledDicts: [String] { didSet { ud.set(enabledDicts, forKey: "enabledDicts") } }
    var enabledWebDicts: [String] { didSet { ud.set(enabledWebDicts, forKey: "enabledWebDicts") } }

    // 语言
    var targetLanguage: String { didSet { ud.set(targetLanguage, forKey: "targetLanguage") } }
    var bookLanguages: [String: String] { didSet { ud.set(bookLanguages, forKey: "bookLanguages") } }

    // 图书源 & 网站
    var bookSources: [BookSource] { didSet { saveJSON(bookSources, "bookSources") } }
    var pinnedSourceId: String { didSet { ud.set(pinnedSourceId, forKey: "pinnedSourceId") } }
    var websites: [Website] { didSet { saveJSON(websites, "websites") } }

    // 引导
    var agreedPolicy: Bool { didSet { ud.set(agreedPolicy, forKey: "agreedPolicy") } }
    var examChosen: Bool { didSet { ud.set(examChosen, forKey: "examChosen") } }
    var demoBookAdded: Bool { didSet { ud.set(demoBookAdded, forKey: "demoBookAdded") } }
    var readerGuideShown: Bool { didSet { ud.set(readerGuideShown, forKey: "readerGuideShown") } }
    var webGuideShown: Bool { didSet { ud.set(webGuideShown, forKey: "webGuideShown") } }

    private init() {
        ud.register(defaults: [
            "fontSize": 19, "lineHeight": 1.6, "fontFamily": "Georgia", "pageAnimation": PageAnimation.slide.rawValue,
            "themeIndex": 0, "dayThemeIndex": 0, "texture": "", "followSystemBrightness": true, "brightness": 0.6,
            "tapToLookup": true, "levelHighlightEnabled": true, "vocabHighlightEnabled": true, "highlightLevels": ["CET6", "KaoYan"], "examName": "",
            "hideStoreTab": false, "disableExternalLinks": true, "einkMode": false,
            "speakWhenQuery": true, "speakWhenLearn": true, "accent": PronounceAccent.us.rawValue,
            "enabledDicts": ["builtin"], "enabledWebDicts": AppLanguage.isChinese ? ["youdao"] : ["wiktionary"], "targetLanguage": TranslateLanguage.deviceDefault,
            "pinnedSourceId": "",
        ])
        fontSize = ud.integer(forKey: "fontSize")
        lineHeight = ud.double(forKey: "lineHeight")
        fontFamily = ud.string(forKey: "fontFamily") ?? "Georgia"
        pageAnimation = PageAnimation(rawValue: ud.string(forKey: "pageAnimation") ?? "") ?? .slide
        themeIndex = ud.integer(forKey: "themeIndex")
        dayThemeIndex = ud.integer(forKey: "dayThemeIndex")
        texture = ud.string(forKey: "texture") ?? ""
        followSystemBrightness = ud.bool(forKey: "followSystemBrightness")
        brightness = ud.double(forKey: "brightness")
        tapToLookup = ud.bool(forKey: "tapToLookup")
        levelHighlightEnabled = ud.bool(forKey: "levelHighlightEnabled")
        vocabHighlightEnabled = ud.bool(forKey: "vocabHighlightEnabled")
        var levels = ud.stringArray(forKey: "highlightLevels") ?? []
        if ud.integer(forKey: "levelsVersion") < 3 {
            if !levels.contains(where: { $0.hasPrefix("CEFR_") }) { levels.append("CEFR_B2") }
            // init 中赋值不会触发 didSet, 迁移结果需要显式保存
            ud.set(levels, forKey: "highlightLevels")
            ud.set(3, forKey: "levelsVersion")
        }
        highlightLevels = levels
        levelColors = (ud.dictionary(forKey: "levelColors") as? [String: String]) ?? [:]
        examName = ud.string(forKey: "examName") ?? ""
        if ud.integer(forKey: "tabsVersion") < 2 {
            // 新增多媒体 Tab 后, 书库移到推荐页入口
            ud.set(true, forKey: "hideStoreTab")
            ud.set(2, forKey: "tabsVersion")
        }
        hideStoreTab = ud.bool(forKey: "hideStoreTab")
        disableExternalLinks = ud.bool(forKey: "disableExternalLinks")
        einkMode = ud.bool(forKey: "einkMode")
        speakWhenQuery = ud.bool(forKey: "speakWhenQuery")
        speakWhenLearn = ud.bool(forKey: "speakWhenLearn")
        accent = PronounceAccent(rawValue: ud.string(forKey: "accent") ?? "") ?? .us
        var dicts = ud.stringArray(forKey: "enabledDicts") ?? ["builtin"]
        var webDicts = ud.stringArray(forKey: "enabledWebDicts") ?? []
        // 新增的多语种内置词典、网页词典默认启用
        if ud.integer(forKey: "dictsVersion") < 3 {
            for id in DictionaryManager.defaultEnabledIds where !dicts.contains(id) { dicts.append(id) }
            for w in DictionaryManager.webDicts where w.lang != "en" && !webDicts.contains(w.id) { webDicts.append(w.id) }
            ud.set(dicts, forKey: "enabledDicts")
            ud.set(webDicts, forKey: "enabledWebDicts")
            ud.set(3, forKey: "dictsVersion")
        }
        enabledDicts = dicts
        enabledWebDicts = webDicts
        targetLanguage = ud.string(forKey: "targetLanguage") ?? TranslateLanguage.deviceDefault
        bookLanguages = (ud.dictionary(forKey: "bookLanguages") as? [String: String]) ?? [:]
        var sources: [BookSource] = Self.loadJSON("bookSources", ud) ?? Self.defaultSources()
        // 默认图书源更新: 移除已失效的地址, 补充新的默认源
        if ud.integer(forKey: "sourcesVersion") < 4 {
            sources.removeAll { $0.url.contains("feedbooks.com/publicdomain") }
            for d in Self.defaultSources() where !sources.contains(where: { $0.url == d.url }) { sources.append(d) }
            if let data = try? JSONEncoder().encode(sources) { ud.set(data, forKey: "bookSources") }
            ud.set(4, forKey: "sourcesVersion")
        }
        bookSources = sources
        pinnedSourceId = ud.string(forKey: "pinnedSourceId") ?? ""
        websites = Self.loadJSON("websites", ud) ?? Self.defaultWebsites
        agreedPolicy = ud.bool(forKey: "agreedPolicy")
        examChosen = ud.bool(forKey: "examChosen")
        demoBookAdded = ud.bool(forKey: "demoBookAdded")
        readerGuideShown = ud.bool(forKey: "readerGuideShown")
        webGuideShown = ud.bool(forKey: "webGuideShown")
    }

    var theme: ReaderTheme {
        if einkMode { return ReaderTheme(id: 0, background: "#FFFFFF", text: "#000000") }
        return ReaderTheme.all[min(max(themeIndex, 0), ReaderTheme.all.count - 1)]
    }

    var isNight: Bool { themeIndex == ReaderTheme.nightIndex && !einkMode }

    func toggleNight() {
        if isNight {
            themeIndex = dayThemeIndex
        } else {
            dayThemeIndex = themeIndex
            themeIndex = ReaderTheme.nightIndex
        }
    }

    func bookLanguage(_ bookId: String) -> String { bookLanguages[bookId] ?? "en" }

    // MARK: JSON
    private func saveJSON<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { ud.set(d, forKey: key) }
    }

    private static func loadJSON<T: Decodable>(_ key: String, _ ud: UserDefaults) -> T? {
        guard let d = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private static func defaultSources() -> [BookSource] {
        struct Raw: Decodable { let type: String; let name: String; let url: String; let iconUrl: String?; let desc: String? }
        guard let url = Paths.bundled("default_libraries.json"), let d = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: d) else { return [] }
        // 名称和简介按界面语言本地化 (翻译在 Localizable.xcstrings 中)
        let loc = { (s: String) in Bundle.main.localizedString(forKey: s, value: s, table: nil) }
        return raw.map { BookSource(type: BookSource.Kind(rawValue: $0.type) ?? .opds, name: loc($0.name), url: $0.url, iconUrl: $0.iconUrl ?? "", desc: loc($0.desc ?? "")) }
    }

    static let defaultWebsites: [Website] = [
        Website(title: "VOA Learning English", url: "https://learningenglish.voanews.com/"),
        Website(title: "BBC News", url: "https://www.bbc.com/news"),
        Website(title: "The Guardian", url: "https://www.theguardian.com/international"),
        Website(title: "NPR", url: "https://text.npr.org/"),
        Website(title: "Wikipedia", url: "https://en.m.wikipedia.org/"),
    ]
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if s.count == 6 { s = "FF" + s }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: Double((v >> 24) & 0xFF) / 255)
    }

    static let accentGreen = Color(hex: "#71C951")
    static let menuBackground = Color(hex: "#131313").opacity(0.97)
    static let menuText = Color(hex: "#999999")
    static let menuSelected = Color(hex: "#C54A44")
}
