import Foundation
import Observation

struct OPDSLink: Hashable {
    let href: URL
    let rel: String
    let type: String
    let title: String
}

struct OPDSEntry: Identifiable, Hashable {
    let id: String
    var title: String
    var author: String
    var summary: String
    var cover: URL?
    var links: [OPDSLink]

    /// 导航条目 (子目录)
    var navigation: OPDSLink? {
        links.first { $0.type.contains("atom+xml") || $0.type.contains("opds-catalog") || $0.rel == "subsection" }
            .flatMap { acquisitions.isEmpty ? $0 : nil }
    }

    /// 可下载的书籍文件, epub 优先
    var acquisitions: [OPDSLink] {
        let acq = links.filter { $0.rel.contains("acquisition") || $0.type.contains("epub") || $0.type.contains("pdf") }
            .filter { ($0.type.contains("epub") && !$0.type.contains("kepub")) || $0.type.contains("pdf") || $0.type.contains("text/plain") }
        return acq.sorted { a, b in
            let pa = a.type.contains("epub") ? (a.href.absoluteString.contains("images") ? 0 : 1) : 2
            let pb = b.type.contains("epub") ? (b.href.absoluteString.contains("images") ? 0 : 1) : 2
            return pa < pb
        }
    }
}

struct OPDSFeed {
    var title = ""
    var entries: [OPDSEntry] = []
    var next: URL?
    var searchTemplate: String?
}

enum OPDSClient {
    private static var openSearchCache: [URL: String] = [:]

    /// OpenSearch 描述文件中 atom 类型的搜索模板
    static func openSearchTemplate(_ url: URL, source: BookSource) async -> String? {
        if let t = openSearchCache[url] { return t }
        guard let (data, _) = try? await URLSession.shared.data(for: request(url, source: source)), let root = XNode.parse(data) else { return nil }
        let urls = root.all("url")
        let t = (urls.first { ($0.attrs["type"] ?? "").contains("atom") } ?? urls.first)?.attrs["template"]
        if let t { openSearchCache[url] = t }
        return t
    }

    static func request(_ url: URL, source: BookSource) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.setValue("VReading/\(AppInfo.version) (iOS)", forHTTPHeaderField: "User-Agent")
        if !source.username.isEmpty {
            let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    enum FetchError: Error { case unauthorized }

    static func fetch(_ url: URL, source: BookSource) async throws -> OPDSFeed {
        let (data, resp) = try await URLSession.shared.data(for: request(url, source: source))
        if (resp as? HTTPURLResponse)?.statusCode == 401 { throw FetchError.unauthorized }
        guard let root = XNode.parse(data), root.name == "feed" || root.first("feed") != nil else {
            throw ReaderError.invalidFile(String(localized: "Couldn't parse OPDS. Make sure the source is an OPDS catalog."))
        }
        let feedNode = root.name == "feed" ? root : root.first("feed")!
        var feed = OPDSFeed()
        feed.title = feedNode.child("title")?.fullText ?? ""
        for l in feedNode.children where l.name == "link" {
            let rel = l.attrs["rel"] ?? ""
            guard let href = l.attrs["href"], let u = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            if rel == "next" { feed.next = u }
            if rel == "search", (l.attrs["type"] ?? "").contains("atom"), u.absoluteString.contains("searchTerms") {
                feed.searchTemplate = u.absoluteString.removingPercentEncoding
            } else if rel == "search", (l.attrs["type"] ?? "").contains("opensearchdescription"), feed.searchTemplate == nil {
                feed.searchTemplate = await openSearchTemplate(u, source: source)
            }
        }
        for e in feedNode.children where e.name == "entry" {
            var links: [OPDSLink] = []
            var cover: URL?
            for l in e.children where l.name == "link" {
                guard let href = l.attrs["href"], let u = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
                let rel = l.attrs["rel"] ?? "", type = l.attrs["type"] ?? ""
                if rel.contains("image") || rel.contains("thumbnail") {
                    if cover == nil || rel.contains("thumbnail") { cover = u }
                } else {
                    links.append(OPDSLink(href: u, rel: rel, type: type, title: l.attrs["title"] ?? ""))
                }
            }
            if cover == nil, let t = e.children.first(where: { $0.name == "thumbnail" || $0.name == "content" && ($0.attrs["medium"] ?? "") == "image" }),
               let u = t.attrs["url"].flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }) {
                cover = u
            }
            let author = e.all("author").compactMap { $0.child("name")?.fullText }.joined(separator: ", ")
            let summary = (e.child("summary") ?? e.child("content"))?.fullText.strippingHTML ?? ""
            feed.entries.append(OPDSEntry(id: e.child("id")?.fullText ?? UUID().uuidString, title: e.child("title")?.fullText ?? "",
                                          author: author, summary: summary, cover: cover, links: links))
        }
        return feed
    }
}

/// 图书下载 (OPDS / WebDAV / 网页), 下载完成后导入书架
@Observable
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    var progress: [URL: Double] = [:]
    @ObservationIgnored private var continuations: [Int: (URL, String, CheckedContinuation<URL, Error>)] = [:]
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func download(_ request: URLRequest, suggestedName: String) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            let task = session.downloadTask(with: request)
            continuations[task.taskIdentifier] = (request.url!, suggestedName, c)
            progress[request.url!] = 0
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (url, _, _) = continuations[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }
        progress[url] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (url, name, c) = continuations.removeValue(forKey: downloadTask.taskIdentifier) else { return }
        progress.removeValue(forKey: url)
        var fileName = (downloadTask.response?.suggestedFilename).flatMap { $0.isEmpty || $0 == "Unknown" ? nil : $0 } ?? name
        let mime = downloadTask.response?.mimeType ?? ""
        if (fileName as NSString).pathExtension.isEmpty || !["epub", "pdf", "txt", "mdx", "mdd"].contains((fileName as NSString).pathExtension.lowercased()) {
            let ext = mime.contains("pdf") ? "pdf" : (mime.contains("text/plain") ? "txt" : ((name as NSString).pathExtension.isEmpty ? "epub" : (name as NSString).pathExtension))
            fileName = (fileName as NSString).deletingPathExtension + "." + ext
        }
        let dest = Paths.downloads.appendingPathComponent(fileName.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            c.resume(returning: dest)
        } catch {
            c.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (url, _, c) = continuations.removeValue(forKey: task.taskIdentifier) else { return }
        progress.removeValue(forKey: url)
        c.resume(throwing: error)
    }

    /// 下载并导入书架 / 词典
    @MainActor
    func downloadAndImport(_ request: URLRequest, name: String) async -> Book? {
        do {
            let file = try await download(request, suggestedName: name)
            let ext = file.pathExtension.lowercased()
            if ext == "mdx" || ext == "mdd" {
                _ = try DictionaryManager.shared.importFile(file)
                toast(String(localized: "Dictionary imported"))
                return nil
            }
            let book = try BookImporter.importBook(from: file, copy: false)
            LibraryStore.shared.reload()
            toast(String(localized: "Saved to bookshelf"))
            return book
        } catch {
            toast(String(localized: "Download failed: \(error.localizedDescription)"))
            return nil
        }
    }
}
