import SwiftUI
import UniformTypeIdentifiers

/// 书架: 继续阅读、阅读时长、排序、宫格/列表、置顶、读完标记、分组、批量管理
struct LibraryView: View {
    @State private var store = LibraryStore.shared
    @State private var search = ""
    @State private var showImporter = false
    @State private var showWiFi = false
    @State private var showStats = false
    @State private var openBook: Book?
    @State private var dialysisBook: Book?
    @State private var detailBook: Book?
    @State private var openGroup: BookGroup?
    @State private var showCreateGroup = false
    @State private var groupName = ""
    @State private var renaming: BookGroup?
    @State private var deleting: [Book] = []
    @State private var share: ShareItem?
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var statsVersion = 0

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad 上封面更大
    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 26, alignment: .top)]
            : [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 18, alignment: .top)]
    }

    private var shelfBooks: [Book] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return store.sorted(store.books.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) })
        }
        return store.sorted(store.books.filter { b in b.groupId == nil || !store.groups.contains { $0.id == b.groupId } })
    }

    private var showGroups: Bool { search.isEmpty && !editing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if search.isEmpty && !editing {
                        statsHeader
                        if let b = store.recentBook { continueCard(b) }
                    }
                    shelfToolbar
                    if store.books.isEmpty {
                        EmptyStateView(icon: "books.vertical", text: String(localized: "Your bookshelf is empty\nTap the top-right button to import books or use Wi-Fi Transfer, or download from the Library"))
                            .frame(height: 300)
                    } else if store.gridMode {
                        LazyVGrid(columns: columns, spacing: 20) {
                            if showGroups { ForEach(store.groups) { groupCell($0) } }
                            ForEach(shelfBooks) { gridCell($0) }
                        }
                        .padding(.horizontal, 18)
                    } else {
                        LazyVStack(spacing: 0) {
                            if showGroups { ForEach(store.groups) { groupRow($0) } }
                            ForEach(shelfBooks) { listRow($0) }
                        }
                    }
                }
                .padding(.bottom, editing ? 80 : 20)
            }
            .refreshable { store.reload() }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search title or author")
            .navigationTitle("Bookshelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.books.isEmpty {
                        Button(editing ? "Done" : "Edit") {
                            withAnimation { editing.toggle(); selected = [] }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .safeAreaInset(edge: .bottom) { if editing { editBar } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { r in
                if case .success(let urls) = r {
                    let res = store.importFiles(urls)
                    if let e = res.errors.first { toast(e) } else if !res.ok.isEmpty { toast(String(localized: "Book imported")) }
                }
            }
            .sheet(isPresented: $showWiFi) { WiFiTransferView(mode: .books) }
            .sheet(isPresented: $showStats) { ReadingStatsView() }
            .sheet(item: $dialysisBook) { b in BookDialysisView(book: b, document: nil) }
            .sheet(item: $detailBook) { b in
                BookDetailView(book: b) { action in
                    detailBook = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { handle(action, b) }
                }
            }
            .sheet(item: $openGroup) { g in
                GroupBooksView(group: g) { b in
                    openGroup = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openBook = b }
                }
            }
            .sheet(item: $share) { ShareSheet(items: $0.items) }
            .fullScreenCover(item: $openBook, onDismiss: { store.reload(); statsVersion += 1 }) { b in ReaderScreen(book: b) }
            .textInputAlert(String(localized: "New Group"), isPresented: $showCreateGroup, text: $groupName, placeholder: String(localized: "Group name")) { name in
                guard !name.isEmpty else { toast(String(localized: "Please enter a group name")); return }
                if store.createGroup(name) {
                    toast(String(localized: "Group created"))
                    if !selected.isEmpty, let g = store.groups.first(where: { $0.name == name }) { moveSelected(to: g) }
                } else {
                    toast(String(localized: "A group with this name already exists"))
                }
            }
            .textInputAlert(String(localized: "Rename Group"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $groupName) { name in
                if let g = renaming, !name.isEmpty { store.rename(g, to: name); toast(String(localized: "Group renamed")) }
            }
            .alert("Delete", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    store.delete(deleting)
                    selected = []
                    if store.books.isEmpty { editing = false }
                }
            } message: {
                Text(deleting.count == 1 ? "Delete “\(deleting[0].name)”? Its file, notes and bookmarks will also be deleted." : "Delete the \(deleting.count) selected books?")
            }
            #if DEBUG
            .onAppear {
                if DebugAutomation.has("-autoWiFi") { showWiFi = true }
                if DebugAutomation.has("-autoStats") { showStats = true }
                if DebugAutomation.has("-autoList") { store.gridMode = false }
                if DebugAutomation.has("-autoEdit") { editing = true; selected = Set(store.books.prefix(1).map(\.id)) }
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .openBook)) { n in
                if let b = n.object as? Book { openBook = b }
            }
        }
    }

    static let importTypes: [UTType] = [UTType(filenameExtension: "epub") ?? .data, .pdf, .plainText]

    // MARK: 顶部
    private var statsHeader: some View {
        let _ = statsVersion
        let today = AppDatabase.shared.dailyReading(days: 1).first?.seconds ?? 0
        let week = AppDatabase.shared.dailyReading(days: 7).reduce(0) { $0 + $1.seconds }
        return Button { showStats = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Today").font(.subheadline).foregroundStyle(.secondary)
                Text("\(today / 60)").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                Text("Minutes").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("This week \(ReadingFormat.duration(week))").font(.footnote).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private func continueCard(_ b: Book) -> some View {
        Button { openBook = b } label: {
            HStack(spacing: 14) {
                BookCoverView(book: b).frame(width: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue Reading").font(.caption).foregroundStyle(Color.accentGreen)
                    Text(b.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    ProgressView(value: b.progress).tint(.accentGreen)
                    Text("Read \(ReadingFormat.percent(b.progress)) · \(ReadingFormat.relative(b.lastRead))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(Color.accentGreen)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var shelfToolbar: some View {
        HStack(spacing: 14) {
            Text(search.isEmpty ? "All Books \(store.books.count)" : "Results \(shelfBooks.count)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Picker("Sort", selection: $store.sortMode) {
                    ForEach(LibraryStore.SortMode.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(store.sortMode.title, systemImage: "arrow.up.arrow.down").font(.footnote)
            }
            Button { withAnimation { store.gridMode.toggle() } } label: {
                Image(systemName: store.gridMode ? "list.bullet" : "square.grid.2x2")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
    }

    private var addMenu: some View {
        Menu {
            Button { showImporter = true } label: { Label("Import Books", systemImage: "folder") }
            Button { showWiFi = true } label: { Label("Wi-Fi Transfer", systemImage: "wifi") }
            Button { groupName = ""; showCreateGroup = true } label: { Label("New Group", systemImage: "folder.badge.plus") }
            Button { showStats = true } label: { Label("Reading Stats", systemImage: "chart.bar") }
        } label: { Image(systemName: "plus.circle") }
    }

    // MARK: 书籍单元
    private func progressText(_ b: Book) -> String {
        if b.isFinished { return String(localized: "Finished") }
        if b.lastRead == 0 && b.progress == 0 { return String(localized: "Unread") }
        return String(localized: "Read \(ReadingFormat.percent(b.progress))")
    }

    private func tap(_ b: Book) {
        if editing {
            if selected.contains(b.id) { selected.remove(b.id) } else { selected.insert(b.id) }
        } else {
            openBook = b
        }
    }

    private func gridCell(_ b: Book) -> some View {
        Button { tap(b) } label: {
            VStack(alignment: .leading, spacing: 5) {
                BookCoverView(book: b)
                    .overlay(alignment: .topLeading) {
                        if b.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.white)
                                .padding(4).background(Color.orange, in: Circle()).padding(4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if editing {
                            Image(systemName: selected.contains(b.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(b.id) ? Color.accentGreen : .white)
                                .shadow(radius: 2).padding(5)
                        }
                    }
                    .opacity(editing && !selected.contains(b.id) ? 0.75 : 1)
                Text(b.name).font(.caption).foregroundStyle(.primary).lineLimit(2)
                Text(progressText(b)).font(.caption2)
                    .foregroundStyle(b.isFinished ? Color.accentGreen : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { if !editing { bookMenu(b) } }
    }

    private func listRow(_ b: Book) -> some View {
        Button { tap(b) } label: {
            HStack(spacing: 14) {
                if editing {
                    Image(systemName: selected.contains(b.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected.contains(b.id) ? Color.accentGreen : .secondary)
                }
                BookCoverView(book: b).frame(width: 52)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        if b.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                        Text(b.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    if !b.author.isEmpty { Text(b.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) {
                        Text(progressText(b)).foregroundStyle(b.isFinished ? Color.accentGreen : .secondary)
                        if b.lastRead > 0 { Text("· \(ReadingFormat.relative(b.lastRead))").foregroundStyle(.tertiary) }
                    }
                    .font(.caption)
                }
                Spacer()
                if !editing {
                    Menu { bookMenu(b) } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 32, height: 32)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { if !editing { bookMenu(b) } }
    }

    @ViewBuilder
    private func bookMenu(_ b: Book) -> some View {
        Button { openBook = b } label: { Label(b.lastRead > 0 ? "Continue Reading" : "Start Reading", systemImage: "book") }
        Button { detailBook = b } label: { Label("Book Details", systemImage: "info.circle") }
        Button { store.setPinned([b], !b.isPinned) } label: { Label(b.isPinned ? "Unpin" : "Pin", systemImage: b.isPinned ? "pin.slash" : "pin") }
        Button { store.setFinished([b], !b.isFinished) } label: {
            Label(b.isFinished ? "Mark as Unfinished" : "Mark as Finished", systemImage: b.isFinished ? "arrow.uturn.backward" : "checkmark.circle")
        }
        if b.format != .pdf {
            Button { dialysisBook = b } label: { Label("Vocabulary Profile", systemImage: "chart.bar.doc.horizontal") }
        }
        Menu {
            ForEach(store.groups) { g in Button(g.name) { store.move([b], to: g) } }
            Button { groupName = ""; selected = [b.id]; showCreateGroup = true } label: { Label("New Group", systemImage: "plus") }
            if b.groupId != nil { Button("Remove from Group") { store.move([b], to: nil) } }
        } label: { Label("Move to Group", systemImage: "folder") }
        Button { share = ShareItem(items: [b.fileURL]) } label: { Label("Share Book", systemImage: "square.and.arrow.up") }
        Button(role: .destructive) { deleting = [b] } label: { Label("Delete", systemImage: "trash") }
    }

    private func handle(_ action: BookDetailView.Action, _ b: Book) {
        switch action {
        case .read: openBook = b
        case .dialysis: dialysisBook = b
        case .share: share = ShareItem(items: [b.fileURL])
        case .delete: deleting = [b]
        }
    }

    // MARK: 分组
    private func groupCell(_ g: BookGroup) -> some View {
        let books = store.books(in: g)
        return Button { openGroup = g } label: {
            VStack(alignment: .leading, spacing: 5) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(books.prefix(4)) { b in BookCoverView(book: b) }
                    ForEach(0..<max(0, 4 - min(books.count, 4)), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).aspectRatio(0.7, contentMode: .fit)
                    }
                }
                .padding(6)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                Text(g.name).font(.caption).foregroundStyle(.primary).lineLimit(2)
                Text("\(books.count) books").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { groupMenu(g) }
    }

    private func groupRow(_ g: BookGroup) -> some View {
        let books = store.books(in: g)
        return Button { openGroup = g } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(Color.accentGreen.opacity(0.8))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.name).font(.subheadline.weight(.semibold))
                    Text("\(books.count) books").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { groupMenu(g) }
    }

    @ViewBuilder
    private func groupMenu(_ g: BookGroup) -> some View {
        Button { groupName = g.name; renaming = g } label: { Label("Rename Group", systemImage: "pencil") }
        Button(role: .destructive) { store.deleteGroup(g) } label: { Label("Delete Group", systemImage: "trash") }
    }

    // MARK: 批量管理
    private var selectedBooks: [Book] { store.books.filter { selected.contains($0.id) } }

    private func moveSelected(to g: BookGroup?) {
        store.move(selectedBooks, to: g)
        toast(g == nil ? String(localized: "Removed from group") : String(localized: "Moved to “\(g!.name)”"))
        selected = []
    }

    private var editBar: some View {
        let allSelected = !shelfBooks.isEmpty && selected.count == shelfBooks.count
        let none = selected.isEmpty
        return HStack(spacing: 0) {
            editButton(allSelected ? String(localized: "Deselect All") : String(localized: "Select All"), "checklist") {
                selected = allSelected ? [] : Set(shelfBooks.map(\.id))
            }
            Menu {
                ForEach(store.groups) { g in Button(g.name) { moveSelected(to: g) } }
                Button { groupName = ""; showCreateGroup = true } label: { Label("New Group", systemImage: "plus") }
                Button("Remove from Group") { moveSelected(to: nil) }
            } label: { editLabel(String(localized: "Move"), "folder") }
            .disabled(none)
            editButton(String(localized: "Finished"), "checkmark.circle", disabled: none) {
                store.setFinished(selectedBooks, true); toast(String(localized: "Marked as finished")); selected = []
            }
            editButton(String(localized: "Pin"), "pin", disabled: none) {
                let pin = selectedBooks.contains { !$0.isPinned }
                store.setPinned(selectedBooks, pin); toast(pin ? String(localized: "Pinned") : String(localized: "Unpinned")); selected = []
            }
            editButton(String(localized: "Delete"), "trash", disabled: none, role: .destructive) { deleting = selectedBooks }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func editLabel(_ t: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18))
            Text(t).font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }

    private func editButton(_ t: String, _ icon: String, disabled: Bool = false, role: ButtonRole? = nil, _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { editLabel(t, icon) }
            .disabled(disabled)
            .foregroundStyle(disabled ? Color.secondary : (role == .destructive ? Color.red : Color.primary))
    }
}

extension Notification.Name {
    static let openBook = Notification.Name("vreading.openBook")
}

enum ReadingFormat {
    static func percent(_ p: Double) -> String {
        if p <= 0 { return "0%" }
        if p < 0.01 { return "1%" }
        return "\(Int((p * 100).rounded()))%"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return seconds > 0 ? String(localized: "< 1 min") : String(localized: "0 min") }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }

    static func relative(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let s = Date().timeIntervalSince(d)
        if s < 60 { return String(localized: "Just now") }
        if s < 3600 { return String(localized: "\(Int(s / 60)) min ago") }
        if Calendar.current.isDateInToday(d) { return String(localized: "\(Int(s / 3600)) h ago") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if s < 30 * 86400 { return String(localized: "\(Int(s / 86400)) days ago") }
        return d.shortString
    }
}

// MARK: 分组内书籍
struct GroupBooksView: View {
    let group: BookGroup
    var onOpen: (Book) -> Void
    @State private var store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let books = store.books(in: group)
            ScrollView {
                if books.isEmpty {
                    EmptyStateView(icon: "folder", text: String(localized: "No books in this group yet\nLong-press a book on the shelf to move it here"))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 18, alignment: .top)], spacing: 20) {
                    ForEach(books) { b in
                        Button { onOpen(b) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                BookCoverView(book: b)
                                Text(b.name).font(.caption).lineLimit(2).foregroundStyle(.primary)
                                Text(b.isFinished ? "Finished" : (b.lastRead == 0 ? "Unread" : "Read \(ReadingFormat.percent(b.progress))"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { store.move([b], to: nil) } label: { Label("Remove from Group", systemImage: "folder.badge.minus") }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}
