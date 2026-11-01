import SwiftUI
import UniformTypeIdentifiers

/// 设置 Tab (对应 setting_fragments)
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var share: ShareItem?
    @State private var showWiFiDict = false
    @State private var showAddSource = false
    @State private var appLanguage = AppLanguage.selected
    @State private var showRestartHint = false
    @State private var debugDict = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("Logo").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppInfo.name).font(.headline)
                            Text(AppInfo.slogan).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Dictionaries") {
                    NavigationLink {
                        DictManagerView()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current Dictionaries")
                            Text(DictionaryManager.shared.enabled().isEmpty ? String(localized: "No local dictionary enabled") : DictionaryManager.shared.enabled().map(\.name).listFormatted)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Button { showWiFiDict = true } label: { Label("Wi-Fi Dictionary Transfer", systemImage: "wifi") }
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(settings.bookSources) { s in
                                NavigationLink { SourceBrowser(source: s) } label: {
                                    VStack(spacing: 6) {
                                        AsyncImage(url: URL(string: s.iconUrl)) { $0.resizable().scaledToFit() } placeholder: {
                                            Image(systemName: "books.vertical").foregroundStyle(Color.accentGreen)
                                        }
                                        .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(s.name).font(.caption2).lineLimit(1).frame(width: 72).foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    if settings.bookSources.isEmpty {
                        Text("No book sources. You can add one.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Book Sources")
                        Spacer()
                        Button { showAddSource = true } label: { Image(systemName: "plus.circle") }
                    }
                }

                Section("Read") {
                    NavigationLink { ReadSettingsView() } label: { Label("Reading", systemImage: "book") }
                    NavigationLink { LanguageSettingView() } label: { Label("Book Language", systemImage: "globe") }
                    NavigationLink { AISettingsView() } label: { Label("AI Settings", systemImage: "sparkles") }
                }

                Section("Other") {
                    Picker(selection: Binding(get: { appLanguage }, set: { l in
                        guard l != appLanguage else { return }
                        appLanguage = l
                        AppLanguage.selected = l
                        showRestartHint = true
                    })) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    } label: { Label("App Language", systemImage: "character.bubble") }
                    if let mail = AppInfo.feedbackEmail {
                        Button { open(String(localized: "mailto:\(mail)?subject=\(AppInfo.name) Feedback")) } label: { Label(String(localized: "Send Feedback"), systemImage: "envelope") }
                    }
                    if let u = AppInfo.faqURL {
                        NavigationLink { WebPageScreen(title: "Guide & FAQ", url: u) } label: { Label("Guide & FAQ", systemImage: "questionmark.circle") }
                    }
                    Button { share = ShareItem(items: [AppInfo.shareText]) } label: { Label("Share App", systemImage: "square.and.arrow.up") }
                    if let u = AppInfo.termsURL {
                        NavigationLink { WebPageScreen(title: "Terms of Service", url: u) } label: { Label("Terms of Service", systemImage: "doc.text") }
                    }
                    if let u = AppInfo.privacyURL {
                        NavigationLink { WebPageScreen(title: "Privacy Policy", url: u) } label: { Label("Privacy Policy", systemImage: "hand.raised") }
                    }
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(AppInfo.version).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Language Changed", isPresented: $showRestartHint) {
                Button("OK", role: .cancel) {}
            } message: { Text("Quit and reopen VReading to apply the new language.") }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .sheet(isPresented: $showWiFiDict) { WiFiTransferView(mode: .dicts) }
            .sheet(isPresented: $showAddSource) { AddBookSourceView() }
            #if DEBUG
            .sheet(isPresented: $debugDict) { NavigationStack { DictManagerView() } }
            .onAppear { if DebugAutomation.has("-autoDict") { debugDict = true } }
            #endif
        }
    }

    private func open(_ s: String) {
        if let u = URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) { UIApplication.shared.open(u) }
    }
}

// MARK: 词典管理
struct DictManagerView: View {
    @State private var settings = AppSettings.shared
    @State private var all: [DictInfo] = []
    @State private var showImporter = false
    @State private var showWiFi = false
    @State private var deleting: DictInfo?

