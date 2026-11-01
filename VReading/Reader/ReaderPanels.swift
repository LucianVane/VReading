import SwiftUI

// MARK: 阅读设置面板 (字号 / 行高 / 字体 / 翻页 / 主题)
struct ReaderFontPanel: View {
    var onMore: () -> Void
    @State private var s = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(String(localized: "Font Size")) {
                stepper(value: "\(s.fontSize)", dec: { s.fontSize = max(12, s.fontSize - 1) }, inc: { s.fontSize = min(40, s.fontSize + 1) })
            }
            row(String(localized: "Line Height")) {
                stepper(value: String(format: "%.1f", s.lineHeight), dec: { s.lineHeight = max(1.0, s.lineHeight - 0.1) }, inc: { s.lineHeight = min(3.0, s.lineHeight + 0.1) })
            }
            row(String(localized: "Font")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ReaderStyle.fonts, id: \.name) { f in
                            chip(String(localized: String.LocalizationValue(f.name)), selected: s.fontFamily == f.name || (f.name == "Default" && s.fontFamily == "Georgia")) { s.fontFamily = f.name }
                        }
                    }
                }
            }
            row(String(localized: "Page Turn")) {
                HStack(spacing: 10) {
                    ForEach(PageAnimation.allCases, id: \.self) { a in
                        chip(a.title, selected: s.pageAnimation == a) { s.pageAnimation = a }
                    }
                }
            }
            row(String(localized: "Theme")) {
                HStack(spacing: 12) {
                    ForEach(ReaderTheme.all) { t in
                        Circle().fill(Color(hex: t.background))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(s.themeIndex == t.id && s.texture.isEmpty ? Color.menuSelected : Color.gray.opacity(0.5), lineWidth: 2))
                            .onTapGesture {
                                s.texture = ""
                                s.themeIndex = t.id
                                if t.id != ReaderTheme.nightIndex { s.dayThemeIndex = t.id }
                            }
                    }
                    Button("More", action: onMore).font(.footnote).foregroundStyle(Color.menuText)
                }
            }
        }
        .padding(16)
        .background(Color.menuBackground)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.subheadline).foregroundStyle(Color.menuText).frame(width: 36, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func stepper(value: String, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: dec) { Text("Small").frame(width: 70, height: 30) }
            Text(value).frame(width: 60)
            Button(action: inc) { Text("Large").frame(width: 70, height: 30) }
        }
        .font(.subheadline)
        .foregroundStyle(Color.menuText)
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.menuText.opacity(0.5)))
    }

    private func chip(_ t: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.menuSelected : Color.menuText)
                .overlay(Capsule().stroke(selected ? Color.menuSelected : Color.menuText.opacity(0.5)))
        }
    }
}

/// 背景 / 纹理
struct ReaderBackgroundPanel: View {
    @State private var s = AppSettings.shared
    static let textures = ["BeachSand", "BrownPaper", "Paper", "PinkRice", "RicePaper", "Snow"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background").font(.subheadline).foregroundStyle(Color.menuText)
            HStack(spacing: 12) {
                ForEach(ReaderTheme.all) { t in
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: t.background))
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(s.themeIndex == t.id && s.texture.isEmpty ? Color.menuSelected : .clear, lineWidth: 2))
                        .onTapGesture { s.texture = ""; s.themeIndex = t.id }
                }
            }
            Text("Texture").font(.subheadline).foregroundStyle(Color.menuText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.textures, id: \.self) { name in
                        if let img = UIImage(named: name) {
                            Image(uiImage: img).resizable(resizingMode: .tile)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(s.texture == name ? Color.menuSelected : .clear, lineWidth: 2))
                                .onTapGesture {
                                    s.texture = name
                                    if s.isNight || s.themeIndex == ReaderTheme.nightIndex { s.themeIndex = 1 }
                                }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.menuBackground)
    }
}

