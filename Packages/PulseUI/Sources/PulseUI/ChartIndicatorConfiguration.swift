import PulseCore
import SwiftUI

/// What the price chart draws on top of, and beneath, the candles. Kept apart from
/// `ChartAnnotationConfiguration` because these are display preferences rather than
/// drawings the user created, so they never enter the store or the sync file.
public struct ChartIndicatorConfiguration: Sendable, Equatable {
    /// Moving averages overlaid on the price pane, in legend order.
    public var movingAverages: [MovingAveragePeriod]
    /// Draws the DIF / DEA / histogram pane underneath the volume strip.
    public var showsMACD: Bool

    public init(movingAverages: [MovingAveragePeriod] = [], showsMACD: Bool = false) {
        self.movingAverages = movingAverages
        self.showsMACD = showsMACD
    }

    /// Nothing on top of the candles and no extra pane.
    public static let hidden = ChartIndicatorConfiguration()

    /// The overlay set the chart ships with: every moving average, no MACD pane.
    public static let standard = ChartIndicatorConfiguration(movingAverages: MovingAveragePeriod.allCases)

    public var isHidden: Bool { movingAverages.isEmpty && !showsMACD }
}

/// One palette for the overlays so the menu swatch, the drawn line and any readout agree.
public struct ChartIndicatorPalette: Sendable {
    public init() {}

    /// Four well-separated hues that stay legible on both the light and dark chart
    /// backgrounds, and stay clear of the red/green gain-loss pair used by candles.
    public func color(for period: MovingAveragePeriod) -> Color {
        switch period {
        case .ma5: Color(red: 0.95, green: 0.62, blue: 0.16)   // amber
        case .ma10: Color(red: 0.20, green: 0.51, blue: 0.90)  // blue
        case .ma20: Color(red: 0.62, green: 0.35, blue: 0.85)  // violet
        case .ma60: Color(red: 0.31, green: 0.60, blue: 0.53)  // teal
        }
    }

    /// DIF moves first and reads as the action line; DEA is its slower signal.
    public static let dif = Color(red: 0.16, green: 0.44, blue: 0.86)
    public static let dea = Color(red: 0.95, green: 0.62, blue: 0.16)
}
