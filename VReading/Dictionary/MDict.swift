import Foundation

/// RIPEMD-128, MDict 2.0 加密的 key block info 需要用它生成解密 key
enum RIPEMD128 {
    private static let r1: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2]
    private static let r2: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14]
    private static let s1: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12]
    private static let s2: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8]
    private static let k1: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC]
    private static let k2: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x00000000]

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    @inline(__always) private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xFF)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                x[i] = UInt32(msg[b]) | UInt32(msg[b + 1]) << 8 | UInt32(msg[b + 2]) << 16 | UInt32(msg[b + 3]) << 24
            }
            var (al, bl, cl, dl) = (h[0], h[1], h[2], h[3])
            var (ar, br, cr, dr) = (h[0], h[1], h[2], h[3])
            for j in 0..<64 {
                let round = j / 16
                var t = rotl(al &+ f(round, bl, cl, dl) &+ x[r1[j]] &+ k1[round], s1[j])
                al = dl; dl = cl; cl = bl; bl = t
                t = rotl(ar &+ f(3 - round, br, cr, dr) &+ x[r2[j]] &+ k2[round], s2[j])
                ar = dr; dr = cr; cr = br; br = t
            }
            let t = h[1] &+ cl &+ dr
            h[1] = h[2] &+ dl &+ ar
            h[2] = h[3] &+ al &+ br
            h[3] = h[0] &+ bl &+ cr
            h[0] = t
        }
        var out: [UInt8] = []
        for v in h { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        return out
    }
}

/// MDict (.mdx / .mdd) 读取器, 支持 1.2 / 2.0 版本, zlib / 无压缩数据块
final class MDictReader {
    let url: URL
    let isMDD: Bool
    private(set) var title: String = ""
    private(set) var stylesheet: String = ""
    private(set) var entryCount = 0

    private let data: Data
    private var version: Double = 2.0
    private var numWidth = 8
    private var encrypted = 0
    private var utf16 = false

    private var keyOffsets: [Int64] = []
    private var keyTexts: [String] = []
    private var index: [String: [Int]] = [:]
    private var recordBlocks: [(comp: Int, decomp: Int, fileOffset: Int, decompOffset: Int64)] = []
    private var totalRecordSize: Int64 = 0

    private var blockCache: [Int: Data] = [:]
    private var blockCacheOrder: [Int] = []
    private let lock = NSLock()

    init(url: URL) throws {
        self.url = url
        isMDD = url.pathExtension.lowercased() == "mdd"
        data = try Data(contentsOf: url, options: .alwaysMapped)
        var pos = try readHeader()
        pos = try readKeys(from: pos)
        try readRecordInfo(from: pos)
    }

