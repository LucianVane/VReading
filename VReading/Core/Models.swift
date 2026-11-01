import Foundation

enum BookFormat: String {
    case epub, pdf, txt

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "txt": self = .txt
        default: return nil
        }
    }

    static let importableExtensions = ["epub", "pdf", "txt"]
}

/// 书架中的图书 (对应 book_library 表)
struct Book: Identifiable, Hashable {
    var id: String
    var name: String
    /// Documents/Books 下的相对路径
    var path: String
    /// Covers 下的相对路径
    var cover: String?
    var lastTimestamp: Int64
    var groupId: String?
    var author: String = ""
    /// 阅读进度 0...1
    var progress: Double = 0
    var isFinished = false
    var isPinned = false
    /// 累计阅读时长(秒)
    var readSeconds: Int = 0
    var addTime: Int64 = 0
    /// 最近阅读时间(毫秒), 0 表示未读
    var lastRead: Int64 = 0

    var fileURL: URL { Paths.books.appendingPathComponent(path) }
    var coverURL: URL? { cover.map { Paths.covers.appendingPathComponent($0) } }
    var format: BookFormat { BookFormat(path: path) ?? .epub }
}

struct BookGroup: Identifiable, Hashable {
    var id: String
    var name: String
    var lastModifyTime: Int64
}

/// 生词 (对应 words 表), 带 SM-2 记忆曲线字段
struct VocabWord: Identifiable, Hashable {
    var word: String
    var bookName: String = ""
    var explain: String = ""
    var isStrange: Bool = true
    var addDate: Date = Date()
    var sentence: String = ""
    var pronounceUrl: String = ""
    var definition: String = ""
    var phonetic: String = ""
    var repetition: Int = 0
    var interval: Int = 0
    var easinessFactor: Double = 2.5
    var previousDate: Date?
    var nextDate: Date = Date()
    var grade: Int = 0
    var mdxFilename: String = ""
    var lang: String = "en"

    var id: String { word + "\u{1}" + sentence }
}

struct BookmarkItem: Identifiable, Hashable {
    var bookId: String
    var bookPath: String
    var fileType: String
    var chapterTitle: String
    /// 位置: "章节索引|章节内进度" 或 pdf 页码
    var bookmark: String
    var createDate: Date
    var summary: String

    var id: String { bookId + bookmark }
}

/// 划线 / 笔记
struct NoteItem: Identifiable, Hashable {
    var id: String
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var start: Int
    var end: Int
    var content: String
    var note: String
    /// yellow / green / blue / pink / underline
    var color: String
    var date: Date
}

struct TOCItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var chapterIndex: Int
    var fragment: String?
    var level: Int
}
