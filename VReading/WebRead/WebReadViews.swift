import SwiftUI
import WebKit

/// 网页阅读 Tab: 常用英文网站列表
struct WebsiteListView: View {
    /// 嵌入到其他页面的导航栈中时不再创建 NavigationStack
    var embedded = false
    @State private var settings = AppSettings.shared
    @State private var search = ""
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var newURL = ""
    @State private var open: Website?

    private var sites: [Website] {
        search.isEmpty ? settings.websites : settings.websites.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                ForEach(sites) { s in
                    Button { open = s } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: s.iconUrl.isEmpty ? "https://www.google.com/s2/favicons?sz=64&domain=\(URL(string: s.url)?.host ?? "")" : s.iconUrl)) {
                                $0.resizable().scaledToFit()
                            } placeholder: { Image(systemName: "globe").foregroundStyle(Color.accentGreen) }
                            .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).foregroundStyle(.primary)
                                Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { settings.websites.removeAll { $0.id == s.id } } label: { Label("Delete Site", systemImage: "trash") }
                    }
                }
                .onMove { settings.websites.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .overlay { if settings.websites.isEmpty { EmptyStateView(icon: "globe", text: String(localized: "No sites yet")) } }
            .searchable(text: $search, prompt: "Search sites")
            .navigationTitle("Web Reading")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                Button { newTitle = ""; newURL = "https://"; showAdd = true } label: {
                    Image(systemName: "plus").font(.title2.bold()).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Color.accentGreen, in: Circle()).shadow(radius: 4)
                }
                .padding(22)
            }
            .alert("Add Website", isPresented: $showAdd) {
                TextField("Title (optional)", text: $newTitle)
                TextField("URL, starting with http or https", text: $newURL).keyboardType(.URL).textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addSite() }
            } message: { Text("Add websites you read often. Open one to tap words to look them up and translate sentences.") }
            .fullScreenCover(item: $open) { s in WebReaderView(site: s) }
    }

    private func addSite() {
        let u = newURL.trimmingCharacters(in: .whitespaces)
        guard (u.hasPrefix("http://") || u.hasPrefix("https://")), let url = URL(string: u), url.host != nil else { toast(String(localized: "Invalid URL")); return }
        if settings.websites.contains(where: { $0.url == u }) { toast(String(localized: "This site is already in your list")); return }
        settings.websites.append(Website(title: newTitle.isEmpty ? (url.host ?? u) : newTitle, url: u))
    }
}

@Observable
final class WebReaderModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    @ObservationIgnored var webView: ReaderWebView!
    var title = ""
    var progress = 0.0
    var readMode = false
    var canGoBack = false
    var canGoForward = false
    var blockLinks = false
    var currentURL: URL?
    @ObservationIgnored var onWord: ((WordTap) -> Void)?
    @ObservationIgnored var onSelection: ((String, String) -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private static var levelMap: [String: String]?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(WeakMessageHandler(self), name: "er")
        for name in ["sentence", "vreading"] {
            if let js = try? String(contentsOf: Paths.webBundle.appendingPathComponent("web/\(name).js"), encoding: .utf8) {
                uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        config.userContentController = uc
        webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] w, _ in self?.progress = w.estimatedProgress },
            webView.observe(\.title) { [weak self] w, _ in self?.title = w.title ?? "" },
            webView.observe(\.canGoBack) { [weak self] w, _ in self?.canGoBack = w.canGoBack },
            webView.observe(\.canGoForward) { [weak self] w, _ in self?.canGoForward = w.canGoForward },
            webView.observe(\.url) { [weak self] w, _ in self?.currentURL = w.url },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { readMode = false }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        enableReadMode()
    }

    /// 切换到阅读模式: 包裹单词, 单击查词、分级词汇高亮
    func enableReadMode() {
        let s = AppSettings.shared
        let vocab = s.vocabHighlightEnabled ? VocabStore.shared.strangeWords.filter { $0.lang == "en" || $0.lang.isEmpty }.map { $0.word.lowercased() } : []
        DispatchQueue.global(qos: .userInitiated).async {
            if Self.levelMap == nil || !s.levelHighlightEnabled {
                Self.levelMap = s.levelHighlightEnabled ? LevelWordDB.shared("en").words(inLevels: Set(s.highlightLevels)) : [:]
            }
            var map = Self.levelMap ?? [:]
            for w in vocab { map[w] = ReaderStyle.vocabCode }
            let mapJSON = String(data: (try? JSONSerialization.data(withJSONObject: map)) ?? Data(), encoding: .utf8) ?? "{}"
            let css = ReaderStyle.levelCSS(night: false, enabled: s.levelHighlightEnabled, lang: "en")
                + "\n::selection{background:rgba(113,201,81,0.35);}"
            let opts = "{paginate:false, clickable:true, blockLinks:\(self.blockLinks), levelMap:\(mapJSON), css:\(css.jsLiteral)}"
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript("ER.setup(\(opts)); true") { r, _ in
                    self.readMode = (r as? Bool) == true
                }
            }
        }
    }

    static func resetLevelCache() { levelMap = nil }

    func toggleMode() {
        if readMode {
            webView.evaluateJavaScript("ER.setClickable(false)")
            readMode = false
        } else {
            webView.evaluateJavaScript("ER.wrapAll(); ER.setClickable(true); true") { [weak self] r, _ in
                if (r as? Bool) == true { self?.readMode = true } else { self?.enableReadMode() }
            }
        }
    }

    func toggleLinks() {
        blockLinks.toggle()
        webView.evaluateJavaScript("ER.setBlockLinks(\(blockLinks))")
        toast(blockLinks ? String(localized: "Links are disabled. Tap the top-right button to enable them.") : String(localized: "Links enabled"))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let type = d["type"] as? String else { return }
        switch type {
        case "word":
            onWord?(WordTap(word: d["word"] as? String ?? "", sentence: d["sentence"] as? String ?? "", level: d["level"] as? String ?? ""))
        case "selection":
            let t = d["text"] as? String ?? ""
            if !t.isEmpty { onSelection?(t, d["sentence"] as? String ?? t) }
        default: break
        }
    }
}

