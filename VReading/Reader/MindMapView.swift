import SwiftUI

/// 书籍思维导图: AI 生成, 节点可跳转到原文位置 (页码按当前排版换算)
struct MindMapView: View {
    let engine: ReaderEngine
    var onJump: (MindLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mindMapLang") private var langRaw = MindMapLanguage.preferred.rawValue
    @AppStorage("mindMapMode") private var outline = false
    @State private var map: MindMap?
    @State private var generating = false
    @State private var progress = ""
    @State private var error: String?
    @State private var selected: MindNode?
    @State private var share: ShareItem?
    @State private var task: Task<Void, Never>?
    @State private var expanded = Set<String>()

    private var lang: MindMapLanguage { MindMapLanguage(rawValue: langRaw) ?? .preferred }

    var body: some View {
        NavigationStack {
            Group {
                if let map {
                    if outline {
                        MindOutline(root: map.root, pageOf: page(of:)) { selected = $0 }
                    } else {
                        MindTreeCanvas(root: map.root, pageOf: page(of:), expanded: $expanded) { selected = $0 }
                    }
                } else if generating {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(progress.isEmpty ? String(localized: "Preparing...") : progress).font(.subheadline).foregroundStyle(.secondary)
                        Text("AI is reading the book and extracting key points. Long books take 1–2 minutes.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 54)).foregroundStyle(Color.accentGreen)
                        Text("AI Mind Map").font(.title3.bold())
                        Text("AI reads the whole book and organizes its key plot points, ideas and characters into a mind map. Every point links to its place in the text; tap to jump there.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
                        Button { generate() } label: {
                            Label("Generate Mind Map in \(lang.title)", systemImage: "sparkles").frame(maxWidth: 260).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent).tint(.accentGreen)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Mind Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $outline) {
                        Text("Map").tag(false)
                        Text("Outline").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Language", selection: $langRaw) {
                            ForEach(MindMapLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        if let map {
                            if !outline {
                                let all = Set(map.root.children.map(\.id))
                                Button {
                                    withAnimation { expanded = expanded == all ? [] : all }
                                } label: {
                                    Label(expanded == all ? "Collapse All" : "Expand All", systemImage: expanded == all ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                }
                            }
                            Button { generate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                            Button { exportImage() } label: { Label("Export Image", systemImage: "square.and.arrow.up") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(generating)
                }
            }
            .sheet(item: $selected) { n in nodeDetail(n) }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
        }
        .onAppear {
            loadCached()
            #if DEBUG
            if map == nil && DebugAutomation.has("-autoGenMind") { generate() }
            if DebugAutomation.has("-autoOutline") { outline = true }
            if DebugAutomation.has("-autoTree") { outline = false }
            if DebugAutomation.has("-autoExpand"), let m = map { expanded = Set(m.root.children.prefix(2).map(\.id)) }
            #endif
        }
        .onChange(of: langRaw) { loadCached() }
        .onDisappear { task?.cancel() }
    }

    private func loadCached() {
        error = nil
        map = MindMapGenerator.cached(bookId: engine.document.book.id, lang: lang)
        // 旧版本生成的导图也按原书顺序排列
        if let m = map { map?.root = m.root.ordered() }
    }

    private func generate() {
        guard !generating else { return }
        generating = true
        error = nil
        map = nil
        progress = ""
        let gen = MindMapGenerator(document: engine.document, language: lang, bookLang: engine.lang)
        gen.onProgress = { progress = $0 }
        task = Task {
            do {
                let m = try await gen.generate()
                await MainActor.run { map = m }
            } catch {
                await MainActor.run { self.error = String(localized: "Generation failed: \(error.localizedDescription)") }
            }
            await MainActor.run { generating = false }
        }
    }

    /// 按当前排版换算全书页码
    private func page(of loc: MindLocation?) -> Int? {
        guard let loc, engine.chapterPageCounts.indices.contains(loc.chapter) else { return nil }
        var counts = engine.chapterPageCounts
        if counts.indices.contains(engine.chapterIndex) { counts[engine.chapterIndex] = engine.pageCount }
        let start = counts.prefix(loc.chapter).reduce(0, +)
        let inChapter = Int(loc.ratio * Double(counts[loc.chapter]))
        return start + min(inChapter, max(counts[loc.chapter] - 1, 0)) + 1
    }

    private func nodeDetail(_ n: MindNode) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(n.title).font(.headline)
                    if !n.detail.isEmpty { Text(n.detail).font(.subheadline) }
                }
                if let loc = n.location {
                    Section("Location in Text") {
                        if !loc.quote.isEmpty {
                            Text("“\(loc.quote)…”").font(.callout.italic()).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(engine.document.chapters[safe: loc.chapter]?.title ?? String(localized: "Chapter \(loc.chapter + 1)"))
                            Spacer()
                            if let p = page(of: loc) { Text("Page \(p)").foregroundStyle(.secondary) }
                        }
                        .font(.footnote)
                        Button {
                            selected = nil
                            dismiss()
                            onJump(loc)
                        } label: { Label("Go to Text", systemImage: "book") }
                    }
                }
                if !n.children.isEmpty {
                    Section("Points") {
                        ForEach(n.children) { c in
                            Button { selected = c } label: {
                                HStack {
                                    Text(c.title).foregroundStyle(.primary)
                                    Spacer()
                                    if let p = page(of: c.location) { Text("p.\(p)").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { selected = nil } label: { Image(systemName: "xmark") } } }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func exportImage() {
        guard let map else { return }
        let content = MindTreeDiagram(root: map.root, pageOf: page(of:), expanded: Set(map.root.children.map(\.id)), onTap: { _ in })
            .padding(30)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let img = renderer.uiImage, let data = img.pngData() else { toast(String(localized: "Export failed")); return }
        let url = Paths.exports.appendingPathComponent(String(localized: "\(engine.document.book.name)_MindMap.png"))
        try? data.write(to: url)
        share = ShareItem(items: [url])
    }
}

// MARK: 树状导图 (可缩放、拖动)
struct MindTreeCanvas: View {
    let root: MindNode
    let pageOf: (MindLocation?) -> Int?
    @Binding var expanded: Set<String>
    var onTap: (MindNode) -> Void
    @State private var scale: CGFloat = 0.85
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                MindTreeDiagram(root: root, pageOf: pageOf, expanded: expanded, onToggle: { id in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo(id, anchor: .leading) }
                    }
                }, onTap: onTap)
                .padding(20)
                .scaleEffect(scale * pinch, anchor: .topLeading)
            }
        }
        .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
            .onEnded { v in scale = min(2, max(0.4, scale * v.magnification)) })
        .background(Color(.systemGroupedBackground))
    }
}

/// 从左到右展开的思维导图: 书名居中于分支列, 分支按原书顺序编号, 点击分支展开要点
struct MindTreeDiagram: View {
    let root: MindNode
    let pageOf: (MindLocation?) -> Int?
    var expanded: Set<String>
    var onToggle: (String) -> Void = { _ in }
    var onTap: (MindNode) -> Void

    static let palette: [Color] = [Color(hex: "#10B981"), Color(hex: "#0EA5E9"), Color(hex: "#8B5CF6"),
                                   Color(hex: "#F59E0B"), Color(hex: "#EF4444"), Color(hex: "#EC4899"),
                                   Color(hex: "#14B8A6"), Color(hex: "#6366F1"), Color(hex: "#84CC16")]

    var body: some View {
        HStack(alignment: .center, spacing: 34) {
            rootNode
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(root.children.enumerated()), id: \.element.id) { i, b in
                    branchRow(b, index: i, color: Self.palette[i % Self.palette.count])
                }
            }
        }
        .backgroundPreferenceValue(LinkKey.self) { ends in
            GeometryReader { proxy in
                Canvas { ctx, _ in
                    let rects = Dictionary(ends.map { ($0.id, proxy[$0.bounds]) }, uniquingKeysWith: { a, _ in a })
                    for e in ends {
                        guard let parent = e.parent, let p = rects[parent] else { continue }
                        let r = proxy[e.bounds]
                        let start = CGPoint(x: p.maxX, y: p.midY)
                        let end = CGPoint(x: r.minX, y: r.midY)
                        var path = Path()
                        path.move(to: start)
                        let dx = (end.x - start.x) * 0.55
                        path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                        ctx.stroke(path, with: .color(e.color.opacity(e.isPoint ? 0.45 : 0.75)),
                                   style: StrokeStyle(lineWidth: e.isPoint ? 1.5 : 2.5, lineCap: .round))
                    }
                }
            }
        }
    }

    private var rootNode: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "book.closed.fill").font(.title3).foregroundStyle(.white.opacity(0.85))
            Text(root.title).font(.headline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text("\(root.children.count) sections · \(root.children.reduce(0) { $0 + $1.children.count }) points")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
        .padding(14)
        .frame(width: 140, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(hex: "#1F2937"), Color(hex: "#111827")], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .onTapGesture { onTap(root) }
        .anchorPreference(key: LinkKey.self, value: .bounds) { [LinkEnd(id: root.id, parent: nil, color: .clear, bounds: $0, isPoint: false)] }
    }

    private func branchRow(_ b: MindNode, index: Int, color: Color) -> some View {
        let open = expanded.contains(b.id)
        return HStack(alignment: .center, spacing: 30) {
            // 分支: 序号 + 标题 + 要点数, 点击展开/收起
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(color)
                    .frame(width: 20, height: 20).background(.white, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).font(.subheadline.bold()).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: "\(b.children.count) points") + (pageOf(b.firstLocation).map { " · p.\($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(width: 170, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: color.opacity(0.35), radius: 5, y: 2)
            .contentShape(Rectangle())
            .onTapGesture { onToggle(b.id) }
            .onLongPressGesture { onTap(b) }
            .anchorPreference(key: LinkKey.self, value: .bounds) { [LinkEnd(id: b.id, parent: root.id, color: color, bounds: $0, isPoint: false)] }
            .id(b.id)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(b.children) { p in pointCard(p, parent: b.id, color: color) }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }

    private func pointCard(_ p: MindNode, parent: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.footnote.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if !p.detail.isEmpty {
                    Text(p.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let page = pageOf(p.location) {
                Text("p.\(page)").font(.caption2.monospacedDigit().bold()).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.12), in: Capsule())
            }
        }
        .padding(8)
        .frame(width: 230, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 1))
        .onTapGesture { onTap(p) }
        .anchorPreference(key: LinkKey.self, value: .bounds) { [LinkEnd(id: p.id, parent: parent, color: color, bounds: $0, isPoint: true)] }
    }
}

private struct LinkEnd {
    let id: String
    let parent: String?
    let color: Color
    let bounds: Anchor<CGRect>
    let isPoint: Bool
}

private struct LinkKey: PreferenceKey {
    static var defaultValue: [LinkEnd] = []
    static func reduce(value: inout [LinkEnd], nextValue: () -> [LinkEnd]) { value.append(contentsOf: nextValue()) }
}

// MARK: 大纲视图
struct MindOutline: View {
    let root: MindNode
    let pageOf: (MindLocation?) -> Int?
    var onTap: (MindNode) -> Void

    var body: some View {
        List {
            if !root.detail.isEmpty {
                Section { Text(root.detail).font(.subheadline).foregroundStyle(.secondary) } header: { Text(root.title) }
            }
            ForEach(Array(root.children.enumerated()), id: \.element.id) { i, b in
                Section {
                    DisclosureGroup {
                        ForEach(b.children) { p in
                            Button { onTap(p) } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(p.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        if !p.detail.isEmpty { Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if let page = pageOf(p.location) {
                                        Text("p.\(page)").font(.caption.monospacedDigit()).foregroundStyle(Color.accentGreen)
                                    }
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i + 1). \(b.title)").font(.headline)
                            if !b.detail.isEmpty { Text(b.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
