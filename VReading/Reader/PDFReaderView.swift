import SwiftUI
import PDFKit

/// PDF 阅读: 单击单词查词, 长按选择文本翻译, 目录/书签/页码跳转
struct PDFReaderView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PDFController()
    @State private var showMenu = false
    @State private var wordQuery: WordQuery?
    @State private var selectionText: String?
    @State private var showOutline = false
    @State private var pageSlider = 0.0
    @State private var settings = AppSettings.shared
    @State private var timer: ReadingTimer?

    var body: some View {
        ZStack {
            PDFKitView(controller: controller)
                .ignoresSafeArea()
            if showMenu { menu }
        }
        .statusBarHidden(!showMenu)
        .onAppear {
            controller.load(book: book)
            if timer == nil {
                let t = ReadingTimer(bookId: book.id)
                t.start()
                timer = t
                controller.onActivity = { [weak t] in t?.activity() }
            }
            controller.onWord = { word, sentence in
                if showMenu { showMenu = false; return }
                guard settings.tapToLookup else { return }
                let q = WordQuery(word: word, sentence: sentence, bookName: book.name)
                if selectionText != nil {
                    selectionText = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { wordQuery = q }
                } else {
                    wordQuery = q
                }
            }
            controller.onTap = { withAnimation { showMenu.toggle() } }
            controller.onSelection = { t in if wordQuery == nil { selectionText = t } }
        }
        .onDisappear {
            controller.savePosition()
            timer?.stop()
            LibraryStore.shared.reload()
        }
        .sheet(item: $wordQuery) { q in
            WordLookupView(query: q).presentationDetents([.fraction(0.55), .large])
        }
        .sheet(isPresented: Binding(get: { selectionText != nil }, set: { if !$0 { selectionText = nil } })) {
            if let t = selectionText {
                VStack(spacing: 0) {
                    HStack {
                        Button { UIPasteboard.general.string = t; toast(String(localized: "Copied")) } label: { Label(String(localized: "Copy"), systemImage: "doc.on.doc") }
                        Spacer()
                        Button { addSelectionWord(t) } label: { Label("Add to Vocabulary", systemImage: "plus.circle") }
                    }
                    .padding()
                    Divider()
                    TranslatePanel(text: t)
                }
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationBackground(Color(.systemBackground))
            }
        }
        .sheet(isPresented: $showOutline) {
            PDFOutlineSheet(controller: controller, bookId: book.id, bookPath: book.path) { showOutline = false; showMenu = false }
        }
    }

    private func addSelectionWord(_ t: String) {
        let w = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !w.contains(" ") else { toast(String(localized: "You selected a sentence. Please select a single word.")); return }
        VocabStore.shared.add(word: w, sentence: "", bookName: book.name, lang: "en", dictId: DictionaryManager.shared.enabled().first?.id ?? "")
        toast(String(localized: "Added to vocabulary"))
    }

    private var menu: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3) }
                Spacer()
                Text(book.name).font(.subheadline).lineLimit(1)
                Spacer()
                Button { controller.toggleBookmark(book: book) } label: { Image(systemName: "bookmark") }
            }
            .foregroundStyle(Color.menuText)
            .padding(.horizontal, 16).frame(height: 54)
            .background(Color.menuBackground.ignoresSafeArea(edges: .top))
            Spacer()
            VStack(spacing: 10) {
                Text("Page \(controller.currentPage + 1) / \(controller.pageCount)").font(.caption).foregroundStyle(Color.menuText)
                Slider(value: $pageSlider, in: 0...Double(max(controller.pageCount - 1, 1)), step: 1) { editing in
                    if !editing { controller.go(to: Int(pageSlider)) }
                }
                .tint(Color.menuSelected)
                .padding(.horizontal, 20)
                HStack {
                    item("list.bullet", String(localized: "Contents")) { showOutline = true }
                    item(controller.pageCurl ? "book.pages" : "scroll", controller.pageCurl ? String(localized: "Curl") : String(localized: "Scroll")) { controller.togglePageMode() }
                    item(settings.isNight ? "sun.max.fill" : "moon.fill", settings.isNight ? String(localized: "Day") : String(localized: "Night")) {
                        settings.toggleNight()
                        controller.applyTheme()
                    }
                }
            }
            .padding(.vertical, 12)
            .background(Color.menuBackground.ignoresSafeArea(edges: .bottom))
            .onAppear { pageSlider = Double(controller.currentPage) }
        }
    }

    private func item(_ icon: String, _ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 4) { Image(systemName: icon); Text(t).font(.caption2) }
                .frame(maxWidth: .infinity).foregroundStyle(Color.menuText)
        }
    }
}

@Observable
final class PDFController: NSObject, UIGestureRecognizerDelegate {
    @ObservationIgnored let view = PDFView()
    @ObservationIgnored var onWord: ((String, String) -> Void)?
    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onSelection: ((String?) -> Void)?
    @ObservationIgnored var onActivity: (() -> Void)?
    var currentPage = 0
    var pageCount = 0
    var pageCurl = true
    @ObservationIgnored private var bookId = ""

    override init() {
        super.init()
        view.autoScales = true
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        applyTheme()
    }

