import Foundation
import PulseCore
import PulseActivity
import ActivityKit

@MainActor
final class IPhoneActivityBinding: PulseActivityDataSource, PulseActivityTokenDelegate {
    private weak var app: IPhoneAppState?
    private let preferences: PulseTrackingPreferenceStore
    private var showing: SymbolID?
    private var wasRemoteCapable = false
    private var operation: Task<Void, Never>?
    private lazy var coordinator = PulseActivityCoordinator(dataSource: self,
        preferencesStore: preferences, capability: .foregroundOnly)

    init(app: IPhoneAppState) {
        self.app = app
        preferences = PulseTrackingPreferenceStore(defaults: app.defaults)
    }
    func changedByUser() {
        let previous = operation
        operation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let app = self.app else { return }
            if app.automaticTrackingEnabled && !app.pausedToday {
                self.preferences.mutate { $0.enabled = true }
                await self.coordinator.resumeToday()
            }
            self.reconcile()
        }
    }
    func reconcile() {
        let previous = operation
        operation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let app = self.app else { return }
            self.preferences.mutate { value in
                value.enabled = app.automaticTrackingEnabled && !app.pausedToday
                value.pinnedSymbolKey = app.activeItems.first {
                    app.watchlist.isPinned($0.symbol, in: app.watchlist.selectedGroupID)
                }?.symbol.description
            }
            self.coordinator.tokenDelegate = self
            self.coordinator.onUserDismissed = { [weak app] in app?.pauseTrackingToday() }
            let remoteCapable = app.pushClient.isConfigured && app.pushClient.liveReady
            if remoteCapable && !self.wasRemoteCapable && self.coordinator.activeActivityCount > 0 {
                // Existing activities were created without a push token; they
                // can never receive remote updates, so recreate them once.
                await self.coordinator.adoptRemotePushCapability()
            }
            self.wasRemoteCapable = remoteCapable
            self.coordinator.setDeclaredCapability(remoteCapable ? .remotePushConfigured : .foregroundOnly)
            if app.pushClient.isConfigured && app.automaticTrackingEnabled { self.coordinator.startObservingPushTokens() }
            let status = app.isForeground ? await self.coordinator.reconcile() : nil
            if app.pushClient.isConfigured {
                let pauseUntil = app.defaults.object(forKey: "ios.tracking.pauseUntil") as? Date
                if !app.automaticTrackingEnabled || app.pausedToday {
                    await app.pushClient.updatePolicy(enabled: app.automaticTrackingEnabled, pauseUntil: pauseUntil)
                } else if let state = self.activityState(now: .now), let symbol = self.primary() {
                    await app.pushClient.register(attributes: self.activityAttributes(), state: state,
                        windows: Self.authorizedWindows(for: symbol.market), enabled: true, pauseUntil: nil)
                } else if self.trackingCandidates().allSatisfy({ !$0.qualifies }) {
                    await app.pushClient.updatePolicy(enabled: false, pauseUntil: nil)
                }
            }
            if !app.automaticTrackingEnabled { app.activityStatus = "自动关注未开启" }
            else if app.pausedToday { app.activityStatus = "今日已暂停 · 下个市场交易日按授权恢复" }
            else if let error = self.coordinator.status.lastErrorDescription { app.activityStatus = error }
            else if !self.coordinator.status.activitiesEnabled { app.activityStatus = "系统尚未允许实时活动" }
            else if app.pushClient.isConfigured { app.activityStatus = app.pushClient.statusText }
            else if let status {
                app.activityStatus = "\(status.shortLabel.isEmpty ? "本机自动关注" : status.shortLabel) · 系统活动 \(self.coordinator.activeActivityCount) 项 · 后台推送未配置"
            }
            else { app.activityStatus = "当前无可展示的开市标的 · 后台推送未配置" }
        }
    }
    func trackingCandidates() -> [PulseActivityCandidate] {
        guard let app else { return [] }
        return app.activeItems.map { item in
            let entries = app.planEntries.filter { $0.symbol == item.symbol && $0.displayState == .waiting }
            return PulseActivityCandidate(symbolKey: item.symbol.description, held: item.hasPosition,
                hasActivePlan: !entries.isEmpty,
                pinned: app.watchlist.isPinned(item.symbol, in: app.watchlist.selectedGroupID),
                actionablePlanCount: entries.filter { entry in
                    TradePlanOverview.isReached(entry, currentPrice: { app.freshPrice($0) })
                }.count)
        }
    }
    private func primary() -> SymbolID? {
        guard let app else { return nil }
        let qualifying = trackingCandidates().filter(\.qualifies)
        let pinned = preferences.load().pinnedSymbolKey
        let candidates = qualifying.filter { candidate in
            guard let item = app.activeItems.first(where: { $0.symbol.description == candidate.symbolKey }) else { return false }
            return candidate.symbolKey == pinned || TradingCalendar.state(of: item.symbol.market) == .regular
        }
        let ordered = PulseTrackingPolicy.order(candidates, pinnedSymbolKey: pinned)
        // Keep a selected primary stable while it still qualifies, unless the
        // user explicitly pins another instrument.
        if let showing, candidates.contains(where: { $0.symbolKey == showing.description }),
           pinned == nil || pinned == showing.description { return showing }
        let key = ordered.first?.symbolKey
        showing = app.activeItems.first { $0.symbol.description == key }?.symbol
        return showing
    }
    func currentMarket() -> (key: String, phase: PulseMarketPhase, timeZone: TimeZone) {
        let symbol = primary()
        let market = symbol?.market ?? .sh
        return (market.rawValue, Self.phase(market), market.timeZone)
    }
    func activityAttributes() -> PulseActivityAttributes {
        let key = primary()?.description ?? "unavailable"
        return PulseActivityAttributes(symbolKey: key, destination: .instrumentDetail(symbolKey: key))
    }
    func activityState(now: Date) -> PulseActivityState? {
        guard let app, let symbol = primary(), let quote = app.quote(symbol), quote.price.isFinite,
              quote.price > 0 else { return nil }
        let entries = app.planEntries.filter { $0.symbol == symbol && $0.displayState == .waiting }
        let digest = PulseActivityPlanDigest(priceConditionReachedCount: entries.filter {
            TradePlanOverview.isReached($0, currentPrice: { app.freshPrice($0) })
        }.count, manualReviewCount: entries.filter {
            ($0.plan.conditions ?? []).contains { $0.state != .confirmed }
        }.count, remainingPlanCount: entries.count,
            asOf: app.confirmedPlanAt,
            revision: app.confirmedPlanRevision,
            syncState: app.syncStatus == "已同步" ? .synced : .pending)
        let phase = Self.phase(symbol.market)
        let isIndex = symbol.indexID != nil || symbol.sectorIndex != nil
        let instrument = PulseActivityInstrument(symbolKey: symbol.description,
            displayName: app.displayName(symbol), identityText: symbol.description,
            currencyCode: quote.currencyCode ?? symbol.currencyCode,
            unit: isIndex ? .points : .currency,
            price: quote.price, change: quote.change, changePercent: quote.previousClose > 0 ? quote.changePercent : nil,
            quoteSourceTime: quote.timestamp, sourceDelay: quote.sourceDelay, marketPhase: phase)
        return PulseActivityState(primary: instrument, plans: digest, status: .live,
            staleDate: PulseStalenessPolicy.default.staleDate(sourceTime: quote.timestamp,
                sourceDelay: quote.sourceDelay, marketPhase: phase), quoteSourceTime: quote.timestamp,
            sessionID: PulseActivitySession.identifier(marketKey: symbol.market.rawValue,
                phase: phase, now: now, timeZone: symbol.market.timeZone))
    }
    func activityDidReceivePushToStartToken(_ token: Data, forAttributesType typeName: String) {
        app?.pushClient.receivePushToStartToken(token)
        reconcile()
    }
    func activityDidReceiveUpdateToken(_ token: Data, forActivityID activityID: String) {
        app?.pushClient.receiveUpdateToken(token, activityID: activityID)
        // A remote start can wake the app without any foreground quote fetch.
        // Relay the real activity's state/token; do not invent a phone quote or
        // wait until the user manually opens the app again.
        Task { @MainActor [weak self] in
            guard let self, let app = self.app, app.automaticTrackingEnabled, !app.pausedToday,
                  let activity = Activity<PulseActivityAttributes>.activities.first(where: { $0.id == activityID }),
                  let symbol = app.watchlist.quoteSymbols.first(where: { $0.description == activity.attributes.symbolKey }) else { return }
            await app.pushClient.register(attributes: activity.attributes, state: activity.content.state,
                windows: Self.authorizedWindows(for: symbol.market), enabled: true, pauseUntil: nil)
        }
        reconcile()
    }
    func activityDidInvalidateToken(_ token: Data) { app?.pushClient.invalidateToken(token) }

    /// Bounded, explicit authorization windows derived from the SAME exchange
    /// calendar as the app. They are refreshed when the app can run; no claim
    /// of permanent background scheduling beyond the authorized horizon.
    private static func authorizedWindows(for market: Market, now: Date = .now) -> [PushSessionWindow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let start = calendar.startOfDay(for: now)
        let limit = calendar.date(byAdding: .day, value: 16, to: start) ?? start
        let formatter = ISO8601DateFormatter()
        var result: [PushSessionWindow] = []
        var open: Date?
        var point = start
        while point <= limit && result.count < 8 {
            let regular = point < limit && TradingCalendar.state(of: market, at: point) == .regular
            let durationLimit = open.map { point.timeIntervalSince($0) >= 8 * 3600 } ?? false
            if let began = open, !regular || durationLimit {
                if point > now {
                    result.append(PushSessionWindow(id: "\(market.rawValue)-\(Int(began.timeIntervalSince1970))",
                        start: formatter.string(from: began), end: formatter.string(from: point)))
                }
                open = nil
            }
            if regular && open == nil { open = point }
            point = point.addingTimeInterval(15 * 60)
        }
        return result
    }
    private static func phase(_ market: Market) -> PulseMarketPhase {
        switch TradingCalendar.state(of: market) {
        case .regular: .regular
        case .preMarket: .preMarket
        case .postMarket: .postMarket
        case .overnight: .overnight
        case .lunchBreak: .lunchBreak
        case .closed: .closed
        }
    }
}
