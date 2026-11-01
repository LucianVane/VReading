import SwiftUI
import WebKit

/// 第三方书库 Tab: 图书源列表 (OPDS / WebDav / 网页)
struct BookSourcesView: View {
    @State private var settings = AppSettings.shared
    @State private var showAdd = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(settings.bookSources) { s in
                        NavigationLink(value: s) { SourceRow(source: s, pinned: settings.pinnedSourceId == s.id) }
                            .contextMenu {
                                Button { path.append(s) } label: { Label("Browse Online", systemImage: "safari") }
                                if settings.pinnedSourceId == s.id {
                                    Button { settings.pinnedSourceId = "" } label: { Label("Remove from Tab Bar", systemImage: "pin.slash") }
                                } else {
                                    Button { settings.pinnedSourceId = s.id; toast(String(localized: "\(s.name) now opens by default in the Library")) } label: { Label(String(localized: "Add to Tab Bar"), systemImage: "pin") }
                                }
                                Button(role: .destructive) { settings.bookSources.removeAll { $0.id == s.id } } label: { Label("Delete Source", systemImage: "trash") }
                            }
                    }
                    .onDelete { settings.bookSources.remove(atOffsets: $0) }
                    .onMove { settings.bookSources.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("\(AppInfo.name) does not provide any books. The third-party sources listed here are publicly available on the internet and their availability is not guaranteed. You can add your own OPDS, WebDAV or web sources.\n1. Tap to browse.  2. Long-press to make a source open by default in the Library.")
                }
            }
            .navigationTitle("Book Sources")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BookSource.self) { s in SourceBrowser(source: s) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(isPresented: $showAdd) { AddBookSourceView() }
            .onAppear {
                #if DEBUG
                if DebugAutomation.has("-autoOpenSource"), path.isEmpty, let i = DebugAutomation.args.firstIndex(of: "-autoOpenSource"),
                   let n = Int(DebugAutomation.args[safe: i + 1] ?? ""), let s = settings.bookSources[safe: n] { path.append(s) }
                #endif
                if path.isEmpty, let pinned = settings.bookSources.first(where: { $0.id == settings.pinnedSourceId }) { path.append(pinned) }
            }
        }
    }
}

