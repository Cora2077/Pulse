import Foundation

/// Retained only to decode older settings snapshots and historical reports:
/// they store the case's `rawValue`, so removing the enum would make those
/// payloads fail to decode. The interface language itself is fixed to
/// Simplified Chinese and no longer consults this preference.
public enum PulseLanguagePreference: String, Codable, CaseIterable, Sendable {
    case system
    case english
    case simplifiedChinese
    case japanese
    case korean

    public var localeIdentifier: String {
        switch self {
        case .system:
            "zh-Hans"
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        case .japanese:
            "ja"
        case .korean:
            "ko"
        }
    }

    public var localizedDisplayName: String {
        switch self {
        case .system:
            PulseLocalization.localizedString("language.system")
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .japanese:
            "日本語"
        case .korean:
            "한국어"
        }
    }
}

public enum PulseLocalization {
    /// The app ships one interface language, so every resolution point below is
    /// a constant. The former `--preview-language` channel and the
    /// `UserDefaults` preference read are gone with the other language tables.
    public static var currentPreference: PulseLanguagePreference {
        .simplifiedChinese
    }

    public static var currentLanguageIdentifier: String {
        "zh-Hans"
    }

    public static var currentLocale: Locale {
        Locale(identifier: "zh-Hans")
    }

    public static func localizedString(_ key: String, _ arguments: CVarArg...) -> String {
        let language = currentLanguageIdentifier
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}
