import ActivityKit
import PulseActivity
import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// The bundle declares the Live Activity configuration (and, in this target,
/// nothing else): the iPhone workbench's home-screen widgets are a separate
/// deliverable with a timeline provider that would need to reach the shared
/// container, and shipping a half-wired one here would be a mock. Adding a
/// `Widget` to this body is the whole integration step for it.
@main
struct PulseWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PulseTrackingActivityWidget()
    }
}

/// The Live Activity for the automatically tracked primary instrument.
struct PulseTrackingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PulseActivityAttributes.self) { context in
            // Lock screen / banner, and — on iOS 18 — the watch smart-stack
            // small family. The view branches on the environment's
            // `activityFamily`, so one attribute type and one payload serve
            // every surface.
            PulseActivityFamilyView(context: context)
        } dynamicIsland: { context in
            PulseDynamicIslandBuilder.build(context: context)
        }
        // The watch smart-stack card. `supplementalActivityFamilies` is iOS 18+;
        // the deployment target is iOS 18, so no availability check is needed —
        // but the *widget extension* must be built for iOS 18+, which is the
        // Lead's target configuration, not something this file can assert.
        .supplementalActivityFamilies([.small])
    }
}

#if DEBUG
// MARK: - Previews
//
// Synthetic, fictional instruments. Nothing here reads the ledger, the network
// or a real quote source; these values exist only to render layouts.

private enum PulseWidgetPreviewData {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func state(
        price: Double = 1_680.5,
        change: Double = 12.4,
        sourceDelay: TimeInterval? = nil,
        phase: PulseMarketPhase = .regular,
        status: PulseActivityStatus = .live,
        reached: Int = 1,
        manual: Int = 0,
        remaining: Int = 3,
        currencyCode: String = "CNY",
        unit: PulseQuoteUnit = .currency,
        symbolKey: String = "600519.SH",
        displayName: String = "贵州茅台",
        identityText: String = "600519.SH",
        planSync: PulsePlanSyncState = .synced,
        planAsOf: Date? = nil
    ) -> PulseActivityState {
        PulseActivityState(
            primary: PulseActivityInstrument(
                symbolKey: symbolKey,
                displayName: displayName,
                identityText: identityText,
                currencyCode: currencyCode,
                unit: unit,
                price: price,
                change: change,
                changePercent: price == 0 ? nil : (change / price) * 100,
                quoteSourceTime: base,
                sourceDelay: sourceDelay,
                marketPhase: phase
            ),
            plans: PulseActivityPlanDigest(
                priceConditionReachedCount: reached,
                manualReviewCount: manual,
                remainingPlanCount: remaining,
                asOf: planSync == .synced ? (planAsOf ?? base) : nil,
                revision: planSync == .synced ? "rev-42" : nil,
                syncState: planSync
            ),
            status: status,
            staleDate: base.addingTimeInterval(300),
            quoteSourceTime: base
        )
    }

    static let attributes = PulseActivityAttributes(
        symbolKey: "600519.SH",
        destination: .instrumentDetail(symbolKey: "600519.SH")
    )
}

#Preview("锁屏 · 交易中", as: .content, using: PulseWidgetPreviewData.attributes) {
    PulseTrackingActivityWidget()
} contentStates: {
    PulseWidgetPreviewData.state()
}

#Preview("锁屏 · 已过期", as: .content, using: PulseWidgetPreviewData.attributes) {
    PulseTrackingActivityWidget()
} contentStates: {
    PulseWidgetPreviewData.state(
        price: 1_642.0, change: -38.5,
        phase: .closed, status: .marketClosed, reached: 0, remaining: 1
    )
}

#Preview("锁屏 · 源延迟", as: .content, using: PulseWidgetPreviewData.attributes) {
    PulseTrackingActivityWidget()
} contentStates: {
    PulseWidgetPreviewData.state(sourceDelay: 900, manual: 2)
}

// The point of the split clock: the quote is live and stamped just now, while
// the plan side is explicitly unconfirmed. The surface must show both facts and
// must not present one uniform "刚刚更新".
#Preview("锁屏 · 行情新但计划待同步", as: .content, using: PulseWidgetPreviewData.attributes) {
    PulseTrackingActivityWidget()
} contentStates: {
    PulseWidgetPreviewData.state(planSync: .pending)
}

#Preview("锁屏 · 指数(点)", as: .content, using: PulseWidgetPreviewData.attributes) {
    PulseTrackingActivityWidget()
} contentStates: {
    PulseWidgetPreviewData.state(
        price: 3_245.67, change: -18.42,
        reached: 0, remaining: 0,
        currencyCode: "CNY", unit: .points,
        symbolKey: "000001.SH", displayName: "上证指数", identityText: "000001.SH"
    )
}
#endif
