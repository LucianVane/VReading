import SwiftUI

/// 背单词 (learning_vocabulary_fragment): 卡片 + 不认识 / 记不清 / 认识
struct LearnWordsView: View {
    @State var words: [VocabWord]
    @Environment(\.dismiss) private var dismiss
    @State private var store = VocabStore.shared
    @State private var index = 0
    @State private var revealed = false
    @State private var reviewInfo = ""
    @State private var drag: CGSize = .zero
    @State private var total = 0
    @State private var showAI = false

    private var current: VocabWord? { words[safe: index] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let w = current {
                    Text("\(min(index + 1, words.count)) / \(words.count)")
                        .font(.footnote).foregroundStyle(.secondary)
                    ZStack {
                        if let next = words[safe: index + 1] {
                            cardShell { WordCardContent(word: next, revealed: false) }
                                .scaleEffect(0.95).offset(y: 10).opacity(0.6)
                        }
                        cardShell {
                            VStack(spacing: 0) {
                                WordCardContent(word: w, revealed: revealed)
                                if revealed {
                                    HStack {
                                        Button {
                                            store.markLearned(w)
                                            toast(String(localized: "Removed from vocabulary"))
                                            advance(remove: true)
                                        } label: { Label("Remove Word", systemImage: "trash") }
                                            .font(.footnote).foregroundStyle(.red)
                                        Spacer()
                                        Button("AI Explain") { showAI = true }.font(.footnote).buttonStyle(.bordered)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                        .offset(drag)
                        .rotationEffect(.degrees(Double(drag.width / 25)))
                        .gesture(revealed ? nil : DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { v in
                                if v.translation.width > 120 { answer(5) } else if v.translation.width < -120 { answer(0) }
                                withAnimation(.spring) { drag = .zero }
                            })
                        .overlay(alignment: .top) {
                            if abs(drag.width) > 40 {
                                Text(drag.width > 0 ? "Know It" : "Don't Know")
                                    .font(.headline).foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(drag.width > 0 ? Color.accentGreen : Color.red, in: Capsule())
                                    .padding(.top, 10)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if revealed {
                        Text(reviewInfo).font(.footnote).foregroundStyle(.secondary)
                        Button {
                            advance(remove: false)
                        } label: {
                            Text("Next").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .foregroundStyle(.white).background(Color(hex: "#30AFC6"), in: RoundedRectangle(cornerRadius: 22))
                        }
                    } else {
                        HStack(spacing: 0) {
                            gradeButton(String(localized: "Don't Know"), "eye.slash.fill", .red) { answer(0) }
                            gradeButton(String(localized: "Not Sure"), "questionmark.circle.fill", .orange) { answer(3) }
                            gradeButton(String(localized: "Know It"), "face.smiling.inverse", .accentGreen) { answer(5) }
                        }
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 70)).foregroundStyle(Color.accentGreen)
                    Text("All done!").font(.title2.bold())
                    Text("You reviewed \(total) words").foregroundStyle(.secondary)
                    Button("Back") { dismiss() }.buttonStyle(.borderedProminent).tint(.accentGreen)
                    Spacer()
                }
            }
            .padding(20)
            .navigationTitle("Review Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .sheet(isPresented: $showAI) {
                if let w = current {
                    AIChatView(initialPrompt: "\(AIConfig.load().wordCommand): \(w.word)" + (w.sentence.isEmpty ? "" : String(localized: "\nSentence: \(w.sentence)")))
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .onAppear {
            total = Set(words.map(\.word)).count
            speakCurrent()
        }
    }

    private func cardShell<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private func gradeButton(_ t: String, _ icon: String, _ color: Color, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(color, in: Circle())
                Text(t).font(.footnote).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func answer(_ q: Int) {
        guard let w = current else { return }
        let updated = store.review(w, quality: q)
        words[index] = updated
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        reviewInfo = String(localized: "Reviews: \(updated.repetition), next review: \(f.string(from: updated.nextDate))")
        // 不认识的单词本轮稍后再出现一次
        if q == 0 { words.append(updated) }
        withAnimation { revealed = true }
    }

    private func advance(remove: Bool) {
        withAnimation {
            if remove { words.removeAll { $0.word == current?.word && $0.sentence == current?.sentence } } else { index += 1 }
            revealed = false
        }
        speakCurrent()
    }

    private func speakCurrent() {
        if AppSettings.shared.speakWhenLearn, let w = current { Speech.shared.speak(w.word, lang: w.lang) }
    }
}

/// 单词卡片内容: 单词、发音、原文句子、释义
struct WordCardContent: View {
    let word: VocabWord
    let revealed: Bool
    @State private var html: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(word.word).font(.system(size: 30, weight: .bold))
                Button { Speech.shared.speak(word.word, lang: word.lang) } label: {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentGreen)
                }
                Spacer()
            }
            if !word.phonetic.isEmpty { Text("[\(word.phonetic)]").foregroundStyle(.secondary) }
            if !word.sentence.isEmpty {
                Text("[Sentence]").font(.caption).foregroundStyle(.tertiary)
                highlightedSentence.font(.callout)
                if !word.bookName.isEmpty { Text("Source: \(word.bookName)").font(.caption2).foregroundStyle(.tertiary) }
            }
            if revealed {
                Text("[Definition]").font(.caption).foregroundStyle(.tertiary)
                if let html {
                    DictHTMLView(html: html, dictId: dictId).frame(minHeight: 200)
                } else {
                    Text(word.explain.isEmpty ? word.definition : word.explain).font(.callout)
                    Spacer(minLength: 0)
                }
            }
        }
        .onChange(of: revealed) { load() }
        .onAppear { if revealed { load() } }
    }

    private var dictId: String { word.mdxFilename.isEmpty ? DictionaryManager.builtinId : word.mdxFilename }

    private func load() {
        guard revealed, html == nil else { return }
        let w = word.word, id = dictId
        DispatchQueue.global().async {
            let h = DictionaryManager.shared.html(for: w, dictId: id, night: false)
                ?? DictionaryManager.shared.enabled().lazy.compactMap { DictionaryManager.shared.html(for: w, dictId: $0.id, night: false) }.first
            DispatchQueue.main.async { html = h }
        }
    }

    private var highlightedSentence: Text {
        let s = word.sentence
        guard let r = s.range(of: word.word, options: .caseInsensitive) else { return Text(s) }
        return Text(s[..<r.lowerBound]) + Text(s[r]).foregroundColor(.accentGreen).bold() + Text(s[r.upperBound...])
    }
}
