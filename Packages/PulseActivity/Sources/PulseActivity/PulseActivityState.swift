import Foundation

/// What the activity's primary instrument row shows.
///
/// This is deliberately *display* data, not ledger data: name, full identity
/// text, currency, price, change, and the *source* timestamp of the quote.
/// There is no position size, cost basis, P&L or account name anywhere in the
/// activity payload — see ``PulseActivityState``.
public struct PulseActivityInstrument: Codable, Hashable, Sendable {
    /// Provider-independent identity key (`600519.SH`, `BTC/USDT`, `hsi`…).
    /// Produced by the app from its own `SymbolID`; the widget layer never
    /// reinterprets it, it only matches it against the pinned preference.
    public var symbolKey: String
    /// Chinese display name when the app has one ("贵州茅台"). Required: an
    /// activity that cannot say what it is tracking is not shown.
    public var displayName: String
    /// Full identity text shown next to the name ("600519.SH", "00700.HK",
    /// "BTC/USDT"). Kept complete and never truncated in storage; the small
    /// widget families shorten it at render time only.
    public var identityText: String
    /// Currency of ``price`` ("CNY", "HKD", "USD"…). Shown so a number is never
    /// presented as if all markets shared one currency.
    ///
    /// Always a real ISO-style 3–4 letter code, **including for an index**: an
    /// index is still quoted in the currency of its market (the SSE Composite in
    /// CNY), and the point-vs-currency distinction lives in ``unit``. Overloading
    /// this field with a pseudo-code like `POINTS` would break the push service's
    /// `^[A-Z]{3,4}$` validation, which is the opposite of what a wire field is
    /// for.
    public var currencyCode: String
    /// What the number *is*, which decides precision and the label beside it.
    /// Defaults to ``PulseQuoteUnit/currency`` so every existing payload and
    /// every equity keeps working unchanged.
    public var unit: PulseQuoteUnit
    public var price: Double
    /// Absolute change against the previous close, in ``currencyCode`` (or in
    /// points when ``unit`` is ``PulseQuoteUnit/points``).
    public var change: Double
    /// Percent change against the previous close. `nil` when the source cannot
    /// supply a previous close; never fabricated from zero.
    public var changePercent: Double?
    /// The time the **source** stamped the quote. This — not the time the device
    /// received or wrote it — is what staleness is measured against.
    public var quoteSourceTime: Date
    /// The source's own delay in seconds when it declares one (delayed feeds).
    public var sourceDelay: TimeInterval?
    /// Trading state of that instrument's market at ``quoteSourceTime``.
    public var marketPhase: PulseMarketPhase

    public init(
        symbolKey: String,
        displayName: String,
        identityText: String,
        currencyCode: String,
        unit: PulseQuoteUnit = .currency,
        price: Double,
        change: Double,
        changePercent: Double? = nil,
        quoteSourceTime: Date,
        sourceDelay: TimeInterval? = nil,
        marketPhase: PulseMarketPhase = .unknown
    ) {
        self.symbolKey = symbolKey
        self.displayName = displayName
        self.identityText = identityText
        self.currencyCode = currencyCode
        self.unit = unit
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.quoteSourceTime = quoteSourceTime
        self.sourceDelay = sourceDelay
        self.marketPhase = marketPhase
    }

    /// Backward-compatible decoding: a payload written before ``unit`` existed
    /// is a currency quote, which is exactly what the old formatter assumed.
    private enum CodingKeys: String, CodingKey {
        case symbolKey, displayName, identityText, currencyCode, unit
        case price, change, changePercent, quoteSourceTime, sourceDelay, marketPhase
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            symbolKey: try container.decode(String.self, forKey: .symbolKey),
            displayName: try container.decode(String.self, forKey: .displayName),
            identityText: try container.decode(String.self, forKey: .identityText),
            currencyCode: try container.decode(String.self, forKey: .currencyCode),
            unit: try container.decodeIfPresent(PulseQuoteUnit.self, forKey: .unit) ?? .currency,
            price: try container.decode(Double.self, forKey: .price),
            change: try container.decode(Double.self, forKey: .change),
            changePercent: try container.decodeIfPresent(Double.self, forKey: .changePercent),
            quoteSourceTime: try container.decode(Date.self, forKey: .quoteSourceTime),
            sourceDelay: try container.decodeIfPresent(TimeInterval.self, forKey: .sourceDelay),
            marketPhase: try container.decodeIfPresent(PulseMarketPhase.self, forKey: .marketPhase) ?? .unknown
        )
    }

    /// Direction used for color. Zero is neither up nor down.
    public var direction: PulseChangeDirection { PulseChangeDirection(change: change) }

    /// Whether the source's own delay makes this quote inherently not live.
    public var isDelayedSource: Bool { (sourceDelay ?? 0) >= 60 }
}

