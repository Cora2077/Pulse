import SwiftUI
import PulseActivity
import WidgetKit

/// The lock-screen / banner presentation of the activity.
///
/// This is a *public* surface: it shows the instrument, the quote with its real
/// source time, a redacted plan count and an honest status. It never shows a
/// position size, a balance, a cost, a P&L or an account name — those fields do
/// not exist in ``PulseActivityState``, so they cannot leak here by accident.
struct PulseLockScreenView: View {
    let context: ActivityViewContext<PulseActivityAttributes>

    private var presentation: PulseActivityPresentation {
        PulseActivityPresentation(state: context.state, now: .now)
    }

    var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrandMark(live: p.status == .live)
                Text(p.instrument.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(p.instrument.identityText)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(presentation: p)
            }

            HStack(alignment: .firstTextBaseline) {
                PriceLine(presentation: p, size: .expanded)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    SourceTimeLabel(presentation: p, includeSeconds: true)
                    Text(p.unitText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: 6) {
                PlanTodoLine(presentation: p)
                Spacer(minLength: 4)
                if p.status == .marketClosed {
                    Text(p.instrument.marketPhase.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Link(destination: p.deepLink ?? fallbackURL) {
                    HStack(spacing: 2) {
                        Text(PulseDeepLink.instrumentDetail(symbolKey: p.instrument.symbolKey).actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .tint(PulseWidgetStyle.brandBlue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.28))
        .activitySystemActionForegroundColor(PulseWidgetStyle.brandBlue)
    }

    private var fallbackURL: URL {
        URL(string: "\(PulseWidgetDeepLinkScheme.value)://instrument")!
    }
}

/// The Dynamic Island, all four presentations.
///
/// `DynamicIsland` is not a `View`, so this is a plain namespace function: the
/// `dynamicIsland:` closure builds it directly. Wrapping it in a `View` would not
/// compile, and building it in a helper keeps the configuration readable.
enum PulseDynamicIslandBuilder {
    @MainActor
    static func build(context: ActivityViewContext<PulseActivityAttributes>) -> DynamicIsland {
        let p = PulseActivityPresentation(state: context.state, now: .now)

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                ExpandedLeading(presentation: p)
            }
            DynamicIslandExpandedRegion(.trailing) {
                ExpandedTrailing(presentation: p)
            }
            DynamicIslandExpandedRegion(.center) {
                EmptyView()
            }
            DynamicIslandExpandedRegion(.bottom) {
                ExpandedBottom(presentation: p)
            }
        } compactLeading: {
            // Just the mark: at this size any number is unreadable, and a
            // half-drawn price is worse than none.
            BrandMark(live: p.status == .live)
        } compactTrailing: {
            CompactTrailing(presentation: p)
        } minimal: {
            // The minimal presentation is the size of the camera housing's
            // neighbour: roughly one glyph. A full price — `1,234.56`, let alone
            // a grouped index level — cannot fit, and shrinking it to fit makes
            // it unreadable at a glance, which is the only thing this slot is
            // for. So it shows direction: an arrow, colored, nothing else.
            MinimalDirection(presentation: p)
                .widgetURL(p.deepLink)
        }
        .keylineTint(PulseWidgetStyle.brandBlue)
        .widgetURL(p.deepLink)
    }
}

// MARK: - Island regions

private struct ExpandedLeading: View {
    let presentation: PulseActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(presentation.instrument.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                StatusBadge(presentation: presentation, compact: true)
            }
            Text(presentation.instrument.identityText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ExpandedTrailing: View {
    let presentation: PulseActivityPresentation

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(presentation.priceText)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(presentation.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(presentation.percentText)
                Text(presentation.changeText)
                    .foregroundStyle(presentation.color.opacity(0.85))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(presentation.color)
            .lineLimit(1)
        }
    }
}

private struct ExpandedBottom: View {
    let presentation: PulseActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SourceTimeLabel(presentation: presentation, includeSeconds: true)
                if presentation.status == .marketClosed {
                    Text(presentation.instrument.marketPhase.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(presentation.unitText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                PlanTodoLine(presentation: presentation)
                Spacer(minLength: 4)
                // Only ever a read destination.
                Text(PulseDeepLink.instrumentDetail(symbolKey: presentation.instrument.symbolKey).actionTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PulseWidgetStyle.brandBlue)
            }
        }
    }
}

private struct CompactTrailing: View {
    let presentation: PulseActivityPresentation

    var body: some View {
        // Percent only: the compact trailing slot is about as wide as four
        // characters, and the percent is comparable across instruments.
        Text(presentation.percentText)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(presentation.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("涨跌 \(presentation.percentText)")
    }
}

/// The minimal Dynamic Island: a direction glyph and nothing else.
///
/// Deliberately **no price**. At this size a number is either truncated or
/// scaled below reading size, and a half-rendered price on a lock screen is
/// worse than an honest arrow: the user looks at the full presentation for the
/// number, and the arrow is enough to say whether they need to.
///
/// The percent is also omitted: even `+1.83%` is wider than the slot, and
/// dropping the digits while keeping the color and the arrow keeps the slot's
/// meaning exact.
private struct MinimalDirection: View {
    let presentation: PulseActivityPresentation

    private var glyph: String {
        switch presentation.direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "minus"
        }
    }

    private var label: String {
        switch presentation.direction {
        case .up: "上涨"
        case .down: "下跌"
        case .flat: "持平"
        }
    }

    var body: some View {
        Image(systemName: glyph)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(presentation.color)
            .accessibilityLabel("\(presentation.instrument.displayName) \(label)")
    }
}

// MARK: - Family dispatch

/// Picks the presentation for the family the system is rendering into.
///
/// On iOS 18 the *same* `ActivityConfiguration` serves the iPhone lock screen,
/// the Dynamic Island and the Apple Watch Smart Stack; ``EnvironmentValues/activityFamily``
/// is the only thing that says which. Branching here — rather than declaring a
/// second configuration — keeps one attribute type and one state payload for
/// every surface, so the watch card cannot drift from the phone's.
struct PulseActivityFamilyView: View {
    let context: ActivityViewContext<PulseActivityAttributes>
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        if activityFamily == .small {
            // Watch Smart Stack: one instrument, price, change, source time and
            // a single redacted plan line.
            PulseWatchSmallView(context: context)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .activityBackgroundTint(Color.black.opacity(0.3))
        } else {
            PulseLockScreenView(context: context)
        }
    }
}

// MARK: - Watch smart stack (iOS 18 small family)

/// The small activity family shown on Apple Watch's Smart Stack.
///
/// One instrument, price, change, source time and a single redacted plan line —
/// the card the design doc asks for. It is a *mirror* of the iPhone activity,
/// not a standalone watch app, and it never contacts the network: the only input
/// is the state the system hands it.
struct PulseWatchSmallView: View {
    let context: ActivityViewContext<PulseActivityAttributes>

    private var p: PulseActivityPresentation {
        PulseActivityPresentation(state: context.state, now: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                BrandMark(live: p.status == .live)
                    .frame(width: 18)
                Text(p.instrument.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                StatusBadge(presentation: p, compact: true)
            }

            Text(p.priceText)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(p.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 4) {
                Text(p.percentText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(p.color)
                Text(p.changeText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(p.color.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Source time, always the real one.
            SourceTimeLabel(presentation: p)
            PlanTodoLine(presentation: p, compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
