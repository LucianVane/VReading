import SwiftUI

/// 多媒体 Tab: 语言学习播客, 播放时同步显示字幕, 字幕单词可点击查询
struct MultimediaView: View {
    @State private var shows = PodcastCatalog.shows
    @State private var player = PodcastPlayer.shared
    @State private var showAdd = false
    @State private var newFeed = ""
    @State private var adding = false
    @State private var showPlayer = false
    @AppStorage("podcastLang") private var lang = "en"
    @AppStorage("recommendLevel_en") private var levelEN = "B1"
    @AppStorage("recommendLevel_fr") private var levelFR = "B1"

    /// 等级分组: A 入门 / B 中级 / C 高级
    private static let groups: [(key: String, title: String)] = [("A", String(localized: "Beginner A1–A2")), ("B", String(localized: "Intermediate B1–B2")), ("C", String(localized: "Advanced C1–C2 · Native")), ("", String(localized: "Other"))]

    private func group(of s: PodcastShow) -> String {
        let g = String(s.level.prefix(1))
        return ["A", "B", "C"].contains(g) ? g : ""
    }

    /// 与「推荐」中设置的水平相符的分组排在最前
    private var orderedGroups: [(key: String, title: String)] {
        let mine = String((lang == "en" ? levelEN : levelFR).prefix(1))
        return Self.groups.sorted { a, b in (a.key == mine ? 0 : 1) < (b.key == mine ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $lang) {
                        Text("English").tag("en")
                        Text("French").tag("fr")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                let mine = String((lang == "en" ? levelEN : levelFR).prefix(1))
                ForEach(orderedGroups, id: \.key) { g in
                    let list = shows.filter { $0.lang == lang && group(of: $0) == g.key }
                    if !list.isEmpty {
                        Section {
                            ForEach(list) { s in
                                NavigationLink { PodcastShowView(show: s) } label: { showRow(s) }
                                    .swipeActions {
                                        Button(role: .destructive) { remove(s) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(g.title)
                                if g.key == mine {
                                    Text("For You").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentGreen, in: Capsule())
                                }
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    Text("“For You” is based on your \(lang == "en" ? String(localized: "English") : String(localized: "French")) level set on the Discover tab. Synced subtitles appear during playback: the show's own transcript is used when available, otherwise one is generated on device. Tap a word to look it up, or tap a line to jump to it.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newFeed = "https://"; showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.episode != nil { MiniPlayerBar { showPlayer = true } }
            }
            .alert("Add Podcast", isPresented: $showAdd) {
                TextField("RSS feed URL", text: $newFeed).keyboardType(.URL).textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Add") { Task { await add() } }
            } message: { Text("You can find a show's RSS feed on Apple Podcasts and similar platforms") }
            .fullScreenCover(isPresented: $showPlayer) { PodcastPlayerView() }
            #if DEBUG
            .task {
                if let i = DebugAutomation.args.firstIndex(of: "-autoPodcast"), let n = Int(DebugAutomation.args[safe: i + 1] ?? ""),
                   let s = shows[safe: n], let (full, eps) = try? await PodcastFeed.fetch(s), let ep = eps.first(where: { $0.transcriptURL != nil }) ?? eps.first {
                    player.play(ep, show: full)
                    showPlayer = true
                }
            }
            #endif
            .overlay { if adding { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
        }
    }

    private func showRow(_ s: PodcastShow) -> some View {
        HStack(spacing: 12) {
            PodcastArtwork(url: s.artwork, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !s.level.isEmpty {
                        Text(s.level).font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentGreen, in: Capsule())
                    }
                }
                Text(s.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .task {
            // 补充节目封面
            guard s.artwork.isEmpty, let (full, _) = try? await PodcastFeed.fetch(s) else { return }
            if let i = shows.firstIndex(where: { $0.id == s.id }) {
                shows[i].artwork = full.artwork
                PodcastCatalog.shows = shows
            }
        }
    }

    private func remove(_ s: PodcastShow) {
        shows.removeAll { $0.id == s.id }
        PodcastCatalog.shows = shows
    }

    private func add() async {
        let u = newFeed.trimmingCharacters(in: .whitespaces)
        guard u.hasPrefix("http"), !shows.contains(where: { $0.feedURL == u }) else { toast(String(localized: "Invalid or duplicate feed URL")); return }
        adding = true
        defer { adding = false }
        do {
            let (s, eps) = try await PodcastFeed.fetch(PodcastShow(feedURL: u, title: "", lang: lang))
            shows.append(s)
            PodcastCatalog.shows = shows
            toast(String(localized: "Added “\(s.title)” (\(eps.count) episodes)"))
        } catch {
            toast(String(localized: "Failed to add: \(error.localizedDescription)"))
        }
    }
}

struct PodcastArtwork: View {
    let url: String
    let size: CGFloat
    var body: some View {
        AsyncImage(url: URL(string: url)) { $0.resizable().scaledToFill() } placeholder: {
            ZStack {
                LinearGradient(colors: [Color(hex: "#5BC26A"), Color(hex: "#2E9E8F")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "headphones").foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14))
    }
}

// MARK: 节目详情
struct PodcastShowView: View {
    enum Sort: String, CaseIterable {
        case newest = "Newest First", oldest = "Oldest First", titleAsc = "Title A→Z", titleDesc = "Title Z→A"
        var icon: String {
            switch self {
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            case .titleAsc, .titleDesc: return "textformat.abc"
            }
        }
    }

    let show: PodcastShow
    @AppStorage("podcastSort") private var sort: Sort = .newest
    @State private var search = ""
    @State private var full: PodcastShow?
    @State private var episodes: [PodcastEpisode] = []
    @State private var error: String?
    @State private var loading = true
    @State private var player = PodcastPlayer.shared
    @State private var showPlayer = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PodcastArtwork(url: (full ?? show).artwork, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text((full ?? show).title).font(.headline)
                        if !(full ?? show).author.isEmpty { Text((full ?? show).author).font(.caption).foregroundStyle(Color.accentGreen) }
                        Text((full ?? show).summary).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                    }
                }
            }
            Section {
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !loading && displayed.isEmpty && !search.isEmpty {
                    Text("No episodes match “\(search)”").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(displayed) { ep in
                    Button {
                        player.play(ep, show: full ?? show)
                        showPlayer = true
                    } label: { episodeRow(ep) }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(search.isEmpty ? "\(episodes.count) episodes" : "\(displayed.count) of \(episodes.count) episodes")
                    Spacer()
                    Text(LocalizedStringKey(sort.rawValue))
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles and descriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Label(LocalizedStringKey($0.rawValue), systemImage: $0.icon).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if player.episode != nil { MiniPlayerBar { showPlayer = true } }
        }
        .fullScreenCover(isPresented: $showPlayer) { PodcastPlayerView() }
        .task { await load() }
        .refreshable { await load() }
    }

    /// 排序 + 关键词筛选后的单集 (匹配标题和简介, 忽略大小写和重音)
    private var displayed: [PodcastEpisode] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? episodes : episodes.filter {
            $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.summary.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        switch sort {
        case .newest: list.sort { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        case .oldest: list.sort { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }
        case .titleAsc: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDesc: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
        return list
    }

    private func episodeRow(_ ep: PodcastEpisode) -> some View {
        let playing = player.episode?.id == ep.id
        let hasTranscript = ep.transcriptURL != nil || TranscriptService.cached(ep)?.complete == true
        return VStack(alignment: .leading, spacing: 4) {
            Text(ep.title).font(.subheadline.weight(.semibold)).foregroundStyle(playing ? Color.accentGreen : .primary).lineLimit(2)
            HStack(spacing: 8) {
                if let d = ep.pubDate { Text(d.shortString) }
                if ep.duration > 0 { Text(PodcastPlayer.format(ep.duration)) }
                if hasTranscript { Label("Subtitles", systemImage: "captions.bubble").labelStyle(.titleAndIcon) }
                if playing { Image(systemName: player.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Color.accentGreen) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !ep.summary.isEmpty { Text(ep.summary).font(.caption).foregroundStyle(.tertiary).lineLimit(2) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func load() async {
        do {
            let (s, eps) = try await PodcastFeed.fetch(show)
            full = s
            episodes = eps
            error = nil
        } catch {
            self.error = String(localized: "Failed to load: \(error.localizedDescription)")
        }
        loading = false
    }
}

// MARK: 迷你播放条
struct MiniPlayerBar: View {
    var onOpen: () -> Void
    @State private var player = PodcastPlayer.shared

    var body: some View {
        if let ep = player.episode {
            HStack(spacing: 12) {
                PodcastArtwork(url: ep.artwork.isEmpty ? (player.show?.artwork ?? "") : ep.artwork, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0).tint(.accentGreen)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }
}

// MARK: 播放页: 同步字幕
struct PodcastPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player = PodcastPlayer.shared
    @State private var query: WordQuery?
    @State private var resumeAfterLookup = false
    @State private var followPlayback = true
    @State private var dragging: Double?
    @State private var translator = CueTranslator.shared
    @AppStorage("podcastTranslate") private var translateOn = false
    @AppStorage("podcastTranslateTarget") private var translateTarget = TranslateLanguage.deviceDefault

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            controls
        }
        .sheet(item: $query, onDismiss: {
            if resumeAfterLookup { player.resume() }
        }) { q in
            WordLookupView(query: q).presentationDetents([.fraction(0.55), .large])
        }
        .onAppear(perform: configureTranslator)
        .onChange(of: translateTarget) { configureTranslator() }
        .onChange(of: translateOn) { if translateOn { configureTranslator() } }
        .onChange(of: player.cues.count) { translator.updateCues(player.cues); requestAroundCurrent() }
        .onChange(of: player.currentCueIndex) { requestAroundCurrent() }
    }

    private func configureTranslator() {
        guard translateOn, let ep = player.episode else { return }
        translator.configure(episode: ep, cues: player.cues, sourceLang: player.show?.lang ?? "en", target: translateTarget)
        requestAroundCurrent()
    }

    /// 翻译当前句附近的字幕 (边听边翻)
    private func requestAroundCurrent() {
        guard translateOn, !player.cues.isEmpty else { return }
        let c = player.currentCueIndex ?? 0
        translator.request(Array(max(0, c - 3)...min(player.cues.count - 1, c + 20)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3) }
            if let ep = player.episode {
                PodcastArtwork(url: ep.artwork.isEmpty ? (player.show?.artwork ?? "") : ep.artwork, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(player.show?.title ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Toggle("Show Translation", isOn: $translateOn)
                Picker("Translate To", selection: $translateTarget) {
                    ForEach(TranslateLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "translate").font(.subheadline.bold()).accessibilityLabel(Text("Translate"))
                    if translator.busy && translateOn { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(translateOn ? .white : Color.accentGreen)
                .frame(minWidth: 30, minHeight: 30)
                .padding(.horizontal, 4)
                .background(translateOn ? Color.accentGreen : Color.accentGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcript: some View {
        if player.cues.isEmpty {
            VStack(spacing: 12) {
                if let e = player.transcriptError {
                    Image(systemName: "captions.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { player.loadTranscript() }.buttonStyle(.bordered)
                } else {
                    ProgressView()
                    Text(player.transcriptStatus.isEmpty ? String(localized: "Preparing subtitles...") : player.transcriptStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("For long episodes, the audio is downloaded and transcribed on device the first time. You can start listening; subtitles will appear progressively.").font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let current = player.currentCueIndex
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        // iPad 上限制字幕宽度并居中
                        if !player.transcriptComplete {
                            HStack { ProgressView().controlSize(.small); Text(player.transcriptStatus).font(.caption2).foregroundStyle(.secondary) }
                                .padding(.horizontal, 16)
                        }
                        ForEach(player.cues) { cue in
                            CueRow(cue: cue, isCurrent: cue.id == current, time: cue.id == current ? player.currentTime : 0,
                                   translation: translateOn ? translator.translations[cue.id] : nil, translating: translateOn) { word in
                                lookup(word, sentence: cue.text)
                            } onSeek: {
                                player.seek(to: cue.start)
                                followPlayback = true
                            }
                            .id(cue.id)
                            .onAppear { if translateOn { translator.request([cue.id]) } }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .simultaneousGesture(DragGesture().onChanged { _ in followPlayback = false })
                .onChange(of: current) { _, c in
                    guard followPlayback, let c else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(c, anchor: .center) }
                }
                .onAppear { if let c = current { proxy.scrollTo(c, anchor: .center) } }
                .overlay(alignment: .bottomTrailing) {
                    if !followPlayback {
                        Button {
                            followPlayback = true
                            if let c = current { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                        } label: {
                            Label("Back to Current", systemImage: "location.fill").font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { dragging ?? player.currentTime }, set: { dragging = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let d = dragging { player.seek(to: d); dragging = nil }
            }
            .tint(.accentGreen)
            HStack {
                Text(PodcastPlayer.format(dragging ?? player.currentTime))
                Spacer()
                Text("-" + PodcastPlayer.format(max(0, player.duration - (dragging ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Menu {
                    ForEach([0.5, 0.75, 0.9, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button(String(format: "%.2gx", r)) { player.setRate(Float(r)) }
                    }
                } label: {
                    Text(String(format: "%.2gx", player.rate)).font(.subheadline.bold()).frame(width: 56)
                }
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56))
                        .foregroundStyle(Color.accentGreen)
                }
                Spacer()
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
                Spacer()
                Button { previousCue() } label: { Image(systemName: "arrow.uturn.backward.circle").font(.title2) }
                    .frame(width: 56)
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// 重听当前句
    private func previousCue() {
        guard let i = player.currentCueIndex else { player.skip(-5); return }
        player.seek(to: player.cues[i].start)
        if !player.isPlaying { player.resume() }
    }

    private func lookup(_ word: String, sentence: String) {
        let w = DictionaryManager.clean(word)
        guard !w.isEmpty else { return }
        resumeAfterLookup = player.isPlaying
        player.pause()
        query = WordQuery(word: w, sentence: sentence, bookName: player.show?.title ?? "", lang: player.show?.lang ?? "fr")
    }
}

/// 一句字幕: 单词可点击查词, 当前句高亮, 有逐词时间时高亮当前单词
struct CueRow: View {
    let cue: TranscriptCue
    let isCurrent: Bool
    let time: Double
    var translation: CueTranslation? = nil
    var translating = false
    var onWord: (String) -> Void
    var onSeek: () -> Void

    private var tokens: [(text: String, start: Double?)] {
        if let words = cue.words, !words.isEmpty {
            return words.map { ($0.text.trimmingCharacters(in: .whitespaces), $0.start) }
        }
        return cue.text.split(separator: " ").map { (String($0), nil) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(PodcastPlayer.format(cue.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
                .onTapGesture(perform: onSeek)
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 4) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { i, t in
                        let active = isCurrent && t.start != nil && t.start! <= time && (i + 1 >= tokens.count || (tokens[i + 1].start ?? .infinity) > time)
                        let word = DictionaryManager.clean(t.text).lowercased()
                        let idiom = !word.isEmpty && (translation?.notes.contains { n in
                            n.phrase.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).contains { $0 == word }
                        } ?? false)
                        Text(t.text)
                            .font(.system(size: 17))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                            .padding(.horizontal, 1)
                            .background(active ? Color.accentGreen.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 3))
                            .overlay(alignment: .bottom) {
                                // 习语 / 俚语下方加点线提示
                                if idiom { Rectangle().fill(Color.orange).frame(height: 1.5).offset(y: 1) }
                            }
                            .onTapGesture { onWord(t.text) }
                    }
                }
                if let tr = translation {
                    Text(tr.text).font(.subheadline).foregroundStyle(isCurrent ? Color.accentGreen : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(tr.notes, id: \.self) { n in
                        (Text("💡 ") + Text(n.phrase).bold() + Text("  \(n.note)"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if translating {
                    Text("Translating...").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isCurrent ? Color.accentGreen.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSeek)
    }
}