struct WebReaderView: View {
    let site: Website
    @Environment(\.dismiss) private var dismiss
    @State private var model = WebReaderModel()
    @State private var settings = AppSettings.shared
    @State private var query: WordQuery?
    @State private var selection: TextSelection?
    @State private var showGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { favorite() } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star").foregroundStyle(isFavorite ? .orange : .secondary)
                }
                Text(model.title.isEmpty ? site.title : model.title).font(.subheadline).lineLimit(1).frame(maxWidth: .infinity)
                Button { model.toggleLinks() } label: {
                    Image(systemName: model.blockLinks ? "link.badge.plus" : "link").foregroundStyle(model.blockLinks ? Color.red : .secondary)
                }
            }
            .padding(.horizontal, 16).frame(height: 44)
            if model.progress < 1 { ProgressView(value: model.progress).tint(.accentGreen) } else { Divider() }
            ContainerHost(view: model.webView)
            Divider()
            HStack {
                barButton("chevron.left", enabled: model.canGoBack) { model.webView.goBack() }
                barButton("chevron.right", enabled: model.canGoForward) { model.webView.goForward() }
                Button { model.toggleMode() } label: {
                    Image(systemName: model.readMode ? "character.book.closed" : "safari").font(.headline).foregroundStyle(.white)
                        .accessibilityLabel(model.readMode ? Text("Read Mode") : Text("Browse Mode"))
                        .frame(width: 44, height: 44)
                        .background(model.readMode ? Color.accentGreen : Color.red, in: Circle())
                }
                .frame(maxWidth: .infinity)
                barButton("arrow.clockwise", enabled: true) { model.webView.reload() }
                barButton("xmark", enabled: true) { dismiss() }
            }
            .frame(height: 54)
        }
        .onAppear {
            if let u = URL(string: site.url), model.webView.url == nil { model.load(u) }
            model.onWord = { t in
                let q = WordQuery(word: t.word, sentence: t.sentence, bookName: model.title)
                if selection != nil {
                    selection = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { query = q }
                } else {
                    query = q
                }
            }
            model.onSelection = { t, s in
                if query == nil { selection = TextSelection(text: t, sentence: s, start: 0, end: 0, rect: .zero) }
            }
            if !settings.webGuideShown { showGuide = true }
        }
        .sheet(item: $query) { q in WordLookupView(query: q).presentationDetents([.fraction(0.55), .large]) }
        .sheet(item: $selection) { sel in
            SelectionPanel(selection: sel, bookName: model.title, lang: "en", allowNotes: false, onUnderline: {}, onNote: {})
                .presentationDetents([.fraction(0.5), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
        }
        .alert("Web Reading", isPresented: $showGuide) {
            Button("Got It") { settings.webGuideShown = true }
        } message: {
            Text("When the center button is green, tap words to look them up or translate. Red means browse mode, where taps follow links normally. Tap the button to switch modes.")
        }
    }

    private var isFavorite: Bool {
        let u = model.currentURL?.absoluteString ?? site.url
        return settings.websites.contains { $0.url == u }
    }

    private func favorite() {
        guard let u = model.currentURL?.absoluteString else { return }
        if let i = settings.websites.firstIndex(where: { $0.url == u }) {
            settings.websites.remove(at: i)
            toast(String(localized: "Removed from saved"))
        } else {
            settings.websites.append(Website(title: model.title.isEmpty ? u : model.title, url: u))
            toast(String(localized: "Page saved"))
        }
    }

    private func barButton(_ icon: String, enabled: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Image(systemName: icon).font(.title3) }
            .disabled(!enabled)
            .frame(maxWidth: .infinity)
    }
}
