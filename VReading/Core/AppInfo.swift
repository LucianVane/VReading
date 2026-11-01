import Foundation

/// 产品信息. 网址、邮箱留空时对应入口不显示
enum AppInfo {
    static let name = "VReading"
    static let slogan = String(localized: "Read in a foreign language, effortlessly.")
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static let website: URL? = nil
    static let faqURL: URL? = nil
    static let termsURL: URL? = nil
    static let privacyURL: URL? = nil
    static let feedbackEmail: String? = nil

    static var shareText: String {
        String(localized: "\(name) - read novels and magazines in a foreign language with tap-to-look-up, MDict dictionaries, translation, notes and vocabulary review. Give it a try!")
            + (website.map { " \($0.absoluteString)" } ?? "")
    }
}
