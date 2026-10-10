import CoreGraphics
import Foundation
import Observation
import ServiceManagement
import PulseCore

enum MenuBarMode: String, Codable, CaseIterable, Sendable {
    case single, rotate, compact

    var displayName: String {
        switch self {
        case .single: PulseLocalization.localizedString("menuBarMode.single")
        case .rotate: PulseLocalization.localizedString("menuBarMode.rotate")
        case .compact: PulseLocalization.localizedString("menuBarMode.compact")
        }
    }
}

enum WatchRowMetricMode: String, Codable, CaseIterable, Sendable {
    case changePercent
    case todayPnL
    case totalPnL
    case summary

    static var allCases: [WatchRowMetricMode] {
        [.changePercent, .todayPnL, .totalPnL]
    }

    var displayName: String {
        switch self {
        case .changePercent: PulseLocalization.localizedString("metric.changePercent")
        case .todayPnL: PulseLocalization.localizedString("metric.todayPnL")
        case .totalPnL: PulseLocalization.localizedString("metric.totalPnL")
        case .summary: PulseLocalization.localizedString("metric.totalPnL")
        }
    }

    var next: WatchRowMetricMode {
        switch self {
        case .changePercent:
            .todayPnL
        case .todayPnL:
            .totalPnL
        case .totalPnL, .summary:
            .changePercent
        }
    }

    var systemImage: String {
        switch self {
        case .changePercent:
            "percent"
        case .todayPnL:
            "calendar"
        case .totalPnL, .summary:
            "briefcase"
        }
    }
}

