import Foundation

/// An estimate from published fund weights, separate from the financial ledger.
/// Only long positions enter the denominator; currencies never mix.
public enum FuyaoLookThrough {
    public struct Component: Codable, Hashable, Sendable, Identifiable {
        public let source: SymbolID
        public let sourceName: String
        public let amount: Double
        public let reportEnd: Date?
        public var id: SymbolID { source }
    }
    public struct Exposure: Codable, Hashable, Sendable, Identifiable {
        public let thscode: String
        public let name: String
        public let amount: Double
        public let percent: Double
        public let components: [Component]
        public var id: String { thscode }
        public var overlaps: Bool { components.count > 1 }
    }
    public struct FundCoverage: Codable, Hashable, Sendable, Identifiable {
        public let symbol: SymbolID
        public let name: String
        public let reportEnd: Date?
        public let disclosedPercent: Double?
        public let unresolvedAmount: Double
        public var id: SymbolID { symbol }
    }
    public struct Currency: Codable, Hashable, Sendable, Identifiable {
        public let code: String
        public let totalLongExposure: Double
        public let unresolvedAmount: Double
        public let excludedShortExposure: Double
        public let exposures: [Exposure]
        public let funds: [FundCoverage]
        public var id: String { code }
    }

    public static func calculate(
        allocation: PortfolioAllocation.Result,
        types: [SymbolID: InstrumentType],
        reports: [SymbolID: FuyaoFundHoldings]
    ) -> [Currency] {
        allocation.currencies.compactMap { currency in
            let longs = currency.holdings.filter { $0.quantity > 0 && $0.exposure.isFinite && $0.exposure > 0 }
            let total = longs.reduce(0) { $0 + $1.exposure }
            guard total.isFinite, total > 0 else { return nil }
            var parts: [String: [Component]] = [:]
            var names: [String: String] = [:]
            var unresolved = 0.0
            var funds: [FundCoverage] = []
            for position in longs {
                switch types[position.symbol] {
                case .equity:
                    let key = wireCode(position.symbol) ?? "direct:" + position.symbol.description
                    names[key] = position.name
                    parts[key, default: []].append(Component(source: position.symbol, sourceName: position.name,
                        amount: position.exposure, reportEnd: nil))
                case .etf, .fund:
                    guard let report = reports[position.symbol], report.fund == position.symbol,
                          report.disclosedWeightPercent != nil else {
                        unresolved += position.exposure
                        funds.append(.init(symbol: position.symbol, name: position.name, reportEnd: reports[position.symbol]?.report.endDate,
                            disclosedPercent: nil, unresolvedAmount: position.exposure))
                        continue
                    }
                    var known = 0.0
                    var seen: Set<String> = []
                    for row in report.holdings {
                        let key = row.thscode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        guard key.split(separator: ".").count == 2, seen.insert(key).inserted, let weight = row.weightPercent,
                              weight.isFinite, weight >= 0, weight <= 100 else { continue }
                        let amount = position.exposure * (weight / 100)
                        guard amount.isFinite, amount > 0 else { continue }
                        known += amount
                        if names[key] == nil { names[key] = row.name }
                        parts[key, default: []].append(.init(source: position.symbol, sourceName: position.name,
                            amount: amount, reportEnd: report.report.endDate))
                    }
                    // Weight sums must not be normalized to hide missing disclosure.
                    let unknown = max(0, position.exposure - known)
                    unresolved += unknown
                    funds.append(.init(symbol: position.symbol, name: position.name, reportEnd: report.report.endDate,
                        disclosedPercent: known / position.exposure * 100, unresolvedAmount: unknown))
                default: unresolved += position.exposure
                }
            }
            let exposures = parts.compactMap { key, components -> Exposure? in
                let amount = components.reduce(0) { $0 + $1.amount }
                guard amount.isFinite, amount > 0 else { return nil }
                return Exposure(thscode: key, name: names[key] ?? key, amount: amount,
                    percent: amount / total * 100, components: components.sorted { $0.amount > $1.amount })
            }.sorted { $0.amount == $1.amount ? $0.thscode < $1.thscode : $0.amount > $1.amount }
            let shorts = currency.holdings.filter { $0.quantity < 0 }.reduce(0) { $0 + $1.exposure }
            return Currency(code: currency.code, totalLongExposure: total, unresolvedAmount: unresolved,
                excludedShortExposure: shorts, exposures: exposures, funds: funds)
        }
    }

    /// Exact exchange identities only. Unverified overseas aliases are not merged.
    public static func wireCode(_ symbol: SymbolID) -> String? {
        guard symbol.indexID == nil, symbol.sectorIndex == nil else { return nil }
        switch symbol.market {
        case .sh: return symbol.code + ".SH"
        case .sz: return symbol.code + ".SZ"
        case .hk: return symbol.code + ".HK"
        default: return nil
        }
    }
}