// MARK: 选中文字面板 (划线 / 笔记 / 字典 / 翻译 / 拷贝 / AI)
struct SelectionPanel: View {
    let selection: TextSelection
    let bookName: String
    let lang: String
    /// 网页阅读中不支持划线/笔记
    var allowNotes = true
    var onUnderline: () -> Void
    var onNote: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private var isWord: Bool {
        let t = DictionaryManager.clean(selection.text)
        return !t.isEmpty && !t.contains(" ") && t.count < (lang == "ja" ? 12 : 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if allowNotes {
                    action(String(localized: "Highlight"), "underline") { onUnderline(); dismiss() }
                    action(String(localized: "Notes"), "highlighter") { onNote() }
                }
                action(String(localized: "Dictionary"), "character.book.closed", selected: tab == 1) {
                    if isWord { tab = 1 } else { toast(String(localized: "Too many words selected for lookup. Use Translate instead.")) }
                }
                action(String(localized: "Translate"), "globe", selected: tab == 0) { tab = 0 }
                action("AI", "sparkles", selected: tab == 2) { tab = 2 }
                action(String(localized: "Copy"), "doc.on.doc") {
                    UIPasteboard.general.string = selection.text
                    toast(String(localized: "Copied"))
                    dismiss()
                }
            }
            .padding(.top, 18).padding(.bottom, 8)
            Divider()
            Group {
                switch tab {
                case 1: WordLookupView(query: WordQuery(word: DictionaryManager.clean(selection.text), sentence: selection.sentence, bookName: bookName, lang: lang))
                case 2:
                    let cfg = AIConfig.load()
                    AIChatView(initialPrompt: "\(isWord ? cfg.wordCommand : (selection.text.split(separator: " ").count <= 4 ? cfg.phraseCommand : cfg.sentenceCommand)): \(selection.text)", compact: true)
                default: TranslatePanel(text: selection.text, sourceLang: lang)
                }
            }
            .id(selection.text)
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .presentationBackground(Color(.systemBackground))
        .onAppear { tab = isWord ? 1 : 0 }
        .onChange(of: selection.text) { tab = isWord ? 1 : 0 }
    }

    private func action(_ t: String, _ icon: String, selected: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17))
                Text(t).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.accentGreen : Color.primary)
        }
    }
}

// MARK: 笔记编辑
struct NoteEditView: View {
    enum Action { case save(NoteItem), delete(String) }
    @State var note: NoteItem
    let isNew: Bool
    var onAction: (Action) -> Void
    @Environment(\.dismiss) private var dismiss
    static let colors: [(String, String)] = [("yellow", "#FFEB6B"), ("green", "#C0ED72"), ("blue", "#ADD8FF"), ("pink", "#FFB0CA")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isNew ? "Add Note" : "Edit Note").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Color.accentGreen) }
            }
            Text(note.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(5)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            TextField("Write a note…", text: $note.note, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            Text("Note Color").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(Self.colors, id: \.0) { c in
                    Circle().fill(Color(hex: c.1)).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(note.color == c.0 ? Color.primary : .clear, lineWidth: 2))
                        .onTapGesture { note.color = c.0 }
                }
                Image(systemName: "underline").font(.title3)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(note.color == "underline" ? Color.primary : .clear, lineWidth: 2))
                    .onTapGesture { note.color = "underline" }
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { onAction(.delete(note.id)); dismiss() }
                }
                Spacer()
                Button("Save") {
                    note.date = Date()
                    onAction(.save(note))
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.accentGreen)
            }
            Spacer()
        }
        .padding(20)
        .presentationBackground(Color(.systemBackground))
    }
}

