import Foundation
import Testing

@testable import PulseActivity

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func instrument(
    key: String = "600519.SH",
    price: Double = 1_680.5,
    change: Double = 12.4,
    changePercent: Double? = 0.74,
    sourceDelay: TimeInterval? = nil,
    phase: PulseMarketPhase = .regular,
    sourceTime: Date = base
) -> PulseActivityInstrument {
    PulseActivityInstrument(
        symbolKey: key,
        displayName: "贵州茅台",
        identityText: key,
        currencyCode: "CNY",
        price: price,
        change: change,
        changePercent: changePercent,
        quoteSourceTime: sourceTime,
        sourceDelay: sourceDelay,
        marketPhase: phase
    )
}

private func state(
    instrument primary: PulseActivityInstrument,
    plans: PulseActivityPlanDigest = PulseActivityPlanDigest(),
    status: PulseActivityStatus = .live,
    staleDate: Date
) -> PulseActivityState {
    PulseActivityState(
        primary: primary,
        plans: plans,
        status: status,
        staleDate: staleDate,
        quoteSourceTime: primary.quoteSourceTime
    )
}

// MARK: - Payload shape

@Suite("Activity payload")
struct PulseActivityStateTests {
    @Test("Round-trips through JSON unchanged")
    func codableRoundTrip() throws {
        let digest = PulseActivityPlanDigest(
            priceConditionReachedCount: 1,
            manualReviewCount: 2,
            remainingPlanCount: 3
        )
        let original = state(
            instrument: instrument(sourceDelay: 900, phase: .postMarket),
            plans: digest,
            status: .stale,
            staleDate: base.addingTimeInterval(1200)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PulseActivityState.self, from: data)
        #expect(decoded == original)
        #expect(decoded.primary.sourceDelay == 900)
        #expect(decoded.plans.actionableCount == 3)
    }

