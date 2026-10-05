import Foundation

/// Local notification delivery state. Market oscillation never rearms a delivered plan;
/// an explicit plan edit or snooze does. This state stays on the notifying Mac.
public struct PlanAlertLedger: Codable, Sendable {
    private struct Record: Codable, Sendable {
        var plan: TradePlan
        var delivered: Bool
        var snoozedUntil: Date?
    }
    private var records: [UUID: Record] = [:]

    public init() {}

    public func shouldNotify(plan: TradePlan, quote: Quote, now: Date = .now) -> Bool {
        guard plan.status == .active, plan.price.isFinite, plan.price > 0,
              plan.quantity.isFinite, plan.quantity > 0,
              quote.price.isFinite, quote.price > 0,
              quote.marketState != .closed,
              quote.timestamp.timeIntervalSince(now) <= 30,
              now.timeIntervalSince(quote.timestamp) <= max(0, quote.sourceDelay ?? 0) + 90,
              plan.isReached(at: quote.price) else { return false }
        if let record = records[plan.id], record.plan == plan {
            if record.delivered { return false }
            if let until = record.snoozedUntil, now < until { return false }
        }
        return true
    }

    public mutating func markDelivered(_ plan: TradePlan) {
        records[plan.id] = Record(plan: plan, delivered: true, snoozedUntil: nil)
    }

    public mutating func snooze(_ plan: TradePlan, until: Date) {
        records[plan.id] = Record(plan: plan, delivered: false, snoozedUntil: until)
    }

    public mutating func prune(keeping ids: Set<UUID>) {
        records = records.filter { ids.contains($0.key) }
    }
}
