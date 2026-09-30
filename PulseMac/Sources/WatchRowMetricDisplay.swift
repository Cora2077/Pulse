import PulseCore
import PulseUI

/// Pure display calculation shared by the live watch row and off-screen share snapshots.
struct WatchRowMetricDisplay {
    let text: String
    let colorValue: Double?

    static func resolve(
        quote: Quote?,
        metrics _: PositionMetrics?,
        mode: WatchRowMetricMode,
        item: WatchItem,
        basis: PositionCostBasis = .average
    ) -> Self {
        guard let quote else {
            return Self(text: "…", colorValue: nil)
        }

        let currencyCode = quote.currencyCode ?? item.symbol.currencyCode
        let valuation = PositionValuation(item: item, quote: quote, basis: basis)
        switch mode {
        case .changePercent:
            return Self(
                text: PriceFormatter.percent(quote.changePercent),
                colorValue: quote.change
            )
        case .todayPnL:
            guard let valuation else {
                return fallbackPercent(quote)
            }
            return Self(
                text: PriceFormatter.signedMoney(valuation.todayPnL, currencyCode: currencyCode),
                colorValue: valuation.todayPnL
            )
        case .totalPnL, .summary:
            guard let valuation else {
                return fallbackPercent(quote)
            }
            return Self(
                text: PriceFormatter.signedMoney(valuation.holdingPnL, currencyCode: currencyCode),
                colorValue: valuation.holdingPnL
            )
        }
    }

    private static func fallbackPercent(_ quote: Quote) -> Self {
        Self(
            text: PriceFormatter.percent(quote.changePercent),
            colorValue: quote.change
        )
    }
}