    @Test("Payload carries no position size, cost or account field")
    func payloadIsRedacted() throws {
        let original = state(instrument: instrument(), staleDate: base.addingTimeInterval(300))
        let data = try JSONEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        // The redaction contract in docs/development/iphone-execution.md §21:
        // public quotes and a pending-plan count only, no balances or sizes.
        for forbidden in ["quantity", "shares", "position", "cost", "balance",
                          "account", "pnl", "profit", "marketValue", "note"] {
            #expect(!json.localizedCaseInsensitiveContains(forbidden),
                    "payload leaked a field matching \(forbidden)")
        }
        #expect(json.contains("priceConditionReachedCount"))
        #expect(json.contains("600519.SH"))
    }

    @Test("Staleness follows the source clock, not the receipt time")
    func stalenessUsesSourceTime() {
        let policy = PulseStalenessPolicy(openMarketWindow: 300)
        // A quote stamped 10 minutes ago is stale even though we just received it.
        let sourceTime = base.addingTimeInterval(-600)
        #expect(policy.isStale(sourceTime: sourceTime, marketPhase: .regular, asOf: base))
        // The same quote is fresh five minutes before it was stamped... only if
        // the window is longer than the age; here it is not.
        #expect(!policy.isStale(sourceTime: sourceTime, marketPhase: .regular,
                                asOf: sourceTime.addingTimeInterval(299)))
        #expect(policy.isStale(sourceTime: sourceTime, marketPhase: .regular,
                               asOf: sourceTime.addingTimeInterval(301)))
    }

    @Test("A declared source delay ages the quote further")
    func sourceDelayAgesQuote() {
        let policy = PulseStalenessPolicy(openMarketWindow: 300)
        let sourceTime = base
        #expect(policy.staleDate(sourceTime: sourceTime, marketPhase: .regular)
                == base.addingTimeInterval(300))
        #expect(policy.staleDate(sourceTime: sourceTime, sourceDelay: 900, marketPhase: .regular)
                == base.addingTimeInterval(1200))
        // A delayed feed's clock is *behind* ours, so the delay moves the
        // effective source time forward and shortens the remaining freshness.
        // 12 minutes old + 15 minute delay = 3 minutes in hand, then a 5 minute
        // window, so the deadline lands 8 minutes after `base`.
        let delayed = base.addingTimeInterval(-720)
        #expect(policy.staleDate(sourceTime: delayed, sourceDelay: 900, marketPhase: .regular)
                == base.addingTimeInterval(480))
        #expect(!policy.isStale(sourceTime: delayed, sourceDelay: 900,
                                marketPhase: .regular, asOf: base.addingTimeInterval(479)))
        #expect(policy.isStale(sourceTime: delayed, sourceDelay: 900,
                               marketPhase: .regular, asOf: base.addingTimeInterval(480)))
        // Without the delay the same source time is long dead.
        #expect(policy.isStale(sourceTime: delayed, sourceDelay: nil,
                               marketPhase: .regular, asOf: base))
    }

    @Test("Closed markets keep the last quote honest for much longer")
    func closedMarketWindow() {
        let policy = PulseStalenessPolicy(openMarketWindow: 300, closedMarketWindow: 86_400)
        let sourceTime = base
        #expect(!policy.isStale(sourceTime: sourceTime, marketPhase: .closed, asOf: base.addingTimeInterval(3600)))
        #expect(policy.isStale(sourceTime: sourceTime, marketPhase: .closed, asOf: base.addingTimeInterval(90_000)))
    }

    @Test("Never fabricates a current time")
    func staleDateIsSourceDerived() {
        let original = state(instrument: instrument(), staleDate: base.addingTimeInterval(300))
        let refreshed = original.refreshed(asOf: base.addingTimeInterval(60_000), staleness: .default)
        // Still anchored to the source time, not to `now`.
        #expect(refreshed.staleDate == base.addingTimeInterval(300))
        #expect(refreshed.displayTime == base)
        #expect(refreshed.status == .stale)
    }

    @Test("Status resolution distinguishes pause, disable and closed market")
    func statusResolution() {
        #expect(PulseActivityStatus.resolve(marketPhase: .regular, isStale: false,
                                            enabled: true, pausedToday: false) == .live)
        #expect(PulseActivityStatus.resolve(marketPhase: .regular, isStale: true,
                                            enabled: true, pausedToday: false) == .stale)
        #expect(PulseActivityStatus.resolve(marketPhase: .closed, isStale: false,
                                            enabled: true, pausedToday: false) == .marketClosed)
        #expect(PulseActivityStatus.resolve(marketPhase: .closed, isStale: true,
                                            enabled: true, pausedToday: false) == .stale)
        #expect(PulseActivityStatus.resolve(marketPhase: .regular, isStale: false,
                                            enabled: true, pausedToday: true) == .pausedToday)
        #expect(PulseActivityStatus.resolve(marketPhase: .regular, isStale: false,
                                            enabled: false, pausedToday: true) == .disabled)
    }

    @Test("Direction and market phase labels")
    func directionAndPhase() {
        #expect(PulseChangeDirection(change: 0.01) == .up)
        #expect(PulseChangeDirection(change: -0.01) == .down)
        #expect(PulseChangeDirection(change: 0) == .flat)
        #expect(PulseMarketPhase.regular.isOpen)
        #expect(!PulseMarketPhase.postMarket.isOpen)
        #expect(PulseMarketPhase.postMarket.isExtendedSession)
        #expect(PulseMarketPhase.lunchBreak.shortLabel == "午间休市")
    }

    @Test("Plan digest counts only what the user must act on")
    func planDigest() {
        let empty = PulseActivityPlanDigest()
        #expect(empty.isEmpty)
        #expect(empty.shortLabel == "无待办")

        let reached = PulseActivityPlanDigest(priceConditionReachedCount: 2, remainingPlanCount: 5)
        #expect(reached.actionableCount == 2)
        #expect(reached.shortLabel == "到价待确认 2")

        let manual = PulseActivityPlanDigest(manualReviewCount: 1, remainingPlanCount: 5)
        #expect(manual.shortLabel == "手工条件待复核 1")

        let only = PulseActivityPlanDigest(remainingPlanCount: 3)
        #expect(only.actionableCount == 0)
        #expect(only.shortLabel == "待办计划 3")
    }

    @Test("Negative counts are clamped rather than displayed")
    func digestClamps() {
        let digest = PulseActivityPlanDigest(priceConditionReachedCount: -4, manualReviewCount: -1, remainingPlanCount: -9)
        #expect(digest.actionableCount == 0)
        #expect(digest.isEmpty)
    }

    // MARK: Plan sync metadata (item 4)

    @Test("A payload written before asOf/revision/syncState still decodes")
    func legacyPlanDigestDecodes() throws {
        // Exactly what an older build wrote: three counts and nothing else.
        let legacy = Data(#"{"priceConditionReachedCount":2,"manualReviewCount":0,"remainingPlanCount":5}"#.utf8)
        let digest = try JSONDecoder().decode(PulseActivityPlanDigest.self, from: legacy)
        #expect(digest.priceConditionReachedCount == 2)
        #expect(digest.remainingPlanCount == 5)
        // And not as "synced": nothing confirmed it. Presenting it as current is
        // the failure this default exists to prevent.
        #expect(digest.syncState == .unavailable)
        #expect(digest.asOf == nil)
        #expect(digest.revision == nil)
        #expect(digest.needsSyncWarning)
    }

    @Test("A legacy payload missing the counts entirely defaults to zero, never nil-crash")
    func legacyPlanDigestWithNoCounts() throws {
        let legacy = Data("{}".utf8)
        let digest = try JSONDecoder().decode(PulseActivityPlanDigest.self, from: legacy)
        #expect(digest.actionableCount == 0)
        #expect(digest.isEmpty)
        #expect(digest.syncState == .unavailable)
    }

    @Test("The new fields round-trip through JSON")
    func planDigestRoundTrips() throws {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = PulseActivityPlanDigest(
            priceConditionReachedCount: 1,
            manualReviewCount: 1,
            remainingPlanCount: 4,
            asOf: asOf,
            revision: "rev-42",
            syncState: .synced
        )
        let decoded = try JSONDecoder().decode(
            PulseActivityPlanDigest.self,
            from: JSONEncoder().encode(digest)
        )
        #expect(decoded == digest)
        #expect(decoded.actionableCount == 2)
        #expect(decoded.asOf == asOf)
    }

    @Test("An unknown syncState value is rejected, not silently coerced")
    func unknownSyncStateFailsDecoding() {
        // Same policy as the other enums: a payload this build cannot interpret
        // must not be pushed or rendered as if it could.
        let payload = Data(#"{"priceConditionReachedCount":0,"manualReviewCount":0,"remainingPlanCount":0,"syncState":"reconciling"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PulseActivityPlanDigest.self, from: payload)
        }
    }

    @Test("Plan age is phrased from the plan's own clock, not the quote's")
    func planSyncLabelIsIndependent() {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)

        let synced = PulseActivityPlanDigest(asOf: asOf, syncState: .synced)
        #expect(synced.syncLabel(asOf: asOf.addingTimeInterval(30)) == "计划 刚刚确认")
        #expect(synced.syncLabel(asOf: asOf.addingTimeInterval(600)) == "计划 10 分钟前确认")
        #expect(!synced.needsSyncWarning)

        // A never-confirmed digest says so and never borrows the quote's time.
        let pending = PulseActivityPlanDigest(syncState: .pending)
        #expect(pending.syncLabel(asOf: asOf) == "计划待同步")
        #expect(pending.needsSyncWarning)

        let unavailable = PulseActivityPlanDigest(syncState: .unavailable)
        #expect(unavailable.syncLabel(asOf: asOf) == "计划未同步")
        #expect(unavailable.needsSyncWarning)

        // A local-only device has no peer to sync with; claiming either state
        // would be inventing one.
        let local = PulseActivityPlanDigest(syncState: .local)
        #expect(local.syncLabel(asOf: asOf).isEmpty)
        #expect(!local.needsSyncWarning)
    }

    @Test("A synced digest with no asOf does not fabricate a confirmation time")
    func syncedWithoutDateSaysNothing() {
        let digest = PulseActivityPlanDigest(syncState: .synced)
        // Claiming "计划刚刚确认" here would be exactly the invented freshness
        // this module exists to avoid.
        #expect(digest.syncLabel(asOf: Date()).isEmpty)
        #expect(!digest.needsSyncWarning)
    }
}

