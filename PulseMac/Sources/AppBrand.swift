import Foundation

/// Presentation names are independent of the stable bundle and data identifiers.
enum AppBrand {
    static let name = "FFF"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? name
    }
}