extension MarketState {
    var extendedSessionLabel: String? {
        switch self {
        case .preMarket:
            PulseLocalization.localizedString("marketState.preMarket")
        case .postMarket:
            PulseLocalization.localizedString("marketState.postMarket")
        case .overnight:
            PulseLocalization.localizedString("marketState.overnight")
        case .regular, .closed:
            nil
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    /// Show quote text (price/change) in the menu bar. Off by default: icon only — subtle and space-saving
    var showPriceInMenuBar: Bool = false { didSet { save() } }

    var menuBarMode: MenuBarMode = .rotate { didSet { save() } }
    /// The symbol pinned in single mode; nil falls back to the first watchlist item
    var primarySymbol: SymbolID? { didSet { save() } }
    var rotateInterval: TimeInterval = 6 { didSet { save() } }
    /// The tag used by menu-bar rotation. Nil resolves to the first available group.
    var rotateGroupID: UUID? { didSet { save() } }
    /// Per-provider quote poll cadence overrides; a missing key falls back to the
    /// provider's suggested interval. Replaces the former global refresh interval.
    var providerPollIntervals: [String: TimeInterval] = [:] { didSet { save() } }
    var watchRowMetricMode: WatchRowMetricMode = .totalPnL { didSet { save() } }
    /// Red-up/green-down (A-share convention); false means green-up/red-down
    var redUp: Bool = true { didSet { save() } }
    /// Show US pre/post-market sessions on every intraday chart (on by default).
    var showsUSExtendedHours: Bool = true { didSet { save() } }
    /// Group the watchlist by market using Beijing-time day/evening block order (on by default).
    var prioritizeOpenMarkets: Bool = true { didSet { save() } }
    /// Last resolution chosen from the intraday candlestick menu.
    var minuteCandlePeriod: CandlePeriod = .minute5 { didSet { save() } }
    var languagePreference: PulseLanguagePreference = .system {
        didSet {
            UserDefaults.standard.set(languagePreference.rawValue, forKey: PulseLocalization.languagePreferenceKey)
            save()
        }
    }

    /// Which cost the position summary reports. A display choice only: the two
    /// bases describe the same holding and agree on the total P&L.
    var positionCostBasis: PositionCostBasis = .average {
        didSet { save() }
    }

    /// Anonymous product analytics only. Event definitions live in PulseTelemetry and
    /// intentionally never include symbols, watchlists, positions, or search content.
    var shareAnonymousUsageData: Bool = true {
        didSet {
            PulseTelemetry.setCollectionEnabled(shareAnonymousUsageData)
            save()
        }
    }

    /// Whether the watchlist was pinned to a floating window at last quit, so the
    /// window comes back on the next launch. Written by the window itself on
    /// appear/disappear, which covers the pin button, Cmd-W, and the close button alike.
    var pinnedWindowVisible: Bool = false { didSet { save() } }

    /// Where the pinned window's top-left corner sat, in AppKit screen coordinates.
    /// SwiftUI re-centers a restored window scene, so remembering the spot the user
    /// dragged it to is on us.
    var pinnedWindowTopLeft: CGPoint? { didSet { save() } }

    /// Total menu-bar panel height the user dragged the resize grip to, including
    /// the grip strip itself. `nil` — the default, and the value an older snapshot
    /// decodes to — keeps the automatic per-route height. This is a local display
    /// preference: it is not watchlist data and is never synced.
    private(set) var menuBarPanelHeight: CGFloat? {
        didSet {
            guard oldValue != menuBarPanelHeight else { return }
            save()
        }
    }

    /// Writes only a height a drag can legitimately produce. Rejecting NaN and
    /// infinities here keeps a corrupt plist value from becoming a window size.
    func setMenuBarPanelHeight(_ height: CGFloat?) {
        guard let height else {
            menuBarPanelHeight = nil
            return
        }
        guard height.isFinite, height > 0 else { return }
        menuBarPanelHeight = height
    }

    /// Provider ids disabled by the user (all enabled by default)
    var disabledProviderIDs: Set<String> = [] { didSet { save() } }

    /// Whether the local MCP agent endpoint should run. Opt-in; binds loopback only.
    var mcpEnabled: Bool = false { didSet { save() } }

    /// Most-recent-first market search queries, capped, user-clearable from the search panel.
    var recentSearchQueries: [String] = [] { didSet { save() } }

    /// Whether plan cards draw at the compact height (on by default).
    ///
    /// A plan list is a queue to scan, not a page to read, so the default is
    /// the dense one and the comfortable layout is the opt-out. Like the panel
    /// height this is a local display preference: it is not watchlist data and
    /// is never synced, and the height it exists to save is off the same panel
    /// the menu-bar grip measures.
    var compactPlanCards: Bool = true { didSet { save() } }

    private static let recentSearchLimit = 8

    func recordRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var queries = recentSearchQueries.filter {
            $0.caseInsensitiveCompare(trimmed) != .orderedSame
        }
        queries.insert(trimmed, at: 0)
        recentSearchQueries = Array(queries.prefix(Self.recentSearchLimit))
    }

    func clearRecentSearches() {
        recentSearchQueries = []
    }

    var locale: Locale {
        PulseLocalization.currentLocale
    }

    var launchAtLogin: Bool = false {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = oldValue
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    /// `@Observable` turns tracked properties into computed accessors, so assignments made
    /// while this class is initializing can still reach their `didSet` observers. Suppress
    /// persistence until every property has been restored to avoid replacing the stored
    /// snapshot with declaration defaults before it has been read.
    @ObservationIgnored private var isInitializing = true

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pulse.settings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        var loadedSnapshot = false
        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            loadedSnapshot = true
            menuBarMode = snapshot.menuBarMode
            primarySymbol = snapshot.primarySymbol
            rotateInterval = snapshot.rotateInterval
            rotateGroupID = snapshot.rotateGroupID
            providerPollIntervals = snapshot.providerPollIntervals ?? [:]
            watchRowMetricMode = switch snapshot.watchRowMetricMode {
            case .changePercent, .todayPnL, .totalPnL:
                snapshot.watchRowMetricMode!
            case .summary:
                .totalPnL
            case nil:
                .totalPnL
            }
            redUp = snapshot.redUp
            showsUSExtendedHours = snapshot.showsUSExtendedHours ?? true
            prioritizeOpenMarkets = snapshot.prioritizeOpenMarkets ?? true
            if let restoredPeriod = snapshot.minuteCandlePeriod, restoredPeriod.isMinuteK {
                minuteCandlePeriod = restoredPeriod
            }
            disabledProviderIDs = snapshot.disabledProviderIDs ?? []
            mcpEnabled = snapshot.mcpEnabled ?? false
            recentSearchQueries = snapshot.recentSearchQueries ?? []
            // An older snapshot has no key at all, and the default the user
            // never chose is the compact one — the same `true` a fresh install
            // gets, so upgrading does not silently reflow every plan row.
            compactPlanCards = snapshot.compactPlanCards ?? true
            pinnedWindowVisible = snapshot.pinnedWindowVisible ?? false
            pinnedWindowTopLeft = snapshot.pinnedWindowTopLeft
            // A rejected (non-finite or nonpositive) stored value decodes as nil,
            // which is the same automatic sizing an absent key gets.
            if let storedHeight = snapshot.menuBarPanelHeight,
               storedHeight.isFinite, storedHeight > 0 {
                menuBarPanelHeight = storedHeight
            }
            showPriceInMenuBar = snapshot.showPriceInMenuBar ?? false
            languagePreference = snapshot.languagePreference ?? .system
            positionCostBasis = snapshot.positionCostBasis ?? .average
            shareAnonymousUsageData = snapshot.shareAnonymousUsageData ?? true
            UserDefaults.standard.set(languagePreference.rawValue, forKey: PulseLocalization.languagePreferenceKey)
        } else {
            languagePreference = PulseLocalization.currentPreference
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isInitializing = false
        if loadedSnapshot {
            // Rewrite a legacy crypto primarySymbol using SymbolID's structured format.
            save()
        }
    }

    private struct Snapshot: Codable {
        var menuBarMode: MenuBarMode
        var primarySymbol: SymbolID?
        var rotateInterval: TimeInterval
        var rotateGroupID: UUID?
        var watchRowMetricMode: WatchRowMetricMode?
        var redUp: Bool
        var showsUSExtendedHours: Bool?
        var prioritizeOpenMarkets: Bool?
        var minuteCandlePeriod: CandlePeriod?
        var disabledProviderIDs: Set<String>?
        var mcpEnabled: Bool?
        var recentSearchQueries: [String]?
        var compactPlanCards: Bool?
        var pinnedWindowVisible: Bool?
        var pinnedWindowTopLeft: CGPoint?
        var menuBarPanelHeight: CGFloat?
        var showPriceInMenuBar: Bool?
        var languagePreference: PulseLanguagePreference?
        var positionCostBasis: PositionCostBasis?
        var providerPollIntervals: [String: TimeInterval]?
        var shareAnonymousUsageData: Bool?
    }

    private func save() {
        guard !isInitializing else { return }
        let snapshot = Snapshot(menuBarMode: menuBarMode, primarySymbol: primarySymbol,
                                rotateInterval: rotateInterval,
                                rotateGroupID: rotateGroupID,
                                watchRowMetricMode: watchRowMetricMode, redUp: redUp,
                                showsUSExtendedHours: showsUSExtendedHours,
                                prioritizeOpenMarkets: prioritizeOpenMarkets,
                                minuteCandlePeriod: minuteCandlePeriod,
                                disabledProviderIDs: disabledProviderIDs,
                                mcpEnabled: mcpEnabled,
                                recentSearchQueries: recentSearchQueries,
                                compactPlanCards: compactPlanCards,
                                pinnedWindowVisible: pinnedWindowVisible,
                                pinnedWindowTopLeft: pinnedWindowTopLeft,
                                menuBarPanelHeight: menuBarPanelHeight,
                                showPriceInMenuBar: showPriceInMenuBar,
                                languagePreference: languagePreference,
                                positionCostBasis: positionCostBasis,
                                providerPollIntervals: providerPollIntervals,
                                shareAnonymousUsageData: shareAnonymousUsageData)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
