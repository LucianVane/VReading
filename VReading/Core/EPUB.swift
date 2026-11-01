import Foundation
import UIKit
import NaturalLanguage

/// 极简 XML DOM (基于 XMLParser), 用于解析 container.xml / opf / ncx / nav
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    weak var parent: XNode?

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func all(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out.append(contentsOf: c.all(n))
        }
        return out
    }

    func first(_ n: String) -> XNode? {
        for c in children {
            if c.name == n { return c }
            if let f = c.first(n) { return f }
        }
        return nil
    }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }

    var fullText: String { (text + children.map(\.fullText).joined()).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) -> XNode? {
        let b = Builder()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.delegate = b
        p.parse()
        return b.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        static func local(_ s: String) -> String {
            (s.split(separator: ":").last.map(String.init) ?? s).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            var a: [String: String] = [:]
            for (k, v) in attributes { a[Self.local(k)] = v; a[k.lowercased()] = v }
            let n = XNode(name: Self.local(elementName), attrs: a)
            n.parent = stack.last
            stack.last?.children.append(n)
            if root == nil { root = n }
            stack.append(n)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

/// epub 元数据 (导入书籍时使用, 不需要整本解压)
struct EPUBMeta {
    var title: String
    var author: String
    var language: String
    var opfPath: String
    var coverPath: String?
    var spine: [String]          // zip 内路径
    var manifest: [String: (href: String, type: String, props: String)]
    var tocPath: String?         // ncx 或 nav 的 zip 内路径
    var tocIsNav: Bool

    static func resolve(_ href: String, base: String) -> String {
        let h = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for comp in h.split(separator: "/") {
            if comp == ".." { _ = parts.popLast() } else if comp != "." { parts.append(String(comp)) }
        }
        return parts.joined(separator: "/")
    }

    static func read(zip: ZipArchive) throws -> EPUBMeta {
        guard let cd = zip.data(for: "META-INF/container.xml"), let container = XNode.parse(cd),
              let opfPath = container.first("rootfile")?.attrs["full-path"],
              let od = zip.data(for: opfPath), let opf = XNode.parse(od) else {
            throw ReaderError.invalidFile(String(localized: "Invalid EPUB structure"))
        }
        let base = (opfPath as NSString).deletingLastPathComponent
        let md = opf.first("metadata")
        let title = md?.first("title")?.fullText ?? ""
        let author = md?.first("creator")?.fullText ?? ""
        let language = md?.first("language")?.fullText ?? "en"

        var manifest: [String: (String, String, String)] = [:]
        for item in opf.first("manifest")?.all("item") ?? [] {
            guard let id = item.attrs["id"], let href = item.attrs["href"] else { continue }
            manifest[id] = (resolve(href, base: base), item.attrs["media-type"] ?? "", item.attrs["properties"] ?? "")
        }
        var cover: String?
        if let coverId = md?.all("meta").first(where: { $0.attrs["name"] == "cover" })?.attrs["content"] {
            cover = manifest[coverId]?.0 ?? manifest.values.first { $0.0.hasSuffix(coverId) }?.0
        }
        if cover == nil { cover = manifest.values.first { $0.2.contains("cover-image") }?.0 }
        if cover == nil { cover = manifest.first { $0.key.lowercased().contains("cover") && $0.value.1.hasPrefix("image") }?.value.0 }

        let spineNode = opf.first("spine")
        let spine = (spineNode?.all("itemref") ?? []).compactMap { manifest[$0.attrs["idref"] ?? ""]?.0 }
        var tocPath: String?
        var isNav = false
        if let nav = manifest.values.first(where: { $0.2.split(separator: " ").contains("nav") }) {
            tocPath = nav.0; isNav = true
        } else if let ncxId = spineNode?.attrs["toc"], let ncx = manifest[ncxId] {
            tocPath = ncx.0
        } else if let ncx = manifest.values.first(where: { $0.1 == "application/x-dtbncx+xml" }) {
            tocPath = ncx.0
        }
        return EPUBMeta(title: title, author: author, language: language, opfPath: opfPath, coverPath: cover,
                        spine: spine, manifest: manifest.mapValues { (href: $0.0, type: $0.1, props: $0.2) },
                        tocPath: tocPath, tocIsNav: isNav)
    }
}

/// 阅读器使用的书籍内容: 每章一个本地 html 文件
final class ReaderDocument {
    struct Chapter {
        let url: URL
        var title: String
    }

    let book: Book
    let rootDir: URL
    private(set) var chapters: [Chapter] = []
    private(set) var toc: [TOCItem] = []
    private(set) var language = "en"

    init(book: Book) throws {
        self.book = book
        rootDir = Paths.epubCache.appendingPathComponent(book.id, isDirectory: true)
        switch book.format {
        case .epub: try loadEPUB()
        case .txt: try loadTXT()
        case .pdf: throw ReaderError.unsupported(String(localized: "PDFs are opened with the PDF reader"))
        }
        if chapters.isEmpty { throw ReaderError.invalidFile(String(localized: "The book is empty")) }
    }

    private func loadEPUB() throws {
        let zip = try ZipArchive(url: book.fileURL)
        let meta = try EPUBMeta.read(zip: zip)
        language = String(meta.language.prefix(2)).lowercased()
        let marker = rootDir.appendingPathComponent(".extracted")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: rootDir)
            try zip.extractAll(to: rootDir)
            try Data().write(to: marker)
        }
        chapters = meta.spine.map { Chapter(url: rootDir.appendingPathComponent($0), title: "") }

        if let tp = meta.tocPath, let d = zip.data(for: tp), let root = XNode.parse(d) {
            let base = (tp as NSString).deletingLastPathComponent
            if meta.tocIsNav {
                let nav = root.all("nav").first { ($0.attrs["type"] ?? "").contains("toc") } ?? root.first("nav")
                if let ol = nav?.child("ol") ?? nav?.first("ol") { parseNavList(ol, base: base, spine: meta.spine, level: 0) }
            } else if let navMap = root.first("navmap") {
                parseNCX(navMap, base: base, spine: meta.spine, level: 0)
            }
        }
        // 章节标题: 取目录中第一个指向该章节的条目
        for item in toc where chapters[item.chapterIndex].title.isEmpty {
            chapters[item.chapterIndex].title = item.title
        }
        var last = book.name
        for i in chapters.indices {
            if chapters[i].title.isEmpty { chapters[i].title = last } else { last = chapters[i].title }
        }
        if toc.isEmpty {
            toc = chapters.enumerated().map { TOCItem(title: $1.title, chapterIndex: $0, fragment: nil, level: 0) }
        }
    }

    private func addToc(title: String, href: String, base: String, spine: [String], level: Int) {
        let path = EPUBMeta.resolve(href, base: base)
        let frag = href.contains("#") ? href.components(separatedBy: "#").last : nil
        guard let idx = spine.firstIndex(of: path) else { return }
        let t = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        toc.append(TOCItem(title: t.isEmpty ? "—" : t, chapterIndex: idx, fragment: frag, level: level))
    }

    private func parseNavList(_ ol: XNode, base: String, spine: [String], level: Int) {
        for li in ol.children where li.name == "li" {
            if let a = li.child("a") ?? li.first("a"), let href = a.attrs["href"] {
                addToc(title: a.fullText, href: href, base: base, spine: spine, level: level)
            }
            if let sub = li.child("ol") { parseNavList(sub, base: base, spine: spine, level: level + 1) }
        }
    }

    private func parseNCX(_ node: XNode, base: String, spine: [String], level: Int) {
        for np in node.children where np.name == "navpoint" {
            if let label = np.child("navlabel")?.fullText, let src = np.child("content")?.attrs["src"] {
                addToc(title: label, href: src, base: base, spine: spine, level: level)
            }
            parseNCX(np, base: base, spine: spine, level: level + 1)
        }
    }

    // MARK: TXT
    static func decodeText(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: d, encoding: String.Encoding(rawValue: gb)) { return s }
        if let s = String(data: d, encoding: .utf16) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    private func loadTXT() throws {
        let marker = rootDir.appendingPathComponent(".extracted")
        let fm = FileManager.default
        if !fm.fileExists(atPath: marker.path) {
            try? fm.removeItem(at: rootDir)
            try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
            let text = Self.decodeText(try Data(contentsOf: book.fileURL)).replacingOccurrences(of: "\r\n", with: "\n")
            let parts = Self.splitChapters(text)
            var titles: [String] = []
            for (i, p) in parts.enumerated() {
                let paras = p.body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let html = """
                <html><head><meta charset="utf-8"><title>\(p.title.htmlEscaped)</title></head><body>
                <h2>\(p.title.htmlEscaped)</h2>
                \(paras.map { "<p>\($0.htmlEscaped)</p>" }.joined(separator: "\n"))
                </body></html>
                """
                try html.write(to: rootDir.appendingPathComponent("chapter-\(i).html"), atomically: true, encoding: .utf8)
                titles.append(p.title)
            }
            try JSONEncoder().encode(titles).write(to: rootDir.appendingPathComponent("titles.json"))
            try Data().write(to: marker)
        }
        let titles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: rootDir.appendingPathComponent("titles.json")))) ?? []
        chapters = titles.enumerated().map { Chapter(url: rootDir.appendingPathComponent("chapter-\($0).html"), title: $1) }
        if let first = chapters.first.map({ _ in plainText(of: 0) }) {
            language = Self.detectLanguage(first)
        }
        toc = chapters.enumerated().map { TOCItem(title: $1.title, chapterIndex: $0, fragment: nil, level: 0) }
    }

    static func splitChapters(_ text: String) -> [(title: String, body: String)] {
        let pattern = "(?m)^\\s*(第[0-9零一二三四五六七八九十百千]+[章节回卷].{0,30}|(?:CHAPTER|Chapter|CHAPITRE|Chapitre|CAPÍTULO|Capítulo|PARTIE|Partie|PARTE|Parte)\\s+[0-9IVXLCivxlc]+.{0,40}|[IVXLC]+\\.?\\s*$)\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [(String(localized: "Text"), text)] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [(String, String)] = []
        if matches.count >= 1 {
            if matches[0].range.location > 0 {
                let pre = ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                if !pre.isEmpty { out.append((String(localized: "Preface"), pre)) }
            }
            for (i, m) in matches.enumerated() {
                let start = m.range.location + m.range.length
                let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
                out.append((ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines),
                            ns.substring(with: NSRange(location: start, length: end - start))))
            }
            return out
        }
        // 没有章节标记: 按约 15000 字符分段
        var idx = text.startIndex
        var n = 1
        while idx < text.endIndex {
            var end = text.index(idx, offsetBy: 15_000, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let nl = text[end...].firstIndex(of: "\n") { end = nl }
            out.append((String(localized: "Section \(n)"), String(text[idx..<end])))
            idx = end
            n += 1
        }
        return out
    }

    /// 某章内目录项的锚点
    func tocFragments(in chapter: Int) -> [String] {
        Array(Set(toc.filter { $0.chapterIndex == chapter }.compactMap(\.fragment)))
    }

    /// 识别文本语言, 返回 en / fr / es / ja 等
    static func detectLanguage(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(3000)))
        return r.dominantLanguage.map { String($0.rawValue.prefix(2)) } ?? "en"
    }

    /// 某章纯文本 (用于词汇透析、全文搜索)
    func plainText(of index: Int) -> String {
        guard let d = try? Data(contentsOf: chapters[index].url) else { return "" }
        var s = Self.decodeText(d)
        if let r = s.range(of: "<body", options: .caseInsensitive) { s = String(s[r.lowerBound...]) }
        return s.strippingHTML
    }
}

