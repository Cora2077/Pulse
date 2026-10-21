import Foundation

public struct FuyaoContextKey: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case plan, fill }
    public let account: BrokerageAccountID
    public let symbol: SymbolID
    public let kind: Kind
    public let recordID: UUID
    public init(account: BrokerageAccountID, symbol: SymbolID, kind: Kind, recordID: UUID) {
        self.account = account; self.symbol = symbol; self.kind = kind; self.recordID = recordID
    }
}
public struct FuyaoContextEvent: Sendable {
    public let key: FuyaoContextKey
    public let createdAt: Date
    public let tradeDate: Date?
    public static func events(in snapshot: WatchlistSyncSnapshot) -> [Self] {
        var result: [Self] = []
        var seen: Set<FuyaoContextKey> = []
        func append(items: [WatchItem], account: BrokerageAccountID) {
            for item in items {
                for plan in item.plans {
                    let key = FuyaoContextKey(account: account, symbol: item.symbol, kind: .plan, recordID: plan.id)
                    if seen.insert(key).inserted { result.append(.init(key: key, createdAt: plan.createdAt, tradeDate: nil)) }
                }
                for fill in item.transactions where fill.kind == .buy || fill.kind == .sell {
                    let key = FuyaoContextKey(account: account, symbol: item.symbol, kind: .fill, recordID: fill.id)
                    if seen.insert(key).inserted { result.append(.init(key: key, createdAt: fill.createdAt, tradeDate: fill.date)) }
                }
            }
        }
        append(items: snapshot.items + snapshot.retainedHistoryItems, account: .unassigned)
        for ledger in snapshot.brokerageAccounts ?? [] { append(items: ledger.items + ledger.retainedHistoryItems, account: ledger.accountID) }
        return result
    }
}
public struct FuyaoMarketContext: Codable, Hashable, Sendable {
    public struct Board: Codable, Hashable, Sendable {
        public let name: String
        public let thscode: String
        public let strength: FuyaoRelativeStrength
        public init(name: String, thscode: String, strength: FuyaoRelativeStrength) { self.name = name; self.thscode = thscode; self.strength = strength }
    }
    public let key: FuyaoContextKey
    public let capturedAt: Date
    public let news: FuyaoTimed<[FuyaoNewsItem]>?
    public let anomalies: FuyaoTimed<[FuyaoAnomaly]>?
    public let hotStock: FuyaoHotStock?
    public let hotDataTime: Date?
    public let statistics: FuyaoTimed<FuyaoMarketStatistics>?
    public let boards: [Board]
    public var hasData: Bool { news?.value.isEmpty == false || anomalies?.value.isEmpty == false || hotStock != nil || statistics != nil || !boards.isEmpty }
    public init(key: FuyaoContextKey, capturedAt: Date, news: FuyaoTimed<[FuyaoNewsItem]>? = nil,
                anomalies: FuyaoTimed<[FuyaoAnomaly]>? = nil, hotStock: FuyaoHotStock? = nil, hotDataTime: Date? = nil,
                statistics: FuyaoTimed<FuyaoMarketStatistics>? = nil, boards: [Board] = []) {
        self.key = key; self.capturedAt = capturedAt; self.news = news; self.anomalies = anomalies
        self.hotStock = hotStock; self.hotDataTime = hotDataTime; self.statistics = statistics; self.boards = boards
    }
}
