import UIKit
import WebKit
import Observation

/// 屏蔽系统长按菜单, 选中文本后由 App 自己的面板处理 (划线/笔记/字典/翻译/拷贝)
final class ReaderWebView: WKWebView {
    var suppressMenu = true

    override func buildMenu(with builder: UIMenuBuilder) {
        if suppressMenu {
            for m: UIMenu.Identifier in [.lookup, .share, .standardEdit, .replace, .learn, .speech, .format, .textStyle, .writingDirection, .spelling, .substitutions, .transformations, .preferences] {
                builder.remove(menu: m)
            }
        }
        super.buildMenu(with: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        suppressMenu ? false : super.canPerformAction(action, withSender: sender)
    }
}

enum ReaderTapZone { case previous, menu, next }

struct WordTap {
    let word: String
    let sentence: String
    let level: String
}

struct TextSelection: Equatable {
    let text: String
    let sentence: String
    let start: Int
    let end: Int
    let rect: CGRect
}

/// 章节内要跳转的位置
enum ChapterTarget {
    case start, end
    case fraction(Double)
    case fragment(String)
    case offset(Int)
    case search(String)
}

/// 生成阅读页面样式
enum ReaderStyle {
    static let fonts: [(name: String, css: String)] = [
        ("Default", "Georgia, 'Times New Roman', serif"),
        ("Times", "'Times New Roman', Times, serif"),
        ("Palatino", "Palatino, 'Book Antiqua', serif"),
        ("Baskerville", "Baskerville, serif"),
        ("Helvetica", "'Helvetica Neue', Helvetica, sans-serif"),
        ("Avenir", "'Avenir Next', Avenir, sans-serif"),
        ("PingFang", "-apple-system, 'PingFang SC', sans-serif"),
        ("Songti", "'Songti SC', serif"),
    ]

    static func fontCSS(_ name: String) -> String {
        fonts.first { $0.name == name }?.css ?? fonts.first { $0.css.contains(name) }?.css ?? fonts[0].css
    }

    static let vocabCode = "VOCAB"
    static let defaultVocabColor = "#FF6D00"

    static func levelCSS(night: Bool, enabled: Bool, lang: String) -> String {
        let s = AppSettings.shared
        var css = ""
        if enabled {
            css = LevelWordDB.shared(lang).levels.map { lv in
                let c = s.levelColors[lv.code] ?? (night ? lv.nightColor : lv.dayColor)
                return "body span.erl-\(lv.code){color:\(c)!important;}"
            }.joined(separator: "\n")
        }
        if s.vocabHighlightEnabled {
            // 生词: 下划线 + 淡底色, 与分级词汇的文字颜色区分
            let c = s.levelColors[vocabCode] ?? defaultVocabColor
            css += "\nbody span.erl-\(vocabCode){color:inherit!important;background-color:\(c)26!important;border-bottom:2px solid \(c)!important;border-radius:2px;}"
        }
        return css
    }

    static let highlightCSS = """
    body span.erhl-yellow{background-color:#FFEB6B!important;color:#222!important}
    body span.erhl-green{background-color:#C0ED72!important;color:#222!important}
    body span.erhl-blue{background-color:#ADD8FF!important;color:#222!important}
    body span.erhl-pink{background-color:#FFB0CA!important;color:#222!important}
    body span.erhl-underline{border-bottom:2px solid #C54A44!important}
    """