/// What a quoted number *is*: money, or an index level.
///
/// Kept separate from ``PulseActivityInstrument/currencyCode`` because the two
/// answer different questions — "which money is this" and "is this money at
/// all". An index has no currency of its own but still has a market, so it keeps
/// its market's currency code for reference while its *value* is points.
public enum PulseQuoteUnit: String, Codable, Hashable, Sendable {
    /// A price in ``PulseActivityInstrument/currencyCode``.
    case currency
    /// An index level, labelled 点 and shown with two decimals.
    case points

    /// The label printed beside the number: 点 for an index, else the code.
    public func label(currencyCode: String) -> String {
        switch self {
        case .points: "点"
        case .currency: currencyCode
        }
    }
}

/// Up / down / flat, resolved once so every surface colors the same way.
public enum PulseChangeDirection: String, Codable, Hashable, Sendable {
    case up, down, flat

    public init(change: Double) {
        if change > 0 { self = .up } else if change < 0 { self = .down } else { self = .flat }
    }
}

/// Market phase at the moment the quote was stamped.
///
/// This is a *displayed* state. It never means "the app is running": an
/// activity showing `.closed` still says something true about the market.
public enum PulseMarketPhase: String, Codable, Hashable, Sendable {
    case preMarket, regular, lunchBreak, postMarket, overnight, closed, unknown

    public var isOpen: Bool { self == .regular }

    public var isExtendedSession: Bool {
        switch self {
        case .preMarket, .postMarket, .overnight: true
        default: false
        }
    }

    /// Short Chinese label for lock screen / compact surfaces.
    public var shortLabel: String {
        switch self {
        case .preMarket: "盘前"
        case .regular: "交易中"
        case .lunchBreak: "午间休市"
        case .postMarket: "盘后"
        case .overnight: "夜盘"
        case .closed: "已休市"
        case .unknown: "状态未知"
        }
    }
}

/// Whether the *plan* side of this activity is confirmed-fresh.
///
/// Price freshness and plan freshness are different clocks: a live quote does
/// not make an unsynced plan current. They are modelled separately and shown
/// separately, so the surface never claims one uniform "just updated".
public enum PulsePlanSyncState: String, Codable, Hashable, Sendable {
    /// This device's plan data is the authority (no sync configured or needed).
    case local
    /// Last sync with the other device succeeded; ``PulseActivityPlanDigest/asOf`` is real.
    case synced
    /// The plan may have changed elsewhere and this device has not confirmed it.
    case pending
    /// No plan data has ever been confirmed on this device.
    case unavailable

    public var needsConfirmation: Bool { self == .pending || self == .unavailable }

    public var shortLabel: String {
        switch self {
        case .local: ""
        case .synced: ""
        case .pending: "计划待同步"
        case .unavailable: "计划未同步"
        }
    }
}