struct SourceRow: View {
    let source: BookSource
    var pinned = false
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: source.iconUrl)) { img in img.resizable().scaledToFit() } placeholder: {
                Image(systemName: source.type == .webdav ? "externaldrive.connected.to.line.below" : (source.type == .web ? "globe" : "books.vertical"))
                    .font(.title2).foregroundStyle(Color.accentGreen)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(source.name).font(.subheadline.bold()).lineLimit(1)
                    Text(source.type.title).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentGreen.opacity(0.15), in: Capsule())
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                }
                Text(source.desc.isEmpty ? source.url : source.desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct SourceBrowser: View {
    let source: BookSource
    var body: some View {
        switch source.type {
        case .opds:
            if let u = URL(string: source.url) { OPDSBrowserView(source: source, url: u, title: source.name) }
        case .webdav:
            if let u = URL(string: source.url) { WebDAVBrowserView(source: source, url: u, title: source.name) }
        case .web:
            if let u = URL(string: source.url) { WebSourceBrowserView(url: u, title: source.name) }
        }
    }
}

/// 常用 WebDAV 网盘
struct WebDAVPreset: Identifiable, Hashable {
    let name: String
    let url: String
    let tip: String
    var id: String { name }

    static let all: [WebDAVPreset] = [
        WebDAVPreset(name: "Koofr", url: "https://app.koofr.net/dav/Koofr",
                     tip: String(localized: "Koofr (10 GB free): the username is your email; generate an app password in Koofr web → Settings → Passwords.")),
        WebDAVPreset(name: String(localized: "Jianguoyun"), url: "https://dav.jianguoyun.com/dav/",
                     tip: String(localized: "Jianguoyun: the username is your email; generate an app password under Account → Security → Third-party Apps.")),
        WebDAVPreset(name: "InfiniCLOUD", url: String(localized: "https://<your-id>.teracloud.jp/dav/"),
                     tip: String(localized: "InfiniCLOUD (20 GB free): enable Apps Connection in My Page to see the WebDAV URL, username and app password, then replace <your-id> in the URL.")),
        WebDAVPreset(name: "Yandex", url: "https://webdav.yandex.com",
                     tip: String(localized: "Yandex Disk (10 GB free): sign in with an app password generated in Yandex ID.")),
    ]
}

// MARK: 添加图书源
struct AddBookSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var type: BookSource.Kind = .opds
    @State private var name = ""
    @State private var url = ""
    @State private var icon = ""
    @State private var user = ""
    @State private var pwd = ""
    @State private var json = ""
    @State private var checking = false
    @State private var jsonMode = false
    @State private var preset: WebDAVPreset?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $jsonMode) {
                    Text("Single Source").tag(false)
                    Text("Json").tag(true)
                }
                .pickerStyle(.segmented)
                if jsonMode {
                    Section {
                        TextEditor(text: $json).frame(minHeight: 200).font(.footnote.monospaced())
                    } footer: {
                        Text("Note: sources can be added as JSON, an array like [{\"type\":\"opds\",\"name\":\"...\",\"url\":\"https://...\",\"iconUrl\":\"\",\"desc\":\"\"}], where type is opds / webdav / web.")
                    }
                } else {
                    Picker("Source Type", selection: $type) {
                        ForEach(BookSource.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if type == .webdav {
                        Section("Cloud Drive") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(WebDAVPreset.all) { p in
                                        Button(p.name) {
                                            preset = p
                                            url = p.url
                                            if name.isEmpty || WebDAVPreset.all.contains(where: { $0.name == name }) { name = p.name }
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(preset == p ? .accentGreen : .gray)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        TextField(type == .webdav ? "WebDAV server name (optional)" : "Source name (optional)", text: $name)
                        TextField(type == .webdav ? "WebDAV server URL" : "Source URL", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if type != .webdav {
                            TextField("Icon URL (optional)", text: $icon).keyboardType(.URL).textInputAutocapitalization(.never)
                        }
                        if type != .web {
                            TextField(type == .webdav ? "WebDAV username" : "Username (optional)", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(type == .webdav ? "WebDAV password" : "Password (optional)", text: $pwd)
                        }
                    } footer: {
                        switch type {
                        case .opds: Text("Note: if the OPDS catalog requires authentication, enter a username and password.")
                        case .webdav: Text(preset?.tip ?? String(localized: "Recommended WebDAV drives: Koofr (10 GB), Jianguoyun, InfiniCLOUD (20 GB), Yandex (10 GB). Store your own books there and download them over WebDAV."))
                        case .web: Text("Note: web sources only support downloading EPUB and PDF files.")
                        }
                    }
                }
            }
            .navigationTitle("Add Book Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if checking { ProgressView() } else { Button("Add") { Task { await add() } } }
                }
            }
        }
    }

    private func add() async {
        if jsonMode {
            struct Raw: Decodable { let type: String?; let name: String; let url: String; let iconUrl: String?; let desc: String? }
            guard let d = json.data(using: .utf8), let arr = (try? JSONDecoder().decode([Raw].self, from: d)) ?? (try? JSONDecoder().decode(Raw.self, from: d)).map({ [$0] }) else {
                toast(String(localized: "Invalid source configuration. Please check the format."))
                return
            }
            settings.bookSources += arr.map { BookSource(type: BookSource.Kind(rawValue: $0.type ?? "opds") ?? .opds, name: $0.name, url: $0.url, iconUrl: $0.iconUrl ?? "", desc: $0.desc ?? "") }
            toast(String(localized: "Source added"))
            dismiss()
            return
        }
        let u = url.trimmingCharacters(in: .whitespaces)
        guard u.hasPrefix("http://") || u.hasPrefix("https://"), let link = URL(string: u) else {
            toast(String(localized: "Enter a URL starting with http:// or https://"))
            return
        }
        var s = BookSource(type: type, name: name.isEmpty ? (link.host ?? u) : name, url: u, iconUrl: icon, username: user, password: pwd)
        checking = true
        defer { checking = false }
        do {
            switch type {
            case .opds:
                let feed = try await OPDSClient.fetch(link, source: s)
                if name.isEmpty, !feed.title.isEmpty { s.name = feed.title }
                toast(String(localized: "Added OPDS source: \(s.name)"))
            case .webdav:
                _ = try await WebDAVClient.list(link, source: s)
                toast(String(localized: "Connected to WebDAV server"))
            case .web:
                toast(String(localized: "Source added"))
            }
            settings.bookSources.append(s)
            dismiss()
        } catch OPDSClient.FetchError.unauthorized {
            toast(String(localized: "Enter a username and password to access this source"))
        } catch {
            toast(String(localized: "Failed to add source: \(error.localizedDescription)"))
        }
    }
}

// MARK: OPDS 浏览
struct OPDSBrowserView: View {
    let source: BookSource
    let url: URL
    let title: String
    @State private var feed: OPDSFeed?
    @State private var error: String?
    @State private var loadingMore = false
    @State private var search = ""
    @State private var detail: OPDSEntry?

    var body: some View {
        Group {
            if let feed {
                List {
                    ForEach(feed.entries) { e in
                        if let nav = e.navigation {
                            NavigationLink {
                                OPDSBrowserView(source: source, url: nav.href, title: e.title)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.title).font(.subheadline.bold())
                                    if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                            }
                        } else {
                            Button { detail = e } label: { OPDSEntryRow(entry: e) }.buttonStyle(.plain)
                        }
                    }
                    if feed.next != nil {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .onAppear { Task { await loadMore() } }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if feed.entries.isEmpty {
                        EmptyStateView(icon: "books.vertical", text: feed.searchTemplate != nil ? String(localized: "No books. Search for a title above.") : String(localized: "No books"))
                    }
                }
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }
                }
                .padding()
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle(feed?.title.isEmpty == false ? feed!.title : title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OPDSSearchModifier(enabled: feed?.searchTemplate != nil, text: $search) {
            if let t = feed?.searchTemplate, let u = URL(string: t.replacingOccurrences(of: "{searchTerms}", with: search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search)) {
                Task { await load(u) }
            }
        })
        .task { if feed == nil { await load() } }
        .sheet(item: $detail) { e in OPDSBookDetail(entry: e, source: source) }
    }

    private func load(_ u: URL? = nil) async {
        error = nil
        do { feed = try await OPDSClient.fetch(u ?? url, source: source) }
        catch OPDSClient.FetchError.unauthorized { error = String(localized: "Enter a username and password in the source settings to access it") }
        catch { self.error = String(localized: "Failed to load source\n\(error.localizedDescription)") }
    }

    private func loadMore() async {
        guard !loadingMore, let next = feed?.next else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more = try? await OPDSClient.fetch(next, source: source) {
            feed?.entries += more.entries
            feed?.next = more.next
        } else {
            feed?.next = nil
        }
    }
}

private struct OPDSSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    var onSubmit: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "Search titles").onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

