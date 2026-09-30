#if DEBUG
import Foundation
import PulseCore

@MainActor
enum MainWindowDemo {
    static let userDefaultsSuite = "app.pulse.mac.main-window-demo"

    static let infos: [SymbolInfo] = [
        SymbolInfo(symbol: SymbolID(market: .us, code: "AAPL"), name: "Apple Inc.", type: .equity),
        SymbolInfo(symbol: SymbolID(market: .hk, code: "700"), name: "Tencent Holdings", type: .equity),
        SymbolInfo(symbol: SymbolID(cryptoBase: "BTC", quote: "USDT"), name: "Bitcoin", type: .crypto),
    ]

    static func seed(state: AppState) {
        guard let groupID = state.watchlist.selectedGroup?.id else { return }
        for info in infos {
            state.watchlist.add(info, to: groupID)
        }

        let now = Date.now
        let today = Calendar(identifier: .gregorian).startOfDay(for: now)
        let trades: [(SymbolID, Double, Double, Double)] = [
            (infos[0].symbol, 204.50, 12, 1.99),
            (infos[1].symbol, 372.00, 100, 18),
            (infos[2].symbol, 63_400, 0.15, 0.75),
        ]
        for (symbol, price, quantity, fee) in trades {
            state.watchlist.addTransaction(symbol, PositionTransaction(
                kind: .buy,
                price: price,
                quantity: quantity,
                date: today,
                fee: fee
            ))
        }

        let thesis: [(SymbolID, String)] = [
            (infos[0].symbol, "Services growth and durable ecosystem support a long-term position."),
            (infos[1].symbol, "A strong platform business with room to recover as sentiment improves."),
            (infos[2].symbol, "A long-term core holding; add on measured pullbacks."),
        ]
        for (symbol, text) in thesis {
            state.watchlist.setThesis(text, for: symbol)
        }

        let plans: [(SymbolID, TradePlan)] = [
            (infos[0].symbol, TradePlan(kind: .buy, price: 215, quantity: 5, note: "Add on a pullback")),
            (infos[0].symbol, TradePlan(kind: .sell, price: 238, quantity: 4, note: "Trim into strength")),
            (infos[1].symbol, TradePlan(kind: .buy, price: 385, quantity: 50, note: "Scale in near support")),
            (infos[2].symbol, TradePlan(kind: .buy, price: 65_000, quantity: 0.05, note: "Add on a measured dip")),
        ]
        for (symbol, plan) in plans {
            _ = state.watchlist.setTradePlan(plan, for: symbol)
        }

        let quotes = infos.map { info in
            let (price, previousClose, open, high, low, volume) = quoteValues(for: info.symbol)
            return Quote(
                symbol: info.symbol,
                name: info.name,
                price: price,
                previousClose: previousClose,
                open: open,
                high: high,
                low: low,
                volume: volume,
                turnover: price * volume,
                currencyCode: info.symbol.currencyCode,
                sourceID: "demo",
                sourceName: "Pulse Demo",
                timestamp: now
            )
        }
        state.market.apply(quotes: quotes)

        for info in infos {
            for period in CandlePeriod.allCases {
                let candles = makeCandles(for: info.symbol, period: period, basePrice: quoteValues(for: info.symbol).0)
                state.market.cache(
                    candles: candles,
                    for: CandleCacheKey(symbol: info.symbol, period: period)
                )
                if period == .minute1 {
                    state.market.apply(sparkline: candles, for: info.symbol)
                }
            }
        }
    }

    static func search(_ query: String) -> [SymbolInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return infos.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.symbol.displayCode.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func quoteValues(for symbol: SymbolID) -> (Double, Double, Double, Double, Double, Double) {
        switch symbol.market {
        case .us: (222.30, 219.60, 220.10, 224.20, 218.80, 48_200_000)
        case .hk: (395.80, 389.20, 391.00, 398.40, 387.60, 16_800_000)
        case .crypto: (67_450, 66_880, 66_950, 68_120, 66_400, 28_400)
        default: (100, 99, 99.5, 101, 98.5, 10_000)
        }
    }

    private static func makeCandles(for symbol: SymbolID, period: CandlePeriod, basePrice: Double) -> [Candle] {
        let interval = intervalSeconds(for: period)
        let now = Date.now
        let calendar = Calendar(identifier: .gregorian)
        let anchor: Date
        let count: Int

        if period.isIntraday && symbol.market == .crypto {
            var utc = calendar
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let dayStart = utc.startOfDay(for: now)
            anchor = dayStart
            count = min(1_440, max(1, Int(now.timeIntervalSince(dayStart) / interval) + 1))
        } else if period.isIntraday {
            var sessionCalendar = calendar
            sessionCalendar.timeZone = symbol.market.timeZone
            let startComponents = DateComponents(year: 2026, month: 9, day: 29, hour: 9, minute: 30)
            anchor = sessionCalendar.date(from: startComponents) ?? now.addingTimeInterval(-interval * 390)
            let regularMinutes = symbol.market == .hk ? 330 : 390
            count = max(1, Int(Double(regularMinutes * 60) / interval))
        } else {
            count = switch period {
            case .day: 180
            case .week: 120
            case .month: 96
            case .minute1, .minute5, .minute15, .minute30, .hour1: 60
            }
            anchor = now.addingTimeInterval(-interval * Double(count - 1))
        }

        return (0..<count).map { index in
            let time = anchor.addingTimeInterval(Double(index) * interval)
            let phase = Double(index) * 0.073
            let drift = Double(index) / Double(max(count, 1)) * 0.018
            let close = basePrice * (1 + drift + sin(phase) * 0.006 + cos(phase * 0.37) * 0.003)
            let open = index == 0
                ? close * (1 - sin(phase + 0.4) * 0.002)
                : basePrice * (1 + Double(index - 1) / Double(max(count, 1)) * 0.018
                    + sin((Double(index) - 1) * 0.073) * 0.006
                    + cos((Double(index) - 1) * 0.073 * 0.37) * 0.003)
            let spread = basePrice * (0.001 + abs(sin(phase * 0.5)) * 0.0015)
            return Candle(
                time: time,
                open: open,
                high: max(open, close) + spread,
                low: max(0.0001, min(open, close) - spread),
                close: close,
                volume: 80_000 + abs(sin(phase)) * 240_000
            )
        }
    }

    private static func intervalSeconds(for period: CandlePeriod) -> TimeInterval {
        switch period {
        case .minute1: 60
        case .minute5: 300
        case .minute15: 900
        case .minute30: 1_800
        case .hour1: 3_600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }
}
#endif
