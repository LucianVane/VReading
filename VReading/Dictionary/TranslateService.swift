import Foundation
import CryptoKit

/// 翻译引擎 (对应原 App 的翻译引擎配置)
enum TranslatorKind: String, CaseIterable, Codable, Identifiable {
    case deepl, chatgpt, deepseek, baidu, youdao, tencent, caiyun, niu, azure
    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepl: return "DeepL"
        case .chatgpt: return "ChatGPT"
        case .deepseek: return "DeepSeek"
        case .baidu: return String(localized: "Baidu Translate")
        case .youdao: return String(localized: "Youdao AI Cloud")
        case .tencent: return String(localized: "Tencent Cloud Translate")
        case .caiyun: return String(localized: "Caiyun Xiaoyi")
        case .niu: return String(localized: "NiuTrans")
        case .azure: return String(localized: "Microsoft Azure")
        }
    }

    /// 需要的字段: (key, 占位提示)
    var fields: [(key: String, label: String)] {
        switch self {
        case .baidu: return [("appId", String(localized: "App ID")), ("secret", String(localized: "App Secret"))]
        case .youdao: return [("appId", String(localized: "App ID")), ("secret", String(localized: "App Secret"))]
        case .tencent: return [("appId", "SecretId"), ("secret", "SecretKey")]
        case .azure: return [("apiKey", "API Key"), ("region", String(localized: "Region (optional, e.g. eastasia)"))]
        default: return [("apiKey", "API Key")]
        }
    }

    var faq: String {
        switch self {
        case .deepl: return String(localized: "Sign up for DeepL and create an API key (500,000 free characters per month): https://www.deepl.com/")
        case .chatgpt: return String(localized: "Create an OpenAI API key at https://platform.openai.com/ (other OpenAI-compatible models can be configured in AI Settings).")
        case .deepseek: return String(localized: "Create a DeepSeek API key at https://platform.deepseek.com/")
        case .baidu: return String(localized: "Baidu Translate (1M free characters per month after verification): see https://fanyi-api.baidu.com/doc/21")
        case .youdao: return String(localized: "Create a \"Text Translation\" app with API access in Youdao AI Cloud and enter its App ID and App Secret: https://ai.youdao.com/")
        case .tencent: return String(localized: "Tencent Cloud Translate (5M free characters per month): create a SecretId / SecretKey in Access Management.")
        case .caiyun: return String(localized: "New Caiyun users get 1M free characters: https://docs.caiyunapp.com/blog/2018/09/03/lingocloud-api/")
        case .niu: return String(localized: "Create a NiuTrans API key (200,000 free characters per day): https://niutrans.com/dev-page")
        case .azure: return String(localized: "Sign in to https://portal.azure.com/, create a Translator resource (2M free characters per month) and copy its API key.")
        }
    }
}

struct TranslatorConfig: Codable, Identifiable, Hashable {
    var kind: TranslatorKind
    var values: [String: String]
    var id: String { kind.rawValue }
}

enum TranslateLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans", en, ja, ko, fr, es, de, ru
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zhHans: return String(localized: "Chinese")
        case .en: return String(localized: "English")
        case .ja: return String(localized: "Japanese")
        case .ko: return String(localized: "Korean")
        case .fr: return String(localized: "French")
        case .es: return String(localized: "Spanish")
        case .de: return String(localized: "German")
        case .ru: return String(localized: "Russian")
        }
    }
    /// Default translation target: the device's preferred language if supported, otherwise English
    static var deviceDefault: String {
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier ?? ""
            if code == "zh" { return TranslateLanguage.zhHans.rawValue }
            if let l = TranslateLanguage(rawValue: code) { return l.rawValue }
        }
        return TranslateLanguage.en.rawValue
    }

    /// 提示词中使用的英文语言名 (不随界面语言变化)
    var englishName: String {
        switch self {
        case .zhHans: return "Simplified Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .fr: return "French"
        case .es: return "Spanish"
        case .de: return "German"
        case .ru: return "Russian"
        }
    }
}

