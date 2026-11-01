import SwiftUI
import WebKit
import Observation

// MARK: Toast
@Observable
final class ToastCenter {
    static let shared = ToastCenter()
    var message: String?
    @ObservationIgnored private var work: DispatchWorkItem?

    func show(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.message = msg
            self.work?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.message = nil }
            self.work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
        }
    }
}

func toast(_ msg: String) { ToastCenter.shared.show(msg) }

struct ToastOverlay: ViewModifier {
    @State private var center = ToastCenter.shared
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let m = center.message {
                Text(m)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 90)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.message)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

// MARK: 分享
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: 词典 html 展示
/// 渲染 MDict 释义: 支持 entry:// 跳转、sound:// 发音、mdd 资源
struct DictHTMLView: UIViewRepresentable {
    let html: String
    let dictId: String
    var onEntry: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "mdict")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            wv.loadHTMLString(html, baseURL: URL(string: "mdict://\(dictId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "d")/"))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var parent: DictHTMLView
        var loaded = ""
        init(_ p: DictHTMLView) { parent = p }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }
            let s = url.absoluteString
            if s.hasPrefix("entry://") {
                decisionHandler(.cancel)
                let w = String(s.dropFirst(8)).removingPercentEncoding ?? ""
                parent.onEntry?(w.trimmingCharacters(in: CharacterSet(charactersIn: "#/")))
            } else if s.hasPrefix("sound://") {
                decisionHandler(.cancel)
                Speech.shared.speak(loadedWord)
            } else if action.navigationType == .linkActivated, url.scheme?.hasPrefix("http") == true {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            } else {
                decisionHandler(.allow)
            }
        }

        private var loadedWord: String {
            let r = loaded.range(of: "<h4[^>]*>\\s*([^<\\s][^<]*)", options: .regularExpression)
            return r.map { String(loaded[$0]).strippingHTML } ?? ""
        }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let dict = url.host?.removingPercentEncoding ?? parent.dictId
            let path = url.path
            let data = DictionaryManager.shared.resource(dictId: dict, path: path) ?? Data()
            let mime: String
            switch (path as NSString).pathExtension.lowercased() {
            case "css": mime = "text/css"
            case "js": mime = "application/javascript"
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "svg": mime = "image/svg+xml"
            case "mp3": mime = "audio/mpeg"
            default: mime = "application/octet-stream"
            }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }
}

/// 简单网页 (网页词典 / 使用指南)
struct SimpleWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {
        if wv.url?.absoluteString != url.absoluteString && !wv.isLoading { wv.load(URLRequest(url: url)) }
    }
}

struct WebPageScreen: View {
    let title: String
    let url: URL
    var body: some View {
        SimpleWebView(url: url)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UIApplication.shared.open(url) } label: { Image(systemName: "safari") }
                }
            }
    }
}

// MARK: 通用组件
struct BookCoverView: View {
    let book: Book
    var body: some View {
        ZStack {
            if let u = book.coverURL, let img = UIImage(contentsOfFile: u.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: "#FF6B6B"), Color(hex: "#EE3A8C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Text(book.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                    Text(book.format.rawValue.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .aspectRatio(0.7, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2)
    }
}

struct EmptyStateView: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单行输入弹窗
struct TextInputAlert: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let placeholder: String
    @Binding var text: String
    let onConfirm: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField(placeholder, text: $text)
            Button("Cancel", role: .cancel) {}
            Button("OK") { onConfirm(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

extension View {
    func textInputAlert(_ title: String, isPresented: Binding<Bool>, text: Binding<String>, placeholder: String = "", onConfirm: @escaping (String) -> Void) -> some View {
        modifier(TextInputAlert(isPresented: isPresented, title: title, placeholder: placeholder, text: text, onConfirm: onConfirm))
    }
}

extension Date {
    var shortString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}

extension Array where Element == String {
    /// Locale-aware list ("a, b and c" / "a、b和c")
    var listFormatted: String { ListFormatter.localizedString(byJoining: self) }
}