struct OPDSEntryRow: View {
    let entry: OPDSEntry
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: entry.cover) { $0.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                .frame(width: 56, height: 80).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.subheadline.bold()).lineLimit(2)
                if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundStyle(Color.accentGreen) }
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct OPDSBookDetail: View {
    let entry: OPDSEntry
    let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = DownloadManager.shared
    @State private var book: Book?
    @State private var downloading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    AsyncImage(url: entry.cover) { $0.resizable().scaledToFit() } placeholder: { Color(.tertiarySystemFill) }
                        .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 6)).shadow(radius: 4)
                    Text(entry.title).font(.title3.bold()).multilineTextAlignment(.center)
                    if !entry.author.isEmpty { Text(entry.author).foregroundStyle(Color.accentGreen) }
                    if let b = book {
                        Button("Start Reading") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NotificationCenter.default.post(name: .openBook, object: b)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.accentGreen)
                    } else if let link = entry.acquisitions.first {
                        if downloading {
                            ProgressView(value: downloads.progress[link.href] ?? 0).frame(width: 200)
                            Text("Downloading").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button {
                                downloading = true
                                Task {
                                    let ext = link.type.contains("pdf") ? "pdf" : (link.type.contains("text/plain") ? "txt" : "epub")
                                    book = await downloads.downloadAndImport(OPDSClient.request(link.href, source: source), name: "\(entry.title).\(ext)")
                                    downloading = false
                                }
                            } label: {
                                Label("\(link.rel.contains("sample") ? String(localized: "Download Sample") : String(localized: "Download")) (\(link.type.contains("pdf") ? "PDF" : (link.type.contains("text") ? "TXT" : "EPUB")))", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent).tint(.accentGreen)
                        }
                    } else {
                        Text("Only EPUB and PDF books can be downloaded").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(entry.summary).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }
}