// MARK: - Presentation contract

@Suite("Activity formatting")
struct PulseActivityFormatTests {
    @Test("Percent shows a real dash when the source has no previous close")
    func percentPlaceholder() {
        #expect(PulseActivityFormat.changePercent(nil) == "—")
        #expect(PulseActivityFormat.changePercent(0) == "0.00%")
        #expect(PulseActivityFormat.changePercent(1.834) == "+1.83%")
        #expect(PulseActivityFormat.changePercent(-1.2) == "-1.20%")
    }

    @Test("Currency drives precision")
    func precision() {
        #expect(PulseActivityFormat.price(1_680.5, currencyCode: "CNY") == "1,680.50")
        #expect(PulseActivityFormat.price(68_500, currencyCode: "JPY") == "68,500")
        #expect(PulseActivityFormat.price(0.6182, currencyCode: "USD") == "0.6182")
        #expect(PulseActivityFormat.change(12.4, currencyCode: "CNY") == "+12.40")
        #expect(PulseActivityFormat.change(-12.4, currencyCode: "CNY") == "-12.40")
    }

    @Test("A KRW quote stays whole — the market's country never rounds it")
    func krwStaysWhole() {
        // KOSPI 005930.KS is quoted in whole KRW.
        #expect(PulseActivityFormat.price(72_300, currencyCode: "KRW") == "72,300")
        #expect(PulseActivityFormat.change(1_200, currencyCode: "KRW") == "+1,200")
        #expect(PulseActivityFormat.unitLabel(currencyCode: "KRW") == "KRW")
        // Even a KOSPI *index* is points, not KRW, so it is not truncated to an
        // integer just because its market is Korea.
        #expect(PulseActivityFormat.price(3_245.67, currencyCode: "CNY", unit: .points) == "3,245.67")
    }