    private static let langOrder = ["en", "fr", "es", "ja"]

    var body: some View {
        List {
            Section {
                if enabledList.isEmpty {
                    Text("No local dictionaries are enabled. Lookups will only show web dictionaries.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(enabledList) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        langTag(d.lang)
                    }
                }
                .onMove { settings.enabledDicts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { idx in
                    let ids = idx.map { enabledList[$0].id }
                    settings.enabledDicts.removeAll { ids.contains($0) }
                }
            } header: { Text("Enabled (\(enabledList.count))") } footer: {
                Text("Drag the handles to reorder; lookups follow this order. Swipe left to disable.")
            }

            Section {
                ForEach(all) { d in
                    Toggle(isOn: binding(for: d)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name)
                                Text(d.isBundled ? String(localized: "Built-in") : d.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.isBundled {
                                langTag(d.lang)
                            } else {
                                Menu {
                                    Button("Any Language") { setLang("", for: d) }
                                    ForEach(Self.langOrder, id: \.self) { l in
                                        Button(DictionaryManager.languageNames[l] ?? l) { setLang(l, for: d) }
                                    }
                                } label: { langTag(d.lang, editable: true) }
                            }
                        }
                    }
                    .tint(.accentGreen)
                    .swipeActions {
                        if !d.isBundled {
                            Button(role: .destructive) { deleting = d } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                Button { showImporter = true } label: { Label("Import Dictionary (mdx / mdd / css)", systemImage: "square.and.arrow.down") }
                Button { showWiFi = true } label: { Label("Wi-Fi Dictionary Transfer", systemImage: "wifi") }
            } header: { Text("All Local Dictionaries") } footer: {
                Text("Tap the language tag of an imported dictionary to set its language: it is then used only for books in that language, or for all books if set to Any. An mdd / css file with the same name is used as its resources and style.")
            }

            ForEach(Self.langOrder, id: \.self) { l in
                Section("Web Dictionaries · \(DictionaryManager.languageNames[l] ?? l)") {
                    ForEach(DictionaryManager.webDicts.filter { $0.lang == l }) { w in
                        Toggle(w.name, isOn: Binding(get: { settings.enabledWebDicts.contains(w.id) }, set: { on in
                            if on { settings.enabledWebDicts.append(w.id) } else { settings.enabledWebDicts.removeAll { $0 == w.id } }
                        }))
                        .tint(.accentGreen)
                    }
                }
            }
        }
        .navigationTitle("Dictionaries")
        .toolbar { EditButton() }
        .onAppear(perform: reload)
        .alert("Delete Dictionary", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let d = deleting { DictionaryManager.shared.delete(d.id); reload() }
            }
        } message: { Text("Delete “\(deleting?.name ?? "")” and its mdd / css files?") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                guard ["mdx", "mdd", "css", "js", "png", "jpg"].contains(u.pathExtension.lowercased()) else { toast(String(localized: "Only mdx, mdd, js, css and image files can be imported")); continue }
                do { _ = try DictionaryManager.shared.importFile(u); toast(String(localized: "Dictionary imported")) }
                catch { toast(String(localized: "Failed to import \(u.lastPathComponent): \(error.localizedDescription)")) }
            }
            reload()
        }
        .sheet(isPresented: $showWiFi, onDismiss: reload) { WiFiTransferView(mode: .dicts) }
    }

    private var enabledList: [DictInfo] { settings.enabledDicts.compactMap { id in all.first { $0.id == id } } }

    private func binding(for d: DictInfo) -> Binding<Bool> {
        Binding(get: { settings.enabledDicts.contains(d.id) }, set: { on in
            if on { if !settings.enabledDicts.contains(d.id) { settings.enabledDicts.append(d.id) } }
            else { settings.enabledDicts.removeAll { $0 == d.id } }
        })
    }

    private func setLang(_ l: String, for d: DictInfo) {
        var m = DictionaryManager.importedLanguages
        m[d.id] = l.isEmpty ? nil : l
        DictionaryManager.importedLanguages = m
        reload()
    }

    private func langTag(_ l: String, editable: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(l.isEmpty ? String(localized: "Any") : (DictionaryManager.languageNames[l] ?? l))
            if editable { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.accentGreen.opacity(0.15), in: Capsule())
        .foregroundStyle(.primary)
    }

    private func reload() {
        let list = DictionaryManager.shared.available()
        all = list.sorted { a, b in
            let ia = Self.langOrder.firstIndex(of: a.lang) ?? 99, ib = Self.langOrder.firstIndex(of: b.lang) ?? 99
            return ia == ib ? a.name < b.name : ia < ib
        }
    }
}

// MARK: 阅读设置 (read_setting_dialog_layout)
struct ReadSettingsView: View {
    @State private var s = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink { PronounceSettingView() } label: {
                    HStack { Text("Pronunciation"); Spacer(); Text(s.accent.title).foregroundStyle(.secondary) }
                }
                NavigationLink { LevelColorView() } label: { Text("Level Highlight Colors") }
                NavigationLink { ExamChooseView(asSheet: false) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Word levels highlighted while reading")
                        Text(levelNames).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Disable Tap to Look Up", isOn: Binding(get: { !s.tapToLookup }, set: { s.tapToLookup = !$0 }))
                Toggle("Highlight Vocabulary Words", isOn: $s.vocabHighlightEnabled)
                Toggle("Disable Level Highlighting", isOn: Binding(get: { !s.levelHighlightEnabled }, set: {
                    s.levelHighlightEnabled = !$0
                    WebReaderModel.resetLevelCache()
                }))
                Toggle("Show Library Tab", isOn: Binding(get: { !s.hideStoreTab }, set: { s.hideStoreTab = !$0 }))
                Toggle("Block External Links in Books", isOn: $s.disableExternalLinks)
                Toggle("E-ink Mode", isOn: $s.einkMode)
            } footer: { Text("E-ink mode uses black text on white and turns pages without animation.") }
            .tint(.accentGreen)
            Section {
                NavigationLink { TranslatorConfigView() } label: { Text("Translation Engines") }
            }
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var levelNames: String {
        let all = LevelWordDB.languages.flatMap { LevelWordDB.shared($0.code).levels }
        let names = s.highlightLevels.compactMap { c in all.first { $0.code == c }?.name }
        return names.isEmpty ? String(localized: "None") : names.listFormatted
    }
}

struct PronounceSettingView: View {
    @State private var s = AppSettings.shared
    var body: some View {
        List {
            Section {
                Toggle("Auto-Pronounce on Lookup", isOn: $s.speakWhenQuery)
                Toggle("Auto-Pronounce in Review", isOn: $s.speakWhenLearn)
            }
            .tint(.accentGreen)
            Section("Accent") {
                ForEach(PronounceAccent.allCases, id: \.self) { a in
                    Button {
                        s.accent = a
                        Speech.shared.speak("reader", accent: a)
                    } label: {
                        HStack {
                            Text(a.title).foregroundStyle(.primary)
                            Spacer()
                            if s.accent == a { Image(systemName: "checkmark").foregroundStyle(Color.accentGreen) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Pronunciation")
    }
}

/// 分级词汇高亮颜色配置
struct LevelColorView: View {
    @State private var s = AppSettings.shared
    var body: some View {
        List {
            ForEach(LevelWordDB.languages, id: \.code) { lang in
                Section(lang.name) {
                    ForEach(LevelWordDB.shared(lang.code).levels) { lv in
                        ColorPicker(selection: Binding(get: { Color(hex: s.levelColors[lv.code] ?? lv.dayColor) }, set: { c in
                            s.levelColors[lv.code] = c.hexString
                        })) {
                            HStack {
                                Text(lv.name)
                                Text("example").foregroundStyle(Color(hex: s.levelColors[lv.code] ?? lv.dayColor))
                            }
                        }
                    }
                }
            }
            Section("Vocabulary") {
                ColorPicker(selection: Binding(get: { Color(hex: s.levelColors[ReaderStyle.vocabCode] ?? ReaderStyle.defaultVocabColor) }, set: { c in
                    s.levelColors[ReaderStyle.vocabCode] = c.hexString
                })) {
                    HStack {
                        Text("Words")
                        let c = Color(hex: s.levelColors[ReaderStyle.vocabCode] ?? ReaderStyle.defaultVocabColor)
                        Text("example").padding(.horizontal, 2).background(c.opacity(0.15)).overlay(alignment: .bottom) { c.frame(height: 2) }
                    }
                }
            }
            Button("Reset") { s.levelColors = [:] }
        }
        .navigationTitle("Level Highlight Colors")
    }
}

/// 选择考试 (english_exam_choose_layout)
struct ExamChooseView: View {
    var asSheet = true
    @State private var s = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Which exam are you preparing for?").font(.title3.bold())
                    Text("Words at the selected levels are highlighted when you read books in that language, so you learn vocabulary as you read. French TCF/TEF levels follow the CEFR (A1–C2).")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(LevelWordDB.languages, id: \.code) { lang in
                        Text(lang.name).font(.subheadline.bold()).padding(.top, 6)
                        FlowLayout(spacing: 10) {
                            ForEach(LevelWordDB.shared(lang.code).levels) { lv in
                                let on = selected.contains(lv.code)
                                Button {
                                    if on { selected.remove(lv.code) } else { selected.insert(lv.code) }
                                } label: {
                                    Text(lang.code == "en" ? String(localized: "\(lv.name) Words") : lv.name)
                                        .font(.subheadline)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .foregroundStyle(on ? .white : Color(hex: lv.displayColor))
                                        .background(on ? Color(hex: lv.displayColor) : Color.clear, in: Capsule())
                                        .overlay(Capsule().stroke(Color(hex: lv.displayColor)))
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                if asSheet { Button("Close") { s.examChosen = true; dismiss() }.buttonStyle(.bordered) }
                Spacer()
                Button("OK") {
                    let all = LevelWordDB.languages.flatMap { LevelWordDB.shared($0.code).levels }
                    s.highlightLevels = all.map(\.code).filter { selected.contains($0) }
                    s.examChosen = true
                    WebReaderModel.resetLevelCache()
                    toast(selected.isEmpty ? String(localized: "Level words won't be highlighted") : String(localized: "Selected: \(s.highlightLevels.compactMap { c in all.first { $0.code == c }?.name }.listFormatted)"))
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(.accentGreen)
            }
        }
        .padding(24)
        .navigationTitle(asSheet ? "" : "Word Levels")
        .onAppear { selected = Set(s.highlightLevels) }
    }
}

/// 简单的流式布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: 翻译引擎配置
struct TranslatorConfigView: View {
    @State private var configs = TranslateService.shared.configs
    @State private var editing: TranslatorKind?

    var body: some View {
        List {
            Section {
                if configs.isEmpty {
                    Text("Without a configured engine, iOS system translation is used (works offline once languages are downloaded).").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(configs) { c in
                    HStack {
                        Text(c.kind.title)
                        Spacer()
                        Text("Configured").font(.caption).foregroundStyle(Color.accentGreen)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = c.kind }
                }
                .onMove { configs.move(fromOffsets: $0, toOffset: $1); save() }
                .onDelete { configs.remove(atOffsets: $0); save() }
            } header: { Text("Configured (by priority)") } footer: {
                Text("With your own key, only the provider's quota applies; the app doesn't limit translations. Long-press and drag to set priority.")
            }
            Section("Add Translation Engine") {
                ForEach(TranslatorKind.allCases.filter { k in !configs.contains { $0.kind == k } }) { k in
                    Button(k.title) { editing = k }
                }
            }
        }
        .navigationTitle("Translation Engines")
        .toolbar { EditButton() }
        .sheet(item: $editing) { k in
            TranslatorKeyForm(kind: k, values: configs.first { $0.kind == k }?.values ?? [:]) { values in
                if let values {
                    if let i = configs.firstIndex(where: { $0.kind == k }) { configs[i].values = values } else { configs.append(TranslatorConfig(kind: k, values: values)) }
                } else {
                    configs.removeAll { $0.kind == k }
                    toast(String(localized: "\(k.title) configuration cleared"))
                }
                save()
            }
        }
    }

    private func save() { TranslateService.shared.configs = configs }
}

struct TranslatorKeyForm: View {
    let kind: TranslatorKind
    @State var values: [String: String]
    var onSave: ([String: String]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(kind.fields, id: \.key) { f in
                        TextField(f.label, text: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0.trimmingCharacters(in: .whitespaces) }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: { Text(kind.faq) }
                Section {
                    Button("Clear Configuration", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .navigationTitle("\(kind.title) Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if checking { ProgressView() } else { Button("Save") { validate() } }
                }
            }
        }
    }

    private func validate() {
        guard kind.fields.prefix(kind == .azure ? 1 : kind.fields.count).allSatisfy({ !(values[$0.key] ?? "").isEmpty }) else {
            toast(String(localized: "Please fill in all fields"))
            return
        }
        checking = true
        Task {
            do {
                let r = try await TranslateService.shared.translate("Hello world", with: TranslatorConfig(kind: kind, values: values))
                await MainActor.run {
                    checking = false
                    guard !r.isEmpty else { toast(String(localized: "Configuration failed. Check that your key is correct.")); return }
                    toast(String(localized: "\(kind.title) configured"))
                    onSave(values)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    checking = false
                    toast(String(localized: "Configuration failed: \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: AI 设置
struct AISettingsView: View {
    @State private var c = AIConfig.load()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("Platform", selection: Binding(get: { c.platform }, set: { c.apply(platform: $0) })) {
                    ForEach(AIConfig.Platform.allCases) { Text($0.title).tag($0) }
                }
                SecureField("API Key", text: $c.apiKey)
                TextField("Host, e.g. https://api.openai.com", text: $c.host).keyboardType(.URL).textInputAutocapitalization(.never)
                TextField("Path, e.g. /v1/chat/completions", text: $c.path).textInputAutocapitalization(.never)
                TextField("Model, e.g. gpt-4o-mini", text: $c.model).textInputAutocapitalization(.never)
            } header: { Text("AI Configuration") } footer: {
                Text("Any provider with an OpenAI-compatible chat completions API can be configured here. Make sure the service is reachable from your network.")
            }
            Section {
                Stepper("Context Messages: \(c.contextCount)", value: $c.contextCount, in: 0...20)
            } footer: { Text("The number of recent messages sent as context. Set to 0 to disable context; the AI will only see your latest message.") }
            Section("System Prompt") {
                TextEditor(text: $c.systemPrompt).frame(minHeight: 100)
            }
            Section("AI Quick Prompts") {
                LabeledContent("Word Prompt") { TextField("", text: $c.wordCommand).multilineTextAlignment(.trailing) }
                LabeledContent("Phrase Prompt") { TextField("", text: $c.phraseCommand).multilineTextAlignment(.trailing) }
                LabeledContent("Sentence Prompt") { TextField("", text: $c.sentenceCommand).multilineTextAlignment(.trailing) }
            }
            Section {
                Button(String(localized: "Reset")) { c = AIConfig(); c.save(); toast(String(localized: "AI settings reset to defaults")) }
            }
        }
        .navigationTitle("AI Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Save")) { c.save(); toast(String(localized: "AI settings saved")); dismiss() }
            }
        }
    }
}

// MARK: 语言设置
struct LanguageSettingView: View {
    @State private var s = AppSettings.shared
    var body: some View {
        List {
            Section("Translate Into") {
                ForEach(TranslateLanguage.allCases) { l in
                    Button { s.targetLanguage = l.rawValue } label: {
                        HStack {
                            Text(l.title).foregroundStyle(.primary)
                            Spacer()
                            if s.targetLanguage == l.rawValue { Image(systemName: "checkmark").foregroundStyle(Color.accentGreen) }
                        }
                    }
                }
            }
            Section {
                Text("A book's language can be changed at the top right of its Vocabulary Profile. Level highlighting supports English, French and Spanish.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Book Language")
    }
}

extension Color {
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
