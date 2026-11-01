import SwiftUI

struct WordQuery: Identifiable, Equatable {
    let id = UUID()
    var word: String
    var sentence: String = ""
    var bookName: String = ""
    var lang: String = "en"
}

/// 查词结果页 (对应原 App 的 word_query_result_layout + 词典 Tab)
struct WordLookupView: View {
    let query: WordQuery
    @Environment(\.dismiss) private var dismiss
    @State private var history: [String] = []
    @State private var word = ""
    @State private var tab = ""
    @State private var htmlByDict: [String: String] = [:]
    @State private var loading = true
    @State private var vocab = VocabStore.shared
    @State private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    private var localDicts: [DictInfo] { DictionaryManager.shared.enabled(lang: query.lang) }
    private var webDicts: [WebDict] { DictionaryManager.shared.webDicts(for: query.lang) }
    private var levelInfo: LevelWordInfo? { LevelWordDB.shared(query.lang).info(word) }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            content
            bottomBar
        }
        .background(Color(.systemBackground))
        .presentationBackground(Color(.systemBackground))
        .onAppear {
            word = DictionaryManager.stripElision(DictionaryManager.clean(query.word), lang: query.lang)
            if tab.isEmpty { tab = localDicts.first?.id ?? webDicts.first?.id ?? "ai" }
            #if DEBUG
            if DebugAutomation.has("-autoAITab") { tab = "ai" }
            if DebugAutomation.has("-autoAddTapped") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !vocab.contains(word) { vocab.add(word: word, sentence: query.sentence, bookName: query.bookName, lang: query.lang, dictId: "") }
                    dismiss()
                }
            }
            #endif
            lookup()
            if settings.speakWhenQuery { Speech.shared.speak(word, lang: query.lang) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if !history.isEmpty {
                    Button {
                        word = history.removeLast()
                        lookup()
                    } label: { Image(systemName: "chevron.left").font(.headline) }
                }
                Text(word).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6)
                Button { Speech.shared.speak(word, lang: query.lang) } label: {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentGreen)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = word
                    toast(String(localized: "Copied"))
                } label: { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                if let p = levelInfo?.pronounce, !p.isEmpty {
                    Text("[\(p)]").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(levelTags, id: \.code) { lv in
                    Text(lv.name)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .background(Color(hex: lv.displayColor), in: Capsule())
                }
            }
            if !query.sentence.isEmpty && query.sentence != word {
                Text(query.sentence).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
    }

    private var levelTags: [WordLevel] {
        let db = LevelWordDB.shared(query.lang)
        return db.levelPriority(levelInfo?.levels ?? []).compactMap { db.level(named: $0) }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(localDicts) { d in tabButton(d.isBuiltin ? String(localized: "Built-in Dictionary") : d.name.replacingOccurrences(of: String(localized: " (built-in)"), with: ""), id: d.id) }
                ForEach(webDicts) { d in tabButton(d.name, id: d.id) }
                tabButton(String(localized: "AI Explain"), id: "ai")
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 36)
    }

    private func tabButton(_ title: String, id: String) -> some View {
        Button { tab = id } label: {
            VStack(spacing: 4) {
                Text(title).font(.subheadline.weight(tab == id ? .semibold : .regular))
                    .foregroundStyle(tab == id ? Color.primary : Color.secondary)
                Capsule().fill(tab == id ? Color.accentGreen : .clear).frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let web = webDicts.first(where: { $0.id == tab }), let url = web.url(for: word) {
            SimpleWebView(url: url)
        } else if tab == "ai" {
            AIChatView(initialPrompt: "\(AIConfig.load().wordCommand): \(word)" + (query.sentence.isEmpty ? "" : String(localized: "\nSentence: \(query.sentence)")), compact: true)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let html = htmlByDict[tab] {
            DictHTMLView(html: html, dictId: tab) { w in
                history.append(word)
                word = w
                lookup()
            }
        } else {
            VStack(spacing: 14) {
                if let m = levelInfo?.meaning, !m.isEmpty {
                    Text(m.replacingOccurrences(of: ";", with: "\n")).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("“\(word)” not found").foregroundStyle(.secondary)
                }
                if let first = webDicts.first {
                    Button("Look Up Online") { tab = first.id }.buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bottomBar: some View {
        let added = vocab.contains(word)
        return Button {
            if added {
                vocab.remove(word: word)
                toast(String(localized: "Removed from vocabulary"))
            } else {
                vocab.add(word: word, sentence: query.sentence, bookName: query.bookName, lang: query.lang, dictId: localDicts.first?.id ?? "")
                toast(String(localized: "Added to vocabulary"))
            }
        } label: {
            Label(added ? "In Vocabulary (tap to remove)" : "Add to Vocabulary", systemImage: added ? "checkmark.circle.fill" : "plus.circle")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(added ? Color.gray : Color.accentGreen, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func lookup() {
        loading = true
        let w = word
        let night = scheme == .dark
        let dicts = localDicts
        let lang = query.lang
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: String] = [:]
            for d in dicts {
                if let h = DictionaryManager.shared.html(for: w, dictId: d.id, night: night, lang: lang) { out[d.id] = h }
            }
            #if DEBUG
            print("LOOKUP", w, dicts.map(\.id), out.mapValues(\.count), DictionaryManager.shared.builtinURL?.path ?? "nil")
            #endif
            DispatchQueue.main.async {
                htmlByDict = out
                loading = false
            }
        }
    }
}
