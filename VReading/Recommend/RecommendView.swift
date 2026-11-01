import SwiftUI

/// 分级推荐的一本书 (来自 recommend_<lang>.json, 由 tools/build_recommendations.py 根据词汇难度分析生成)
struct RecommendedBook: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let author: String
    let level: String
    /// 难度分数 (越小越容易)
    let score: Double
    let words: Int
    /// 对 A1...C2 读者的词汇覆盖率 (0-100)
    let coverage: [Double]
    let epub: String
    let cover: String
    var genre: String = ""
    /// 含成人内容, 在书单中标注 18+, 默认隐藏
    var adult: Bool? = false

    var isAdult: Bool { adult ?? false }

    var coverURL: URL? { URL(string: cover) }

    /// 预计阅读时长 (按每分钟 150 词)
    var readingTime: String {
        let minutes = max(1, words / 150)
        return minutes >= 60 ? String(localized: "~\(minutes / 60) h") : String(localized: "~\(minutes) min")
    }
}

enum RecommendCatalog {
    static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]
    static let languages: [(code: String, name: String)] = [("en", String(localized: "English")), ("fr", String(localized: "French"))]

    /// 各等级对应的大致词汇量
    static let vocabularySize = ["A1": String(localized: "~500 words"), "A2": String(localized: "~1,000 words"), "B1": String(localized: "~2,000 words"), "B2": String(localized: "~4,000 words"), "C1": String(localized: "~6,000 words"), "C2": String(localized: "8,000+ words")]

    private static var cache: [String: [RecommendedBook]] = [:]

    static func books(lang: String) -> [RecommendedBook] {
        if let c = cache[lang] { return c }
        guard let url = Paths.bundled("recommend_\(lang).json"), let d = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([RecommendedBook].self, from: d) else { return [] }
        cache[lang] = list
        return list
    }

    static func levelIndex(_ level: String) -> Int { levels.firstIndex(of: level) ?? 2 }

    /// 已下载到书架的推荐书 (古登堡 id -> 书架文件名)
    static func downloadedBook(_ rec: RecommendedBook) -> Book? {
        guard let path = UserDefaults.standard.string(forKey: "rec_\(rec.id)") else { return nil }
        guard let b = AppDatabase.shared.book(path: path), FileManager.default.fileExists(atPath: b.fileURL.path) else { return nil }
        return b
    }

    static func markDownloaded(_ rec: RecommendedBook, book: Book) {
        UserDefaults.standard.set(book.path, forKey: "rec_\(rec.id)")
    }
}

/// 推荐 Tab: 根据词汇量 (CEFR 等级) 推荐可直接阅读的书
struct RecommendView: View {
    @AppStorage("recommendLang") private var lang = "en"
    @AppStorage("recommendLevel_fr") private var levelFR = "B1"
    @AppStorage("recommendLevel_en") private var levelEN = "B1"
    @State private var browseLevel = "B1"

    /// 每种语言各自记录水平
    private var myLevel: String {
        get { lang == "en" ? levelEN : levelFR }
        nonmutating set { if lang == "en" { levelEN = newValue } else { levelFR = newValue } }
    }

    private var langName: String { RecommendCatalog.languages.first { $0.code == lang }?.name ?? "" }
    @State private var downloads = DownloadManager.shared
    @State private var loadingId: Int?
    @State private var openBook: Book?
    @State private var showLevelInfo = false
    @State private var version = 0
    @AppStorage("recommendShowAdult") private var showAdult = false

    private var catalog: [RecommendedBook] { RecommendCatalog.books(lang: lang).filter { showAdult || !$0.isAdult } }
    private var myIndex: Int { RecommendCatalog.levelIndex(myLevel) }