    static func css(paginate: Bool, lang: String) -> String {
        let s = AppSettings.shared
        let t = s.theme
        let margin = 22
        let pagination = paginate ? """
        :root{height:100vh!important;width:100vw!important;max-width:none!important;box-sizing:border-box!important;
          margin:0!important;padding:26px \(margin)px 34px \(margin)px!important;
          column-width:calc(100vw - \(margin * 2)px)!important;column-gap:\(margin * 2)px!important;column-fill:auto!important;
          overflow:hidden!important;-webkit-text-size-adjust:none;}
        body{margin:0!important;padding:0!important;height:auto!important;width:auto!important;max-width:none!important;}
        img,svg,video{max-width:100%!important;max-height:calc(100vh - 80px)!important;object-fit:contain;break-inside:avoid;}
        @media (min-width: 700px) {
          :root{padding:36px 48px 44px 48px!important;column-width:calc((100vw - 192px) / 2)!important;column-gap:96px!important;}
        }
        p,blockquote{orphans:2;widows:2;}
        """ : ""
        return """
        \(pagination)
        html{background:transparent!important;}
        body{background:transparent!important;color:\(t.text)!important;font-size:\(s.fontSize)px!important;
          line-height:\(s.lineHeight)!important;font-family:\(fontCSS(s.fontFamily))!important;text-align:justify;}
        body *:not(img):not(svg):not(code):not(pre){color:inherit!important;background-color:transparent!important;font-family:inherit!important;}
        body p, body div, body li, body blockquote, body span{line-height:inherit!important;}
        a{text-decoration:none!important;}
        ::selection{background:rgba(113,201,81,0.35);}
        \(levelCSS(night: s.isNight, enabled: s.levelHighlightEnabled, lang: lang))
        \(highlightCSS)
        """
    }
}

/// 阅读引擎: 管理 WKWebView、分页、翻页动画、阅读进度
@Observable
final class ReaderEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let document: ReaderDocument
    var chapterIndex = 0
    var page = 0
    var pageCount = 1
    var isReady = false
    /// 各章页数 (实测或估算), 用于全书页码
    var chapterPageCounts: [Int] = []
    @ObservationIgnored var measuredPages: [Int: Int] = [:]
    /// 目录锚点所在的章内页码: 章节 -> [锚点: 页]
    @ObservationIgnored var fragmentPages: [Int: [String: Int]] = [:]
    @ObservationIgnored var measuredKey = ""
    @ObservationIgnored var chapterChars: [Int] = []
    @ObservationIgnored var chapterImages: [Int] = []
    @ObservationIgnored var pageCounter: PageCounter?

    @ObservationIgnored var onWordTap: ((WordTap) -> Void)?
    @ObservationIgnored var onSelection: ((TextSelection?) -> Void)?
    @ObservationIgnored var onTapZone: ((ReaderTapZone) -> Void)?
    @ObservationIgnored var onNoteTap: ((String) -> Void)?
    @ObservationIgnored var onSwipeVertical: (() -> Void)?
    @ObservationIgnored var onActivity: (() -> Void)?
    /// 双指捏合: 状态 + 缩放比例
    @ObservationIgnored var onPinch: ((UIGestureRecognizer.State, CGFloat) -> Void)?

    @ObservationIgnored let container = ReaderContainerView()
    @ObservationIgnored private(set) var webView: ReaderWebView!
    @ObservationIgnored private var pendingTarget: ChapterTarget = .start
    @ObservationIgnored private var pendingCompletion: (() -> Void)?
    @ObservationIgnored private var levelMapCache: [Int: [String: String]] = [:]

    var lang: String { AppSettings.shared.bookLanguages[document.book.id] ?? document.language }
    var chapterTitle: String { document.chapters[safe: chapterIndex]?.title ?? document.book.name }

