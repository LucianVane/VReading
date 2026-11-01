import SwiftUI

/// 打开书籍: epub / txt 使用 WebView 阅读器, pdf 使用 PDFKit
struct ReaderScreen: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var engine: ReaderEngine?
    @State private var error: String?

    var body: some View {
        Group {
            if book.format == .pdf {
                PDFReaderView(book: book)
            } else if let engine {
                ReaderView(engine: engine)
            } else if let error {
                VStack(spacing: 16) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Close") { dismiss() }
                }
            } else {
                ProgressView("Loading book...")
                    .task {
                        do {
                            let doc = try await Task.detached { try ReaderDocument(book: book) }.value
                            engine = ReaderEngine(document: doc)
                        } catch {
                            self.error = String(localized: "Failed to load book: \(error.localizedDescription)")
                        }
                    }
            }
        }
        .onAppear { AppDatabase.shared.touch(book.id) }
        .onDisappear { LibraryStore.shared.reload() }
    }
}

private enum ReaderPanel { case none, fonts, background, brightness }

struct ReaderView: View {
    @State var engine: ReaderEngine
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var vocab = VocabStore.shared
    @State private var showMenu = false
    @State private var panel: ReaderPanel = .none
    @State private var wordQuery: WordQuery?
    @State private var selection: TextSelection?
    @State private var editingNote: NoteItem?
    @State private var showTOC = false
    @State private var tocTab = 0
    @State private var showSearch = false
    @State private var showDialysis = false
    @State private var showReadSettings = false
    @State private var showGuide = false
    @State private var sliderValue = 0.0
    @State private var savedBrightness = UIScreen.main.brightness
    @State private var bookmarkVersion = 0
    @State private var timer: ReadingTimer?
    @State private var pinchBase = 0
    @State private var pinchSize: Int?
    @State private var showMindMap = false

