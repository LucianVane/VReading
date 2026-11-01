import Foundation

/// Build-time secrets, injected from `Local.xcconfig` through Info.plist.
/// Open-source builds leave these empty; users configure their own keys in Settings.
enum Secrets {
    static var deepSeekAPIKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "VRDeepSeekAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