/// 导入书籍: 复制到 Documents/Books, 提取封面, 写入书架
enum BookImporter {
    static func bookId(for path: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h % 10_000_000_000)
    }

    @discardableResult
    static func importBook(from src: URL, copy: Bool = true, groupId: String? = nil) throws -> Book {
        let ext = src.pathExtension.lowercased()
        guard BookFormat.importableExtensions.contains(ext) else {
            throw ReaderError.unsupported(String(localized: "Unsupported file format: \(ext)"))
        }
        let fm = FileManager.default
        var fileName = src.lastPathComponent
        var dest = Paths.books.appendingPathComponent(fileName)
        if src.standardizedFileURL != dest.standardizedFileURL {
            if let existing = AppDatabase.shared.book(path: fileName), fm.fileExists(atPath: dest.path) {
                throw ReaderError.invalidFile(String(localized: "“\(existing.name)” is already on your bookshelf."))
            }
            if fm.fileExists(atPath: dest.path) {
                fileName = "\(src.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).\(ext)"
                dest = Paths.books.appendingPathComponent(fileName)
            }
            if copy { try fm.copyItem(at: src, to: dest) } else { try fm.moveItem(at: src, to: dest) }
        }
        return try register(fileName: fileName, groupId: groupId)
    }

    /// 已在 Books 目录中的文件登记到书架 (WiFi 传书)
    @discardableResult
    static func register(fileName: String, groupId: String? = nil) throws -> Book {
        let url = Paths.books.appendingPathComponent(fileName)
        let id = bookId(for: fileName)
        var name = url.deletingPathExtension().lastPathComponent
        var author = ""
        var cover: String?
        switch BookFormat(path: fileName) {
        case .epub:
            let zip = try ZipArchive(url: url)
            let meta = try EPUBMeta.read(zip: zip)
            if !meta.title.isEmpty { name = meta.title }
            author = meta.author
            if let cp = meta.coverPath, let d = zip.data(for: cp), let img = UIImage(data: d) {
                cover = saveCover(img, id: id)
            }
        case .pdf:
            if let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
                cover = saveCover(renderPDFPage(page), id: id)
            }
        default: break
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var book = Book(id: id, name: name, path: fileName, cover: cover, lastTimestamp: now, groupId: groupId)
        book.author = author
        book.addTime = now
        AppDatabase.shared.save(book)
        return book
    }

    private static func saveCover(_ img: UIImage, id: String) -> String? {
        let target = CGSize(width: 300, height: 300 * img.size.height / max(img.size.width, 1))
        let small = UIGraphicsImageRenderer(size: target).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let d = small.jpegData(compressionQuality: 0.8) else { return nil }
        let name = "\(id).jpg"
        try? d.write(to: Paths.covers.appendingPathComponent(name))
        return name
    }

    private static func renderPDFPage(_ page: CGPDFPage) -> UIImage {
        let rect = page.getBoxRect(.mediaBox)
        let scale = 400 / max(rect.width, 1)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.drawPDFPage(page)
        }
    }

    static func delete(_ book: Book) {
        AppDatabase.shared.delete(book: book)
        try? FileManager.default.removeItem(at: book.fileURL)
        if let c = book.coverURL { try? FileManager.default.removeItem(at: c) }
        try? FileManager.default.removeItem(at: Paths.epubCache.appendingPathComponent(book.id))
        UserDefaults.standard.removeObject(forKey: "pos_\(book.id)")
    }

    /// 首次启动时缓存示例书籍《The Moon and Sixpence》
    static func addDemoBookIfNeeded() {
        let s = AppSettings.shared
        guard !s.demoBookAdded, let src = Paths.bundled("The-Moon-and-Sixpence.epub") else { return }
        _ = try? importBook(from: src)
        s.demoBookAdded = true
    }
}
