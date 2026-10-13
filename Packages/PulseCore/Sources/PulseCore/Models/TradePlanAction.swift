import Foundation

/// The same derived progress drives action availability on every plan surface.
/// Selection/account routing is not part of the availability rule.
public enum TradePlanAction: String, CaseIterable, Sendable, Identifiable {
    case recordFill, backfill, edit, history, snooze, abandon, revive, delete
    public var id: String { rawValue }

    public static func available(for entry: TradePlanEntry) -> [Self] {
        var actions: [Self] = []
        if entry.displayState == .waiting { actions.append(.recordFill) }
        else if entry.canBackfillFill { actions.append(.backfill) }
        actions += [.edit, .history]
        if entry.displayState == .waiting { actions += [.snooze, .abandon] }
        else if entry.displayState != .filled { actions.append(.revive) }
        actions.append(.delete)
        return actions
    }
}
