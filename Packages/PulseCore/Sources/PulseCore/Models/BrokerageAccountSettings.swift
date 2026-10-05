import Foundation

public struct BrokerageCashBalance: Codable, Hashable, Sendable {
    public var amount: Double
    public var updatedAt: Date
    public init(amount: Double, updatedAt: Date) { self.amount = amount; self.updatedAt = updatedAt }
}

public struct BrokeragePoolLimit: Codable, Hashable, Sendable {
    public var currency: String
    public var pool: PositionPool
    public var amount: Double
    public init(currency: String, pool: PositionPool, amount: Double) {
        self.currency = currency; self.pool = pool; self.amount = amount
    }
}

public struct BrokeragePoolBudgetScenario: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var planIDs: [UUID]
    public init(id: UUID, name: String, planIDs: [UUID]) { self.id = id; self.name = name; self.planIDs = planIDs }
}

/// Nil on an older snapshot means unknown; an explicit empty value clears settings.
public struct BrokerageAccountSettings: Codable, Equatable, Sendable {
    public var cashBalances: [String: BrokerageCashBalance]
    public var poolLimits: [BrokeragePoolLimit]
    public var scenarios: [BrokeragePoolBudgetScenario]
    public var sectorLimits: [String: Double]
    public init(cashBalances: [String: BrokerageCashBalance] = [:], poolLimits: [BrokeragePoolLimit] = [],
                scenarios: [BrokeragePoolBudgetScenario] = [], sectorLimits: [String: Double] = [:]) {
        self.cashBalances = cashBalances; self.poolLimits = poolLimits
        self.scenarios = scenarios; self.sectorLimits = sectorLimits
    }

    public var isValid: Bool {
        func currency(_ value: String) -> Bool {
            (2...12).contains(value.count) && value.utf8.allSatisfy { (65...90).contains($0) }
        }
        return cashBalances.allSatisfy { currency($0.key) && $0.value.amount.isFinite && $0.value.amount >= 0
            && $0.value.updatedAt.timeIntervalSince1970.isFinite }
            && poolLimits.allSatisfy { currency($0.currency) && $0.amount.isFinite && $0.amount >= 0 }
            && Set(poolLimits.map { "\($0.currency)|\($0.pool.rawValue)" }).count == poolLimits.count
            && Set(scenarios.map(\.id)).count == scenarios.count
            && scenarios.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.name.count <= 80 && !$0.planIDs.isEmpty && Set($0.planIDs).count == $0.planIDs.count }
            && sectorLimits.allSatisfy { !$0.key.isEmpty && $0.value.isFinite && $0.value > 0 && $0.value <= 100 }
    }
}