    func load(book: Book) {
        bookId = book.id
        guard view.document == nil, let doc = PDFDocument(url: book.fileURL) else { return }
        view.document = doc
        pageCount = doc.pageCount
        let saved = UserDefaults.standard.integer(forKey: "pdfpos_\(book.id)")
        go(to: saved)
    }

    func go(to page: Int) {
        guard let p = view.document?.page(at: min(max(page, 0), max(pageCount - 1, 0))) else { return }
        view.go(to: p)
    }

    func savePosition() {
        UserDefaults.standard.set(currentPage, forKey: "pdfpos_\(bookId)")
        guard pageCount > 0, !bookId.isEmpty else { return }
        AppDatabase.shared.setProgress(Double(currentPage + 1) / Double(pageCount), for: bookId)
        AppDatabase.shared.touch(bookId)
        onActivity?()
    }

    func applyTheme() {
        view.backgroundColor = AppSettings.shared.isNight ? UIColor(hexString: "#131313") : UIColor(hexString: "#E8E8E8")
    }

    func togglePageMode() {
        let page = currentPage
        pageCurl.toggle()
        view.usePageViewController(pageCurl)
        view.displayMode = pageCurl ? .singlePage : .singlePageContinuous
        view.displayDirection = pageCurl ? .horizontal : .vertical
        go(to: page)
    }

    func toggleBookmark(book: Book) {
        let mark = "\(currentPage)"
        if let b = AppDatabase.shared.bookmarks(bookId: book.id).first(where: { $0.bookmark == mark }) {
            AppDatabase.shared.delete(bookmark: b)
            toast(String(localized: "Remove Bookmark"))
        } else {
            let summary = view.document?.page(at: currentPage)?.string?.prefix(80).replacingOccurrences(of: "\n", with: " ") ?? ""
            AppDatabase.shared.save(BookmarkItem(bookId: book.id, bookPath: book.path, fileType: "pdf", chapterTitle: String(localized: "Page \(currentPage + 1)"),
                                                 bookmark: mark, createDate: Date(), summary: summary))
            toast(String(localized: "Bookmark added"))
        }
    }

    @objc private func pageChanged() {
        if let p = view.currentPage, let doc = view.document { currentPage = doc.index(for: p) }
        savePosition()
    }

    @objc private func selectionChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reportSelection), object: nil)
        perform(#selector(reportSelection), with: nil, afterDelay: 0.6)
    }

    @objc private func reportSelection() {
        let t = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty, !suppressSelection { onSelection?(t) }
        suppressSelection = false
    }

    @ObservationIgnored private var suppressSelection = false

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let pt = g.location(in: view)
        guard let page = view.page(for: pt, nearest: false) else { onTap?(); return }
        let p = view.convert(pt, to: page)
        if let sel = page.selectionForWord(at: p), let w = sel.string?.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)),
           w.range(of: "[A-Za-z]", options: .regularExpression) != nil, sel.bounds(for: page).insetBy(dx: -4, dy: -4).contains(p) {
            suppressSelection = true
            view.setCurrentSelection(sel, animate: false)
            let line = page.selectionForLine(at: p)?.string ?? ""
            onWord?(w, line.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            onTap?()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

struct PDFKitView: UIViewRepresentable {
    let controller: PDFController
    func makeUIView(context: Context) -> PDFView { controller.view }
    func updateUIView(_ v: PDFView, context: Context) {}
}

struct PDFOutlineSheet: View {
    let controller: PDFController
    let bookId: String
    let bookPath: String
    var onClose: () -> Void
    @State private var tab = 0
    @State private var bookmarks: [BookmarkItem] = []

    private var outline: [(String, Int, Int)] {
        guard let doc = controller.view.document, let root = doc.outlineRoot else { return [] }
        var out: [(String, Int, Int)] = []
        func walk(_ o: PDFOutline, level: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                if let p = c.destination?.page { out.append((c.label ?? "", doc.index(for: p), level)) }
                walk(c, level: level + 1)
            }
        }
        walk(root, level: 0)
        return out
    }

    var body: some View {
        NavigationStack {
            VStack {
                Picker("", selection: $tab) { Text("Contents").tag(0); Text("Bookmarks").tag(1) }
                    .pickerStyle(.segmented).padding()
                if tab == 0 {
                    if outline.isEmpty {
                        EmptyStateView(icon: "list.bullet", text: String(localized: "This book has no table of contents"))
                    } else {
                        List(Array(outline.enumerated()), id: \.offset) { _, o in
                            Button {
                                controller.go(to: o.1)
                                onClose()
                            } label: {
                                HStack {
                                    Text(o.0).padding(.leading, CGFloat(o.2) * 14)
                                    Spacer()
                                    Text("\(o.1 + 1)").foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else if bookmarks.isEmpty {
                    EmptyStateView(icon: "bookmark", text: String(localized: "No bookmarks yet"))
                } else {
                    List {
                        ForEach(bookmarks) { b in
                            Button {
                                controller.go(to: Int(b.bookmark) ?? 0)
                                onClose()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(b.chapterTitle).font(.subheadline.bold())
                                    Text(b.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { idx in
                            idx.map { bookmarks[$0] }.forEach(AppDatabase.shared.delete(bookmark:))
                            bookmarks = AppDatabase.shared.bookmarks(bookId: bookId)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", action: onClose) } }
            .onAppear { bookmarks = AppDatabase.shared.bookmarks(bookId: bookId) }
        }
    }
}
