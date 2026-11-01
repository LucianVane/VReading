import UIKit
import WebKit

/// 后台逐章排版统计页数 (隐藏的 WKWebView, 与阅读页相同尺寸和样式)
final class PageCounter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let document: ReaderDocument
    private let css: String
    private var queue: [Int]
    private var current: Int?
    private let onResult: (Int, Int, [String: Int]) -> Void

    init(container: UIView, frame: CGRect, document: ReaderDocument, css: String, chapters: [Int], onResult: @escaping (Int, Int, [String: Int]) -> Void) {
        self.document = document
        self.css = css
        self.queue = chapters
        self.onResult = onResult
        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        let viewport = "(function(){function f(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.setAttribute('name','viewport');(document.head||document.documentElement).appendChild(m);}m.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');}if(document.documentElement){f();}document.addEventListener('DOMContentLoaded',f);})();"
        uc.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let js = try? String(contentsOf: Paths.webBundle.appendingPathComponent("web/vreading.js"), encoding: .utf8) {
            uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        config.userContentController = uc
        // 放在容器可视区域之外 (容器裁剪), 不会透到透明的阅读页上
        webView = WKWebView(frame: frame.offsetBy(dx: frame.width * 3, dy: 0), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        container.clipsToBounds = true
        container.insertSubview(webView, at: 0)
    }

    func start() { next() }

    func cancel() {
        queue = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    private func next() {
        guard let i = queue.first, document.chapters.indices.contains(i) else {
            webView.removeFromSuperview()
            return
        }
        queue.removeFirst()
        current = i
        webView.loadFileURL(document.chapters[i].url, allowingReadAccessTo: document.rootDir)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let i = current else { return }
        let js = "ER.fixViewport(); ER.setStyle(\(css.jsLiteral)); " + Self.measureJS(document.tocFragments(in: i))
        // 等图片和样式生效
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            webView.evaluateJavaScript(js) { r, _ in
                if let d = r as? [String: Any], let n = d["count"] as? Int {
                    self.onResult(i, n, d["frags"] as? [String: Int] ?? [:])
                }
                self.next()
            }
        }
    }

    /// 统计页数以及目录锚点所在页
    static func measureJS(_ frags: [String]) -> String {
        let list = String(data: (try? JSONSerialization.data(withJSONObject: frags)) ?? Data(), encoding: .utf8) ?? "[]"
        return "(function(){var f={};\(list).forEach(function(id){f[id]=ER.pageOfFragment(id);});return {count:ER.pageCount(),frags:f};})()"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { next() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { next() }
}

/// 全书页码: 已排版的章节用真实页数, 其余按字数估算
extension ReaderEngine {
    var layoutKey: String {
        let s = AppSettings.shared
        return "\(s.fontSize)|\(s.lineHeight)|\(s.fontFamily)|\(Int(webView.bounds.width))x\(Int(webView.bounds.height))"
    }

    private var pagesStoreKey: String { "bookpages_\(document.book.id)" }

    /// 统计各章字数和图片数 (后台)
    func prepareChapterStats() {
        let doc = document
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var chars: [Int] = [], images: [Int] = []
            for i in doc.chapters.indices {
                chars.append(doc.plainText(of: i).count)
                let raw = (try? String(contentsOf: doc.chapters[i].url, encoding: .utf8)) ?? ""
                images.append(raw.components(separatedBy: "<img").count - 1 + raw.components(separatedBy: "<image").count - 1)
            }
            DispatchQueue.main.async {
                self?.chapterChars = chars
                self?.chapterImages = images
                self?.recomputeBookPages()
            }
        }
    }

    /// 当前章节排版完成后调用
    func recordCurrentChapterPages() {
        let key = layoutKey
        if key != measuredKey {
            loadMeasured(for: key)
        }
        measuredPages[chapterIndex] = pageCount
        let ch = chapterIndex
        let frags = document.tocFragments(in: ch)
        if !frags.isEmpty {
            webView.evaluateJavaScript(PageCounter.measureJS(frags)) { [weak self] r, _ in
                guard let self, let d = r as? [String: Any], let f = d["frags"] as? [String: Int] else { return }
                self.fragmentPages[ch] = f
                self.saveMeasured()
                self.recomputeBookPages()
            }
        }
        saveMeasured()
        recomputeBookPages()
        startPageCounterIfNeeded()
    }

    private func loadMeasured(for key: String) {
        measuredKey = key
        measuredPages = [:]
        fragmentPages = [:]
        if let d = UserDefaults.standard.dictionary(forKey: pagesStoreKey), d["key"] as? String == key, d["v"] as? Int == 2,
           let pages = d["pages"] as? [String: Int] {
            for (k, v) in pages { if let i = Int(k) { measuredPages[i] = v } }
            for (k, v) in (d["frags"] as? [String: [String: Int]]) ?? [:] { if let i = Int(k) { fragmentPages[i] = v } }
        }
        pageCounter?.cancel()
        pageCounter = nil
    }

    private func saveMeasured() {
        let pages = Dictionary(uniqueKeysWithValues: measuredPages.map { (String($0.key), $0.value) })
        let frags = Dictionary(uniqueKeysWithValues: fragmentPages.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(["v": 2, "key": measuredKey, "pages": pages, "frags": frags], forKey: pagesStoreKey)
    }

    /// 排版设置变化后重新统计
    func invalidatePagination() {
        pageCounter?.cancel()
        pageCounter = nil
        measuredKey = ""
    }

    func recomputeBookPages() {
        let n = document.chapters.count
        guard n > 0 else { return }
        // 每页字数: 用已排版的正文章节估计
        var chars = 0, pages = 0
        for (i, p) in measuredPages where chapterChars.indices.contains(i) && chapterChars[i] > 300 {
            chars += chapterChars[i]
            pages += p
        }
        let perPage = pages > 0 ? Double(chars) / Double(pages) : 1200
        chapterPageCounts = (0..<n).map { i in
            if let m = measuredPages[i] { return m }
            guard chapterChars.indices.contains(i) else { return 1 }
            let c = chapterChars[i]
            let imgs = chapterImages.indices.contains(i) ? chapterImages[i] : 0
            return max(1, Int((Double(c) / perPage).rounded(.up)) + (c < 300 ? max(0, imgs - 1) : 0))
        }
    }

    private func startPageCounterIfNeeded() {
        guard pageCounter == nil, webView.bounds.width > 0 else { return }
        let todo = document.chapters.indices.filter { measuredPages[$0] == nil }
        guard !todo.isEmpty else { return }
        let key = layoutKey
        let counter = PageCounter(container: container, frame: webView.frame, document: document,
                                  css: ReaderStyle.css(paginate: true, lang: lang), chapters: todo) { [weak self] i, n, frags in
            guard let self, self.measuredKey == key else { return }
            self.measuredPages[i] = n
            if !frags.isEmpty { self.fragmentPages[i] = frags }
            self.saveMeasured()
            self.recomputeBookPages()
        }
        pageCounter = counter
        counter.start()
    }

    /// 目录项在全书中的页码 (从 1 开始)
    func bookPage(for item: TOCItem) -> Int? {
        guard chapterPageCounts.indices.contains(item.chapterIndex) else { return nil }
        var counts = chapterPageCounts
        if counts.indices.contains(chapterIndex) { counts[chapterIndex] = pageCount }
        let start = counts.prefix(item.chapterIndex).reduce(0, +)
        let offset = item.fragment.flatMap { fragmentPages[item.chapterIndex]?[$0] } ?? 0
        return start + max(0, offset) + 1
    }

    /// 全书页码 (从 1 开始)
    var bookPage: Int {
        guard !chapterPageCounts.isEmpty else { return page + 1 }
        return chapterPageCounts.prefix(chapterIndex).reduce(0, +) + min(page, max(pageCount - 1, 0)) + 1
    }

    var bookPageTotal: Int {
        guard !chapterPageCounts.isEmpty else { return pageCount }
        var counts = chapterPageCounts
        if counts.indices.contains(chapterIndex) { counts[chapterIndex] = pageCount }
        return max(counts.reduce(0, +), bookPage)
    }
}