    // MARK: header
    private func readHeader() throws -> Int {
        guard data.count > 8 else { throw ReaderError.invalidFile(String(localized: "Invalid dictionary file")) }
        let len = Int(data.u32be(0))
        guard 4 + len + 4 <= data.count else { throw ReaderError.invalidFile(String(localized: "Invalid dictionary header")) }
        let headerData = data.sub(4, len)
        let header = String(data: headerData, encoding: .utf16LittleEndian) ?? ""
        func attr(_ name: String) -> String? {
            guard let r = header.range(of: "\(name)=\"") else { return nil }
            let rest = header[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        version = Double(attr("GeneratedByEngineVersion") ?? "2.0") ?? 2.0
        numWidth = version < 2.0 ? 4 : 8
        let enc = attr("Encrypted") ?? "0"
        encrypted = enc == "Yes" ? 1 : (Int(enc) ?? 0)
        if encrypted & 1 != 0 { throw ReaderError.unsupported(String(localized: "Encrypted dictionaries that require a registration code are not supported")) }
        let encoding = (attr("Encoding") ?? "UTF-8").uppercased()
        utf16 = isMDD || encoding.hasPrefix("UTF-16")
        title = (attr("Title") ?? "").htmlUnescaped
        if title.isEmpty || title == "Title (No HTML code allowed)" {
            title = url.deletingPathExtension().lastPathComponent
        }
        stylesheet = attr("StyleSheet") ?? ""
        return 4 + len + 4
    }

    private func num(_ d: Data, _ o: Int) -> Int {
        numWidth == 8 ? Int(d.u64be(o)) : Int(d.u32be(o))
    }

    private static func fastDecrypt(_ d: Data, key: [UInt8]) -> Data {
        var out = [UInt8](d)
        var previous: UInt8 = 0x36
        for i in 0..<out.count {
            let b = out[i]
            var t = (b >> 4) | (b << 4)
            t = t ^ previous ^ UInt8(i & 0xFF) ^ key[i % key.count]
            previous = b
            out[i] = t
        }
        return Data(out)
    }

    private func decompressBlock(_ block: Data, expected: Int) -> Data? {
        guard block.count >= 8 else { return nil }
        let type = block.u32le(0)
        let payload = block.sub(8, block.count - 8)
        switch type {
        case 0: return payload
        case 2: return inflateZlib(payload, expectedSize: expected)
        default: return nil // LZO 等格式暂不支持
        }
    }

    // MARK: keys
    private func readKeys(from start: Int) throws -> Int {
        var pos = start
        let numKeyBlocks: Int
        var keyInfoDecompSize = 0
        let keyInfoSize: Int
        let keyBlocksSize: Int
        if version >= 2.0 {
            let h = data.sub(pos, 40)
            numKeyBlocks = num(h, 0)
            entryCount = num(h, 8)
            keyInfoDecompSize = num(h, 16)
            keyInfoSize = num(h, 24)
            keyBlocksSize = num(h, 32)
            pos += 44
        } else {
            let h = data.sub(pos, 16)
            numKeyBlocks = num(h, 0)
            entryCount = num(h, 4)
            keyInfoSize = num(h, 8)
            keyBlocksSize = num(h, 12)
            pos += 16
        }

        var info = data.sub(pos, keyInfoSize)
        pos += keyInfoSize
        if version >= 2.0 {
            if encrypted & 2 != 0 {
                let key = RIPEMD128.hash([UInt8](info.sub(4, 4)) + [0x95, 0x36, 0x00, 0x00])
                info = info.sub(0, 8) + Self.fastDecrypt(info.sub(8, info.count - 8), key: key)
            }
            guard let d = decompressBlock(info, expected: keyInfoDecompSize) else {
                throw ReaderError.invalidFile(String(localized: "Failed to decompress dictionary index"))
            }
            info = d
        }

        // 解析 key block info, 只需要每个 block 的压缩/解压大小
        var blockSizes: [(Int, Int)] = []
        var p = 0
        let termSize = version >= 2.0 ? 1 : 0
        let charWidth = utf16 ? 2 : 1
        for _ in 0..<numKeyBlocks {
            p += numWidth // entries in block
            let headSize = version >= 2.0 ? Int(info.u16be(p)) : Int(info[info.startIndex + p])
            p += version >= 2.0 ? 2 : 1
            p += (headSize + termSize) * charWidth
            let tailSize = version >= 2.0 ? Int(info.u16be(p)) : Int(info[info.startIndex + p])
            p += version >= 2.0 ? 2 : 1
            p += (tailSize + termSize) * charWidth
            let comp = num(info, p); p += numWidth
            let decomp = num(info, p); p += numWidth
            blockSizes.append((comp, decomp))
        }

        keyOffsets.reserveCapacity(entryCount)
        keyTexts.reserveCapacity(entryCount)
        var bpos = pos
        for (comp, decomp) in blockSizes {
            guard let block = decompressBlock(data.sub(bpos, comp), expected: decomp) else {
                throw ReaderError.invalidFile(String(localized: "Failed to decompress dictionary index block"))
            }
            parseKeyBlock(block)
            bpos += comp
        }
        pos += keyBlocksSize

        index.reserveCapacity(keyTexts.count)
        for (i, k) in keyTexts.enumerated() {
            index[Self.normalize(k), default: []].append(i)
        }
        return pos
    }

    private func parseKeyBlock(_ block: Data) {
        block.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i + numWidth <= n {
                var off: Int64 = 0
                for j in 0..<numWidth { off = off << 8 | Int64(bytes[i + j]) }
                i += numWidth
                let s = i
                if utf16 {
                    while i + 1 < n, !(bytes[i] == 0 && bytes[i + 1] == 0) { i += 2 }
                    let d = Data(bytes[s..<i])
                    keyTexts.append(String(data: d, encoding: .utf16LittleEndian) ?? "")
                    i += 2
                } else {
                    while i < n, bytes[i] != 0 { i += 1 }
                    keyTexts.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[s..<i]), as: UTF8.self))
                    i += 1
                }
                keyOffsets.append(off)
            }
        }
    }

    // MARK: records
    private func readRecordInfo(from start: Int) throws {
        var pos = start
        let numBlocks = num(data, pos); pos += numWidth
        pos += numWidth // entries
        let infoSize = num(data, pos); pos += numWidth
        pos += numWidth // blocks size
        var fileOffset = pos + infoSize
        var decompOffset: Int64 = 0
        var p = pos
        for _ in 0..<numBlocks {
            let comp = num(data, p); p += numWidth
            let decomp = num(data, p); p += numWidth
            recordBlocks.append((comp, decomp, fileOffset, decompOffset))
            fileOffset += comp
            decompOffset += Int64(decomp)
        }
        totalRecordSize = decompOffset
    }

    private func recordBlock(_ i: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let d = blockCache[i] { return d }
        let b = recordBlocks[i]
        guard let d = decompressBlock(data.sub(b.fileOffset, b.comp), expected: b.decomp) else { return nil }
        blockCache[i] = d
        blockCacheOrder.append(i)
        if blockCacheOrder.count > 8 { blockCache.removeValue(forKey: blockCacheOrder.removeFirst()) }
        return d
    }

    private func record(at keyIndex: Int) -> Data? {
        let start = keyOffsets[keyIndex]
        var end = totalRecordSize
        var k = keyIndex + 1
        while k < keyOffsets.count {
            if keyOffsets[k] > start { end = keyOffsets[k]; break }
            k += 1
        }
        // 二分查找所在 record block
        var lo = 0, hi = recordBlocks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if recordBlocks[mid].decompOffset <= start { lo = mid } else { hi = mid - 1 }
        }
        guard let block = recordBlock(lo) else { return nil }
        let b = recordBlocks[lo]
        let s = Int(start - b.decompOffset)
        let e = min(Int(end - b.decompOffset), block.count)
        guard s < e else { return nil }
        return block.sub(s, e - s)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func contains(_ word: String) -> Bool { index[Self.normalize(word)] != nil }

    /// 查询单词, 返回 html 释义列表 (自动跟随 @@@LINK= 跳转)
    func lookup(_ word: String) -> [String] {
        var results: [String] = []
        var visited = Set<String>()
        var queue = [word]
        while let w = queue.first, results.count < 6 {
            queue.removeFirst()
            let key = Self.normalize(w)
            guard !visited.contains(key), let ids = index[key] else { continue }
            visited.insert(key)
            for i in ids {
                guard let d = record(at: i) else { continue }
                var html = (utf16 ? String(data: d, encoding: .utf16LittleEndian) : String(decoding: d, as: UTF8.self)) ?? ""
                html = html.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n "))
                if html.hasPrefix("@@@LINK=") {
                    queue.append(String(html.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines))
                } else if !html.isEmpty {
                    results.append(html)
                }
            }
        }
        return results
    }

    /// mdd 资源 (key 形如 \image.png)
    func resource(_ path: String) -> Data? {
        var key = path.replacingOccurrences(of: "/", with: "\\")
        if !key.hasPrefix("\\") { key = "\\" + key }
        guard let ids = index[Self.normalize(key)], let i = ids.first else { return nil }
        return record(at: i)
    }

    /// 前缀联想
    func suggestions(prefix: String, limit: Int = 20) -> [String] {
        let p = Self.normalize(prefix)
        guard !p.isEmpty else { return [] }
        var out: [String] = []
        for k in keyTexts where k.lowercased().hasPrefix(p) {
            out.append(k)
            if out.count >= limit { break }
        }
        return out
    }
}

extension String {
    var htmlUnescaped: String {
        var s = self
        let map = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&#160;": " ", "&amp;": "&"]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 去掉 html 标签得到纯文本
    var strippingHTML: String {
        var s = replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</h\\d>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.htmlUnescaped.replacingOccurrences(of: "&#(\\d+);", with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