    init(document: ReaderDocument) {
        self.document = document
        super.init()
        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(WeakMessageHandler(self), name: "er")
        for name in ["sentence", "vreading"] {
            if let url = Paths.webBundle.appendingPathComponent("web/\(name).js") as URL?,
               let js = try? String(contentsOf: url, encoding: .utf8) {
                uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        // 尽早设置 viewport, 避免以 980px 宽度排版
        let viewport = "(function(){function f(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.setAttribute('name','viewport');(document.head||document.documentElement).appendChild(m);}m.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');}if(document.documentElement){f();}document.addEventListener('DOMContentLoaded',f);})();"
        uc.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = uc
        config.dataDetectorTypes = []
        webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.bounces = false
        webView.alpha = 0
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for dir: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            g.delegate = self
            webView.addGestureRecognizer(g)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        webView.addGestureRecognizer(pinch)
        prepareChapterStats()
        // iPad 旋转 / 分屏改变尺寸后重新分页, 保持阅读位置
        container.onResize = { [weak self] in
            guard let self, self.isReady else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.applyStyle() }
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        onPinch?(g.state, g.scale)
    }

    // MARK: 位置
    private var positionKey: String { "pos_\(document.book.id)" }

    func restorePosition() {
        let saved = UserDefaults.standard.string(forKey: positionKey) ?? ""
        let parts = saved.split(separator: "|")
        let ch = Int(parts.first ?? "") ?? 0
        let frac = Double(parts.dropFirst().first ?? "") ?? 0
        load(chapter: min(max(ch, 0), document.chapters.count - 1), target: .fraction(frac))
    }

    var chapterFraction: Double { pageCount > 1 ? Double(page) / Double(pageCount) : 0 }

    var bookProgress: Double {
        guard !document.chapters.isEmpty else { return 0 }
        if !chapterPageCounts.isEmpty, bookPageTotal > 0 {
            return Double(bookPage) / Double(bookPageTotal)
        }
        return (Double(chapterIndex) + chapterFraction) / Double(document.chapters.count)
    }

    func savePosition() {
        UserDefaults.standard.set("\(chapterIndex)|\(chapterFraction)", forKey: positionKey)
        guard isReady else { return }
        let atEnd = page + 1 >= pageCount && chapterIndex + 1 >= document.chapters.count
        AppDatabase.shared.setProgress(atEnd ? 1 : bookProgress, for: document.book.id)
        onActivity?()
    }

    // MARK: 加载章节
    func load(chapter: Int, target: ChapterTarget, completion: (() -> Void)? = nil) {
        guard document.chapters.indices.contains(chapter) else { completion?(); return }
        chapterIndex = chapter
        pendingTarget = target
        pendingCompletion = completion
        isReady = false
        webView.alpha = completion == nil ? 0 : 1
        onSelection?(nil)
        webView.loadFileURL(document.chapters[chapter].url, allowingReadAccessTo: document.rootDir)
    }

    /// 生词本中当前语言的单词 (主线程调用)
    func vocabularySet() -> Set<String> {
        guard AppSettings.shared.vocabHighlightEnabled else { return [] }
        let l = lang
        return Set(VocabStore.shared.strangeWords.filter { $0.lang == l || $0.lang.isEmpty }.map { $0.word.lowercased() })
    }

    private func isVocab(_ w: String, _ vocab: Set<String>) -> Bool {
        if vocab.contains(w) { return true }
        switch lang {
        case "en": return Lemmatizer.candidates(w).contains { vocab.contains($0) }
        case "fr": return Lemmatizer.frenchCandidates(w).contains { vocab.contains($0) }
        default: return false
        }
    }

    private func levelMap(for chapter: Int, vocab: Set<String>) -> [String: String] {
        let s = AppSettings.shared
        let levelsOn = s.levelHighlightEnabled && !s.highlightLevels.isEmpty
        guard levelsOn || !vocab.isEmpty else { return [:] }
        if let m = levelMapCache[chapter] { return m }
        let db = LevelWordDB.shared(lang)
        let codes = Set(s.highlightLevels)
        var map: [String: String] = [:]
        let text = document.plainText(of: chapter)
        let re = try? NSRegularExpression(pattern: "[A-Za-z\\u00C0-\\u024F][A-Za-z\\u00C0-\\u024F'’-]*")
        var seen = Set<String>()
        re?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
            guard let m, let r = Range(m.range, in: text) else { return }
            let w = text[r].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            guard w.count >= 2, !seen.contains(w) else { return }
            seen.insert(w)
            if !vocab.isEmpty, self.isVocab(w, vocab) {
                map[w] = ReaderStyle.vocabCode
                return
            }
            guard levelsOn, w.count >= db.minChars else { return }
            if let info = db.info(w), let lv = db.levelPriority(info.levels).first(where: { codes.contains($0) }) {
                map[w] = lv
            }
        }
        levelMapCache[chapter] = map
        return map
    }

    func invalidateLevelCache() { levelMapCache.removeAll() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let chapter = chapterIndex
        let notes = AppDatabase.shared.notes(bookId: document.book.id, chapter: chapter)
        let vocab = vocabularySet()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let map = self.levelMap(for: chapter, vocab: vocab)
            DispatchQueue.main.async { self.setupPage(levelMap: map, notes: notes) }
        }
    }

