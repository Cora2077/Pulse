import Foundation

/// Gross position exposure by trading currency. This does not represent account equity or cash.
public enum PortfolioAllocation {
    public struct Position: Sendable, Hashable {
        public let symbol: SymbolID
        public let name: String
        public let quantity: Double
        public let price: Double?
        public let currencyCode: String?
        public let supportsPosition: Bool

        public init(
            symbol: SymbolID,
            name: String,
            quantity: Double,
            price: Double?,
            currencyCode: String?,
            supportsPosition: Bool = true
        ) {
            self.symbol = symbol
            self.name = name
            self.quantity = quantity
            self.price = price
            self.currencyCode = currencyCode
            self.supportsPosition = supportsPosition
        }
    }

    public struct PlannedBuy: Sendable, Hashable {
        public let symbol: SymbolID
        public let quantity: Double

        public init(symbol: SymbolID, quantity: Double) {
            self.symbol = symbol
            self.quantity = quantity
        }
    }

    public struct Holding: Sendable, Hashable, Identifiable {
        public let symbol: SymbolID
        public let name: String
        public let quantity: Double
        public let exposure: Double
        public let percent: Double
        public var id: SymbolID { symbol }

        public var isShort: Bool { quantity < 0 }
    }

    public struct Currency: Sendable, Hashable, Identifiable {
        public let code: String
        public let totalExposure: Double
        public let topThreeConcentration: Double
        public let holdings: [Holding]
        public var id: String { code }
    }

    public struct PlannedResult: Sendable, Hashable {
        public let symbol: SymbolID
        public let currencyCode: String
        public let percent: Double
        public let totalExposure: Double
    }

    public struct Result: Sendable, Hashable {
        public let currencies: [Currency]
        public let excludedMissingQuoteCount: Int
        public let excludedUnrepresentableCurrencyCodes: [String]
        public let plannedBuy: PlannedResult?
    }

    /// Recalculates the whole portfolio after adding a plan's signed buy quantity.
    /// Returns nil when the plan cannot be priced or applied safely.
    public static func previewAfterBuy(positions: [Position], plannedBuy: PlannedBuy) -> Result? {
        guard plannedBuy.quantity.isFinite, plannedBuy.quantity > 0 else { return nil }
        var seen = Set<SymbolID>()
        var uniquePositions = positions.filter { seen.insert($0.symbol).inserted }
        guard let index = uniquePositions.firstIndex(where: { $0.symbol == plannedBuy.symbol }) else { return nil }
        let position = uniquePositions[index]
        guard position.supportsPosition,
              position.quantity.isFinite,
              let price = position.price, price.isFinite, price > 0,
              let currency = position.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currency.isEmpty else { return nil }
        let resultingQuantity = position.quantity + plannedBuy.quantity
        guard resultingQuantity.isFinite else { return nil }
        uniquePositions[index] = Position(
            symbol: position.symbol,
            name: position.name,
            quantity: resultingQuantity,
            price: price,
            currencyCode: currency,
            supportsPosition: position.supportsPosition
        )
        return calculate(positions: uniquePositions)
    }

    public static func calculate(positions: [Position], plannedBuy: PlannedBuy? = nil) -> Result {
        var unique: [SymbolID: Position] = [:]
        for position in positions where unique[position.symbol] == nil {
            unique[position.symbol] = position
        }

        var valuesByCurrency: [String: [(Position, Double)]] = [:]
        var missingQuoteCount = 0
        var unrepresentableCurrencySet = Set<String>()
        for position in unique.values where position.supportsPosition
            && position.quantity.isFinite && position.quantity != 0 {
            let currency = position.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            guard let price = position.price, price.isFinite, price > 0, !currency.isEmpty else {
                missingQuoteCount += 1
                continue
            }
            let exposure = abs(position.quantity) * price
            guard exposure.isFinite else {
                unrepresentableCurrencySet.insert(currency)
                continue
            }
            valuesByCurrency[currency, default: []].append((position, exposure))
        }

        var currencies: [Currency] = []
        for (code, values) in valuesByCurrency {
            guard !unrepresentableCurrencySet.contains(code) else { continue }
            let total = values.reduce(0) { $0 + $1.1 }
            guard total.isFinite else {
                unrepresentableCurrencySet.insert(code)
                continue
            }
            var holdings: [Holding] = []
            for (position, exposure) in values {
                holdings.append(Holding(
                    symbol: position.symbol,
                    name: position.name,
                    quantity: position.quantity,
                    exposure: exposure,
                    percent: total > 0 ? exposure / total * 100 : 0
                ))
            }
            holdings.sort { $0.exposure == $1.exposure ? $0.name < $1.name : $0.exposure > $1.exposure }
            currencies.append(Currency(
                code: code,
                totalExposure: total,
                topThreeConcentration: holdings.prefix(3).reduce(0) { $0 + $1.percent },
                holdings: holdings
            ))
        }
        currencies.sort { $0.code < $1.code }
        let unrepresentableCurrencies = unrepresentableCurrencySet.sorted()

        var plannedResult: PlannedResult?
        if let plannedBuy, let position = unique[plannedBuy.symbol],
           let currency = position.currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !currency.isEmpty, !unrepresentableCurrencySet.contains(currency),
           let preview = previewAfterBuy(positions: positions, plannedBuy: plannedBuy),
           !preview.excludedUnrepresentableCurrencyCodes.contains(currency) {
            let future = preview.currencies.first { $0.code == currency }
            plannedResult = PlannedResult(
                symbol: plannedBuy.symbol,
                currencyCode: currency,
                percent: future?.holdings.first { $0.symbol == plannedBuy.symbol }?.percent ?? 0,
                totalExposure: future?.totalExposure ?? 0
            )
        }

        return Result(
            currencies: currencies,
            excludedMissingQuoteCount: missingQuoteCount,
            excludedUnrepresentableCurrencyCodes: unrepresentableCurrencies,
            plannedBuy: plannedResult
        )
    }
}
