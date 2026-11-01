import Foundation
import Compression

/// 原始 deflate 数据解压 (zip method 8 / zlib 去掉 2 字节头之后的数据)
func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
    if data.isEmpty { return Data() }
    var capacity = max(expectedSize, data.count * 4, 1024)
    while true {
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        if written == 0 { return nil }
        // 解压缓冲区满了说明可能被截断, 扩容重试 (已知大小时一次即可)
        if written < capacity || expectedSize > 0 {
            out.count = written
            return out
        }
        capacity *= 4
    }
}

/// zlib 流 (带 2 字节头 + adler32 尾)
func inflateZlib(_ data: Data, expectedSize: Int) -> Data? {
    guard data.count > 2 else { return nil }
    return inflateRaw(data.subdata(in: data.startIndex + 2 ..< data.endIndex), expectedSize: expectedSize)
}

extension Data {
    func u16le(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32le(_ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(self[startIndex + o + i]) << (8 * i) }
        return v
    }
    func u16be(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) << 8 | UInt16(self[startIndex + o + 1]) }
    func u32be(_ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[startIndex + o + i]) }
        return v
    }
    func u64be(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[startIndex + o + i]) }
        return v
    }
    func sub(_ o: Int, _ len: Int) -> Data { subdata(in: startIndex + o ..< startIndex + o + len) }
}

/// 只读 zip (epub) 解析
final class ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var orderedNames: [String] = []

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try parseCentralDirectory()
    }

    private func parseCentralDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw ReaderError.invalidFile(String(localized: "ZIP file is too small")) }
        var eocd = -1
        var i = n - 22
        let lower = max(0, n - 65_557)
        while i >= lower {
            if data.u32le(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ReaderError.invalidFile(String(localized: "ZIP central directory not found")) }
        let count = Int(data.u16le(eocd + 10))
        var p = Int(data.u32le(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= n, data.u32le(p) == 0x02014b50 else { break }
            let flags = data.u16le(p + 8)
            let method = data.u16le(p + 10)
            let csize = Int(data.u32le(p + 20))
            let usize = Int(data.u32le(p + 24))
            let nameLen = Int(data.u16le(p + 28))
            let extraLen = Int(data.u16le(p + 30))
            let commentLen = Int(data.u16le(p + 32))
            let offset = Int(data.u32le(p + 42))
            let nameData = data.sub(p + 46, nameLen)
            let name = (flags & 0x800) != 0
                ? String(decoding: nameData, as: UTF8.self)
                : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "")
            entries[name] = Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset)
            orderedNames.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func data(for name: String) -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.lowercased() == name.lowercased() })?.value else { return nil }
        let o = e.localHeaderOffset
        guard o + 30 <= data.count, data.u32le(o) == 0x04034b50 else { return nil }
        let start = o + 30 + Int(data.u16le(o + 26)) + Int(data.u16le(o + 28))
        guard start + e.compressedSize <= data.count else { return nil }
        let raw = data.sub(start, e.compressedSize)
        switch e.method {
        case 0: return raw
        case 8: return inflateRaw(raw, expectedSize: e.uncompressedSize)
        default: return nil
        }
    }

    /// 解压全部文件到目录
    func extractAll(to dir: URL) throws {
        let fm = FileManager.default
        for name in orderedNames where !name.hasSuffix("/") {
            let dest = dir.appendingPathComponent(name)
            // 防止 ../ 越界
            guard dest.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) else { continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = data(for: name) { try d.write(to: dest) }
        }
    }
}

/// 简单的 zip 写入 (只存储不压缩), 用于导出 anki apkg
final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    func add(name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(out.count)
        var h = Data()
        h.appendLE(UInt32(0x04034b50)); h.appendLE(UInt16(20)); h.appendLE(UInt16(0x800)); h.appendLE(UInt16(0))
        h.appendLE(UInt16(0)); h.appendLE(UInt16(0x21))
        h.appendLE(crc); h.appendLE(UInt32(data.count)); h.appendLE(UInt32(data.count))
        h.appendLE(UInt16(nameData.count)); h.appendLE(UInt16(0))
        out.append(h); out.append(nameData); out.append(data)

        var c = Data()
        c.appendLE(UInt32(0x02014b50)); c.appendLE(UInt16(20)); c.appendLE(UInt16(20)); c.appendLE(UInt16(0x800)); c.appendLE(UInt16(0))
        c.appendLE(UInt16(0)); c.appendLE(UInt16(0x21))
        c.appendLE(crc); c.appendLE(UInt32(data.count)); c.appendLE(UInt32(data.count))
        c.appendLE(UInt16(nameData.count)); c.appendLE(UInt16(0)); c.appendLE(UInt16(0))
        c.appendLE(UInt16(0)); c.appendLE(UInt16(0)); c.appendLE(UInt32(0)); c.appendLE(offset)
        central.append(c); central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var result = out
        let cdOffset = UInt32(result.count)
        result.append(central)
        var e = Data()
        e.appendLE(UInt32(0x06054b50)); e.appendLE(UInt16(0)); e.appendLE(UInt16(0))
        e.appendLE(UInt16(count)); e.appendLE(UInt16(count))
        e.appendLE(UInt32(central.count)); e.appendLE(cdOffset); e.appendLE(UInt16(0))
        result.append(e)
        return result
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buf in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}

enum ReaderError: LocalizedError {
    case invalidFile(String)
    case unsupported(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let s), .unsupported(let s), .network(let s): return s
        }
    }
}
