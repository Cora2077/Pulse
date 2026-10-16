import Foundation

/// The URL scheme activities and widgets use to open the app.
///
/// The app target owns the real scheme (its bundle identifier in this project),
/// supplied at build time through `PULSE_WIDGET_LINK_SCHEME`. The default keeps
/// previews and tests working without any build settings, and is deliberately
/// *not* a writable route.
public enum PulseWidgetDeepLinkScheme {
    public static let value: String = {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "PulseDeepLinkScheme") as? String,
           !configured.isEmpty {
            return configured
        }
        return "fff-pulse"
    }()
}
