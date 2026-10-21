import Foundation

public struct FuyaoMarketStatistics: Codable, Hashable, Sendable {
    public struct Tier: Codable, Hashable, Sendable, Identifiable {
        public let boardNumber: Int
        public let count: Int
        public var id: Int { boardNumber }
        public init(boardNumber: Int, count: Int) { self.boardNumber = boardNumber; self.count = count }
    }
    public let tradeDate: Date
    public let dataTime: Date?
    public let limitUp: Int?
    public let opened: Int?
    public let touched: Int?
    /// Fraction, not a percentage number.
    public let sealRate: Double?
    public let tiers: [Tier]
    public init(tradeDate: Date, dataTime: Date?, limitUp: Int?, opened: Int?, touched: Int?, sealRate: Double?, tiers: [Tier]) {
        self.tradeDate = tradeDate; self.dataTime = dataTime; self.limitUp = limitUp; self.opened = opened
        self.touched = touched; self.sealRate = sealRate; self.tiers = tiers
    }
}
public enum FuyaoLimitKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case up = "limit-up-pool", down = "limit-down-pool", broken = "limit-break-pool"
    public var id: String { rawValue }
    public var title: String { switch self { case .up: "涨停"; case .down: "跌停"; case .broken: "炸板" } }
}
public struct FuyaoLimitStock: Codable, Hashable, Sendable, Identifiable {
    public let thscode: String
    public let name: String
    public let changePercent: Double?
    public let consecutiveDays: Int?
    public let boardText: String?
    public let reason: String?
    public var id: String { thscode }
    public var symbol: SymbolID? { FuyaoConstituent(thscode: thscode, name: name).symbol }
    public init(thscode: String, name: String, changePercent: Double?, consecutiveDays: Int?, boardText: String?, reason: String?) {
        self.thscode = thscode; self.name = name; self.changePercent = changePercent
        self.consecutiveDays = consecutiveDays; self.boardText = boardText; self.reason = reason
    }
}
public struct FuyaoLimitPool: Codable, Hashable, Sendable {
    public let kind: FuyaoLimitKind
    public let tradeDate: Date
    public let dataTime: Date?
    public let stocks: [FuyaoLimitStock]
    public let total: Int?
    public let page: Int
    public let pages: Int?
    public var hasMore: Bool { pages.map { page < $0 } ?? (stocks.count == 200) }
    public init(kind: FuyaoLimitKind, tradeDate: Date, dataTime: Date?, stocks: [FuyaoLimitStock], total: Int?, page: Int, pages: Int?) {
        self.kind = kind; self.tradeDate = tradeDate; self.dataTime = dataTime; self.stocks = stocks
        self.total = total; self.page = page; self.pages = pages
    }
}
