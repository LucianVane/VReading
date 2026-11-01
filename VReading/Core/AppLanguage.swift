import Foundation

/// App interface language. English is the development language; Simplified Chinese is bundled.
/// "System" follows iOS (Settings → Apps → VReading → Language also works).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, zhHans = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Follow System")
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }

    private static let key = "appLanguage"

    /// The user's in-app choice (not necessarily active until the next launch).
    static var selected: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The localization actually in use for this launch.
    static var isChinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true }
}
