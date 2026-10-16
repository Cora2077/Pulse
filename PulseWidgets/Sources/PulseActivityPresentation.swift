import SwiftUI
import PulseActivity
import WidgetKit

/// Everything the surfaces need to draw, resolved once.
///
/// The views never read the clock themselves: `now` is passed in (from the
/// widget timeline entry or the activity context), so a rendered snapshot is
/// reproducible and a stale state cannot accidentally look live.
struct PulseActivityPresentation {
    let state: PulseActivityState
    let now: Date
    let timeZone: TimeZone

    init(state: PulseActivityState, now: Date) {
        self.state = state
        self.now = now
        self.timeZone = PulseActivityFormat.timeZone(forMarketKey: state.primary.symbolKey)
    }

    var instrument: PulseActivityInstrument { state.primary }
    var isStale: Bool { state.isStale(asOf: now) }

    /// The status as displayed: never claims `live` once the deadline passed,
    /// whatever the stored value says.
    var status: PulseActivityStatus {
        guard state.status.isDisplayable else { return state.status }
        if state.status == .marketClosed { return .marketClosed }
        return isStale ? .stale : state.status
    }

    var priceText: String {
        PulseActivityFormat.price(instrument.price, currencyCode: instrument.currencyCode, unit: instrument.unit)
    }

    var changeText: String {
        PulseActivityFormat.change(instrument.change, currencyCode: instrument.currencyCode, unit: instrument.unit)
    }

    var percentText: String {
        PulseActivityFormat.changePercent(instrument.changePercent)
    }

    var direction: PulseChangeDirection { instrument.direction }

    var color: Color { PulseWidgetStyle.color(for: direction) }

    /// Source clock, e.g. `14:32`. This is the *source* time, always.
    var sourceTimeText: String {
        PulseActivityFormat.sourceTime(instrument.quoteSourceTime, timeZone: timeZone)
    }

    var sourceTimeWithSecondsText: String {
        PulseActivityFormat.sourceTimeWithSeconds(instrument.quoteSourceTime, timeZone: timeZone)
    }

    var freshnessText: String {
        PulseActivityFormat.freshness(
            quoteSourceTime: instrument.quoteSourceTime,
            sourceDelay: instrument.sourceDelay,
            asOf: now
        )
    }

    /// `14:32 源时间` — the tightest honest way to label a number.
    var sourceLine: String {
        "\(sourceTimeText) 源时间"
    }

    /// Whether the plan side needs a "not confirmed" marker.
    ///
    /// This reads the **plan** sync state, not the activity status. The old
    /// version keyed off `status == .remoteUnavailable`, which conflated two
    /// unrelated things: a device with no remote push service was shown a plan
    /// warning even when its plans were perfectly confirmed, and a device with a
    /// service showed no warning while its plans were stale.
    var planNeedsSync: Bool { state.plans.needsSyncWarning }

    /// The plan-side freshness line, e.g. `计划待同步`. Independent of the
    /// quote's source time — the two are rendered on separate lines and neither
    /// stands in for the other.
    var planSyncText: String { state.plans.syncLabel(asOf: now) }

    var planText: String { state.plans.shortLabel }

    /// The unit beside the price: `点` for an index, the currency code otherwise.
    var unitText: String { PulseActivityFormat.unitLabel(currencyCode: instrument.currencyCode, unit: instrument.unit) }

    var deepLink: URL? { state.deepLinkURL }
}

extension PulseActivityState {
    /// Where a tap on any of these surfaces goes. Always a read destination.
    var deepLinkURL: URL? {
        PulseDeepLink.instrumentDetail(symbolKey: primary.symbolKey)
            .url(scheme: PulseWidgetDeepLinkScheme.value)
    }
}

// MARK: - Reusable pieces

/// The source-time line. Every family renders this; none of them render `Date()`.
struct SourceTimeLabel: View {
    let presentation: PulseActivityPresentation
    var includeSeconds: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: presentation.isStale ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: 9, weight: .semibold))
            Text(includeSeconds ? presentation.sourceTimeWithSecondsText : presentation.sourceTimeText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
            if presentation.status == .stale {
                Text("待更新")
                    .font(.system(size: 10, weight: .semibold))
            } else if presentation.instrument.isDelayedSource {
                Text("延迟")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(presentation.isStale ? Color.orange : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "行情源时间 \(presentation.sourceTimeText)，\(presentation.freshnessText)"
        )
    }
}