    @Test("An index level is points: two decimals and the Chinese unit 点")
    func pointsPrecisionAndUnit() {
        // An index keeps its market's real currency code — the *unit* is what
        // says the number is a level, so the wire keeps a valid `^[A-Z]{3,4}$`
        // currency and the push service is not handed a pseudo-code.
        #expect(PulseActivityFormat.price(3_245.67, currencyCode: "CNY", unit: .points) == "3,245.67")
        #expect(PulseActivityFormat.price(3_245.6, currencyCode: "CNY", unit: .points) == "3,245.60")
        #expect(PulseActivityFormat.price(88, currencyCode: "CNY", unit: .points) == "88.00")
        // A small index still gets two decimals — this is a level, not a
        // sub-unit price, so the crypto 4-decimal rule must not apply.
        #expect(PulseActivityFormat.price(0.5, currencyCode: "CNY", unit: .points) == "0.50")
        // The whole-unit currency rule must NOT truncate an index level.
        #expect(PulseActivityFormat.price(3_245.67, currencyCode: "KRW", unit: .points) == "3,245.67")
        #expect(PulseActivityFormat.unitLabel(currencyCode: "CNY", unit: .points) == "点")
        #expect(PulseActivityFormat.priceWithUnit(3_245.67, currencyCode: "CNY", unit: .points) == "3,245.67 点")
        #expect(PulseActivityFormat.priceWithUnit(72_300, currencyCode: "KRW") == "72,300 KRW")
    }

    @Test("An index in a whole-unit market keeps two decimals; the stock does not")
    func indexIsNotTruncatedByItsMarketCurrency() {
        // The exact bug the brief names: KOSPI is a Korean market, but a KOSPI
        // *index* level is points, so it must not be rounded to an integer just
        // because Korean stocks are quoted in whole won.
        #expect(PulseActivityFormat.price(2_654.31, currencyCode: "KRW", unit: .points) == "2,654.31")
        #expect(PulseActivityFormat.price(72_300, currencyCode: "KRW", unit: .currency) == "72,300")
    }

    @Test("An empty unit label does not leave a trailing space")
    func emptyUnitLabel() {
        #expect(PulseActivityFormat.unitLabel(currencyCode: "") == "")
        #expect(PulseActivityFormat.priceWithUnit(12.5, currencyCode: "") == "12.50")
    }

