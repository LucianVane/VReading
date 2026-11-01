import Foundation

struct DavResource: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    var id: URL { url }
}

/// WebDAV 云盘 (坚果云、Infini Cloud 等): PROPFIND 列目录, GET 下载
enum WebDAVClient {
    static func authorized(_ url: URL, _ s: BookSource) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        let token = Data("\(s.username):\(s.password)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func list(_ url: URL, source: BookSource) async throws -> [DavResource] {
        var r = authorized(url, source)
        r.httpMethod = "PROPFIND"
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw ReaderError.network(String(localized: "WebDAV authorization failed. Check your username and password.")) }
        guard code == 207 || code == 200, let root = XNode.parse(data) else {
            throw ReaderError.network(String(localized: "WebDAV authorization failed. Check your configuration. (\(code))"))
        }
        let base = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var out: [DavResource] = []
        for resp in root.all("response") {
            guard let href = resp.child("href")?.fullText, let u = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            let path = u.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == base || (path.removingPercentEncoding ?? path) == (base.removingPercentEncoding ?? base) { continue }
            let isDir = resp.first("collection") != nil
            var name = resp.first("displayname")?.fullText ?? ""
            if name.isEmpty { name = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent }
            let size = Int64(resp.first("getcontentlength")?.fullText ?? "0") ?? 0
            out.append(DavResource(url: u, name: name, isDirectory: isDir, size: size))
        }
        return out.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}
