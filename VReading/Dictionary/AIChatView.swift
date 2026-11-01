import SwiftUI

struct AIMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String
    var content: String
}

/// AI 对话 (AI学词 / 句子分析)
struct AIChatView: View {
    var initialPrompt: String = ""
    var compact = false
    @State private var messages: [AIMessage] = []
    @State private var input = ""
    @State private var streaming = false
    @State private var config = AIConfig.load()
    @State private var showSettings = false
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            if !config.isConfigured {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Color.accentGreen)
                    Text("Let AI explain grammar, phrases and more as you read.").font(.subheadline).multilineTextAlignment(.center)
                    Text("Configure an API key for an OpenAI-compatible model (ChatGPT, DeepSeek, …) first.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("AI Settings") { showSettings = true }.buttonStyle(.borderedProminent).tint(.accentGreen)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { m in bubble(m).id(m.id) }
                            if streaming && messages.last?.content.isEmpty != false {
                                Text("Generating, please wait...").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: messages) { _, new in
                        if let last = new.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                quickCommands
                inputBar
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { config = AIConfig.load() }) {
            NavigationStack { AISettingsView() }
        }
        .onAppear {
            guard !started else { return }
            started = true
            if config.isConfigured && !initialPrompt.isEmpty { send(initialPrompt) }
        }
    }

    private func bubble(_ m: AIMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 40) }
            Text(Self.render(m.content))
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(10)
                .background(m.role == "user" ? Color.accentGreen.opacity(0.18) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            if m.role != "user" { Spacer(minLength: 20) }
        }
    }

    /// Markdown 渲染: 行内样式交给 AttributedString, 标题 / 分隔线转换为粗体和空行
    static func render(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            if t == "---" || t == "***" { return "" }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return "• " + t.dropFirst(2) }
            return line
        }
        let md = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    }

    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach([(String(localized: "Word Prompt"), config.wordCommand), (String(localized: "Phrase Prompt"), config.phraseCommand), (String(localized: "Sentence Prompt"), config.sentenceCommand)], id: \.0) { item in
                    Button(item.0) { input = item.1 + ": " + input }
                        .font(.caption).buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 4)
    }

    private var inputBar: some View {
        HStack {
            TextField("Ask a question…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button {
                if streaming { toast(String(localized: "The AI is still replying. Please wait...")); return }
                send(input)
            } label: {
                Image(systemName: "paperplane.fill").foregroundStyle(input.isEmpty ? Color.secondary : Color.accentGreen)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        var system = config.systemPrompt
        if compact { system += String(localized: "\nYou are answering inside a small lookup panel: keep it under 60 words.") }
        var history: [[String: String]] = [["role": "system", "content": system]]
        let ctx = messages.suffix(config.contextCount * 2)
        history += ctx.map { ["role": $0.role, "content": $0.content] }
        history.append(["role": "user", "content": t])
        messages.append(AIMessage(role: "user", content: t))
        messages.append(AIMessage(role: "assistant", content: ""))
        streaming = true
        let cfg = config
        Task {
            do {
                for try await chunk in AIService.stream(config: cfg, messages: history, maxTokens: compact ? 300 : 800) {
                    await MainActor.run { messages[messages.count - 1].content += chunk }
                }
            } catch {
                await MainActor.run { messages[messages.count - 1].content = "⚠️ \(error.localizedDescription)" }
            }
            await MainActor.run { streaming = false }
        }
    }
}