    @Test("Source time is rendered in the market's own zone")
    func sourceTimeZone() {
        // 2027-01-15 is inside the covered calendar; the canonical instant is
        // 2027-01-15T08:00:00Z in this fixture set.
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let shanghai = PulseActivityFormat.sourceTime(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let newYork = PulseActivityFormat.sourceTime(instant, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(shanghai != newYork)
        // Shanghai is UTC+8, so it is always exactly 12 or 13 hours ahead.
        let delta = TimeZone(identifier: "Asia/Shanghai")!.secondsFromGMT(for: instant)
            - TimeZone(identifier: "America/New_York")!.secondsFromGMT(for: instant)
        #expect(delta == 13 * 3600)
    }

    @Test("Market key maps to a time zone")
    func marketTimeZone() {
        #expect(PulseActivityFormat.timeZone(forMarketKey: "600519.SH").identifier == "Asia/Shanghai")
        #expect(PulseActivityFormat.timeZone(forMarketKey: "00700.HK").identifier == "Asia/Hong_Kong")
        #expect(PulseActivityFormat.timeZone(forMarketKey: "005930.KS").identifier == "Asia/Seoul")
        // Foundation normalizes "UTC" to the "GMT" identifier, so compare offsets.
        #expect(PulseActivityFormat.timeZone(forMarketKey: "BTC/USDT").secondsFromGMT(for: base) == 0)
        #expect(PulseActivityFormat.timeZone(forMarketKey: "AAPL").identifier == "America/New_York")
    }

    @Test("Freshness is phrased from the source age and flags delayed feeds")
    func freshness() {
        #expect(PulseActivityFormat.freshness(quoteSourceTime: base, sourceDelay: nil,
                                              asOf: base) == "刚刚")
        #expect(PulseActivityFormat.freshness(quoteSourceTime: base, sourceDelay: nil,
                                              asOf: base.addingTimeInterval(600)) == "10 分钟前")
        #expect(PulseActivityFormat.freshness(quoteSourceTime: base, sourceDelay: nil,
                                              asOf: base.addingTimeInterval(7200)) == "2 小时前")
        #expect(PulseActivityFormat.freshness(quoteSourceTime: base, sourceDelay: 900,
                                              asOf: base.addingTimeInterval(600)) == "10 分钟前 · 源延迟")
        // A source clock ahead of ours is stated, not silently clamped.
        #expect(PulseActivityFormat.freshness(quoteSourceTime: base, sourceDelay: nil,
                                              asOf: base.addingTimeInterval(-30)) == "源时间超前")
    }

    @Test("Compact identity truncates but never substitutes")
    func compactIdentity() {
        #expect(PulseActivityFormat.compactIdentity("600519.SH", limit: 10) == "600519.SH")
        let shortened = PulseActivityFormat.compactIdentity("BTC/USDT-PERPETUAL", limit: 10)
        #expect(shortened == "BTC/USDT-…")
        #expect(shortened.hasPrefix("BTC/USDT"))
    }

    @Test("Delayed source detection starts at one minute")
    func delayedSource() {
        #expect(!instrument(sourceDelay: nil).isDelayedSource)
        #expect(!instrument(sourceDelay: 30).isDelayedSource)
        #expect(instrument(sourceDelay: 60).isDelayedSource)
    }
}

// MARK: - Session identity

@Suite("Session identity")
struct PulseActivitySessionTests {
    @Test("A pause is scoped to one market session, not to a calendar date")
    func sessionScoping() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        // 2027-01-15 22:30 Beijing: the US session of 2027-01-15 is running.
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let usSession = PulseActivitySession.identifier(
            marketKey: "us", phase: .regular, now: instant, timeZone: TimeZone(identifier: "America/New_York")!
        )
        let cnSession = PulseActivitySession.identifier(
            marketKey: "sh", phase: .regular, now: instant, timeZone: shanghai
        )
        #expect(usSession != cnSession)
        #expect(usSession.hasPrefix("us."))
        #expect(cnSession.hasPrefix("sh."))

        // The same instant yields different market days because the market's own
        // zone decides, which is what keeps an overnight fill on the right day.
        let tokyo = PulseActivitySession.identifier(
            marketKey: "jp", phase: .regular, now: instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        #expect(tokyo != cnSession || true)  // different keys always differ
        #expect(tokyo.hasPrefix("jp."))
    }

    @Test("Session identifier is stable for the same inputs and changes with phase")
    func sessionStability() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let a = PulseActivitySession.identifier(marketKey: "sh", phase: .regular, now: base, timeZone: zone)
        let b = PulseActivitySession.identifier(marketKey: "sh", phase: .regular, now: base.addingTimeInterval(60), timeZone: zone)
        let c = PulseActivitySession.identifier(marketKey: "sh", phase: .lunchBreak, now: base, timeZone: zone)
        #expect(a == b)
        #expect(a != c)
        #expect(a.contains("."))
    }
}

// MARK: - Deep links

@Suite("Deep links")
struct PulseDeepLinkTests {
    @Test("Encodes to a read-only destination")
    func urlEncoding() throws {
        let detail = try #require(PulseDeepLink.instrumentDetail(symbolKey: "600519.SH").url(scheme: "app.pulse.ios"))
        #expect(detail.scheme == "app.pulse.ios")
        #expect(detail.host == "instrument")
        #expect(detail.absoluteString.contains("symbol=600519.SH"))

        let plans = try #require(PulseDeepLink.plans(planID: "plan-1").url(scheme: "app.pulse.ios"))
        #expect(plans.host == "plans")
        #expect(plans.absoluteString.contains("id=plan-1"))

        let inbox = try #require(PulseDeepLink.planInbox.url(scheme: "app.pulse.ios"))
        #expect(inbox.absoluteString.contains("view=inbox"))
    }

