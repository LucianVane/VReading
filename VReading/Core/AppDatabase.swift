import Foundation

enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    static var books: URL { dir(documents, "Books") }
    static var dictionaries: URL { dir(documents, "Dictionaries") }
    static var covers: URL { dir(support, "Covers") }
    static var epubCache: URL { dir(caches, "EpubCache") }
    static var exports: URL { dir(caches, "Exports") }
    static var downloads: URL { dir(caches, "Downloads") }

    private static func dir(_ base: URL, _ name: String) -> URL {
        let u = base.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    static func bundled(_ name: String) -> URL? {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return Bundle.main.url(forResource: base, withExtension: ext)
    }

    static var webBundle: URL { Bundle.main.url(forResource: "Web", withExtension: "bundle")! }
}

/// App 主数据库: 书架、生词本、书签、笔记
final class AppDatabase {
    static let shared = AppDatabase()
    let db: SQLiteDB

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        db = try! SQLiteDB(path: Paths.support.appendingPathComponent("vreading.db").path)
        migrate()
    }

    private func migrate() {
        if db.userVersion < 1 {
            db.exec("""
            CREATE TABLE IF NOT EXISTS book_library (
                book_id TEXT not NULL, book_name TEXT, book_path TEXT unique not NULL,
                cover TEXT, last_timestamp INTEGER, book_group_id TEXT);
            CREATE TABLE IF NOT EXISTS words (
                book_name TEXT, word TEXT not NULL, explain TEXT, is_strange INTEGER, add_date TEXT,
                sentence TEXT, pronounce_url TEXT, definition TEXT, phonetic TEXT, repetition INTEGER,
                _interval INTEGER, easinessFactor REAL, previousDateTimestamp INTEGER, nextDateTimestamp INTEGER,
                grade INTEGER, mdx_filename TEXT, lang TEXT, unique(word, sentence));
            CREATE TABLE IF NOT EXISTS bookmarks (
                book_id TEXT not NULL, book_path TEXT not NULL, file_type TEXT, chapter_title TEXT,
                bookmark TEXT not NULL, create_date TEXT, summary TEXT, unique(book_id, bookmark));
            CREATE TABLE IF NOT EXISTS book_groups (
                id TEXT not NULL, name TEXT not NULL, lastModifyTime INTEGER, unique(id));
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY, book_id TEXT NOT NULL, chapter_index INTEGER, chapter_title TEXT,
                start_offset INTEGER, end_offset INTEGER, content TEXT, note TEXT, color TEXT, date INTEGER);
            """)
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            for col in ["author TEXT", "progress REAL DEFAULT 0", "is_finished INTEGER DEFAULT 0", "is_pinned INTEGER DEFAULT 0",
                        "read_seconds INTEGER DEFAULT 0", "add_time INTEGER DEFAULT 0", "last_read INTEGER DEFAULT 0"] {
                db.exec("ALTER TABLE book_library ADD COLUMN \(col)")
            }
            db.exec("UPDATE book_library SET add_time = last_timestamp WHERE add_time = 0")
            db.exec("CREATE TABLE IF NOT EXISTS reading_log (day TEXT NOT NULL, book_id TEXT NOT NULL, seconds INTEGER DEFAULT 0, PRIMARY KEY(day, book_id))")
            db.userVersion = 2
        }
    }

    // MARK: 书架
    func allBooks() -> [Book] {
        db.query("SELECT * FROM book_library ORDER BY last_timestamp DESC").map {
            var b = Book(id: $0.str("book_id") ?? "", name: $0.str("book_name") ?? "", path: $0.str("book_path") ?? "",
                         cover: $0.str("cover"), lastTimestamp: $0.int("last_timestamp"), groupId: $0.str("book_group_id"))
            b.author = $0.str("author") ?? ""
            b.progress = $0.dbl("progress")
            b.isFinished = $0.int("is_finished") != 0
            b.isPinned = $0.int("is_pinned") != 0
            b.readSeconds = Int($0.int("read_seconds"))
            b.addTime = $0.int("add_time")
            b.lastRead = $0.int("last_read")
            return b
        }
    }

    func book(path: String) -> Book? { allBooks().first { $0.path == path } }

    func save(_ b: Book) {
        db.run("INSERT OR REPLACE INTO book_library (book_id, book_name, book_path, cover, last_timestamp, book_group_id, author, progress, is_finished, is_pinned, read_seconds, add_time, last_read) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
               args: [b.id, b.name, b.path, b.cover, b.lastTimestamp, b.groupId, b.author, b.progress, b.isFinished, b.isPinned,
                      b.readSeconds, b.addTime, b.lastRead])
    }

    func touch(_ bookId: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        db.run("UPDATE book_library SET last_timestamp = ?, last_read = ? WHERE book_id = ?", now, now, bookId)
    }

    func setProgress(_ p: Double, for bookId: String) {
        db.run("UPDATE book_library SET progress = ? WHERE book_id = ?", min(max(p, 0), 1), bookId)
        if p >= 0.995 { db.run("UPDATE book_library SET is_finished = 1 WHERE book_id = ?", bookId) }
    }

    func setFinished(_ v: Bool, for bookId: String) {
        db.run("UPDATE book_library SET is_finished = ? WHERE book_id = ?", v, bookId)
    }

    func setPinned(_ v: Bool, for bookId: String) {
        db.run("UPDATE book_library SET is_pinned = ? WHERE book_id = ?", v, bookId)
    }

    // MARK: 阅读时长
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func addReadingTime(_ seconds: Int, bookId: String) {
        guard seconds > 0 else { return }
        let day = Self.dayFormatter.string(from: Date())
        db.run("INSERT OR IGNORE INTO reading_log (day, book_id, seconds) VALUES (?,?,0)", day, bookId)
        db.run("UPDATE reading_log SET seconds = seconds + ? WHERE day = ? AND book_id = ?", seconds, day, bookId)
        db.run("UPDATE book_library SET read_seconds = read_seconds + ? WHERE book_id = ?", seconds, bookId)
    }

    /// 最近 n 天每天的阅读秒数 (从旧到新)
    func dailyReading(days n: Int) -> [(day: Date, seconds: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(n - 1), to: today)!
        var map: [String: Int] = [:]
        for r in db.query("SELECT day, SUM(seconds) AS s FROM reading_log WHERE day >= ? GROUP BY day", Self.dayFormatter.string(from: start)) {
            map[r.str("day") ?? ""] = Int(r.int("s"))
        }
        return (0..<n).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            return (d, map[Self.dayFormatter.string(from: d)] ?? 0)
        }
    }

    var totalReadingSeconds: Int { Int(db.scalar("SELECT IFNULL(SUM(seconds),0) FROM reading_log")) }
    var readingDays: Int { Int(db.scalar("SELECT COUNT(DISTINCT day) FROM reading_log WHERE seconds >= 60")) }

    func delete(book: Book) {
        db.run("DELETE FROM book_library WHERE book_id = ?", book.id)
        db.run("DELETE FROM bookmarks WHERE book_id = ?", book.id)
        db.run("DELETE FROM notes WHERE book_id = ?", book.id)
    }

    func setGroup(_ groupId: String?, for bookId: String) {
        db.run("UPDATE book_library SET book_group_id = ? WHERE book_id = ?", groupId, bookId)
    }

    // MARK: 分组
    func allGroups() -> [BookGroup] {
        db.query("SELECT * FROM book_groups ORDER BY lastModifyTime DESC").map {
            BookGroup(id: $0.str("id") ?? "", name: $0.str("name") ?? "", lastModifyTime: $0.int("lastModifyTime"))
        }
    }

    func save(_ g: BookGroup) {
        db.run("INSERT OR REPLACE INTO book_groups (id, name, lastModifyTime) VALUES (?,?,?)", g.id, g.name, g.lastModifyTime)
    }

    func delete(group: BookGroup) {
        db.run("DELETE FROM book_groups WHERE id = ?", group.id)
        db.run("UPDATE book_library SET book_group_id = NULL WHERE book_group_id = ?", group.id)
    }

    // MARK: 生词
    private func word(from r: Row) -> VocabWord {
        var w = VocabWord(word: r.str("word") ?? "")
        w.bookName = r.str("book_name") ?? ""
        w.explain = r.str("explain") ?? ""
        w.isStrange = r.int("is_strange") != 0
        w.addDate = Self.dateFormatter.date(from: r.str("add_date") ?? "") ?? Date()
        w.sentence = r.str("sentence") ?? ""
        w.pronounceUrl = r.str("pronounce_url") ?? ""
        w.definition = r.str("definition") ?? ""
        w.phonetic = r.str("phonetic") ?? ""
        w.repetition = Int(r.int("repetition"))
        w.interval = Int(r.int("_interval"))
        let ef = r.dbl("easinessFactor")
        w.easinessFactor = ef < 1.3 ? 2.5 : ef
        let prev = r.int("previousDateTimestamp")
        w.previousDate = prev > 0 ? Date(timeIntervalSince1970: Double(prev) / 1000) : nil
        let next = r.int("nextDateTimestamp")
        w.nextDate = next > 0 ? Date(timeIntervalSince1970: Double(next) / 1000) : w.addDate
        w.grade = Int(r.int("grade"))
        w.mdxFilename = r.str("mdx_filename") ?? ""
        w.lang = r.str("lang") ?? "en"
        return w
    }

    func allWords() -> [VocabWord] {
        db.query("SELECT * FROM words ORDER BY add_date DESC").map(word(from:))
    }

    func words(matching word: String) -> [VocabWord] {
        db.query("SELECT * FROM words WHERE lower(word) = lower(?)", word).map(self.word(from:))
    }

    func isInVocabulary(_ word: String) -> Bool {
        db.scalar("SELECT count(*) FROM words WHERE lower(word) = lower(?) AND is_strange = 1", word) > 0
    }

    func save(_ w: VocabWord) {
        db.run("""
        INSERT OR REPLACE INTO words (book_name, word, explain, is_strange, add_date, sentence, pronounce_url, definition,
            phonetic, repetition, _interval, easinessFactor, previousDateTimestamp, nextDateTimestamp, grade, mdx_filename, lang)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, args: [w.bookName, w.word, w.explain, w.isStrange, Self.dateFormatter.string(from: w.addDate), w.sentence,
                    w.pronounceUrl, w.definition, w.phonetic, w.repetition, w.interval, w.easinessFactor,
                    w.previousDate.map { Int64($0.timeIntervalSince1970 * 1000) },
                    Int64(w.nextDate.timeIntervalSince1970 * 1000), w.grade, w.mdxFilename, w.lang])
    }

    func delete(word: VocabWord) {
        db.run("DELETE FROM words WHERE word = ? AND sentence = ?", word.word, word.sentence)
    }

    func deleteWord(_ text: String) {
        db.run("DELETE FROM words WHERE lower(word) = lower(?)", text)
    }

    // MARK: 书签
    func bookmarks(bookId: String) -> [BookmarkItem] {
        db.query("SELECT * FROM bookmarks WHERE book_id = ? ORDER BY create_date DESC", bookId).map {
            BookmarkItem(bookId: $0.str("book_id") ?? "", bookPath: $0.str("book_path") ?? "", fileType: $0.str("file_type") ?? "",
                         chapterTitle: $0.str("chapter_title") ?? "", bookmark: $0.str("bookmark") ?? "",
                         createDate: Self.dateFormatter.date(from: $0.str("create_date") ?? "") ?? Date(),
                         summary: $0.str("summary") ?? "")
        }
    }

    func save(_ b: BookmarkItem) {
        db.run("INSERT OR REPLACE INTO bookmarks (book_id, book_path, file_type, chapter_title, bookmark, create_date, summary) VALUES (?,?,?,?,?,?,?)",
               b.bookId, b.bookPath, b.fileType, b.chapterTitle, b.bookmark, Self.dateFormatter.string(from: b.createDate), b.summary)
    }

    func delete(bookmark b: BookmarkItem) {
        db.run("DELETE FROM bookmarks WHERE book_id = ? AND bookmark = ?", b.bookId, b.bookmark)
    }

    // MARK: 笔记
    func notes(bookId: String, chapter: Int? = nil) -> [NoteItem] {
        let rows = chapter == nil
            ? db.query("SELECT * FROM notes WHERE book_id = ? ORDER BY chapter_index, start_offset", bookId)
            : db.query("SELECT * FROM notes WHERE book_id = ? AND chapter_index = ? ORDER BY start_offset", bookId, chapter!)
        return rows.map {
            NoteItem(id: $0.str("id") ?? "", bookId: $0.str("book_id") ?? "", chapterIndex: Int($0.int("chapter_index")),
                     chapterTitle: $0.str("chapter_title") ?? "", start: Int($0.int("start_offset")), end: Int($0.int("end_offset")),
                     content: $0.str("content") ?? "", note: $0.str("note") ?? "", color: $0.str("color") ?? "yellow",
                     date: Date(timeIntervalSince1970: Double($0.int("date")) / 1000))
        }
    }

    func save(_ n: NoteItem) {
        db.run("INSERT OR REPLACE INTO notes (id, book_id, chapter_index, chapter_title, start_offset, end_offset, content, note, color, date) VALUES (?,?,?,?,?,?,?,?,?,?)",
               n.id, n.bookId, n.chapterIndex, n.chapterTitle, n.start, n.end, n.content, n.note, n.color, Int64(n.date.timeIntervalSince1970 * 1000))
    }

    func delete(noteId: String) {
        db.run("DELETE FROM notes WHERE id = ?", noteId)
    }
}
