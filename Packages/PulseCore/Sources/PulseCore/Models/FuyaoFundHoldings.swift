import Foundation

public struct FuyaoFundReport: Codable, Sendable, Hashable {
    public let reportType: String
    public let reportTypeName: String?
    public let endDate: Date
    public init(reportType: String, reportTypeName: String? = nil, endDate: Date) {
        self.reportType = reportType; self.reportTypeName = reportTypeName; self.endDate = endDate
    }
}
public struct FuyaoFundHolding: Codable, Sendable, Hashable, Identifiable {
    public let thscode: String
    public let name: String
    public let weightPercent: Double?
    public let reportEnd: Date?
    public let rank: Int?
    public var id: String { thscode }
    public init(thscode: String, name: String, weightPercent: Double?, reportEnd: Date? = nil, rank: Int? = nil) {
        self.thscode = thscode; self.name = name; self.weightPercent = weightPercent
        self.reportEnd = reportEnd; self.rank = rank
    }
}
public struct FuyaoFundHoldings: Codable, Sendable, Hashable {
    public let fund: SymbolID
    public let report: FuyaoFundReport
    public let holdings: [FuyaoFundHolding]
    public let fetchedAt: Date
    public init(fund: SymbolID, report: FuyaoFundReport, holdings: [FuyaoFundHolding], fetchedAt: Date) {
        self.fund = fund; self.report = report; self.holdings = holdings; self.fetchedAt = fetchedAt
    }
    /// Sum known, deduplicated stock weights. Missing disclosure stays uncovered.
    public var disclosedWeightPercent: Double? {
        var seen: Set<String> = []
        var sum = 0.0
        for row in holdings {
            let code = row.thscode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            guard let weight = row.weightPercent else { continue }
            guard weight.isFinite, weight >= 0, weight <= 100 else { return nil }
            sum += weight
        }
        return sum.isFinite && sum <= 100.01 ? sum : nil
    }
}
