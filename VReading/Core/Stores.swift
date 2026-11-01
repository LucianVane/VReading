import SwiftUI
import Observation

/// 书架数据
@Observable
final class LibraryStore {
    static let shared = LibraryStore()
    var books: [Book] = []
    var groups: [BookGroup] = []

    private init() {
        reload()
        backfillAuthors()
    }

    /// 旧版本导入的 epub 补充作者信息
    private func backfillAuthors() {
        let missing = books.filter { $0.author.isEmpty && $0.format == .epub }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for var b in missing {
                guard let zip = try? ZipArchive(url: b.fileURL), let meta = try? EPUBMeta.read(zip: zip), !meta.author.isEmpty else { continue }
                b.author = meta.author
                AppDatabase.shared.save(b)
            }
            DispatchQueue.main.async { self.reload() }
        }
    }

    func reload() {
        books = AppDatabase.shared.allBooks()
        groups = AppDatabase.shared.allGroups()
    }

    func books(in group: BookGroup) -> [Book] { sorted(books.filter { $0.groupId == group.id }) }

    // MARK: 书架排序 (置顶的书始终在前)
    enum SortMode: String, CaseIterable, Identifiable {
        case recent, added, title, progress
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return String(localized: "Recently Read")
            case .added: return String(localized: "Date Added")
            case .title: return String(localized: "Title")
            case .progress: return String(localized: "Progress")
            }
        }
    }

    var sortMode: SortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: "shelfSort") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: "shelfSort") }
    }
    var gridMode: Bool = !UserDefaults.standard.bool(forKey: "shelfList") {
        didSet { UserDefaults.standard.set(!gridMode, forKey: "shelfList") }
    }

    func sorted(_ list: [Book]) -> [Book] {
        list.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch sortMode {
            case .recent: return max(a.lastRead, a.lastTimestamp) > max(b.lastRead, b.lastTimestamp)
            case .added: return a.addTime > b.addTime
            case .title: return a.name.localizedCompare(b.name) == .orderedAscending
            case .progress: return a.progress > b.progress
            }
        }
    }

    /// 最近在读 (继续阅读卡片)
    var recentBook: Book? { books.filter { $0.lastRead > 0 && !$0.isFinished }.max { $0.lastRead < $1.lastRead } }

    func setPinned(_ list: [Book], _ v: Bool) {
        list.forEach { AppDatabase.shared.setPinned(v, for: $0.id) }
        reload()
    }

    func setFinished(_ list: [Book], _ v: Bool) {
        list.forEach { AppDatabase.shared.setFinished(v, for: $0.id) }
        reload()
    }

    func delete(_ list: [Book]) {
        list.forEach(BookImporter.delete)
        reload()
    }

    func move(_ list: [Book], to group: BookGroup?) {
        list.forEach { AppDatabase.shared.setGroup(group?.id, for: $0.id) }
        reload()
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> (ok: [Book], errors: [String]) {
        var ok: [Book] = [], errors: [String] = []
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            do { ok.append(try BookImporter.importBook(from: u)) } catch { errors.append(error.localizedDescription) }
        }
        reload()
        return (ok, errors)
    }

    func delete(_ book: Book) {
        BookImporter.delete(book)
        reload()
    }

    func createGroup(_ name: String) -> Bool {
        guard !groups.contains(where: { $0.name == name }) else { return false }
        AppDatabase.shared.save(BookGroup(id: UUID().uuidString, name: name, lastModifyTime: Int64(Date().timeIntervalSince1970 * 1000)))
        reload()
        return true
    }

    func rename(_ g: BookGroup, to name: String) {
        var g = g
        g.name = name
        g.lastModifyTime = Int64(Date().timeIntervalSince1970 * 1000)
        AppDatabase.shared.save(g)
        reload()
    }

    func deleteGroup(_ g: BookGroup) {
        AppDatabase.shared.delete(group: g)
        reload()
    }

    func move(_ book: Book, to group: BookGroup?) {
        AppDatabase.shared.setGroup(group?.id, for: book.id)
        reload()
    }
}

/// 生词本数据 + SM-2 记忆曲线
@Observable
final class VocabStore {
    static let shared = VocabStore()
    var words: [VocabWord] = []

    private init() { reload() }

    func reload() { words = AppDatabase.shared.allWords() }

    var strangeWords: [VocabWord] { words.filter(\.isStrange) }
    var learnedWords: [VocabWord] { words.filter { !$0.isStrange } }

    /// 生词的语言, 旧数据没有语言时视为英语
    static func language(of w: VocabWord) -> String { w.lang.isEmpty ? "en" : w.lang }

    func dueToday(book: String? = nil, lang: String? = nil) -> [VocabWord] {
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        return strangeWords.filter {
            $0.nextDate < end && (book == nil || $0.bookName == book) && (lang == nil || Self.language(of: $0) == lang)
        }
    }

    var bookNames: [String] { Array(Set(words.map(\.bookName).filter { !$0.isEmpty })).sorted() }

    func bookNames(lang: String) -> [String] {
        Array(Set(words.filter { Self.language(of: $0) == lang }.map(\.bookName).filter { !$0.isEmpty })).sorted()
    }

    func contains(_ word: String) -> Bool {
        words.contains { $0.isStrange && $0.word.lowercased() == word.lowercased() }
    }

    func add(word: String, sentence: String, bookName: String, lang: String, dictId: String) {
        let w = DictionaryManager.stripElision(DictionaryManager.clean(word), lang: lang)
        guard !w.isEmpty else { return }
        var v = VocabWord(word: w)
        v.sentence = sentence
        v.bookName = bookName
        v.lang = lang
        v.mdxFilename = dictId
        let info = LevelWordDB.shared(lang).info(w)
        v.phonetic = info?.pronounce ?? ""
        v.explain = DictionaryManager.shared.shortExplain(w, lang: lang)
        v.definition = info?.meaning ?? ""
        AppDatabase.shared.save(v)
        reload()
    }

    func remove(word: String) {
        AppDatabase.shared.deleteWord(word)
        reload()
    }

    func delete(_ list: [VocabWord]) {
        for w in list { AppDatabase.shared.delete(word: w) }
        reload()
    }

    /// 已掌握: 从生词库中移除, 复习时不再出现
    func markLearned(_ w: VocabWord) {
        var v = w
        v.isStrange = false
        AppDatabase.shared.save(v)
        reload()
    }

    func markStrange(_ w: VocabWord) {
        var v = w
        v.isStrange = true
        v.nextDate = Date()
        AppDatabase.shared.save(v)
        reload()
    }

    /// SM-2: quality 0 不认识 / 3 记不清 / 5 认识
    @discardableResult
    func review(_ w: VocabWord, quality q: Int) -> VocabWord {
        var v = w
        if q >= 3 {
            switch v.repetition {
            case 0: v.interval = 1
            case 1: v.interval = 6
            default: v.interval = Int((Double(v.interval) * v.easinessFactor).rounded())
            }
            v.repetition += 1
        } else {
            v.repetition = 0
            v.interval = 1
        }
        let qd = Double(5 - q)
        v.easinessFactor = max(1.3, v.easinessFactor + (0.1 - qd * (0.08 + qd * 0.02)))
        v.grade = q
        v.previousDate = Date()
        v.nextDate = Calendar.current.date(byAdding: .day, value: v.interval, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        AppDatabase.shared.save(v)
        if let i = words.firstIndex(where: { $0.id == v.id }) { words[i] = v }
        return v
    }
}
