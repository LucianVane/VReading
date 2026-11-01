import SwiftUI

struct DialysisWord: Identifiable, Hashable {
    let word: String
    let count: Int
    let meaning: String
    let pronounce: String
    var id: String { word }
}

/// 词汇透析: 统计书籍词汇量、字数, 按考试等级分组, 可设置阅读时高亮
struct BookDialysisView: View {
    let book: Book
    let document: ReaderDocument?
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var analyzing = true
    @State private var uniqueCount = 0
    @State private var totalCount = 0
    @State private var byLevel: [String: [DialysisWord]] = [:]
    @State private var lang = "en"

    private var db: LevelWordDB { LevelWordDB.shared(lang) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        BookCoverView(book: book).frame(width: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.name).font(.headline).lineLimit(2)
                            HStack(spacing: 20) {
                                stat(String(localized: "Unique Words"), uniqueCount)
                                stat(String(localized: "Total Words"), totalCount)
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach(LevelWordDB.languages + [("ja", String(localized: "Japanese"))], id: \.code) { l in
                                Button(l.name) {
                                    settings.bookLanguages[book.id] = l.code
                                    lang = l.code
                                    analyze()
                                }
                            }
                        } label: {
                            Text(lang).font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(hex: "#FF4B6A"), in: Capsule())
                        }
                    }
                }
                Section {
                    if analyzing {
                        HStack { ProgressView(); Text("Analyzing vocabulary...").foregroundStyle(.secondary) }
                    } else {
                        ForEach(db.levels) { lv in
                            let words = byLevel[lv.code] ?? []
                            HStack {
                                NavigationLink {
                                    LevelWordsList(level: lv, words: words, bookName: book.name, lang: lang)
                                } label: {
                                    HStack {
                                        Circle().fill(Color(hex: lv.displayColor)).frame(width: 10, height: 10)
                                        Text(lv.name)
                                        Spacer()
                                        Text("\(words.count)").foregroundStyle(.secondary)
                                    }
                                }
                                Toggle("", isOn: Binding(get: { settings.highlightLevels.contains(lv.code) }, set: { on in
                                    if on { settings.highlightLevels.append(lv.code) } else { settings.highlightLevels.removeAll { $0 == lv.code } }
                                }))
                                .labelsHidden()
                                .tint(Color(hex: lv.displayColor))
                            }
                        }
                    }
                } header: {
                    Text("Word Levels")
                } footer: {
                    Text("Check a level to highlight its words while reading. Tap the red button at the top right to change the book's language (French and Spanish are supported).")
                }
            }
            .navigationTitle("Vocabulary Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
        .onAppear {
            lang = settings.bookLanguages[book.id] ?? document?.language ?? "en"
            if !["en", "fr", "es", "ja"].contains(lang) { lang = "en" }
            analyze()
        }
    }

    private func stat(_ t: String, _ v: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(v)").font(.title3.bold()).foregroundStyle(Color.accentGreen)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func analyze() {
        analyzing = true
        let b = book, doc = document, l = lang
        DispatchQueue.global(qos: .userInitiated).async {
            let d = doc ?? (try? ReaderDocument(book: b))
            let db = LevelWordDB.shared(l)
            var counts: [String: Int] = [:]
            var total = 0
            if let d {
                let re = try? NSRegularExpression(pattern: db.wordRegex + "+")
                for i in d.chapters.indices {
                    let text = d.plainText(of: i)
                    re?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
                        guard let m, let r = Range(m.range, in: text) else { return }
                        total += 1
                        let w = text[r].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
                        guard w.count >= db.minChars else { return }
                        let base = l == "en" ? Lemmatizer.lemma(w) : w
                        counts[base, default: 0] += 1
                    }
                }
            }
            var unique = 0
            var levels: [String: [DialysisWord]] = [:]
            for (w, c) in counts {
                if l == "en" && Lemmatizer.stopwords.contains(w) { continue }
                unique += 1
                if let info = db.info(w) {
                    for lv in info.levels {
                        levels[lv, default: []].append(DialysisWord(word: w, count: c, meaning: info.meaning, pronounce: info.pronounce))
                    }
                }
            }
            for k in levels.keys { levels[k]?.sort { $0.count > $1.count } }
            DispatchQueue.main.async {
                uniqueCount = unique
                totalCount = total
                byLevel = levels
                analyzing = false
            }
        }
    }
}

struct LevelWordsList: View {
    let level: WordLevel
    let words: [DialysisWord]
    let bookName: String
    let lang: String
    @State private var vocab = VocabStore.shared
    @State private var query: WordQuery?

    var body: some View {
        List(words) { w in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(w.word).font(.headline).foregroundStyle(Color(hex: level.displayColor))
                        if !w.pronounce.isEmpty { Text("[\(w.pronounce)]").font(.caption).foregroundStyle(.secondary) }
                        Text("×\(w.count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(w.meaning).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {
                    if vocab.contains(w.word) { vocab.remove(word: w.word) } else {
                        vocab.add(word: w.word, sentence: "", bookName: bookName, lang: lang, dictId: DictionaryManager.builtinId)
                        toast(String(localized: "Added to vocabulary"))
                    }
                } label: {
                    Image(systemName: vocab.contains(w.word) ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(Color.accentGreen).font(.title3)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture { query = WordQuery(word: w.word, bookName: bookName, lang: lang) }
        }
        .listStyle(.plain)
        .navigationTitle("\(level.name) (\(words.count))")
        .sheet(item: $query) { q in WordLookupView(query: q).presentationDetents([.fraction(0.55), .large]) }
    }
}
