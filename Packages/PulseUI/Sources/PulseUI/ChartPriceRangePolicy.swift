import Foundation
import PulseCore

/// Shared rules for fitting plan and indicator prices into the visible chart domain.
enum ChartPriceRangePolicy {
    /// Expands the y-domain by the bottom bands' height so the candle pane keeps its size.
    static let macdDomainGrowth = 0.587

    static func range(of prices: [Double]) -> ClosedRange<Double>? {
        let valid = prices.filter { $0.isFinite && $0 > 0 }
        guard let lower = valid.min(), let upper = valid.max() else { return nil }
        return lower...upper
    }

    static func candleYDomain(
        of prices: [Double],
        including additionalPrices: [Double] = [],
        hasBuyMarkers: Bool,
        hasSellMarkers: Bool,
        reserveVolumeBand: Bool,
        reserveMACDBand: Bool = false
    ) -> ClosedRange<Double> {
        let validRange = range(of: prices + additionalPrices)
        let lo = validRange?.lowerBound ?? 0
        let hi = validRange?.upperBound ?? 1
        let span = max(hi - lo, hi * 0.001, 0.0001)
        let bottomPad: Double
        if reserveVolumeBand {
            bottomPad = span * (hasBuyMarkers ? 0.42 : 0.28)
        } else {
            bottomPad = span * (hasBuyMarkers ? 0.16 : 0.05)
        }
        let topPad = span * (hasSellMarkers ? 0.16 : 0.05)
        let extraPad = reserveMACDBand ? (span + bottomPad + topPad) * macdDomainGrowth : 0
        return (lo - bottomPad - extraPad)...(hi + topPad)
    }

    /// Active plans are shown by default. Historical plans join only when the
    /// user enabled that display option. Invalid prices never affect the scale.
    static func visiblePlanPrices(_ plans: [TradePlan], showsHistorical: Bool) -> [Double] {
        plans.compactMap { plan in
            guard (showsHistorical || plan.status == .active),
                  plan.price.isFinite, plan.price > 0 else { return nil }
            return plan.price
        }
    }

    /// Returns sorted unique prices so the result does not depend on plan array
    /// order. Nearby candidates are considered by distance to the natural range;
    /// ties use ascending price. A focused price is always retained, even when it
    /// is remote. Other prices may expand the natural range by at most `capFactor`.
    static func pricesToFit(
        _ candidates: [Double],
        naturalRange: ClosedRange<Double>,
        focusedPrice: Double? = nil,
        fitsAll: Bool = false,
        capFactor: Double = 3
    ) -> [Double] {
        guard naturalRange.lowerBound.isFinite, naturalRange.upperBound.isFinite,
              naturalRange.lowerBound > 0, naturalRange.upperBound > 0,
              capFactor.isFinite, capFactor >= 1 else { return [] }

        let validCandidates = Set(candidates.filter { $0.isFinite && $0 > 0 })
        let focused = focusedPrice.flatMap {
            $0.isFinite && $0 > 0 && validCandidates.contains($0) ? $0 : nil
        }
        var selected = Set<Double>()

        if fitsAll {
            selected = validCandidates
            if let focused { selected.insert(focused) }
            return selected.sorted()
        }

        let naturalLower = min(naturalRange.lowerBound, naturalRange.upperBound)
        let naturalUpper = max(naturalRange.lowerBound, naturalRange.upperBound)
        let rawSpan = naturalUpper - naturalLower
        let naturalSpan = max(rawSpan, max(naturalUpper * 0.001, 0.0001))
        let maximumSpan = naturalSpan * capFactor
        var expandedLower = naturalLower
        var expandedUpper = naturalUpper

        let ordered = validCandidates.sorted { lhs, rhs in
            let lhsDistance = distance(lhs, to: naturalLower...naturalUpper)
            let rhsDistance = distance(rhs, to: naturalLower...naturalUpper)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
        }

        for price in ordered where price != focused {
            let nextLower = min(expandedLower, price)
            let nextUpper = max(expandedUpper, price)
            guard nextUpper - nextLower <= maximumSpan else { continue }
            selected.insert(price)
            expandedLower = nextLower
            expandedUpper = nextUpper
        }

        if let focused { selected.insert(focused) }

        return selected.sorted()
    }

    static func percentageChange(price: Double, previousClose: Double) -> Double? {
        guard price.isFinite, price > 0,
              previousClose.isFinite, previousClose > 0 else { return nil }
        let change = (price / previousClose - 1) * 100
        return change.isFinite ? change : nil
    }

    /// One price tick list feeds both sides of the intraday axis. The valid
    /// previous close is inserted verbatim so the matching left label is exactly 0%.
    static func priceAxisTicks(
        in domain: ClosedRange<Double>,
        including referencePrice: Double?
    ) -> [Double] {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard lower.isFinite, upper.isFinite, lower < upper else {
            return lower.isFinite ? [lower] : []
        }

        let rawStep = (upper - lower) / 4
        guard rawStep.isFinite, rawStep > 0 else { return [lower, upper] }
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let multiplier: Double = normalized <= 1 ? 1
            : normalized <= 2 ? 2
            : normalized <= 2.5 ? 2.5
            : normalized <= 5 ? 5 : 10
        let step = multiplier * magnitude
        var ticks: [Double] = []
        var price = ceil(lower / step) * step
        for _ in 0..<40 where price <= upper {
            if price.isFinite { ticks.append(price) }
            let next = price + step
            guard next > price else { break }
            price = next
        }
        if ticks.isEmpty { ticks = [lower, upper] }
        if let referencePrice, referencePrice.isFinite,
           referencePrice >= lower, referencePrice <= upper {
            // Give the exact baseline tick room for its 0% label. A nearby nice
            // tick can otherwise produce two labels only a few pixels apart.
            let tolerance = max(abs(step) * 0.3, 1e-12)
            ticks.removeAll { abs($0 - referencePrice) <= tolerance }
            ticks.append(referencePrice)
        }
        return Array(Set(ticks)).sorted()
    }

    private static func distance(_ price: Double, to range: ClosedRange<Double>) -> Double {
        if price < range.lowerBound { return range.lowerBound - price }
        if price > range.upperBound { return price - range.upperBound }
        return 0
    }
}

/// Chooses the nearest valid OHLC price in screen space, with a small hit band.
/// Each adapter supplies only the prices appropriate for its chart type.
enum ChartAnchorSnapPolicy {
    static func nearestPrice(
        atY y: CGFloat,
        candidates: [Double],
        yForPrice: (Double) -> CGFloat?,
        maximumDistance: CGFloat = 8
    ) -> Double? {
        guard y.isFinite, maximumDistance.isFinite, maximumDistance >= 0 else { return nil }

        var best: (price: Double, distance: CGFloat)?
        for price in candidates where price.isFinite && price > 0 {
            guard let projectedY = yForPrice(price), projectedY.isFinite else { continue }
            let distance = abs(projectedY - y)
            guard distance <= maximumDistance else { continue }
            if best == nil || distance < best!.distance {
                best = (price, distance)
            }
        }
        return best?.price
    }
}