    private func setupPage(levelMap: [String: String], notes: [NoteItem]) {
        let s = AppSettings.shared
        let opts: [String: Any] = [
            "paginate": true,
            "lang": lang,
            "clickable": s.tapToLookup,
            "blockLinks": false,
            "levelMap": levelMap,
            "css": ReaderStyle.css(paginate: true, lang: lang),
            "notes": notes.map { ["id": $0.id, "start": $0.start, "end": $0.end, "color": $0.color] },
        ]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: opts)) ?? Data(), encoding: .utf8) ?? "{}"
        webView.evaluateJavaScript("ER.setup(\(json))") { [weak self] result, _ in
            guard let self else { return }
            self.pageCount = ((result as? [String: Any])?["count"] as? Int) ?? 1
            self.resolveTarget()
        }
    }

    private func resolveTarget() {
        let finish: (Int) -> Void = { [weak self] p in
            guard let self else { return }
            self.goTo(page: p) {
                self.isReady = true
                self.recordCurrentChapterPages()
                UIView.animate(withDuration: 0.15) { self.webView.alpha = 1 }
                self.savePosition()
                AppDatabase.shared.touch(self.document.book.id)
                let c = self.pendingCompletion
                self.pendingCompletion = nil
                c?()
            }
        }
        switch pendingTarget {
        case .start: finish(0)
        case .end: finish(pageCount - 1)
        case .fraction(let f): finish(Int((f * Double(pageCount)).rounded(.down)))
        case .fragment(let id):
            webView.evaluateJavaScript("ER.pageOfFragment(\(id.jsLiteral))") { r, _ in finish((r as? Int) ?? 0) }
        case .offset(let o):
            webView.evaluateJavaScript("ER.pageOfOffset(\(o))") { r, _ in finish((r as? Int) ?? 0) }
        case .search(let q):
            webView.evaluateJavaScript("ER.find(\(q.jsLiteral))") { r, _ in finish(max(0, (r as? Int) ?? 0)) }
        }
    }

    private func goTo(page p: Int, completion: (() -> Void)? = nil) {
        webView.evaluateJavaScript("ER.goToPage(\(p))") { [weak self] r, _ in
            guard let self else { return }
            if let d = r as? [String: Any] {
                self.page = d["page"] as? Int ?? p
                self.pageCount = d["count"] as? Int ?? self.pageCount
            }
            self.savePosition()
            completion?()
        }
    }

    // MARK: 翻页
    func nextPage() {
        onSelection?(nil)
        if page + 1 < pageCount {
            animate(forward: true) { done in self.goTo(page: self.page + 1, completion: done) }
        } else if chapterIndex + 1 < document.chapters.count {
            animate(forward: true) { done in self.load(chapter: self.chapterIndex + 1, target: .start, completion: done) }
        }
    }

    func previousPage() {
        onSelection?(nil)
        if page > 0 {
            animate(forward: false) { done in self.goTo(page: self.page - 1, completion: done) }
        } else if chapterIndex > 0 {
            animate(forward: false) { done in self.load(chapter: self.chapterIndex - 1, target: .end, completion: done) }
        }
    }

    var isAtBookEnd: Bool { page + 1 >= pageCount && chapterIndex + 1 >= document.chapters.count }

    func jump(chapter: Int, target: ChapterTarget = .start) {
        load(chapter: chapter, target: target)
    }

    /// 截图覆盖 + 动画实现 覆盖/滑动/仿真 翻页效果
    private func animate(forward: Bool, change: @escaping (@escaping () -> Void) -> Void) {
        let s = AppSettings.shared
        let anim: PageAnimation = s.einkMode ? .none : s.pageAnimation
        guard anim != .none, let snap = webView.snapshotView(afterScreenUpdates: false) else {
            change {}
            return
        }
        snap.frame = webView.frame
        snap.backgroundColor = UIColor(hexString: s.theme.background)
        container.addSubview(snap)
        let w = container.bounds.width
        change { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                switch anim {
                case .slide:
                    self.webView.transform = CGAffineTransform(translationX: forward ? w : -w, y: 0)
                    UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) {
                        snap.transform = CGAffineTransform(translationX: forward ? -w : w, y: 0)
                        self.webView.transform = .identity
                    } completion: { _ in snap.removeFromSuperview() }
                case .cover:
                    if forward {
                        snap.layer.shadowOpacity = 0.3
                        snap.layer.shadowRadius = 8
                        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                            snap.transform = CGAffineTransform(translationX: -w, y: 0)
                        } completion: { _ in snap.removeFromSuperview() }
                    } else {
                        self.container.insertSubview(snap, belowSubview: self.webView)
                        self.webView.transform = CGAffineTransform(translationX: -w, y: 0)
                        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                            self.webView.transform = .identity
                        } completion: { _ in snap.removeFromSuperview() }
                    }
                case .curl:
                    UIView.transition(with: self.container, duration: 0.5,
                                      options: forward ? .transitionCurlUp : .transitionCurlDown) {
                        snap.removeFromSuperview()
                    }
                case .none:
                    snap.removeFromSuperview()
                }
            }
        }
    }

    // MARK: 样式变更
    func applyStyle(keepPosition: Bool = true) {
        let frac = chapterFraction
        let css = ReaderStyle.css(paginate: true, lang: lang)
        webView.evaluateJavaScript("ER.setStyle(\(css.jsLiteral)); ER.setClickable(\(AppSettings.shared.tapToLookup)); ER.pageCount()") { [weak self] r, _ in
            guard let self else { return }
            self.pageCount = (r as? Int) ?? self.pageCount
            self.invalidatePagination()
            self.recordCurrentChapterPages()
            if keepPosition { self.goTo(page: Int((frac * Double(self.pageCount)).rounded(.down))) }
        }
    }

    /// 词汇高亮等级改变后刷新
    func reloadLevels() {
        invalidateLevelCache()
        let chapter = chapterIndex
        let vocab = vocabularySet()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let map = self.levelMap(for: chapter, vocab: vocab)
            let json = String(data: (try? JSONSerialization.data(withJSONObject: map)) ?? Data(), encoding: .utf8) ?? "{}"
            DispatchQueue.main.async {
                // 高亮只改颜色, 不影响排版, 无需重新分页
                let css = ReaderStyle.css(paginate: true, lang: self.lang)
                self.webView.evaluateJavaScript("ER.setLevelMap(\(json)); ER.setStyle(\(css.jsLiteral))")
            }
        }
    }

    func applyNote(_ n: NoteItem) {
        let json = "[{\"id\":\(n.id.jsLiteral),\"start\":\(n.start),\"end\":\(n.end),\"color\":\(n.color.jsLiteral)}]"
        webView.evaluateJavaScript("ER.clearSelection(); ER.applyNotes(\(json))")
    }

    func removeNote(_ id: String) { webView.evaluateJavaScript("ER.removeNote(\(id.jsLiteral))") }
    func setNoteColor(_ id: String, _ color: String) { webView.evaluateJavaScript("ER.setNoteColor(\(id.jsLiteral), \(color.jsLiteral))") }
    func clearSelection() { webView.evaluateJavaScript("ER.clearSelection()") }

    func pageInfo(_ completion: @escaping (Int, String) -> Void) {
        webView.evaluateJavaScript("ER.pageInfo()") { r, _ in
            let d = r as? [String: Any]
            completion(d?["offset"] as? Int ?? 0, d?["text"] as? String ?? "")
        }
    }

    // MARK: JS 消息
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let type = d["type"] as? String else { return }
        #if DEBUG
        print("JSMSG", type, d["word"] ?? "")
        #endif
        switch type {
        case "word":
            onWordTap?(WordTap(word: d["word"] as? String ?? "", sentence: d["sentence"] as? String ?? "", level: d["level"] as? String ?? ""))
        case "selection":
            let text = d["text"] as? String ?? ""
            if text.isEmpty {
                onSelection?(nil)
            } else {
                let rect = CGRect(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0, width: d["w"] as? Double ?? 0, height: d["h"] as? Double ?? 0)
                onSelection?(TextSelection(text: text, sentence: d["sentence"] as? String ?? text,
                                           start: d["start"] as? Int ?? 0, end: d["end"] as? Int ?? 0, rect: rect))
            }
        case "tap":
            let x = d["x"] as? Double ?? 0, w = max(d["w"] as? Double ?? 1, 1)
            onTapZone?(x < w / 3 ? .previous : (x > w * 2 / 3 ? .next : .menu))
        case "note":
            if let id = d["id"] as? String { onNoteTap?(id) }
        case "pages":
            pageCount = d["count"] as? Int ?? pageCount
            if isReady { recordCurrentChapterPages() }
        default: break
        }
    }

    // 书内链接 (脚注、目录) 跳转到对应章节; 外部链接按设置处理
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            if let idx = document.chapters.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
                if let frag = url.fragment, idx == chapterIndex {
                    webView.evaluateJavaScript("ER.pageOfFragment(\(frag.jsLiteral))") { [weak self] r, _ in self?.goTo(page: (r as? Int) ?? 0) }
                } else {
                    load(chapter: idx, target: url.fragment.map { .fragment($0) } ?? .start)
                }
            }
        } else if !AppSettings.shared.disableExternalLinks {
            UIApplication.shared.open(url)
        }
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        switch g.direction {
        case .left: nextPage()
        case .right: previousPage()
        default: onSwipeVertical?()
        }
    }
}

extension ReaderEngine: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// 阅读页容器: 尺寸变化时通知重新分页
final class ReaderContainerView: UIView {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        let old = lastSize
        lastSize = bounds.size
        if old != .zero { onResize?() }
    }
}

/// 避免 WKUserContentController 强引用导致循环引用
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

extension String {
    /// 作为 JS 字符串字面量
    var jsLiteral: String {
        let d = (try? JSONSerialization.data(withJSONObject: [self])) ?? Data()
        let s = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension UIColor {
    convenience init(hexString: String) {
        var s = hexString.replacingOccurrences(of: "#", with: "")
        if s.count == 6 { s = "FF" + s }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: CGFloat((v >> 24) & 0xFF) / 255)
    }
}
