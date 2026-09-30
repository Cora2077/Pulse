import Foundation
import Observation
import PulseCore

/// One main-window chart's local drawing undo sequence. The symbol is stored
/// with each command so an old edit can never be replayed onto another chart.
@MainActor
@Observable
final class MainChartDrawingSession {
    private struct Change {
        var symbol: SymbolID
        var identity: DrawingIdentity
        var before: ChartDrawing?
        var after: ChartDrawing?
    }

    private struct DrawingIdentity: Hashable {
        let symbol: SymbolID
        let id: UUID
    }

    @ObservationIgnored private var undoStack: [Change] = []
    @ObservationIgnored private var redoStack: [Change] = []
    /// Undoing a soft deletion must restore under a new UUID. This alias lets
    /// older edits in the same session continue to address that restored line.
    @ObservationIgnored private var currentIDs: [DrawingIdentity: UUID] = [:]

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func record(symbol: SymbolID, before: ChartDrawing?, after: ChartDrawing) {
        let identity = identity(for: after.id, symbol: symbol)
        undoStack.append(Change(symbol: symbol, identity: identity, before: before, after: after))
        redoStack.removeAll()
    }

    func recordDelete(symbol: SymbolID, drawing: ChartDrawing) {
        let identity = identity(for: drawing.id, symbol: symbol)
        undoStack.append(Change(symbol: symbol, identity: identity, before: drawing, after: nil))
        redoStack.removeAll()
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        currentIDs.removeAll()
    }

    func undo(
        for symbol: SymbolID,
        upsert: (ChartDrawing, SymbolID) -> Bool,
        delete: (UUID, SymbolID) -> Bool
    ) {
        guard let change = undoStack.last, change.symbol == symbol else { return }
        var updated = change
        let currentID = resolvedID(for: change.identity)
        let succeeded: Bool
        switch (change.before, change.after) {
        case (nil, .some):
            succeeded = delete(currentID, symbol)
        case (.some(let before), nil):
            var restored = before
            restored.id = UUID()
            restored.createdAt = .now
            restored.updatedAt = .now
            restored.deletedAt = nil
            succeeded = upsert(restored, symbol)
            if succeeded {
                currentIDs[change.identity] = restored.id
                updated.before = restored
            }
        case (.some(let before), .some):
            var restored = before
            restored.id = currentID
            if upsert(restored, symbol) {
                succeeded = true
            } else {
                // A remote delete may have tombstoned the edited ID while this
                // local command remained in the undo stack. Restore the old
                // snapshot with a fresh identity rather than stalling undo.
                restored.id = UUID()
                restored.createdAt = .now
                restored.updatedAt = .now
                restored.deletedAt = nil
                succeeded = upsert(restored, symbol)
                if succeeded { currentIDs[change.identity] = restored.id }
            }
        case (nil, nil):
            succeeded = false
        }
        guard succeeded else { return }
        _ = undoStack.popLast()
        redoStack.append(updated)
    }

    func redo(
        for symbol: SymbolID,
        upsert: (ChartDrawing, SymbolID) -> Bool,
        delete: (UUID, SymbolID) -> Bool
    ) {
        guard let change = redoStack.last, change.symbol == symbol else { return }
        var updated = change
        let currentID = resolvedID(for: change.identity)
        let succeeded: Bool
        switch (change.before, change.after) {
        case (nil, .some(let after)):
            var restored = after
            // Undoing a create left a tombstone for its old UUID. A redo is a
            // fresh creation so it cannot resurrect that deleted identity.
            restored.id = UUID()
            restored.createdAt = .now
            restored.updatedAt = .now
            restored.deletedAt = nil
            succeeded = upsert(restored, symbol)
            if succeeded {
                currentIDs[change.identity] = restored.id
                updated.after = restored
            }
        case (.some, nil):
            succeeded = delete(currentID, symbol)
        case (.some, .some(let after)):
            var restored = after
            restored.id = currentID
            if upsert(restored, symbol) {
                succeeded = true
            } else {
                restored.id = UUID()
                restored.createdAt = .now
                restored.updatedAt = .now
                restored.deletedAt = nil
                succeeded = upsert(restored, symbol)
                if succeeded { currentIDs[change.identity] = restored.id }
            }
        case (nil, nil):
            succeeded = false
        }
        guard succeeded else { return }
        _ = redoStack.popLast()
        undoStack.append(updated)
    }

    private func identity(for id: UUID, symbol: SymbolID) -> DrawingIdentity {
        if let existing = currentIDs.first(where: { $0.key.symbol == symbol && $0.value == id })?.key {
            return existing
        }
        let identity = DrawingIdentity(symbol: symbol, id: id)
        if currentIDs[identity] == nil { currentIDs[identity] = id }
        return identity
    }

    private func resolvedID(for identity: DrawingIdentity) -> UUID {
        currentIDs[identity] ?? identity.id
    }
}
