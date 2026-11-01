import Foundation

/// AI 大模型配置 (兼容 ChatGPT chat completions 接口)
struct AIConfig: Codable, Equatable {
    enum Platform: String, Codable, CaseIterable, Identifiable {
        case chatgpt, deepseek, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chatgpt: return "ChatGPT"
            case .deepseek: return "DeepSeek"
            case .other: return String(localized: "Other")
            }
        }
    }

    static var defaultSystemPrompt: String { String(localized: "You are a language teacher helping the user learn a foreign language while reading. Keep answers short: get straight to the point, with no headings, pleasantries or follow-up questions, usually under 80 words.") }
    /// 旧版本的默认提示词 (加载配置时替换为当前默认值)
    static let oldDefaults = ["你是一个英语老师，帮助用户在阅读中学习外语。回答要简短: 直接给出要点，不要标题、不要客套话、不要追问，一般不超过120字。",
                              "你是一个英语专家，你的任务是帮助用户学习英语，回答用户的各种外语问题，例如句子语法结构、单词释义、短语用法等。根据用户的上下文提供清晰、简明的解释和示例。",
                              "给出单词的释义、用法", "详细解释下面的短语", "分析下面句子的语法"]

    // 默认使用 DeepSeek; API Key 来自 Local.xcconfig (可为空, 由用户在设置中填写)
    var platform: Platform = .deepseek
    var host = "https://api.deepseek.com"
    var path = "/chat/completions"
    var model = "deepseek-chat"
    var apiKey = Secrets.deepSeekAPIKey
    var systemPrompt = defaultSystemPrompt
    var contextCount = 4
    var wordCommand = String(localized: "Briefly explain what this word means in the sentence, with phonetics, part of speech and a short example.")
    var phraseCommand = String(localized: "Briefly explain the meaning and usage of this phrase.")
    var sentenceCommand = String(localized: "Briefly translate this sentence and point out the key grammar.")

    var isConfigured: Bool { !apiKey.isEmpty && !host.isEmpty }

    static func load() -> AIConfig {
        guard let d = UserDefaults.standard.data(forKey: "aiConfig"), var c = try? JSONDecoder().decode(AIConfig.self, from: d) else { return AIConfig() }
        // 旧版默认提示词更新为简短版本
        let def0 = AIConfig()
        if Self.oldDefaults.contains(c.systemPrompt) { c.systemPrompt = def0.systemPrompt }
        if Self.oldDefaults.contains(c.wordCommand) { c.wordCommand = def0.wordCommand }
        if Self.oldDefaults.contains(c.phraseCommand) { c.phraseCommand = def0.phraseCommand }
        if Self.oldDefaults.contains(c.sentenceCommand) { c.sentenceCommand = def0.sentenceCommand }
        // 之前保存的配置没有 key 时, 回退到内置的 DeepSeek
        if c.apiKey.isEmpty {
            let def = AIConfig()
            c.platform = def.platform; c.host = def.host; c.path = def.path; c.model = def.model; c.apiKey = def.apiKey
        }
        return c
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "aiConfig") }

    mutating func apply(platform p: Platform) {
        platform = p
        switch p {
        case .chatgpt: host = "https://api.openai.com"; path = "/v1/chat/completions"; model = "gpt-4o-mini"
        case .deepseek:
            host = "https://api.deepseek.com"; path = "/chat/completions"; model = "deepseek-chat"
            if apiKey.isEmpty { apiKey = Secrets.deepSeekAPIKey }
        case .other: break
        }
    }

    var endpoint: URL? {
        let h = host.hasSuffix("/") ? String(host.dropLast()) : host
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: h + p)
    }
}

enum AIService {
    private static func request(config: AIConfig, messages: [[String: String]], stream: Bool, maxTokens: Int? = nil, json: Bool = false, temperature: Double? = nil) throws -> URLRequest {
        guard config.isConfigured, let url = config.endpoint else { throw ReaderError.network(String(localized: "Set an API key in Settings → AI Settings first.")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = json ? 180 : 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": config.model, "messages": messages, "stream": stream]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if json { body["response_format"] = ["type": "json_object"] }
        if let temperature { body["temperature"] = temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func complete(config: AIConfig, messages: [[String: String]], maxTokens: Int? = nil, json: Bool = false, temperature: Double? = nil) async throws -> String {
        let (data, _) = try await URLSession.shared.data(for: request(config: config, messages: messages, stream: false, maxTokens: maxTokens, json: json, temperature: temperature))
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = j?["error"] as? [String: Any] { throw ReaderError.network(err["message"] as? String ?? String(localized: "AI request failed")) }
        let msg = ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return msg?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 流式输出
    static func stream(config: AIConfig, messages: [[String: String]], maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: request(config: config, messages: messages, stream: true, maxTokens: maxTokens))
                    if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ReaderError.network(String(localized: "AI request failed (\(code)): \(body.prefix(200))"))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let delta = (j["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
