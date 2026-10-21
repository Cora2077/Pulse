import Foundation

public enum FuyaoStatementKind: String, Codable, CaseIterable, Sendable {
    case income = "income-statements", balance = "balance-sheets", cashFlow = "cash-flow-statements"
    public var title: String { switch self { case .income: "利润表"; case .balance: "资产负债表"; case .cashFlow: "现金流量表" } }
}
public struct FuyaoFinancialPeriod: Codable, Hashable, Sendable, Identifiable {
    public let fiscalYear: Int
    public let fiscalPeriod: String
    public let periodEnd: Date
    public let disclosedAt: Date?
    public let currency: String?
    /// Known values only, in original currency units. Missing is never zero.
    public let values: [String: Double]
    public var id: Date { periodEnd }
    public init(fiscalYear: Int, fiscalPeriod: String, periodEnd: Date, disclosedAt: Date?, currency: String?, values: [String: Double]) {
        self.fiscalYear = fiscalYear; self.fiscalPeriod = fiscalPeriod; self.periodEnd = periodEnd
        self.disclosedAt = disclosedAt; self.currency = currency; self.values = values
    }
    public func yearOverYear(_ key: String, in history: [Self]) -> Double? {
        guard let current = values[key], current.isFinite,
              let previous = history.first(where: { $0.fiscalYear == fiscalYear - 1 && $0.fiscalPeriod == fiscalPeriod && $0.currency == currency }),
              let base = previous.values[key], base.isFinite, base > 0 else { return nil }
        let value = (current / base - 1) * 100
        return value.isFinite ? value : nil
    }
}
public struct FuyaoValuation: Codable, Hashable, Sendable {
    public let thscode: String
    public let peTTM: Double?
    public let peMRQ: Double?
    public let pbMRQ: Double?
    public let psTTM: Double?
    public let pcfTTM: Double?
    public init(thscode: String, peTTM: Double?, peMRQ: Double?, pbMRQ: Double?, psTTM: Double?, pcfTTM: Double?) {
        self.thscode = thscode; self.peTTM = peTTM; self.peMRQ = peMRQ; self.pbMRQ = pbMRQ; self.psTTM = psTTM; self.pcfTTM = pcfTTM
    }
}