    private var book: Book { engine.document.book }
    private var theme: ReaderTheme { settings.theme }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(engine.chapterTitle)
                    .font(.caption2).foregroundStyle(Color(hex: theme.text).opacity(0.55))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).frame(height: 18)
                ContainerHost(view: engine.container)
                HStack {
                    Text("\(engine.bookPage)/\(engine.bookPageTotal)")
                    Spacer()
                    Text(String(format: "%.1f%%", engine.bookProgress * 100))
                }
                .font(.caption2).foregroundStyle(Color(hex: theme.text).opacity(0.55))
                .padding(.horizontal, 22).frame(height: 18)
            }
            if !engine.isReady && engine.pageCount <= 1 && engine.page == 0 {
                ProgressView().tint(Color(hex: theme.text))
            }
            if let size = pinchSize {
                VStack(spacing: 4) {
                    Image(systemName: "textformat.size").font(.title2)
                    Text("Font size \(size)").font(.headline.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if showMenu { menuOverlay }
            if showGuide { guideOverlay }
        }
        .statusBarHidden(!showMenu)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear(perform: setup)
        .onDisappear {
            engine.savePosition()
            engine.pageCounter?.cancel()
            engine.pageCounter = nil
            timer?.stop()
            if !settings.followSystemBrightness { UIScreen.main.brightness = savedBrightness }
        }
        .onChange(of: settings.fontSize) { engine.applyStyle() }
        .onChange(of: settings.lineHeight) { engine.applyStyle() }
        .onChange(of: settings.fontFamily) { engine.applyStyle() }
        .onChange(of: settings.themeIndex) { engine.applyStyle() }
        .onChange(of: settings.einkMode) { engine.applyStyle() }
        .onChange(of: settings.tapToLookup) { engine.applyStyle() }
        .onChange(of: settings.levelColors) { engine.applyStyle() }
        .onChange(of: settings.highlightLevels) { engine.reloadLevels() }
        .onChange(of: settings.levelHighlightEnabled) { engine.reloadLevels() }
        .onChange(of: settings.vocabHighlightEnabled) { engine.reloadLevels() }
        .onChange(of: vocab.strangeWords.map(\.word)) { engine.reloadLevels() }
        .onChange(of: settings.bookLanguages) { engine.reloadLevels() }
        .sheet(item: $wordQuery, onDismiss: { engine.clearSelection() }) { q in
            WordLookupView(query: q)
                .presentationDetents([.fraction(0.55), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selection, onDismiss: { engine.clearSelection() }) { sel in
            SelectionPanel(selection: sel, bookName: book.name, lang: engine.lang,
                           onUnderline: { addNote(sel, color: "underline", note: "") },
                           onNote: {
                               selection = nil
                               let note = NoteItem(id: UUID().uuidString, bookId: book.id, chapterIndex: engine.chapterIndex,
                                                   chapterTitle: engine.chapterTitle, start: sel.start, end: sel.end,
                                                   content: sel.text, note: "", color: "yellow", date: Date())
                               // 等划词面板关闭后再弹出笔记编辑, 避免两个弹窗冲突
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { editingNote = note }
                           })
                .presentationDetents([.fraction(0.5), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingNote) { n in
            NoteEditView(note: n, isNew: AppDatabase.shared.notes(bookId: book.id).first { $0.id == n.id } == nil) { action in
                switch action {
                case .save(let item):
                    let exists = AppDatabase.shared.notes(bookId: book.id).contains { $0.id == item.id }
                    AppDatabase.shared.save(item)
                    if exists { engine.setNoteColor(item.id, item.color) } else { engine.applyNote(item) }
                    toast(exists ? String(localized: "Note updated") : String(localized: "Note added"))
                case .delete(let id):
                    AppDatabase.shared.delete(noteId: id)
                    engine.removeNote(id)
                    toast(String(localized: "Note deleted"))
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTOC) {
            TOCSheet(engine: engine, initialTab: tocTab) { showTOC = false; showMenu = false }
        }
        .sheet(isPresented: $showSearch) {
            BookSearchView(document: engine.document) { chapter, q in
                showSearch = false
                showMenu = false
                engine.jump(chapter: chapter, target: .search(q))
            }
        }
        .fullScreenCover(isPresented: $showMindMap) {
            MindMapView(engine: engine) { loc in
                showMenu = false
                // 搜索原文锚点句定位, 不受字体大小影响
                engine.jump(chapter: loc.chapter, target: loc.quote.isEmpty ? .fraction(loc.ratio) : .search(loc.quote))
            }
        }
        .sheet(isPresented: $showDialysis) {
            BookDialysisView(book: book, document: engine.document)
        }
        .sheet(isPresented: $showReadSettings) {
            NavigationStack { ReadSettingsView() }
        }
    }

    @ViewBuilder
    private var background: some View {
        if !settings.texture.isEmpty, !settings.isNight, let img = UIImage(named: settings.texture) {
            Image(uiImage: img).resizable(resizingMode: .tile)
        } else {
            Color(hex: theme.background)
        }
    }

    private func setup() {
        if timer == nil {
            let t = ReadingTimer(bookId: book.id)
            t.start()
            timer = t
            engine.onActivity = { [weak t] in t?.activity() }
        }
        engine.onWordTap = { tap in
            if showMenu { showMenu = false; return }
            let q = WordQuery(word: tap.word, sentence: tap.sentence, bookName: book.name, lang: engine.lang)
            if selection != nil {
                selection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { wordQuery = q }
            } else {
                wordQuery = q
            }
        }
        engine.onSelection = { sel in
            if let sel, wordQuery == nil, editingNote == nil { selection = sel }
        }
        engine.onTapZone = { zone in
            if showMenu { withAnimation { showMenu = false; panel = .none }; return }
            switch zone {
            case .menu: withAnimation { showMenu = true }
            case .next:
                if engine.isAtBookEnd { toast(String(localized: "You've reached the end of the book")) } else { engine.nextPage() }
            case .previous: engine.previousPage()
            }
        }
        engine.onPinch = { state, scale in
            switch state {
            case .began:
                pinchBase = settings.fontSize
                pinchSize = settings.fontSize
            case .changed:
                // 指数映射, 捏合手感更平滑
                pinchSize = min(40, max(12, Int((Double(pinchBase) * pow(Double(scale), 0.6)).rounded())))
            case .ended:
                if let s = pinchSize, s != settings.fontSize { settings.fontSize = s }
                withAnimation { pinchSize = nil }
            default:
                withAnimation { pinchSize = nil }
            }
        }
        engine.onSwipeVertical = { withAnimation { showMenu.toggle(); panel = .none } }
        engine.onNoteTap = { id in
            editingNote = AppDatabase.shared.notes(bookId: book.id).first { $0.id == id }
        }
        if engine.pageCount <= 1 && !engine.isReady { engine.restorePosition() }
        if !settings.followSystemBrightness { UIScreen.main.brightness = settings.brightness }
        if !settings.readerGuideShown { showGuide = true }
        #if DEBUG
        if DebugAutomation.has("-autoMindMap") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showMindMap = true } }
        if DebugAutomation.has("-autoTOC") { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { tocTab = 0; showTOC = true } }
        DebugAutomation.runReader(engine: engine) { withAnimation { showMenu = true } }
        #endif
    }

    private func addNote(_ sel: TextSelection, color: String, note: String) {
        let n = NoteItem(id: UUID().uuidString, bookId: book.id, chapterIndex: engine.chapterIndex, chapterTitle: engine.chapterTitle,
                         start: sel.start, end: sel.end, content: sel.text, note: note, color: color, date: Date())
        AppDatabase.shared.save(n)
        engine.applyNote(n)
        selection = nil
    }

    // MARK: 菜单
    private var menuOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showMenu = false; panel = .none } }
            switch panel {
            case .fonts: ReaderFontPanel(onMore: { panel = .background })
            case .background: ReaderBackgroundPanel()
            case .brightness: brightnessPanel
            case .none: EmptyView()
            }
            bottomBar
        }
        .transition(.opacity)
    }

    private var isBookmarked: Bool {
        _ = bookmarkVersion
        return AppDatabase.shared.bookmarks(bookId: book.id).contains { $0.bookmark.hasPrefix("\(engine.chapterIndex)|") && abs((Double($0.bookmark.split(separator: "|").last ?? "") ?? -1) - engine.chapterFraction) < 0.0001 }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3) }
            Spacer()
            Text(book.name).font(.subheadline).lineLimit(1)
            Spacer()
            Button { toggleBookmark() } label: { Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark") }
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            Button { showMindMap = true } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            Button { showDialysis = true } label: { Image(systemName: "chart.bar.doc.horizontal") }
        }
        .foregroundStyle(Color.menuText)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Color.menuBackground.ignoresSafeArea(edges: .top))
    }

    private func toggleBookmark() {
        if isBookmarked {
            for b in AppDatabase.shared.bookmarks(bookId: book.id) where b.bookmark == "\(engine.chapterIndex)|\(engine.chapterFraction)" {
                AppDatabase.shared.delete(bookmark: b)
            }
            toast(String(localized: "Remove Bookmark"))
            bookmarkVersion += 1
            return
        }
        engine.pageInfo { _, text in
            AppDatabase.shared.save(BookmarkItem(bookId: book.id, bookPath: book.path, fileType: book.format.rawValue,
                                                 chapterTitle: engine.chapterTitle, bookmark: "\(engine.chapterIndex)|\(engine.chapterFraction)",
                                                 createDate: Date(), summary: text))
            toast(String(localized: "Bookmark added"))
            bookmarkVersion += 1
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Text(engine.document.chapters[safe: Int(sliderValue.rounded())]?.title ?? "")
                .font(.caption).foregroundStyle(Color.menuText).lineLimit(1)
            HStack(spacing: 12) {
                Button("Previous Chapter") {
                    if engine.chapterIndex > 0 { engine.jump(chapter: engine.chapterIndex - 1) }
                }
                Slider(value: $sliderValue, in: 0...Double(max(engine.document.chapters.count - 1, 1)), step: 1) { editing in
                    if !editing { engine.jump(chapter: Int(sliderValue.rounded())) }
                }
                .tint(Color.menuSelected)
                Button("Next Chapter") {
                    if engine.chapterIndex + 1 < engine.document.chapters.count { engine.jump(chapter: engine.chapterIndex + 1) }
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.menuText)
            .padding(.horizontal, 16)
            HStack {
                menuButton("list.bullet", String(localized: "Contents")) { tocTab = 0; showTOC = true }
                menuButton("square.and.pencil", String(localized: "Notes")) { tocTab = 2; showTOC = true }
                menuButton("textformat.size", String(localized: "Settings"), selected: panel == .fonts || panel == .background) { panel = panel == .fonts ? .none : .fonts }
                menuButton("sun.max", String(localized: "Brightness"), selected: panel == .brightness) { panel = panel == .brightness ? .none : .brightness }
                menuButton("ellipsis.circle", String(localized: "More")) { showReadSettings = true }
                menuButton(settings.isNight ? "sun.max.fill" : "moon.fill", settings.isNight ? String(localized: "Day") : String(localized: "Night")) { settings.toggleNight() }
            }
            .padding(.top, 6)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.menuBackground.ignoresSafeArea(edges: .bottom))
        .onAppear { sliderValue = Double(engine.chapterIndex) }
        .onChange(of: engine.chapterIndex) { _, v in sliderValue = Double(v) }
    }

    private func menuButton(_ icon: String, _ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.menuSelected : Color.menuText)
        }
    }

    private var brightnessPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brightness").font(.subheadline).foregroundStyle(Color.menuText)
            HStack {
                Image(systemName: "sun.min").foregroundStyle(Color.menuText)
                Slider(value: Binding(get: { settings.brightness }, set: {
                    settings.brightness = $0
                    settings.followSystemBrightness = false
                    UIScreen.main.brightness = $0
                }), in: 0.05...1)
                .tint(Color.menuSelected)
                Image(systemName: "sun.max").foregroundStyle(Color.menuText)
            }
            Toggle("Use System Brightness", isOn: Binding(get: { settings.followSystemBrightness }, set: {
                settings.followSystemBrightness = $0
                UIScreen.main.brightness = $0 ? savedBrightness : settings.brightness
            }))
            .foregroundStyle(Color.menuText).tint(Color.accentGreen)
        }
        .padding(16)
        .background(Color.menuBackground)
    }

    private var guideOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack(spacing: 0) {
                    guideZone(String(localized: "Previous Page"))
                    guideZone(String(localized: "Menu"))
                    guideZone(String(localized: "Next Page"))
                }
                .frame(height: 220)
                Text("Swipe up or down to show the menu.\nTap a word to look it up and translate its sentence.\nLong-press to select text to highlight, annotate or translate.")
                    .multilineTextAlignment(.center).foregroundStyle(.white).font(.callout)
                Button("Got It") {
                    settings.readerGuideShown = true
                    showGuide = false
                }
                .buttonStyle(.borderedProminent).tint(.accentGreen)
            }
            .padding()
        }
    }

    private func guideZone(_ t: String) -> some View {
        Text(t).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5])))
            .padding(4)
    }
}

/// 把 UIKit 容器视图嵌入 SwiftUI
struct ContainerHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 固定 id: 拖动选区时只刷新面板内容, 不会反复关闭/弹出
extension TextSelection: Identifiable {
    var id: String { "selection" }
}
