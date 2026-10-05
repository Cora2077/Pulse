import Foundation

/// User classifications over the existing gross exposure calculation; no inferred ETF holdings.
public struct SectorExposure: Identifiable, Sendable {
    public let name: String
    public let currencyCode: String
    public let exposure: Double
    public let percent: Double
    public let holdings: [PortfolioAllocation.Holding]
    public var id: String { "\(currencyCode):\(name)" }

    public static func make(allocation: PortfolioAllocation.Result, sectors: [SymbolID: String]) -> [Self] {
        var result: [Self] = []
        for currency in allocation.currencies {
            let grouped = Dictionary(grouping: currency.holdings) { holding in
                let label = sectors[holding.symbol]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return label.isEmpty ? "未分类" : label
            }
            var rows: [Self] = []
            for (name, holdings) in grouped {
                let exposure = holdings.reduce(0.0) { $0 + $1.exposure }
                rows.append(Self(name: name, currencyCode: currency.code, exposure: exposure,
                                 percent: exposure / currency.totalExposure * 100, holdings: holdings))
            }
            rows.sort { $0.exposure == $1.exposure ? $0.name < $1.name : $0.exposure > $1.exposure }
            result.append(contentsOf: rows)
        }
        return result
    }
}
