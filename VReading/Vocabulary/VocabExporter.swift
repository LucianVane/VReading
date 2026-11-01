import UIKit
import CryptoKit

/// 生词本导出: Anki(apkg) / PDF / TXT / 单词列表
enum VocabExportFormat: String, CaseIterable, Identifiable {
    case apkg, pdf, txt, lines
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apkg: return String(localized: "APKG")
        case .pdf: return String(localized: "PDF")
        case .txt: return String(localized: "TXT")
        case .lines: return String(localized: "TXT (words only)")
        }
    }

    var desc: String {
        switch self {
        case .apkg: return String(localized: "Anki package with words, sentences and source books.")
        case .pdf: return String(localized: "PDF with words, sentences and source books, great for review.")
        case .txt: return String(localized: "Plain text with words, sentences and source books, easy to edit.")
        case .lines: return String(localized: "Words only, one per line, for importing into other flashcard apps.")
        }
    }
}

enum VocabExporter {
    static func export(_ words: [VocabWord], format: VocabExportFormat) throws -> URL {
        guard !words.isEmpty else { throw ReaderError.invalidFile(String(localized: "Nothing to export")) }
        let base = String(localized: "VReading_Vocabulary_\(Date().shortString)")
        switch format {
        case .txt:
            var s = ""
            for w in words {
                s += "\(w.word)\(w.phonetic.isEmpty ? "" : "  [\(w.phonetic)]")\n"
                if !w.explain.isEmpty { s += String(localized: "[Definition] \(w.explain)\n") }
                if !w.sentence.isEmpty { s += String(localized: "[Sentence] \(w.sentence)\n") }
                if !w.bookName.isEmpty { s += String(localized: "Source: \(w.bookName)\n") }
                s += "\n"
            }
            return try write(s, name: base + ".txt")
        case .lines:
            return try write(words.map(\.word).joined(separator: "\n"), name: base + "_words.txt")
        case .pdf:
            return try pdf(words, name: base + ".pdf")
        case .apkg:
            return try anki(words, name: base + ".apkg")
        }
    }

    private static func write(_ s: String, name: String) throws -> URL {
        let u = Paths.exports.appendingPathComponent(name)
        try s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private static func pdf(_ words: [VocabWord], name: String) throws -> URL {
        let url = Paths.exports.appendingPathComponent(name)
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 17), .foregroundColor: UIColor(hexString: "#2E7D32")]
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]
        let srcAttr: [NSAttributedString.Key: Any] = [.font: UIFont.italicSystemFont(ofSize: 10), .foregroundColor: UIColor.gray]
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            var y = margin
            let width = page.width - margin * 2
            String(localized: "VReading Vocabulary (\(words.count) words)").draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
            y += 36
            for w in words {
                var blocks: [NSAttributedString] = [NSAttributedString(string: w.word + (w.phonetic.isEmpty ? "" : "  [\(w.phonetic)]"), attributes: titleAttr)]
                if !w.explain.isEmpty { blocks.append(NSAttributedString(string: w.explain, attributes: bodyAttr)) }
                if !w.sentence.isEmpty { blocks.append(NSAttributedString(string: String(localized: "[Sentence] ") + w.sentence, attributes: bodyAttr)) }
                if !w.bookName.isEmpty { blocks.append(NSAttributedString(string: String(localized: "Source: \(w.bookName)"), attributes: srcAttr)) }
                let heights = blocks.map { $0.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height + 4 }
                if y + heights.reduce(0, +) > page.height - margin {
                    ctx.beginPage()
                    y = margin
                }
                for (b, h) in zip(blocks, heights) {
                    b.draw(with: CGRect(x: margin, y: y, width: width, height: h), options: [.usesLineFragmentOrigin], context: nil)
                    y += h
                }
                y += 12
            }
        }
        return url
    }

    /// 基于原 App 的 anki 模板 (collection.anki2) 写入笔记与卡片, 打包为 apkg
    private static func anki(_ words: [VocabWord], name: String) throws -> URL {
        guard let template = Paths.bundled("anki_template.anki2") else { throw ReaderError.invalidFile(String(localized: "Anki template missing")) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("collection.anki2")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.copyItem(at: template, to: work)
        do {
            let db = try SQLiteDB(path: work.path)
            let modelId: Int64 = 1466955598888
            let deckId: Int64 = 1645790697606
            let now = Int64(Date().timeIntervalSince1970)
            var nid = Int64(Date().timeIntervalSince1970 * 1000)
            db.transaction {
                for (i, w) in words.enumerated() {
                    nid += 1
                    let source = w.bookName.isEmpty ? "" : String(localized: "Source: \(w.bookName)")
                    let flds = [w.word, w.sentence.htmlEscaped, source, w.explain.htmlEscaped].joined(separator: "\u{1f}")
                    let digest = Insecure.SHA1.hash(data: Data(w.word.utf8)).prefix(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
                    db.run("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                           args: [nid, String(UUID().uuidString.prefix(10)), modelId, now, -1, "", flds, w.word, digest, 0, ""])
                    db.run("INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           args: [nid, nid, deckId, 0, now, -1, 0, 0, i + 1, 0, 0, 0, 0, 0, 0, 0, 0, ""])
                }
            }
        }
        let zip = ZipWriter()
        zip.add(name: "collection.anki2", data: try Data(contentsOf: work))
        zip.add(name: "media", data: Data("{}".utf8))
        let url = Paths.exports.appendingPathComponent(name)
        try zip.finish().write(to: url)
        return url
    }
}