    /// 为你推荐: 本级 + 覆盖率最高的下一级书
    private var forYou: [RecommendedBook] {
        let same = catalog.filter { $0.level == myLevel }
        let next = catalog.filter { RecommendCatalog.levelIndex($0.level) == myIndex + 1 }
        return Array((same + next).sorted { $0.coverage[myIndex] > $1.coverage[myIndex] }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    levelHeader
                    if !forYou.isEmpty {
                        Text("Recommended for You").font(.title3.bold()).padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(forYou) { b in featureCard(b) }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    Text("Graded Reading List").font(.title3.bold()).padding(.horizontal, 16)
                    levelPicker
                    let list = catalog.filter { $0.level == browseLevel }.sorted { $0.score < $1.score }
                    if list.isEmpty {
                        EmptyStateView(icon: "books.vertical", text: catalog.isEmpty ? String(localized: "The \(langName) list is coming soon") : String(localized: "No recommendations for this level yet")).frame(height: 200)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { b in row(b) }
                        }
                    }
                    Text("Levels are estimated automatically from how the book's vocabulary is distributed in the \(lang == "en" ? "EFLLex" : "FLELex") graded word list, plus average sentence length. Books are public-domain titles from Project Gutenberg; download one to read it with tap-to-look-up.")
                        .font(.caption2).foregroundStyle(.secondary).padding(16)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Graded Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(RecommendCatalog.languages, id: \.code) { l in
                            Button {
                                lang = l.code
                                browseLevel = myLevel
                            } label: {
                                if l.code == lang { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(langName).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { BookSourcesList() } label: { Label("Library", systemImage: "building.columns") }
                    NavigationLink { WebsiteListView(embedded: true) } label: { Label("Web Reading", systemImage: "safari") }
                }
            }
            .onAppear {
                browseLevel = myLevel
                #if DEBUG
                if DebugAutomation.has("-autoOpenRec"), let b = catalog.filter({ $0.level == "A1" }).sorted(by: { $0.score < $1.score }).first { open(b) }
                #endif
            }
            .fullScreenCover(item: $openBook, onDismiss: { version += 1; LibraryStore.shared.reload() }) { b in ReaderScreen(book: b) }
            .alert("Choosing a Level", isPresented: $showLevelInfo) {
                Button("Got It", role: .cancel) {}
            } message: {
                Text(lang == "en"
                     ? "A1/A2 beginner, B1/B2 intermediate (IELTS 5.5–6.5 ≈ B2), C1/C2 advanced (IELTS 7+). Recommended books have high vocabulary coverage at your level, so they won't feel too hard."
                     : "A1/A2 beginner, B1/B2 intermediate (TCF/TEF for immigration usually requires about B2), C1/C2 advanced. Recommended books have high vocabulary coverage at your level; 95%+ coverage reads fluently.")
            }
        }
    }

    // MARK: 我的水平
    private var levelHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("My \(langName) Level").font(.subheadline.bold())
                Button { showLevelInfo = true } label: { Image(systemName: "questionmark.circle") }.font(.subheadline)
                Spacer()
                Text("Vocabulary \(RecommendCatalog.vocabularySize[myLevel] ?? "-")").font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(get: { myLevel }, set: { myLevel = $0; browseLevel = $0 })) {
                ForEach(RecommendCatalog.levels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $showAdult) {
                Text("Show 18+ Titles").font(.footnote)
            }
            .tint(.accentGreen)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private var levelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RecommendCatalog.levels, id: \.self) { l in
                    let n = catalog.filter { $0.level == l }.count
                    Button { browseLevel = l } label: {
                        Text("\(l) · \(n) books")
                            .font(.subheadline.weight(browseLevel == l ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .foregroundStyle(browseLevel == l ? .white : .primary)
                            .background(browseLevel == l ? Color.accentGreen : Color(.secondarySystemBackground), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 书籍单元
    private func cover(_ b: RecommendedBook, width: CGFloat) -> some View {
        AsyncImage(url: b.coverURL) { img in img.resizable().scaledToFill() } placeholder: {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5BC26A"), Color(hex: "#2E9E8F")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(b.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(6)
            }
        }
        .frame(width: width, height: width / 0.68)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        .overlay(alignment: .center) {
            if loadingId == b.id {
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView().tint(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func coverageText(_ b: RecommendedBook) -> some View {
        let c = b.coverage[myIndex]
        // 整本小说对本级读者的覆盖率通常在 85%-90%
        let color: Color = c >= 88 ? .accentGreen : (c >= 84 ? .orange : .red)
        return Text(String(localized: "Coverage \(Int(c.rounded()))%")).font(.caption2.bold()).foregroundStyle(color)
    }

    private func featureCard(_ b: RecommendedBook) -> some View {
        Button { open(b) } label: {
            VStack(alignment: .leading, spacing: 4) {
                cover(b, width: 104)
                Text(b.title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(b.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(b.level).font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentGreen, in: Capsule())
                    coverageText(b)
                }
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
    }

    private func row(_ b: RecommendedBook) -> some View {
        let _ = version
        let downloaded = RecommendCatalog.downloadedBook(b) != nil
        return Button { open(b) } label: {
            HStack(alignment: .top, spacing: 14) {
                cover(b, width: 62)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(b.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    }
                    Text(b.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if b.isAdult {
                        Text(verbatim: "18+").font(.caption2.bold()).foregroundStyle(.pink)
                    }
                    HStack(spacing: 8) {
                        coverageText(b)
                        Text("\(b.words.formatted(.number.notation(.compactName))) words · \(b.readingTime)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !b.genre.isEmpty {
                        Text(b.genre.replacingOccurrences(of: "Category: ", with: "")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                Text(downloaded ? "Read" : "Download")
                    .font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(downloaded ? .white : Color.accentGreen)
                    .background(downloaded ? Color.accentGreen : Color.accentGreen.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 下载并打开
    private func open(_ rec: RecommendedBook) {
        if let b = RecommendCatalog.downloadedBook(rec) {
            openBook = b
            return
        }
        guard loadingId == nil, let url = URL(string: rec.epub) else { return }
        loadingId = rec.id
        Task {
            let name = "\(rec.title.replacingOccurrences(of: "/", with: " ")).epub"
            if let book = await downloads.downloadAndImport(URLRequest(url: url), name: name) {
                RecommendCatalog.markDownloaded(rec, book: book)
                AppSettings.shared.bookLanguages[book.id] = lang
                openBook = book
            }
            loadingId = nil
            version += 1
        }
    }
}