/// Redacted, count-only summary of what the user still has to deal with.
///
/// This carries **no** plan notes, prices, sizes or account names — an activity
/// is a lock-screen surface and is treated as public. The count is of pending
/// items, never of money.
///
/// **The plan clock is not the quote clock.** ``asOf`` and ``revision`` describe
/// the plan data this digest was computed from, and they move on their own
/// schedule: a live quote does not make an unsynced plan current, and a plan
/// confirmed just now does not make an old quote fresh. The surface therefore
/// never prints one uniform "刚刚更新" for both.
public struct PulseActivityPlanDigest: Codable, Hashable, Sendable {
    /// Plans with an automatic price condition that has been crossed and is
    /// waiting for the user to confirm. The system never marks these done.
    public var priceConditionReachedCount: Int
    /// Plans whose manual condition the user must review themselves.
    public var manualReviewCount: Int
    /// Remaining (unfilled) plan items, counted per plan — not per share and not
    /// per currency amount.
    public var remainingPlanCount: Int
    /// When the *plan* data behind these counts was last confirmed by its
    /// authority. `nil` means "never confirmed" and is displayed as such; it is
    /// never filled in with the quote's time.
    public var asOf: Date?
    /// The plan revision the counts were computed from, when the sync layer has
    /// one. Opaque to this module: it is carried, displayed as "有新版本" at
    /// most, and never parsed.
    public var revision: String?
    /// Where these counts came from and whether they can be trusted as current.
    /// Defaults to ``PulsePlanSyncState/unavailable`` on decode when absent, so
    /// a payload written before this field existed is never presented as
    /// confirmed.
    public var syncState: PulsePlanSyncState

    public init(
        priceConditionReachedCount: Int = 0,
        manualReviewCount: Int = 0,
        remainingPlanCount: Int = 0,
        asOf: Date? = nil,
        revision: String? = nil,
        syncState: PulsePlanSyncState = .unavailable
    ) {
        self.priceConditionReachedCount = max(0, priceConditionReachedCount)
        self.manualReviewCount = max(0, manualReviewCount)
        self.remainingPlanCount = max(0, remainingPlanCount)
        self.asOf = asOf
        self.revision = revision
        self.syncState = syncState
    }

    // Backward-compatible decoding.
    //
    // An activity written by an older build has only the three counts. That
    // payload must still decode — the alternative is a Live Activity that fails
    // to update — but it must **not** be decoded as `.synced`, which would put a
    // confident "计划已同步" on the lock screen for data whose age nobody knows.
    // Absent metadata therefore means `.unavailable`: not "pending", because
    // there is nothing saying a newer revision exists, and not "synced",
    // because nothing confirmed it either.
    private enum CodingKeys: String, CodingKey {
        case priceConditionReachedCount, manualReviewCount, remainingPlanCount
        case asOf, revision, syncState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            priceConditionReachedCount: try container.decodeIfPresent(Int.self, forKey: .priceConditionReachedCount) ?? 0,
            manualReviewCount: try container.decodeIfPresent(Int.self, forKey: .manualReviewCount) ?? 0,
            remainingPlanCount: try container.decodeIfPresent(Int.self, forKey: .remainingPlanCount) ?? 0,
            asOf: try container.decodeIfPresent(Date.self, forKey: .asOf),
            revision: try container.decodeIfPresent(String.self, forKey: .revision),
            syncState: try container.decodeIfPresent(PulsePlanSyncState.self, forKey: .syncState) ?? .unavailable
        )
    }

    /// Everything the user has to act on. This is the number a compact surface
    /// can honestly show.
    public var actionableCount: Int { priceConditionReachedCount + manualReviewCount }

    /// Anything at all to show in the "today" row.
    public var isEmpty: Bool { actionableCount == 0 && remainingPlanCount == 0 }

    /// Whether the plan side needs a "not confirmed" marker on the surface.
    public var needsSyncWarning: Bool { syncState.needsConfirmation }

    /// The plan-side freshness line, kept separate from the quote's.
    ///
    /// Returns an empty string when the plan side has nothing to qualify, so a
    /// caller renders the quote's source time alone rather than a doubled line.
    public func syncLabel(asOf now: Date) -> String {
        switch syncState {
        case .local:
            // This device is the authority; saying "已同步" would imply a
            // peer that does not exist.
            return ""
        case .synced:
            guard let asOf else { return "" }
            return "计划 \(Self.ageText(since: asOf, now: now))确认"
        case .pending:
            return "计划待同步"
        case .unavailable:
            return "计划未同步"
        }
    }

    private static func ageText(since date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        if age < 0 { return "时间超前·" }
        if age < 60 { return "刚刚" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前" }
        if age < 86_400 { return "\(Int(age / 3600)) 小时前" }
        return "\(Int(age / 86_400)) 天前"
    }

    /// One short Chinese phrase, ordered by what the user must do first.
    public var shortLabel: String {
        if priceConditionReachedCount > 0 { return "到价待确认 \(priceConditionReachedCount)" }
        if manualReviewCount > 0 { return "手工条件待复核 \(manualReviewCount)" }
        if remainingPlanCount > 0 { return "待办计划 \(remainingPlanCount)" }
        return "无待办"
    }
}

