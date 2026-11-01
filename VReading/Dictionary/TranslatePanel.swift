import SwiftUI
import Translation

/// 句子翻译. 顺序: 已配置的翻译引擎 → 系统离线翻译(仅限已下载语言) → 免费在线翻译
/// 注意: 不能在弹出页里触发系统翻译的语言下载窗口 (iOS 26 会崩溃), 所以只在语言已安装时使用系统翻译
struct TranslatePanel: View {
    let text: String
    var sourceLang: String = "en"
    @State private var result = ""
    @State private var engine = ""
    @State private var error: String?
    @State private var loading = true
    @State private var systemConfig: TranslationSession.Configuration?
    @State private var showConfig = false
    @State private var hint: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let e = error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                    Button("Translation Engines") { showConfig = true }.font(.footnote)
                } else {
                    Text(result).font(.body).textSelection(.enabled)
                    HStack {
                        Text(engine).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = result
                            toast(String(localized: "Copied"))
                        } label: { Image(systemName: "doc.on.doc") }.font(.caption)
                        Button { Speech.shared.tts(text, lang: sourceLang) } label: { Image(systemName: "speaker.wave.2") }.font(.caption)
                    }
                    if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(hex: "#FCF8E2").opacity(0.35))
        .task(id: text) { await run() }
        .translationTask(systemConfig) { session in
            do {
                let r = try await session.translate(text)
                show(r.targetText, engine: String(localized: "System Translation (offline)"))
            } catch {
                await online()
            }
        }
        .sheet(isPresented: $showConfig) { NavigationStack { TranslatorConfigView() } }
    }

    private func show(_ r: String, engine e: String) {
        result = r
        engine = e
        error = nil
        loading = false
    }

    private func run() async {
        loading = true
        error = nil
        hint = nil
        if TranslateService.shared.hasEngine, let r = try? await TranslateService.shared.translate(text) {
            show(r.text, engine: r.engine)
            return
        }
        let target = Locale.Language(identifier: AppSettings.shared.targetLanguage)
        let source = Locale.Language(identifier: sourceLang)
        let status = await LanguageAvailability().status(from: source, to: target)
        if status == .installed {
            if systemConfig == nil {
                systemConfig = TranslationSession.Configuration(source: source, target: target)
            } else {
                systemConfig?.invalidate()
            }
        } else {
            await online()
            if status == .supported {
                hint = String(localized: "Tip: download languages in iOS Settings → Apps → Translate to use offline system translation.")
            }
        }
    }

    private func online() async {
        do {
            let r = try await FreeTranslator.translate(text, from: sourceLang, to: AppSettings.shared.targetLanguage)
            show(r.text, engine: r.engine)
        } catch {
            self.error = String(localized: "Translation failed: \(error.localizedDescription)\nYou can add engines such as DeepL in Settings → Reading → Translation Engines.")
            loading = false
        }
    }
}

/// 免 Key 的在线翻译 (谷歌 → MyMemory)
enum FreeTranslator {
    static func translate(_ text: String, from: String, to: String) async throws -> (engine: String, text: String) {
        let tl = to == "zh-Hans" ? "zh-CN" : to
        if let r = try? await google(text, tl: tl), !r.isEmpty { return (String(localized: "Google Translate"), r) }
        return ("MyMemory", try await myMemory(text, from: from, tl: tl))
    }

    private static func google(_ text: String, tl: String) async throws -> String {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: tl),
                        .init(name: "dt", value: "t"), .init(name: "q", value: text)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any], let parts = arr.first as? [Any] else {
            throw ReaderError.network(String(localized: "Google Translate returned an unexpected response"))
        }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }

    private static func myMemory(_ text: String, from: String, tl: String) async throws -> String {
        var c = URLComponents(string: "https://api.mymemory.translated.net/get")!
        c.queryItems = [.init(name: "q", value: String(text.prefix(500))), .init(name: "langpair", value: "\(from)|\(tl)")]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let t = (j?["responseData"] as? [String: Any])?["translatedText"] as? String, !t.isEmpty else {
            throw ReaderError.network(String(localized: "Online translation is unavailable. Check your network."))
        }
        return t
    }
}