/// The price, change and percent line — the one thing every family must show.
struct PriceLine: View {
    let presentation: PulseActivityPresentation
    var size: Size = .regular
    /// Compact families drop the absolute change; the percent is the signal.
    var showsAbsoluteChange: Bool = true

    enum Size {
        case compact, regular, expanded

        var priceFont: Font {
            switch self {
            case .compact: .system(size: 13, weight: .semibold, design: .rounded)
            case .regular: .system(size: 15, weight: .semibold, design: .rounded)
            case .expanded: .system(size: 20, weight: .bold, design: .rounded)
            }
        }

        var changeFont: Font {
            switch self {
            case .compact: .system(size: 10, weight: .medium, design: .rounded)
            case .regular: .system(size: 11, weight: .medium, design: .rounded)
            case .expanded: .system(size: 12, weight: .semibold, design: .rounded)
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(presentation.priceText)
                .font(size.priceFont)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(presentation.percentText)
                .font(size.changeFont)
                .monospacedDigit()
                .foregroundStyle(presentation.color)
                .lineLimit(1)
            if showsAbsoluteChange, size != .compact {
                Text(presentation.changeText)
                    .font(size.changeFont)
                    .monospacedDigit()
                    .foregroundStyle(presentation.color.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(presentation.instrument.displayName) \(presentation.priceText) "
            + "\(presentation.unitText)，涨跌 \(presentation.percentText)"
        )
    }
}

/// Name plus full identity, e.g. `贵州茅台 · 600519.SH`.
struct IdentityLine: View {
    let presentation: PulseActivityPresentation
    var limit: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(presentation.instrument.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(limit.map { PulseActivityFormat.compactIdentity(presentation.instrument.identityText, limit: $0) }
                 ?? presentation.instrument.identityText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(presentation.instrument.displayName)，\(presentation.instrument.identityText)"
        )
    }
}

/// The status badge: 已休市 / 待更新 / 今日暂停 and friends.
struct StatusBadge: View {
    let presentation: PulseActivityPresentation
    var compact: Bool = false

    var body: some View {
        let label = presentation.status.shortLabel
        if !label.isEmpty {
            HStack(spacing: 3) {
                Circle()
                    .fill(PulseWidgetStyle.color(for: presentation.status))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
            }
            .foregroundStyle(PulseWidgetStyle.color(for: presentation.status))
            .lineLimit(1)
        }
    }
}

/// The redacted plan to-do line. Counts only — no plan text, no amounts.
///
/// The plan's own confirmation state rides here, in its own slot. It is the
/// point of the separation: a fresh quote with unconfirmed plans shows the
/// source time *and* `计划待同步`, rather than one "刚刚更新" that claims both
/// clocks moved together.
struct PlanTodoLine: View {
    let presentation: PulseActivityPresentation
    var compact: Bool = false

    var body: some View {
        let digest = presentation.state.plans
        HStack(spacing: 4) {
            Image(systemName: digest.actionableCount > 0
                  ? "exclamationmark.circle.fill"
                  : "checklist")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            Text(digest.shortLabel)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // Only rendered when there is something to say — `local`/`synced`
            // return an empty string rather than a reassuring filler.
            let sync = presentation.planSyncText
            if !sync.isEmpty && !compact {
                Text(sync)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(digest.actionableCount > 0 ? Color.orange : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: digest, sync: presentation.planSyncText))
    }

    private func accessibilityText(for digest: PulseActivityPlanDigest, sync: String) -> String {
        let base = digest.actionableCount > 0
            ? "计划待办 \(digest.shortLabel)"
            : digest.isEmpty ? "没有待办计划" : "待办计划 \(digest.remainingPlanCount) 项"
        return sync.isEmpty ? base : "\(base)，\(sync)"
    }
}

/// The mark shown at the head of every surface.
struct BrandMark: View {
    var live: Bool

    var body: some View {
        PulseWaveMark(
            tint: live ? PulseWidgetStyle.brandBlue : .secondary,
            liveTint: live ? PulseWidgetStyle.brandBlue : nil
        )
        .frame(width: 26)
        .accessibilityHidden(true)
    }
}