/// What the whole activity is doing right now.
///
/// Every case is something the user can be told truthfully; there is no
/// "syncing…" filler and no success state that was not observed.
public enum PulseActivityStatus: String, Codable, Hashable, Sendable {
    /// Quote is inside its freshness window for the current market phase.
    case live
    /// Quote is old enough to be labelled. Shown with the real source time.
    case stale
    /// The instrument's market is closed; the last quote stands, labelled.
    case marketClosed
    /// The user paused tracking for today. Distinct from ``disabled``.
    case pausedToday
    /// The user turned automatic tracking off. Distinct from ``pausedToday``.
    case disabled
    /// No permission / no authorized activity slot.
    case permissionRequired
    /// A remote service is required for this mode and is not configured here.
    case remoteUnavailable
    /// Nothing qualifies to be tracked.
    case noCandidate
    /// The quote is old *and* the market is closed — the common overnight case.
    public static func resolve(
        marketPhase: PulseMarketPhase,
        isStale: Bool,
        enabled: Bool,
        pausedToday: Bool
    ) -> PulseActivityStatus {
        if !enabled { return .disabled }
        if pausedToday { return .pausedToday }
        if marketPhase == .closed {
            return isStale ? .stale : .marketClosed
        }
        return isStale ? .stale : .live
    }
}

extension PulseActivityStatus {
    public var isDisplayable: Bool {
        switch self {
        case .live, .stale, .marketClosed: true
        case .pausedToday, .disabled, .permissionRequired, .remoteUnavailable, .noCandidate: false
        }
    }

    /// Short Chinese label; empty when the state needs no badge.
    public var shortLabel: String {
        switch self {
        case .live: ""
        case .stale: "待更新"
        case .marketClosed: "已休市"
        case .pausedToday: "今日暂停"
        case .disabled: "自动关注已关闭"
        case .permissionRequired: "需要权限"
        case .remoteUnavailable: "仅本机前台"
        case .noCandidate: "暂无可关注"
        }
    }

    /// Longer, honest description used by the expanded island and the app.
    public var detail: String {
        switch self {
        case .live: "行情在有效期内"
        case .stale: "行情已过期，显示的是源时间"
        case .marketClosed: "该市场已休市，显示最后一个报价"
        case .pausedToday: "今天不再自动开始，下一个交易日按原设置恢复"
        case .disabled: "自动关注已关闭，需要你重新开启"
        case .permissionRequired: "缺少实时活动权限，无法自动出现"
        case .remoteUnavailable: "未配置远程服务，只能在本机前台更新"
        case .noCandidate: "当前没有持仓、有效计划或置顶关注"
        }
    }
}

/// The live state of the activity, written by the app and rendered by the widget.
///
/// It is `Codable` + `Hashable` + `Sendable` so the same value can be persisted
/// to an App Group, handed to ActivityKit, and sent to a push service as the
/// content state of a Live Activity update.
public struct PulseActivityState: Codable, Hashable, Sendable {
    /// Primary instrument. Always present.
    public var primary: PulseActivityInstrument
    /// Redacted plan counters. Never money, never a note.
    public var plans: PulseActivityPlanDigest
    public var status: PulseActivityStatus
    /// Hard deadline handed to ActivityKit. Derived from the source time plus
    /// the freshness window, never from the receipt time.
    public var staleDate: Date
    /// The source time the whole payload was assembled from. Equal to
    /// ``PulseActivityInstrument/quoteSourceTime`` for the primary; kept here so
    /// the payload is self-describing on surfaces that only read the root.
    public var quoteSourceTime: Date
    /// Which market session this state describes, so a surface can tell that a
    /// "live" quote is a US overnight quote, say.
    public var sessionID: String?

