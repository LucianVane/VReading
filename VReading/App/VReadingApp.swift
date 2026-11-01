import SwiftUI

@main
struct VReadingApp: App {
    init() {
        #if DEBUG
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
        BookImporter.addDemoBookIfNeeded()
        DictionaryManager.shared.preload()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.accentGreen)
                .toastOverlay()
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case library, store, web, media, words, settings }
    @State private var tab: Tab = .library
    @State private var settings = AppSettings.shared
    @State private var showExam = false

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Bookshelf", systemImage: "books.vertical") }
                .tag(Tab.library)
            if !settings.hideStoreTab {
                BookSourcesView()
                    .tabItem { Label("Library", systemImage: "building.columns") }
                    .tag(Tab.store)
            }
            RecommendView()
                .tabItem { Label("Discover", systemImage: "star.square.on.square") }
                .tag(Tab.web)
            MultimediaView()
                .tabItem { Label("Media", systemImage: "headphones") }
                .tag(Tab.media)
            VocabularyView()
                .tabItem { Label("Review Words", systemImage: "character.book.closed") }
                .tag(Tab.words)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .fullScreenCover(isPresented: Binding(get: { !settings.agreedPolicy }, set: { _ in })) {
            PolicyView()
        }
        .sheet(isPresented: $showExam) {
            ExamChooseView().presentationDetents([.medium, .large])
        }
        .onChange(of: settings.agreedPolicy) { _, agreed in
            if agreed && !settings.examChosen { showExam = true }
        }
        .onAppear {
            if settings.agreedPolicy && !settings.examChosen { showExam = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBook)) { _ in tab = .library }
        #if DEBUG
        .task { DebugAutomation.runRoot(select: { tab = $0 }) }
        #endif
        .onOpenURL { url in
            // 从"文件"等 App 以 VReading 打开的书籍
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let book = try BookImporter.importBook(from: url)
                LibraryStore.shared.reload()
                tab = .library
                toast(String(localized: "Book imported"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .openBook, object: book)
                }
            } catch {
                toast(error.localizedDescription)
            }
        }
    }
}

/// 服务协议与隐私政策
struct PolicyView: View {
    @State private var settings = AppSettings.shared
    @State private var page: (String, URL)?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("Logo").resizable().frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 18))
            Text("Terms of Service & Privacy Policy").font(.title3.bold())
            Text("Please read the Terms of Service and Privacy Policy carefully. \(AppInfo.name) stores your books, vocabulary and notes locally on your device. Translation, AI and web dictionary features send the text you look up to the third-party services you configure.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            HStack(spacing: 18) {
                if let u = AppInfo.termsURL { Button("Terms of Service") { page = ("Terms of Service", u) } }
                if let u = AppInfo.privacyURL { Button("Privacy Policy") { page = ("Privacy Policy", u) } }
            }
            .font(.subheadline)
            Spacer()
            Button {
                settings.agreedPolicy = true
            } label: {
                Text("Agree").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundStyle(.white).background(Color.accentGreen, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .padding(28)
        .sheet(isPresented: Binding(get: { page != nil }, set: { if !$0 { page = nil } })) {
            if let page { NavigationStack { WebPageScreen(title: page.0, url: page.1) } }
        }
    }
}

#if DEBUG
/// 调试用启动参数, 便于在模拟器中自动走查主要流程 (仅 Debug 构建)
enum DebugAutomation {
    static let args = ProcessInfo.processInfo.arguments
    static func has(_ a: String) -> Bool { args.contains(a) }

    static func runRoot(select: @escaping (RootView.Tab) -> Void) {
        if let i = args.firstIndex(of: "-autoTab"), i + 1 < args.count {
            let map: [String: RootView.Tab] = ["store": .store, "web": .web, "media": .media, "words": .words, "settings": .settings]
            if let t = map[args[i + 1]] { select(t) }
        }
        if has("-autoAddVocab") {
            for w in ["gouvernement", "galoper", "maison", "citoyen"] where !VocabStore.shared.contains(w) {
                VocabStore.shared.add(word: w, sentence: "", bookName: "fr-test", lang: "fr", dictId: "")
            }
        }
        if has("-autoOpenBook") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let b = LibraryStore.shared.books.first { NotificationCenter.default.post(name: .openBook, object: b) }
            }
        }
    }

    static func runReader(engine: ReaderEngine, showMenu: @escaping () -> Void) {
        if has("-autoTapWord") {
            // 等页面准备好后点击当前页的一个单词
            func tryTap(_ n: Int) {
                guard n < 40 else { return }
                guard engine.isReady else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryTap(n + 1) }
                    return
                }
                engine.webView.evaluateJavaScript("var s=[].filter.call(document.querySelectorAll('span.erw'),function(e){var r=e.getBoundingClientRect();return r.left>0&&r.right<innerWidth&&e.textContent.length>4;}); var t=s[Math.min(5,s.length-1)]; var a=t&&t.closest?t.closest('a'):null; if(s.length){t.click();} JSON.stringify({n:s.length, word:t&&t.textContent, inLink:!!a, ct:document.contentType, hasER:!!window.ER, hasSentence:typeof getSelectionSentence, fs:getComputedStyle(document.body).fontSize, w:innerWidth, vp:(document.querySelector('meta[name=viewport]')||{}).content})") { r, e in
                    print("AUTOTAP", r ?? "nil", e?.localizedDescription ?? "", "tapToLookup=\(AppSettings.shared.tapToLookup)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { tryTap(0) }
        }
        if has("-autoSelect") {
            // 模拟长按选中一句话
            func trySelect(_ n: Int) {
                guard n < 40 else { return }
                guard engine.isReady else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { trySelect(n + 1) }
                    return
                }
                engine.webView.evaluateJavaScript("var ps=[].filter.call(document.querySelectorAll('p'),function(e){var r=e.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth&&e.textContent.length>40;}); if(ps.length){var r=document.createRange(); r.selectNodeContents(ps[0]); var s=getSelection(); s.removeAllRanges(); s.addRange(r);} ps.length") { r, e in
                    print("AUTOSELECT", r ?? "nil", e?.localizedDescription ?? "")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { trySelect(0) }
        }
        if let i = args.firstIndex(of: "-autoChapter"), i + 1 < args.count, let c = Int(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { engine.jump(chapter: c) }
        }
        if has("-autoNext") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { engine.nextPage() }
        }
        if has("-autoPinch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                engine.onPinch?(.began, 1)
                engine.onPinch?(.changed, 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { engine.onPinch?(.ended, 1.5) }
            }
        }
        if has("-autoMenu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { showMenu() }
        }
    }
}
#endif