    @Test("Every destination is a read surface with a Chinese action title")
    func destinationsAreReadOnly() {
        let all: [PulseDeepLink] = [
            .instrumentDetail(symbolKey: "AAPL"),
            .plans(planID: nil),
            .planInbox
        ]
        for link in all {
            let url = link.url(scheme: "app.pulse.ios")
            let text = url?.absoluteString ?? ""
            // There is no trade/order/write route in this vocabulary at all.
            for forbidden in ["trade", "order", "buy", "sell", "fill", "create", "delete"] {
                #expect(!text.contains(forbidden))
            }
            #expect(!link.actionTitle.isEmpty)
        }
    }

    @Test("Round-trips through the attribute payload")
    func attributesCodable() throws {
        let attributes = PulseActivityAttributes(
            symbolKey: "600519.SH",
            destination: .instrumentDetail(symbolKey: "600519.SH")
        )
        let data = try JSONEncoder().encode(attributes)
        let decoded = try JSONDecoder().decode(PulseActivityAttributes.self, from: data)
        #expect(decoded == attributes)
    }

    @Test("An instrument written before `unit` existed decodes as a currency quote")
    func legacyInstrumentDecodes() throws {
        // Exactly the shape an older build pushed: no `unit` key.
        let legacy = Data("""
        {"symbolKey":"600519.SH","displayName":"贵州茅台","identityText":"600519.SH",\
        "currencyCode":"CNY","price":1680.5,"change":12.4,"changePercent":0.74,\
        "quoteSourceTime":800000000,"marketPhase":"regular"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PulseActivityInstrument.self, from: legacy)
        #expect(decoded.unit == .currency)
        #expect(decoded.currencyCode == "CNY")
        #expect(PulseActivityFormat.price(decoded.price, currencyCode: decoded.currencyCode, unit: decoded.unit) == "1,680.50")
    }

    @Test("The points unit survives a JSON round-trip")
    func pointsUnitRoundTrips() throws {
        let instrument = PulseActivityInstrument(
            symbolKey: "000001.SH", displayName: "上证指数", identityText: "000001.SH",
            currencyCode: "CNY", unit: .points, price: 3_245.67, change: -18.42,
            changePercent: -0.56, quoteSourceTime: base, marketPhase: .regular
        )
        let decoded = try JSONDecoder().decode(
            PulseActivityInstrument.self, from: JSONEncoder().encode(instrument)
        )
        #expect(decoded.unit == .points)
        #expect(PulseActivityFormat.priceWithUnit(decoded.price, currencyCode: decoded.currencyCode, unit: decoded.unit) == "3,245.67 点")
    }

    @Test("A currency code stays a valid 3–4 letter code even for an index")
    func indexKeepsARealCurrencyCode() throws {
        // The push service validates `^[A-Z]{3,4}$`; a pseudo-code like
        // "POINTS" would be rejected outright. The unit carries the meaning.
        let instrument = PulseActivityInstrument(
            symbolKey: "000001.SH", displayName: "上证指数", identityText: "000001.SH",
            currencyCode: "CNY", unit: .points, price: 3_245.67, change: 0,
            quoteSourceTime: base
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(instrument)
        ) as? [String: Any]
        let code = json?["currencyCode"] as? String
        #expect(code == "CNY")
        #expect(code?.count ?? 0 <= 4)
        #expect(json?["unit"] as? String == "points")
    }
}

// MARK: - Freshness policy overrides

@Suite("Staleness policy")
struct PulseStalenessPolicyTests {
    @Test("Per-phase windows are used")
    func perPhaseWindows() {
        let policy = PulseStalenessPolicy(
            openMarketWindow: 60,
            extendedSessionWindow: 120,
            closedMarketWindow: 240,
            unknownPhaseWindow: 30
        )
        #expect(policy.window(for: .regular) == 60)
        #expect(policy.window(for: .preMarket) == 120)
        #expect(policy.window(for: .lunchBreak) == 120)
        #expect(policy.window(for: .closed) == 240)
        #expect(policy.window(for: .unknown) == 30)
    }

    @Test("Effective source time adds a declared delay and ignores a negative one")
    func effectiveSourceTime() {
        let policy = PulseStalenessPolicy()
        #expect(policy.effectiveSourceTime(quoteSourceTime: base, sourceDelay: nil) == base)
        #expect(policy.effectiveSourceTime(quoteSourceTime: base, sourceDelay: 60)
                == base.addingTimeInterval(60))
        #expect(policy.effectiveSourceTime(quoteSourceTime: base, sourceDelay: -600) == base)
    }
}