    public init(
        primary: PulseActivityInstrument,
        plans: PulseActivityPlanDigest = PulseActivityPlanDigest(),
        status: PulseActivityStatus,
        staleDate: Date,
        quoteSourceTime: Date,
        sessionID: String? = nil
    ) {
        self.primary = primary
        self.plans = plans
        self.status = status
        self.staleDate = staleDate
        self.quoteSourceTime = quoteSourceTime
        self.sessionID = sessionID
    }

    /// Whether the freshness deadline has passed *as of* `now`.
    ///
    /// Deliberately takes `now` explicitly: nothing in this module reads the
    /// clock on its own, so tests and previews are deterministic.
    public func isStale(asOf now: Date) -> Bool { now >= staleDate }

    /// The state as it should read at `now`, with the status and stale deadline
    /// recomputed. Used by foreground reconcile and by previews.
    public func refreshed(asOf now: Date, staleness: PulseStalenessPolicy) -> PulseActivityState {
        let effective = staleness.effectiveSourceTime(
            quoteSourceTime: quoteSourceTime,
            sourceDelay: primary.sourceDelay
        )
        let deadline = staleness.staleDate(
            sourceTime: effective,
            marketPhase: primary.marketPhase
        )
        var copy = self
        copy.staleDate = deadline
        if status.isDisplayable {
            copy.status = PulseActivityStatus.resolve(
                marketPhase: primary.marketPhase,
                isStale: now >= deadline,
                enabled: true,
                pausedToday: false
            )
        }
        return copy
    }

    /// Display time — the *source* clock, never `Date()`.
    public var displayTime: Date { primary.quoteSourceTime }
}

// MARK: - Freshness

/// How long a quote stays presentable, per market phase.
///
/// The numbers are display windows, not promises about a feed. A closed market's
/// last quote is honest for much longer than an open market's, because nothing
/// should have changed it.
public struct PulseStalenessPolicy: Hashable, Sendable {
    /// Freshness window during the regular session of an open market.
    public var openMarketWindow: TimeInterval
    /// Window during pre/post/overnight sessions, which update less often.
    public var extendedSessionWindow: TimeInterval
    /// Window applied once the market is closed.
    public var closedMarketWindow: TimeInterval
    /// Window used when the phase is unknown (source did not say).
    public var unknownPhaseWindow: TimeInterval

    public init(
        openMarketWindow: TimeInterval = 5 * 60,
        extendedSessionWindow: TimeInterval = 20 * 60,
        closedMarketWindow: TimeInterval = 24 * 60 * 60,
        unknownPhaseWindow: TimeInterval = 15 * 60
    ) {
        self.openMarketWindow = openMarketWindow
        self.extendedSessionWindow = extendedSessionWindow
        self.closedMarketWindow = closedMarketWindow
        self.unknownPhaseWindow = unknownPhaseWindow
    }

    public static let `default` = PulseStalenessPolicy()

    public func window(for phase: PulseMarketPhase) -> TimeInterval {
        switch phase {
        case .regular: openMarketWindow
        case .preMarket, .postMarket, .overnight, .lunchBreak: extendedSessionWindow
        case .closed: closedMarketWindow
        case .unknown: unknownPhaseWindow
        }
    }

    /// The time staleness is measured from. A source that declares a delay has
    /// effectively aged its own quote by that much, so the delay is added to the
    /// source timestamp rather than ignored.
    public func effectiveSourceTime(quoteSourceTime: Date, sourceDelay: TimeInterval?) -> Date {
        quoteSourceTime.addingTimeInterval(max(0, sourceDelay ?? 0))
    }

    public func staleDate(sourceTime: Date, sourceDelay: TimeInterval? = nil, marketPhase: PulseMarketPhase) -> Date {
        effectiveSourceTime(quoteSourceTime: sourceTime, sourceDelay: sourceDelay)
            .addingTimeInterval(window(for: marketPhase))
    }

    public func isStale(sourceTime: Date, sourceDelay: TimeInterval? = nil, marketPhase: PulseMarketPhase, asOf now: Date) -> Bool {
        now >= staleDate(sourceTime: sourceTime, sourceDelay: sourceDelay, marketPhase: marketPhase)
    }
}
