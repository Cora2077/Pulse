import Foundation

/// Moving-average windows offered on the price chart. The raw value is the window
/// length, so exposing another window is a one-line change here.
public enum MovingAveragePeriod: Int, CaseIterable, Sendable, Codable, Hashable {
    case ma5 = 5
    case ma10 = 10
    case ma20 = 20
    case ma60 = 60

    public var period: Int { rawValue }

    public var label: String { "MA\(rawValue)" }

    /// Bit standing for this window, so any set of selected windows fits one `Int`
    /// default and the menu can toggle them independently.
    public var mask: Int { 1 << rawValue }

    /// Every window selected — the state the indicator menu starts from.
    public static var allMask: Int { allCases.reduce(0) { $0 | $1.mask } }
}

/// MACD window lengths. The defaults are the set every domestic terminal shows.
public struct MACDParameters: Sendable, Codable, Hashable {
    public var fastPeriod: Int
    public var slowPeriod: Int
    public var signalPeriod: Int

    public init(fastPeriod: Int = 12, slowPeriod: Int = 26, signalPeriod: Int = 9) {
        self.fastPeriod = fastPeriod
        self.slowPeriod = slowPeriod
        self.signalPeriod = signalPeriod
    }

    /// The conventional 12 / 26 / 9.
    public static let standard = MACDParameters()
}

/// The three MACD series, all aligned to the input bar count. A `nil` entry marks a
/// bar where the window was not warm yet, so a chart can skip the point instead of
/// drawing an extrapolated value.
public struct MACDSeries: Sendable, Equatable {
    public var dif: [Double?]
    public var dea: [Double?]
    public var histogram: [Double?]

    public init(dif: [Double?], dea: [Double?], histogram: [Double?]) {
        self.dif = dif
        self.dea = dea
        self.histogram = histogram
    }

    public static let empty = MACDSeries(dif: [], dea: [], histogram: [])

    /// An all-`nil` result of the same length as the input bars.
    public static func empty(count: Int) -> MACDSeries {
        let blanks = [Double?](repeating: nil, count: max(count, 0))
        return MACDSeries(dif: blanks, dea: blanks, histogram: blanks)
    }
}

/// Deterministic, view-independent indicator math. It lives in `PulseCore` so the chart
/// layer only maps numbers to coordinates, and so the same values can back tests, the
/// hover readout and any future export.
public enum ChartIndicatorMath {
    /// Simple moving average. The first `period - 1` entries are `nil`; a window that
    /// contains a non-finite value yields `nil` for that bar.
    public static func simpleMovingAverage(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return [Double?](repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        guard values.count >= period else { return result }

        var windowSum = 0.0
        var finiteCount = 0
        for index in values.indices {
            let incoming = values[index]
            if incoming.isFinite {
                windowSum += incoming
                finiteCount += 1
            }
            if index >= period {
                let outgoing = values[index - period]
                if outgoing.isFinite {
                    windowSum -= outgoing
                    finiteCount -= 1
                }
            }
            if index >= period - 1, finiteCount == period {
                result[index] = windowSum / Double(period)
            }
        }
        return result
    }

    /// Exponential moving average seeded with the SMA of the first window, so early values
    /// stay anchored instead of inheriting the very first close. Entries before the seed are
    /// `nil`, and the series stops at the first non-finite input.
    public static func exponentialMovingAverage(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0 else { return [Double?](repeating: nil, count: values.count) }
        var result = [Double?](repeating: nil, count: values.count)
        guard values.count >= period else { return result }

        var seedSum = 0.0
        for index in 0..<period {
            let value = values[index]
            guard value.isFinite else { return result }
            seedSum += value
        }

        let alpha = 2.0 / Double(period + 1)
        var previous = seedSum / Double(period)
        result[period - 1] = previous
        for index in period..<values.count {
            let value = values[index]
            guard value.isFinite else { return result }
            previous += alpha * (value - previous)
            result[index] = previous
        }
        return result
    }

    /// DIF = EMA(fast) − EMA(slow); DEA = EMA(signal) of DIF; histogram = 2 × (DIF − DEA).
    /// The ×2 matches what domestic terminals plot, so the bars read with familiar heights.
    public static func macd(_ values: [Double], parameters: MACDParameters = .standard) -> MACDSeries {
        guard parameters.fastPeriod > 0, parameters.slowPeriod > 0, parameters.signalPeriod > 0 else {
            return .empty(count: values.count)
        }
        let fast = exponentialMovingAverage(values, period: parameters.fastPeriod)
        let slow = exponentialMovingAverage(values, period: parameters.slowPeriod)

        var dif = [Double?](repeating: nil, count: values.count)
        for index in values.indices {
            if let fastValue = fast[index], let slowValue = slow[index] {
                dif[index] = fastValue - slowValue
            }
        }

        // DIF is contiguous from its first defined bar, so the signal EMA runs on the
        // compacted values and the result is shifted back into place.
        let firstDefined = dif.firstIndex { $0 != nil } ?? dif.count
        let signalValues = exponentialMovingAverage(dif.compactMap { $0 }, period: parameters.signalPeriod)

        var dea = [Double?](repeating: nil, count: values.count)
        for (offset, value) in signalValues.enumerated() {
            guard let value else { continue }
            let index = firstDefined + offset
            guard dea.indices.contains(index) else { continue }
            dea[index] = value
        }

        var histogram = [Double?](repeating: nil, count: values.count)
        for index in values.indices {
            if let difValue = dif[index], let deaValue = dea[index] {
                histogram[index] = 2 * (difValue - deaValue)
            }
        }
        return MACDSeries(dif: dif, dea: dea, histogram: histogram)
    }

    /// Convenience: close prices in bar order, ready for any of the series above.
    public static func closes(of candles: [Candle]) -> [Double] {
        candles.map(\.close)
    }
}
