import SwiftUI

/// 背单词 Tab (对应 vocabulary_fragment_layout_new). 不同语言的生词分开记忆
struct VocabularyView: View {
    @State private var store = VocabStore.shared
    @State private var search = ""
    @State private var query: WordQuery?
    @State private var bookFilter: String?
    @State private var showLearn = false
    @State private var showExport = false
    @AppStorage("vocabLang") private var lang = "en"

    /// 当前语言的未掌握生词
    private var filtered: [VocabWord] {
        store.strangeWords.filter { VocabStore.language(of: $0) == lang && (bookFilter == nil || $0.bookName == bookFilter) }
    }

    private var learnedCount: Int {
        store.learnedWords.filter { VocabStore.language(of: $0) == lang && (bookFilter == nil || $0.bookName == bookFilter) }.count
    }

    private var due: [VocabWord] { store.dueToday(book: bookFilter, lang: lang) }

    /// 英语、法语始终显示; 其他语言有生词时才显示
    private var languages: [String] {
        var list = ["en", "fr"]
        for l in ["es", "ja"] where store.words.contains(where: { VocabStore.language(of: $0) == l }) { list.append(l) }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Language", selection: $lang) {
                        ForEach(languages, id: \.self) { l in
                            Text(DictionaryManager.languageNames[l] ?? l).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: lang) { bookFilter = nil }

                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Look up a word…", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit {
                                let w = search.trimmingCharacters(in: .whitespaces)
                                if !w.isEmpty { query = WordQuery(word: w, lang: lang) }
                            }
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                    Image("KeepLearning").resizable().scaledToFit().frame(maxHeight: 220)