/// 文本翻译: 按用户排序依次尝试已配置的引擎, 未配置时由界面使用系统翻译 (Translation 框架)
final class TranslateService {
    static let shared = TranslateService()
    private let key = "translatorConfigs"

    var configs: [TranslatorConfig] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([TranslatorConfig].self, from: d)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    var hasEngine: Bool { !configs.isEmpty }

    func translate(_ text: String) async throws -> (engine: String, text: String) {
        var lastError: Error = ReaderError.network(String(localized: "No translation engine configured"))
        for c in configs {
            do {
                let r = try await translate(text, with: c)
                return (c.kind.title, r)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private var target: String { AppSettings.shared.targetLanguage }

    func translate(_ text: String, with c: TranslatorConfig) async throws -> String {
        let v = c.values
        switch c.kind {
        case .deepl:
            let key = v["apiKey"] ?? ""
            let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
            var req = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
            req.httpMethod = "POST"
            req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let lang = target == "zh-Hans" ? "ZH" : target.uppercased()
            req.httpBody = try JSONSerialization.data(withJSONObject: ["text": [text], "target_lang": lang])
            let j = try await json(req)
            return ((j["translations"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n")

        case .chatgpt, .deepseek:
            var ai = AIConfig.load()
            if c.kind == .deepseek {
                ai.host = "https://api.deepseek.com"; ai.path = "/chat/completions"; ai.model = "deepseek-chat"
            } else {
                ai.host = "https://api.openai.com"; ai.path = "/v1/chat/completions"; ai.model = "gpt-4o-mini"
            }
            ai.apiKey = v["apiKey"] ?? ""
            let langName = TranslateLanguage(rawValue: target)?.englishName ?? "Chinese"
            return try await AIService.complete(config: ai, messages: [
                ["role": "user", "content": "Translate the following text into \(langName). Output only the translation:\n\(text)"]
            ])

        case .baidu:
            let appid = v["appId"] ?? "", secret = v["secret"] ?? ""
            let salt = String(Int.random(in: 10000...99999))
            let sign = md5(appid + text + salt + secret)
            let to = target == "zh-Hans" ? "zh" : (target == "ja" ? "jp" : (target == "ko" ? "kor" : (target == "fr" ? "fra" : (target == "es" ? "spa" : target))))
            var comps = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!
            comps.queryItems = [.init(name: "q", value: text), .init(name: "from", value: "auto"), .init(name: "to", value: to),
                                .init(name: "appid", value: appid), .init(name: "salt", value: salt), .init(name: "sign", value: sign)]
            let j = try await json(URLRequest(url: comps.url!))
            if let err = j["error_msg"] as? String { throw ReaderError.network(String(localized: "Baidu Translate: \(err)")) }
            return ((j["trans_result"] as? [[String: Any]])?.compactMap { $0["dst"] as? String } ?? []).joined(separator: "\n")

        case .youdao:
            let appKey = v["appId"] ?? "", secret = v["secret"] ?? ""
            let salt = UUID().uuidString
            let curtime = String(Int(Date().timeIntervalSince1970))
            let input = text.count <= 20 ? text : String(text.prefix(10)) + "\(text.count)" + String(text.suffix(10))
            let sign = sha256(appKey + input + salt + curtime + secret)
            let to = target == "zh-Hans" ? "zh-CHS" : target
            var req = URLRequest(url: URL(string: "https://openapi.youdao.com/api")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form(["q": text, "from": "auto", "to": to, "appKey": appKey, "salt": salt, "sign": sign, "signType": "v3", "curtime": curtime])
            let j = try await json(req)
            if let code = j["errorCode"] as? String, code != "0" { throw ReaderError.network(String(localized: "Youdao error code: \(code)")) }
            return ((j["translation"] as? [String]) ?? []).joined(separator: "\n")

        case .tencent:
            return try await tencent(text, secretId: v["appId"] ?? "", secretKey: v["secret"] ?? "")

        case .caiyun:
            var req = URLRequest(url: URL(string: "https://api.interpreter.caiyunai.com/v1/translator")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("token \(v["apiKey"] ?? "")", forHTTPHeaderField: "x-authorization")
            let to = target == "zh-Hans" ? "zh" : target
            req.httpBody = try JSONSerialization.data(withJSONObject: ["source": [text], "trans_type": "auto2\(to)", "request_id": "vreading", "detect": true])
            let j = try await json(req)
            return ((j["target"] as? [String]) ?? []).joined(separator: "\n")

        case .niu:
            var req = URLRequest(url: URL(string: "https://api.niutrans.com/NiuTransServer/translation")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let to = target == "zh-Hans" ? "zh" : target
            req.httpBody = form(["from": "auto", "to": to, "apikey": v["apiKey"] ?? "", "src_text": text])
            let j = try await json(req)
            if let err = j["error_msg"] as? String { throw ReaderError.network(String(localized: "NiuTrans: \(err)")) }
            return j["tgt_text"] as? String ?? ""

        case .azure:
            var req = URLRequest(url: URL(string: "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=\(target)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(v["apiKey"] ?? "", forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            if let r = v["region"], !r.isEmpty { req.setValue(r, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
            req.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])
            let (data, _) = try await URLSession.shared.data(for: req)
            let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            guard let t = (arr?.first?["translations"] as? [[String: Any]])?.first?["text"] as? String else {
                throw ReaderError.network(String(localized: "Azure translation failed: \(String(decoding: data, as: UTF8.self).prefix(120))"))
            }
            return t
        }
    }

    // MARK: 腾讯云 TC3-HMAC-SHA256 签名
    private func tencent(_ text: String, secretId: String, secretKey: String) async throws -> String {
        let host = "tmt.tencentcloudapi.com"
        let ts = Int(Date().timeIntervalSince1970)
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let to = target == "zh-Hans" ? "zh" : target
        let payload = String(data: try JSONSerialization.data(withJSONObject: ["SourceText": text, "Source": "auto", "Target": to, "ProjectId": 0]), encoding: .utf8)!
        let ct = "application/json; charset=utf-8"
        let canonical = "POST\n/\n\ncontent-type:\(ct)\nhost:\(host)\n\ncontent-type;host\n\(sha256(payload))"
        let scope = "\(date)/tmt/tc3_request"
        let stringToSign = "TC3-HMAC-SHA256\n\(ts)\n\(scope)\n\(sha256(canonical))"
        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }
        let kDate = hmac(Data("TC3\(secretKey)".utf8), date)
        let kService = hmac(kDate, "tmt")
        let kSigning = hmac(kService, "tc3_request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()
        var req = URLRequest(url: URL(string: "https://\(host)")!)
        req.httpMethod = "POST"
        req.httpBody = Data(payload.utf8)
        req.setValue(ct, forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue("TextTranslate", forHTTPHeaderField: "X-TC-Action")
        req.setValue("\(ts)", forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        req.setValue("ap-guangzhou", forHTTPHeaderField: "X-TC-Region")
        req.setValue("TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=content-type;host, Signature=\(signature)", forHTTPHeaderField: "Authorization")
        let j = try await json(req)
        let resp = j["Response"] as? [String: Any]
        if let err = resp?["Error"] as? [String: Any] { throw ReaderError.network(String(localized: "Tencent Cloud: \(err["Message"] as? String ?? "")")) }
        return resp?["TargetText"] as? String ?? ""
    }

    // MARK: helpers
    private func json(_ req: URLRequest) async throws -> [String: Any] {
        var r = req
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ReaderError.network(String(localized: "Translation failed (\(code)): \(String(decoding: data, as: UTF8.self).prefix(120))"))
        }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 {
            throw ReaderError.network(String(localized: "Translation failed: invalid API key"))
        }
        return j
    }

    private func form(_ d: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(d.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    private func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