// MARK: 目录 / 书签 / 笔记
struct TOCSheet: View {
    let engine: ReaderEngine
    var initialTab = 0
    var onClose: () -> Void
    @State private var tab = 0
    @State private var bookmarks: [BookmarkItem] = []
    @State private var notes: [NoteItem] = []
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Contents").tag(0)
                    Text("Bookmarks").tag(1)
                    Text("Notes").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case 0: tocList
                case 1: bookmarkList
                default: noteList
                }
            }
            .navigationTitle(engine.document.book.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close", action: onClose) }
                if tab == 2 && !notes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { exportNotes() } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .onAppear {
            tab = initialTab
            reload()
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
    }

    private func reload() {
        bookmarks = AppDatabase.shared.bookmarks(bookId: engine.document.book.id)
        notes = AppDatabase.shared.notes(bookId: engine.document.book.id)
    }

    private var tocList: some View {
        ScrollViewReader { proxy in
            List(engine.document.toc) { item in
                Button {
                    engine.jump(chapter: item.chapterIndex, target: item.fragment.map { .fragment($0) } ?? .start)
                    onClose()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .padding(.leading, CGFloat(item.level) * 16)
                            .foregroundStyle(item.chapterIndex == engine.chapterIndex ? Color.accentGreen : .primary)
                        Spacer(minLength: 12)
                        if let p = engine.bookPage(for: item) {
                            Text("\(p)").font(.footnote.monospacedDigit())
                                .foregroundStyle(item.chapterIndex == engine.chapterIndex ? Color.accentGreen : .secondary)
                        }
                    }
                }
                .id(item.id)
            }
            .listStyle(.plain)
            .onAppear {
                if let cur = engine.document.toc.last(where: { $0.chapterIndex <= engine.chapterIndex }) { proxy.scrollTo(cur.id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if bookmarks.isEmpty {
            EmptyStateView(icon: "bookmark", text: String(localized: "No bookmarks yet"))
        } else {
            List {
                ForEach(bookmarks) { b in
                    Button {
                        let parts = b.bookmark.split(separator: "|")
                        engine.jump(chapter: Int(parts.first ?? "") ?? 0, target: .fraction(Double(parts.last ?? "") ?? 0))
                        onClose()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(b.chapterTitle).font(.subheadline.bold())
                            Text(b.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Text(AppDatabase.dateFormatter.string(from: b.createDate)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .onDelete { idx in
                    idx.map { bookmarks[$0] }.forEach(AppDatabase.shared.delete(bookmark:))
                    reload()
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var noteList: some View {
        if notes.isEmpty {
            EmptyStateView(icon: "square.and.pencil", text: String(localized: "No notes yet"))
        } else {
            List {
                ForEach(notes) { n in
                    Button {
                        engine.jump(chapter: n.chapterIndex, target: .offset(n.start))
                        onClose()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: NoteEditView.colors.first { $0.0 == n.color }?.1 ?? "#C54A44"))
                                .frame(width: 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.content).font(.subheadline).lineLimit(3)
                                if !n.note.isEmpty { Text("Note: \(n.note)").font(.footnote).foregroundStyle(Color.accentGreen) }
                                Text("\(n.chapterTitle) · \(n.date.shortString)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        AppDatabase.shared.delete(noteId: notes[i].id)
                        engine.removeNote(notes[i].id)
                    }
                    reload()
                }
            }
            .listStyle(.plain)
        }
    }

    private func exportNotes() {
        let b = engine.document.book
        var text = String(localized: "Notes on “\(b.name)”\n\n")
        for n in notes {
            text += "[\(n.chapterTitle)]\n\(n.content)\n"
            if !n.note.isEmpty { text += String(localized: "Note: \(n.note)\n") }
            text += "\n"
        }
        let url = Paths.exports.appendingPathComponent(String(localized: "\(b.name)_Notes_\(Date().shortString).txt"))
        try? text.write(to: url, atomically: true, encoding: .utf8)
        share = ShareItem(items: [url])
    }
}

// MARK: 全文搜索
struct BookSearchView: View {
    let document: ReaderDocument
    var onSelect: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(chapter: Int, snippet: String)] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List(Array(results.enumerated()), id: \.offset) { _, r in
                Button { onSelect(r.chapter, query) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.chapters[r.chapter].title).font(.caption).foregroundStyle(Color.accentGreen)
                        Text(r.snippet).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if searching { ProgressView() } else if results.isEmpty && !query.isEmpty { EmptyStateView(icon: "magnifyingglass", text: String(localized: "No results")) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search in book")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = []
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [(Int, String)] = []
            for i in document.chapters.indices {
                let text = document.plainText(of: i).replacingOccurrences(of: "\n", with: " ")
                if let r = text.range(of: q, options: .caseInsensitive) {
                    let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
                    out.append((i, "…" + String(text[start..<end]) + "…"))
                }
                if out.count >= 200 { break }
            }
            DispatchQueue.main.async {
                results = out
                searching = false
            }
        }
    }
}