                    card
                    Text("Reviews are scheduled along the forgetting curve for efficient memorization.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Review Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .onAppear {
                store.reload()
                #if DEBUG
                if DebugAutomation.has("-autoAddWords") && store.words.isEmpty {
                    for w in ["melancholy", "acquaintance", "frequented", "singularities"] {
                        store.add(word: w, sentence: "It is not without melancholy that I wander among my recollections.", bookName: "The Moon and Sixpence", lang: "en", dictId: DictionaryManager.builtinId)
                    }
                }
                if DebugAutomation.has("-autoExport") {
                    for f in VocabExportFormat.allCases { print("EXPORT", (try? VocabExporter.export(store.words, format: f).path) ?? "fail") }
                }
                if DebugAutomation.has("-autoLearn") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showLearn = true } }
                #endif
            }
            .sheet(item: $query) { q in WordLookupView(query: q).presentationDetents([.fraction(0.6), .large]) }
            .sheet(isPresented: $showExport) {
                ExportOptionsView(words: store.words.filter { VocabStore.language(of: $0) == lang && (bookFilter == nil || $0.bookName == bookFilter) })
            }
            .fullScreenCover(isPresented: $showLearn, onDismiss: { store.reload() }) {
                LearnWordsView(words: due)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            HStack {
                Menu {
                    Button("All Words") { bookFilter = nil }
                    ForEach(store.bookNames(lang: lang), id: \.self) { n in Button("“\(n)”") { bookFilter = n } }
                } label: {
                    Label(bookFilter.map { "“\($0)”" } ?? String(localized: "All \(DictionaryManager.languageNames[lang] ?? "") Words"), systemImage: "line.3.horizontal.decrease.circle")
                        .font(.footnote).lineLimit(1)
                }
                Spacer()
            }
            VStack(spacing: 4) {
                Text("\(due.count)").font(.system(size: 46, weight: .bold)).foregroundStyle(Color.accentGreen)
                Text("Due Today").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                NavigationLink {
                    WordListView(title: String(localized: "\(DictionaryManager.languageNames[lang] ?? "") Vocabulary"), learned: false, bookFilter: bookFilter, lang: lang)
                } label: {
                    Label("All Words (\(filtered.count))", systemImage: "book.closed").frame(maxWidth: .infinity)
                }
                NavigationLink {
                    WordListView(title: String(localized: "Mastered"), learned: true, bookFilter: bookFilter, lang: lang)
                } label: {
                    Label("Mastered (\(learnedCount))", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            Button {
                if filtered.isEmpty { toast(String(localized: "\(DictionaryManager.languageNames[lang] ?? "") vocabulary is empty")) }
                else if due.isEmpty { toast(String(localized: "No words due today!")) }
                else { showLearn = true }
            } label: {
                Text("Start Review").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(.white).background(Color.accentGreen, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}

// MARK: 生词列表 (StrangeVocabulariesActivity)
struct WordListView: View {
    enum Sort: String, CaseIterable { case dateDesc = "Date (Newest)", dateAsc = "Date (Oldest)", charDesc = "Z → A", charAsc = "A → Z" }
    let title: String
    let learned: Bool
    var bookFilter: String?
    /// 只显示该语言的单词
    var lang: String = "en"
    @State private var store = VocabStore.shared
    @State private var sort: Sort = .dateDesc
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var detail: VocabWord?
    @State private var confirmDelete = false

    private var words: [VocabWord] {
        let base = (learned ? store.learnedWords : store.strangeWords)
            .filter { VocabStore.language(of: $0) == lang && (bookFilter == nil || $0.bookName == bookFilter) }
        switch sort {
        case .dateDesc: return base.sorted { $0.addDate > $1.addDate }
        case .dateAsc: return base.sorted { $0.addDate < $1.addDate }
        case .charDesc: return base.sorted { $0.word.lowercased() > $1.word.lowercased() }
        case .charAsc: return base.sorted { $0.word.lowercased() < $1.word.lowercased() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Sort.allCases, id: \.self) { s in
                        Button(LocalizedStringKey(s.rawValue)) { sort = s }
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(sort == s ? .white : .primary)
                            .background(sort == s ? Color.accentGreen : Color(.secondarySystemBackground), in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if words.isEmpty {
                EmptyStateView(icon: "text.book.closed", text: learned ? String(localized: "No mastered words yet") : String(localized: "Your vocabulary is empty"))
            } else {
                List(words, selection: editing ? $selected : nil) { w in
                    row(w).tag(w.id)
                        .swipeActions {
                            Button(role: .destructive) { store.delete([w]) } label: { Label("Delete", systemImage: "trash") }
                            if learned {
                                Button { store.markStrange(w) } label: { Label("Learn Again", systemImage: "arrow.uturn.backward") }.tint(.orange)
                            } else {
                                Button { store.markLearned(w) } label: { Label("Mastered", systemImage: "checkmark") }.tint(.accentGreen)
                            }
                        }
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(editing ? .active : .inactive))
            }
            if editing {
                HStack {
                    Button(selected.count == words.count ? "Deselect All" : "Select All") {
                        selected = selected.count == words.count ? [] : Set(words.map(\.id))
                    }
                    Spacer()
                    Button("Delete (\(selected.count))", role: .destructive) {
                        if selected.isEmpty { toast(String(localized: "No words selected")) } else { confirmDelete = true }
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle("\(title) (\(words.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "Done" : "Edit") { editing.toggle(); selected = [] }
            }
        }
        .alert("Delete", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.delete(words.filter { selected.contains($0.id) })
                selected = []
                editing = false
            }
        } message: { Text("Delete the selected words?") }
        .sheet(item: $detail) { w in WordDetailSheet(word: w) }
    }

    private func row(_ w: VocabWord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(w.word).font(.headline)
                    if !w.phonetic.isEmpty { Text("[\(w.phonetic)]").font(.caption).foregroundStyle(.secondary) }
                }
                if !w.explain.isEmpty { Text(w.explain).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                if !w.bookName.isEmpty { Text("Source: \(w.bookName)").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button { Speech.shared.speak(w.word, lang: w.lang) } label: {
                Image(systemName: "speaker.wave.2").foregroundStyle(Color.accentGreen)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { detail = w } }
    }
}

/// 单词详情 (word_detail_dialog_fragment)
struct WordDetailSheet: View {
    let word: VocabWord
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            WordCardContent(word: word, revealed: true)
                .padding()
                .navigationTitle("Definition")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: 导出
struct ExportOptionsView: View {
    let words: [VocabWord]
    @Environment(\.dismiss) private var dismiss
    @State private var format: VocabExportFormat = .apkg
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(VocabExportFormat.allCases) { f in
                        Button { format = f } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.title).foregroundStyle(.primary)
                                    Text(f.desc).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if format == f { Image(systemName: "checkmark").foregroundStyle(Color.accentGreen) }
                            }
                        }
                    }
                } footer: { Text("\(words.count) words") }
                Section {
                    Button("Export") {
                        do { share = ShareItem(items: [try VocabExporter.export(words, format: format)]) }
                        catch { toast(error.localizedDescription) }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.accentGreen)
                }
            }
            .navigationTitle("Export Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
        }
        .presentationDetents([.medium, .large])
    }
}