// MARK: WebDAV 浏览
struct WebDAVBrowserView: View {
    let source: BookSource
    let url: URL
    let title: String
    @State private var items: [DavResource]?
    @State private var error: String?
    @State private var downloads = DownloadManager.shared
    @State private var done = Set<URL>()

    private static let exts = ["epub", "pdf", "txt", "mdx", "mdd"]

    var body: some View {
        Group {
            if let items {
                List(items) { r in
                    if r.isDirectory {
                        NavigationLink {
                            WebDAVBrowserView(source: source, url: r.url, title: r.name)
                        } label: { Label(r.name, systemImage: "folder.fill") }
                    } else {
                        Button { download(r) } label: {
                            HStack {
                                Image(systemName: Self.exts.contains((r.name as NSString).pathExtension.lowercased()) ? "book.closed" : "doc")
                                    .foregroundStyle(Color.accentGreen)
                                VStack(alignment: .leading) {
                                    Text(r.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let p = downloads.progress[r.url] {
                                    ProgressView(value: p).frame(width: 60)
                                } else if done.contains(r.url) {
                                    Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay { if items.isEmpty { EmptyStateView(icon: "folder", text: String(localized: "This folder is empty")) } }
                .safeAreaInset(edge: .bottom) {
                    Text("Tap a book file to download it.").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if items == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        error = nil
        do { items = try await WebDAVClient.list(url, source: source) } catch { self.error = error.localizedDescription }
    }

    private func download(_ r: DavResource) {
        guard Self.exts.contains((r.name as NSString).pathExtension.lowercased()) else {
            toast(String(localized: "Sorry, this file type can't be downloaded"))
            return
        }
        guard downloads.progress[r.url] == nil else { return }
        Task {
            _ = await downloads.downloadAndImport(WebDAVClient.authorized(r.url, source), name: r.name)
            done.insert(r.url)
        }
    }
}

// MARK: 网页图书源 (任意网页书库): 拦截 epub/pdf 下载, 导入书架后直接打开阅读
struct WebSourceBrowserView: View {
    let url: URL
    let title: String
    @State private var model = WebSourceModel()
    @State private var openBook: Book?

    var body: some View {
        VStack(spacing: 0) {
            if model.progress < 1 { ProgressView(value: model.progress).tint(.accentGreen) }
            WebSourceWebView(url: url, model: model)
        }
        .overlay(alignment: .bottom) {
            if let p = model.downloadProgress {
                HStack(spacing: 12) {
                    ProgressView(value: p).tint(.accentGreen)
                    Text(model.downloadName).font(.caption).lineLimit(1).frame(maxWidth: 160)
                    Button { model.cancelDownload() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .navigationTitle(model.title.isEmpty ? title : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                Spacer()
                Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                Spacer()
                Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear { model.onBookReady = { openBook = $0 } }
        .fullScreenCover(item: $openBook, onDismiss: { LibraryStore.shared.reload() }) { b in ReaderScreen(book: b) }
    }
}

@Observable
final class WebSourceModel: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var onBookReady: ((Book) -> Void)?
    var title = ""
    var progress = 0.0
    var downloadProgress: Double?
    var downloadName = ""
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var destinations: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var current: WKDownload?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    private static let bookExts = ["epub", "pdf", "txt", "mdx", "mobi", "azw3", "azw", "fb2", "djvu"]

    func attach(_ wv: WKWebView) {
        webView = wv
        observations = [
            wv.observe(\.estimatedProgress) { [weak self] w, _ in self?.progress = w.estimatedProgress },
            wv.observe(\.title) { [weak self] w, _ in self?.title = w.title ?? "" },
        ]
    }

    private func isBook(_ url: URL?, mime: String?) -> Bool {
        let ext = url?.pathExtension.lowercased() ?? ""
        let m = mime ?? ""
        return Self.bookExts.contains(ext) || m.contains("epub") || m == "application/pdf" || m == "application/octet-stream"
            || m.contains("mobipocket") || m.contains("fictionbook")
    }

    // 带 download 属性的链接
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let r = navigationResponse.response
        let disposition = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !navigationResponse.canShowMIMEType || isBook(r.url, mime: r.mimeType) || disposition.lowercased().contains("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    // target=_blank 的链接在当前页面打开
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { track(download) }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { track(download) }

    private func track(_ download: WKDownload) {
        download.delegate = self
        current = download
        downloadProgress = 0
        progressObservation = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { if self?.downloadProgress != nil { self?.downloadProgress = p.fractionCompleted } }
        }
    }

    func cancelDownload() {
        current?.cancel { _ in }
        finishUI()
    }

    private func finishUI() {
        downloadProgress = nil
        downloadName = ""
        current = nil
        progressObservation = nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        var name = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        if (name as NSString).pathExtension.isEmpty {
            let mime = response.mimeType ?? ""
            name += mime.contains("pdf") ? ".pdf" : (mime.contains("epub") ? ".epub" : "")
        }
        downloadName = name
        let dest = Paths.downloads.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        destinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finishUI()
        guard let dest = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let ext = dest.pathExtension.lowercased()
        do {
            if ext == "mdx" || ext == "mdd" {
                _ = try DictionaryManager.shared.importFile(dest)
                toast(String(localized: "Dictionary imported"))
                return
            }
            guard BookFormat.importableExtensions.contains(ext) else {
                try? FileManager.default.removeItem(at: dest)
                toast(ext.isEmpty ? String(localized: "Unsupported format. Please choose EPUB or PDF on the website.") : String(localized: "Unsupported format \(ext). Please choose EPUB or PDF on the website."))
                return
            }
            // 已在书架中则直接打开
            if let existing = AppDatabase.shared.book(path: dest.lastPathComponent),
               FileManager.default.fileExists(atPath: existing.fileURL.path) {
                try? FileManager.default.removeItem(at: dest)
                onBookReady?(existing)
                return
            }
            let book = try BookImporter.importBook(from: dest, copy: false)
            LibraryStore.shared.reload()
            toast(String(localized: "Saved to bookshelf"))
            onBookReady?(book)
        } catch {
            toast(error.localizedDescription)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finishUI()
        if (error as NSError).code != NSURLErrorCancelled { toast(String(localized: "Download failed: \(error.localizedDescription)")) }
    }
}

struct WebSourceWebView: UIViewRepresentable {
    let url: URL
    let model: WebSourceModel
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = WebSourceModel.safariUA
        wv.navigationDelegate = model
        wv.uiDelegate = model
        wv.allowsBackForwardNavigationGestures = true
        model.attach(wv)
        var target = url
        #if DEBUG
        if DebugAutomation.has("-autoDownloadTest") { target = URL(string: "https://www.gutenberg.org/ebooks/84.epub3.images")! }
        #endif
        wv.load(URLRequest(url: target))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 书库列表 (嵌入在推荐页的导航栈中使用)
struct BookSourcesList: View {
    @State private var settings = AppSettings.shared
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach(settings.bookSources) { s in
                    NavigationLink { SourceBrowser(source: s) } label: { SourceRow(source: s) }
                }
                .onDelete { settings.bookSources.remove(atOffsets: $0) }
                .onMove { settings.bookSources.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("\(AppInfo.name) does not provide any books. Third-party sources are publicly available on the internet. OPDS, WebDAV and web sources are supported.")
            }
        }
        .navigationTitle("Book Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddBookSourceView() }
    }
}
