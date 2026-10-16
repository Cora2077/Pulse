import Foundation

/// The immutable identity of one tracked activity.
///
/// ActivityKit requires the attribute part to be constant for the activity's
/// whole life, so it holds only identity: the primary symbol and the deep link.
/// Everything that moves lives in ``PulseActivityState``.
///
/// The type itself is unconditional (the app, the widget extension, tests and a
/// push service all need it); only the ActivityKit *lifecycle* is iOS-gated.
public struct PulseActivityAttributes: Codable, Hashable, Sendable {
    /// Provider-independent key of the primary instrument (`600519.SH`). Used to
    /// match a pinned preference and to reconcile against existing activities.
    public var symbolKey: String
    /// Deep link the activity opens. Detail/plan viewing only — no write route
    /// can be expressed by this type, by construction.
    public var destination: PulseDeepLink

    public init(symbolKey: String, destination: PulseDeepLink) {
        self.symbolKey = symbolKey
        self.destination = destination
    }

    public init(primary: PulseActivityInstrument, plans: PulseActivityPlanDigest = PulseActivityPlanDigest()) {
        self.init(
            symbolKey: primary.symbolKey,
            destination: .instrumentDetail(symbolKey: primary.symbolKey)
        )
    }
}

/// ActivityKit lifecycle payload: a state plus its freshness deadline.
///
/// Mirrors `ActivityContent<State>` so the value can be built, tested and
/// pushed from code that must compile on macOS too.
public struct PulseActivityContent: Codable, Hashable, Sendable {
    public var state: PulseActivityState
    /// `nil` means "never stale" and is only used for the closed-market case
    /// where a deadline would be a lie; a closed market's quote expires only
    /// when the market reopens, which the app re-evaluates on foreground.
    public var staleDate: Date?
    /// Handed to ActivityKit so the system can order competing activities.
    public var relevanceScore: Double

    public init(state: PulseActivityState, staleDate: Date? = nil, relevanceScore: Double = 0) {
        self.state = state
        self.staleDate = staleDate ?? state.staleDate
        self.relevanceScore = relevanceScore
    }
}

// MARK: - Deep links

/// Every destination an activity or widget is allowed to open.
///
/// This enum is the whole write-surface contract: there is no case that creates,
/// edits or deletes a plan or a fill. Adding trading from a lock-screen surface
/// would require changing this type, on purpose.
public enum PulseDeepLink: Codable, Hashable, Sendable {
    /// Instrument detail in the watchlist (quote, chart, plans for that symbol).
    case instrumentDetail(symbolKey: String)
    /// The plan list, optionally focused on one plan.
    case plans(planID: String?)
    /// The plan list filtered to what needs the user right now.
    case planInbox

    /// The URL encoded into the activity's `widgetURL` / `Link`.
    ///
    /// The scheme is supplied by the app (`app.pulse.ios` in this project) so
    /// this module does not hard-code a bundle identifier.
    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch self {
        case .instrumentDetail(let symbolKey):
            components.host = "instrument"
            components.queryItems = [URLQueryItem(name: "symbol", value: symbolKey)]
        case .plans(let planID):
            components.host = "plans"
            if let planID { components.queryItems = [URLQueryItem(name: "id", value: planID)] }
        case .planInbox:
            components.host = "plans"
            components.queryItems = [URLQueryItem(name: "view", value: "inbox")]
        }
        return components.url
    }

    /// Human-readable action title, in Chinese, for the expanded island's link.
    public var actionTitle: String {
        switch self {
        case .instrumentDetail: "查看详情"
        case .plans: "查看计划"
        case .planInbox: "查看待办计划"
        }
    }
}
