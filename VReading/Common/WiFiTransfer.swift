import SwiftUI
import Network

/// WiFi 传书 / 传字典: 局域网 HTTP 服务, 页面复用原 App 的 wifi 网页 (jQuery + html5 上传)
final class WiFiServer {
    enum Mode { case books, dicts }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wifi.server")
    private(set) var port: UInt16 = 0
    let mode: Mode
    var onFileReceived: ((URL) -> Void)?

    init(mode: Mode) { self.mode = mode }

    var directory: URL { mode == .books ? Paths.books : Paths.dictionaries }

    func start() throws {
        var lastError: Error?
        for p: UInt16 in [8080, 8090, 8888, 9090, 10080] {
            do {
                let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: p)!)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.start(queue: queue)
                listener = l
                port = p
                return
            } catch { lastError = error }
        }
        throw lastError ?? ReaderError.network(String(localized: "Failed to start the HTTP server"))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static var localIP: String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" || name == "en1" || (addr == nil && name.hasPrefix("bridge")) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
            if name == "en0" { break }
        }
        return addr
    }

    private func accept(_ c: NWConnection) {
        let conn = HTTPConnection(connection: c, server: self)
        conn.start(queue: queue)
    }

    // MARK: 路由
    func handle(method: String, path rawPath: String, headers: [String: String], bodyFile: URL?) -> (Int, String, Data) {
        let path = (rawPath.components(separatedBy: "?").first ?? rawPath).removingPercentEncoding ?? rawPath
        if method == "GET" {
            if path == "/" || path == "/index.html" {
                var html = (try? String(contentsOf: Paths.webBundle.appendingPathComponent("wifi/index.html"), encoding: .utf8)) ?? ""
                // 网页语言跟随 App 界面语言
                if AppLanguage.isChinese {
                    html = html.replacingOccurrences(of: "scripts/lang.en.js", with: "scripts/lang.zh-Hans.js")
                    html = html.replacingOccurrences(of: "<html>", with: "<html lang=\"zh-Hans\">")
                }
                let title = mode == .dicts ? String(localized: "Wi-Fi Dictionary Transfer") : String(localized: "Wi-Fi Transfer")
                html = html.replacingOccurrences(of: "Wi-Fi Transfer", with: title)
                html = html.replacingOccurrences(of: "</head>", with: "<script>window.addEventListener('load',function(){document.title='\(title)';var t=document.getElementById('wifi_trans_title');if(t)t.innerText='\(title)';});</script></head>")
                return (200, "text/html; charset=utf-8", Data(html.utf8))
            }
            if path == "/files" {
                let list = files().map { ["name": $0.lastPathComponent, "size": Self.formatSize($0)] }
                return (200, "application/json", (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8))
            }
            if path.hasPrefix("/files/") {
                let f = directory.appendingPathComponent(String(path.dropFirst(7)))
                if let d = try? Data(contentsOf: f) { return (200, "application/octet-stream", d) }
                return (404, "text/plain", Data("not found".utf8))
            }
            if path.hasPrefix("/progress/") {
                let name = String(path.dropFirst(10))
                let j: [String: Any] = ["fileName": name, "size": "-", "progress": 1]
                return (200, "application/json", (try? JSONSerialization.data(withJSONObject: j)) ?? Data())
            }
            let f = Paths.webBundle.appendingPathComponent("wifi").appendingPathComponent(String(path.dropFirst()))
            if f.standardizedFileURL.path.hasPrefix(Paths.webBundle.path), let d = try? Data(contentsOf: f) {
                return (200, Self.mime(f.pathExtension), d)
            }
            return (404, "text/plain", Data("not found".utf8))
        }
        if method == "POST" {
            if path == "/files", let bodyFile, let ct = headers["content-type"] {
                let saved = saveMultipart(bodyFile, contentType: ct)
                return (200, "text/plain", Data(saved.isEmpty ? "error".utf8 : "ok".utf8))
            }
            if path.hasPrefix("/files/") {
                let name = String(path.dropFirst(7))
                let f = directory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: f)
                DispatchQueue.main.async {
                    if self.mode == .books, let b = AppDatabase.shared.book(path: name) { LibraryStore.shared.delete(b) }
                }
                return (200, "text/plain", Data("ok".utf8))
            }
        }
        return (404, "text/plain", Data())
    }

    private func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func formatSize(_ u: URL) -> String {
        let size = Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "html": return "text/html; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// 解析 multipart/form-data, 保存文件
    private func saveMultipart(_ file: URL, contentType: String) -> [URL] {
        guard let bRange = contentType.range(of: "boundary=") else { return [] }
        let boundary = contentType[bRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return [] }
        let delim = Data(("--" + boundary).utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var fields: [String: String] = [:]
        var fileParts: [(filename: String, range: Range<Int>)] = []
        var pos = data.startIndex
        while let r = data.range(of: delim, in: pos..<data.endIndex) {
            let partStart = r.upperBound + 2
            guard partStart < data.endIndex, let next = data.range(of: delim, in: partStart..<data.endIndex),
                  let he = data.range(of: headerEnd, in: partStart..<next.lowerBound) else { break }
            let headers = String(decoding: data[partStart..<he.lowerBound], as: UTF8.self)
            let bodyRange = he.upperBound..<(next.lowerBound - 2)
            let name = Self.attr("name", in: headers) ?? ""
            if let fn = Self.attr("filename", in: headers), !fn.isEmpty {
                fileParts.append((fn, bodyRange))
            } else {
                fields[name] = String(decoding: data[bodyRange], as: UTF8.self)
            }
            pos = next.lowerBound
        }
        var saved: [URL] = []
        for part in fileParts {
            var name = (fields["fileName"].flatMap { $0.removingPercentEncoding } ?? part.filename)
            name = (name as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let isDict = ["mdx", "mdd", "css", "js", "png", "jpg"].contains(ext)
            let dir = isDict ? Paths.dictionaries : Paths.books
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            do {
                try data.subdata(in: part.range).write(to: dest)
                saved.append(dest)
                DispatchQueue.main.async { self.onFileReceived?(dest) }
            } catch {}
        }
        return saved
    }

    private static func attr(_ key: String, in headers: String) -> String? {
        guard let r = headers.range(of: "\(key)=\"") else { return nil }
        let rest = headers[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

/// 单个 HTTP 连接: 读取请求头, 请求体写入临时文件 (支持大文件上传)
private final class HTTPConnection {
    let connection: NWConnection
    unowned let server: WiFiServer
    private var buffer = Data()
    private var headerParsed = false
    private var method = "", path = ""
    private var headers: [String: String] = [:]
    private var contentLength = 0
    private var received = 0
    private var bodyFile: URL?
    private var handle: FileHandle?
    private var selfRef: HTTPConnection?

    init(connection: NWConnection, server: WiFiServer) {
        self.connection = connection
        self.server = server
    }

    func start(queue: DispatchQueue) {
        selfRef = self
        connection.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.close() }
            if case .cancelled = s { self?.selfRef = nil }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if err != nil || (done && !self.headerParsed) { self.close(); return }
            if self.headerParsed && self.received >= self.contentLength {
                self.respond()
            } else if !done {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        if !headerParsed {
            buffer.append(data)
            guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            method = first.first.map(String.init) ?? "GET"
            path = first.dropFirst().first.map(String.init) ?? "/"
            for l in lines {
                if let i = l.firstIndex(of: ":") {
                    headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            contentLength = Int(headers["content-length"] ?? "0") ?? 0
            headerParsed = true
            let rest = buffer[r.upperBound...]
            buffer = Data()
            if contentLength > 0 {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: f.path, contents: nil)
                bodyFile = f
                handle = try? FileHandle(forWritingTo: f)
            }
            if !rest.isEmpty { writeBody(Data(rest)) }
        } else {
            writeBody(data)
        }
    }

    private func writeBody(_ d: Data) {
        handle?.write(d)
        received += d.count
    }

    private func respond() {
        try? handle?.close()
        handle = nil
        let (code, type, body) = server.handle(method: method, path: path, headers: headers, bodyFile: bodyFile)
        if let f = bodyFile { try? FileManager.default.removeItem(at: f) }
        let status = code == 200 ? "OK" : "Not Found"
        var head = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
        if path.hasPrefix("/files/") && method == "GET" {
            let name = (path.dropFirst(7).removingPercentEncoding ?? "")
            head += "Content-Disposition: attachment; filename*=UTF-8''\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func close() {
        connection.cancel()
    }
}

struct WiFiTransferView: View {
    let mode: WiFiServer.Mode
    @Environment(\.dismiss) private var dismiss
    @State private var server: WiFiServer?
    @State private var address = ""
    @State private var error: String?
    @State private var received: [String] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "wifi").font(.system(size: 56)).foregroundStyle(Color.accentGreen).padding(.top, 30)
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if address.isEmpty {
                    Text("Getting address...").foregroundStyle(.secondary)
                } else {
                    Text("Enter this full address in your computer's browser").foregroundStyle(.secondary)
                    Text(address).font(.title2.monospaced().bold()).textSelection(.enabled)
                    Text(mode == .books ? "Only EPUB, PDF and TXT books or MDX dictionaries are supported." : "Supports MDict dictionaries (mdx, mdd and css files)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Keep this screen open and don't lock your device during upload").font(.footnote).foregroundStyle(.orange)
                }
                if !received.isEmpty {
                    List(received, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentGreen) }
                        .listStyle(.plain)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(mode == .books ? "Wi-Fi Transfer" : "Wi-Fi Dictionary Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
        .onAppear(perform: start)
        .onDisappear {
            server?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func start() {
        guard server == nil else { return }
        guard let ip = WiFiServer.localIP else { error = String(localized: "Wi-Fi is not available. Connect to Wi-Fi and try again."); return }
        let s = WiFiServer(mode: mode)
        s.onFileReceived = { url in
            let ext = url.pathExtension.lowercased()
            if BookFormat.importableExtensions.contains(ext) {
                do {
                    try BookImporter.register(fileName: url.lastPathComponent)
                    LibraryStore.shared.reload()
                } catch { toast(error.localizedDescription) }
            } else if ext == "mdx" {
                _ = try? DictionaryManager.shared.importFile(url)
            }
            received.append(url.lastPathComponent)
        }
        do {
            try s.start()
            server = s
            address = "http://\(ip):\(s.port)"
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            self.error = String(localized: "Failed to start Wi-Fi transfer")
        }
    }
}
