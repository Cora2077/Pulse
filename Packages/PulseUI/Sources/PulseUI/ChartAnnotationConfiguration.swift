import Foundation
import Observation
import PulseCore

/// The chart interaction mode selected by the host toolbar.
public enum ChartAnnotationTool: Sendable, Equatable {
    case browse
    case horizontal
    case trend
    case measure
}

/// Window-local state for chart annotation tools.
///
/// Persisted drawings stay with the host's watchlist model. The controller only keeps
/// transient interaction state and selection; mutations are sent back through the
/// callbacks in `ChartAnnotationConfiguration`, and the host owns session undo.
@MainActor
@Observable
public final class ChartAnnotationController {
    public var tool: ChartAnnotationTool = .browse
    public var showsPlans = true
    public var showsDrawings = true
    public var showsHistoricalPlans = false
    public var fitsPlans = false
    public var snappingEnabled = false
    public var focusedPlanPrice: Double?
    public var selectedDrawingID: UUID?
    public private(set) var hasMeasurement = false
    public private(set) var isMeasurementSelected = false
    public private(set) var isInteracting = false

    /// Changed by Escape/reset so an overlay can discard in-progress previews and
    /// temporary measurements without owning persistent state in the host.
    private(set) var transientResetID = 0

    /// A measurement-only invalidation signal. Clearing a temporary measurement
    /// must not reset drawing selection or an unrelated pending chart interaction.
    private(set) var measurementClearID = 0

    @ObservationIgnored private var visibleDrawings: [ChartDrawing] = []
    @ObservationIgnored private var visibleDrawingIDs: Set<UUID> = []
    @ObservationIgnored private var upsert: (@MainActor (ChartDrawing) -> Void)?
    @ObservationIgnored private var delete: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var undoRequest: (@MainActor () -> Void)?
    @ObservationIgnored private var redoRequest: (@MainActor () -> Void)?

    public init() {}

    /// Cancels a pending first/second point or drag. If no interaction is active,
    /// Escape leaves the current tool and returns to browse mode.
    public func cancelInteraction() {
        transientResetID &+= 1
        isInteracting = false
        clearMeasurementAvailability()
        if tool == .browse {
            selectedDrawingID = nil
        } else {
            tool = .browse
        }
    }

    /// Clears previews and temporary measurement state, for example when the symbol,
    /// period, or intraday session changes.
    public func resetTransientState() {
        transientResetID &+= 1
        isInteracting = false
        selectedDrawingID = nil
        focusedPlanPrice = nil
        clearMeasurementAvailability()
    }

    /// Clears the temporary two-point measurement while leaving the current tool
    /// selected. The host may call this from its Clear Measurement command.
    public func clearMeasurement() {
        measurementClearID &+= 1
        clearMeasurementAvailability()
    }

    public func selectDrawing(_ id: UUID?) {
        selectedDrawingID = id
        isMeasurementSelected = false
    }

    public func selectMeasurement() {
        guard hasMeasurement else { return }
        selectedDrawingID = nil
        isMeasurementSelected = true
    }

    /// Deletes the selected drawing through the host callback; the host records this
    /// mutation in its instrument-session history.
    public var canDeleteSelected: Bool {
        if isMeasurementSelected { return hasMeasurement }
        guard let id = selectedDrawingID, delete != nil else { return false }
        return visibleDrawingIDs.contains(id)
            && visibleDrawings.contains(where: { $0.id == id && !$0.isDeleted && $0.isValid })
    }

    @discardableResult
    public func deleteSelected() -> Bool {
        if isMeasurementSelected, hasMeasurement {
            clearMeasurement()
            return true
        }
        guard let id = selectedDrawingID,
              canDeleteSelected else { return false }
        delete?(id)
        selectedDrawingID = nil
        return true
    }

    /// Routes undo/redo to the host's instrument-session history, which can include
    /// chart drawing changes and edits made in the host's drawing editor.
    public func setHistoryHandlers(
        undo: @escaping @MainActor () -> Void,
        redo: @escaping @MainActor () -> Void
    ) {
        undoRequest = undo
        redoRequest = redo
    }

    public func undo() { undoRequest?() }

    public func redo() { redoRequest?() }

    func beginInteraction() { isInteracting = true }

    func finishInteraction() { isInteracting = false }

    func setMeasurementAvailable(_ available: Bool) {
        hasMeasurement = available
        if !available { isMeasurementSelected = false }
    }

    func attach(_ configuration: ChartAnnotationConfiguration, visibleDrawingIDs: Set<UUID>) {
        self.visibleDrawingIDs = visibleDrawingIDs
        visibleDrawings = configuration.drawings.filter { visibleDrawingIDs.contains($0.id) }
        upsert = configuration.onUpsert
        delete = configuration.onDelete
    }

    private func clearMeasurementAvailability() {
        hasMeasurement = false
        isMeasurementSelected = false
    }

}

/// Inputs and edit routes for the reusable chart annotation overlay.
@MainActor
public struct ChartAnnotationConfiguration {
    public var controller: ChartAnnotationController
    public var drawings: [ChartDrawing]
    public var plans: [TradePlan]
    public var currentPrice: Double?
    public var scope: ChartDrawingScope
    public var currencyCode: String?
    public var quantityUnit: String?
    public var onUpsert: @MainActor (ChartDrawing) -> Void
    public var onDelete: @MainActor (UUID) -> Void
    public var onEditDrawing: @MainActor (UUID) -> Void
    public var onEditPlan: @MainActor (UUID) -> Void

    public init(
        controller: ChartAnnotationController,
        drawings: [ChartDrawing],
        plans: [TradePlan],
        currentPrice: Double?,
        scope: ChartDrawingScope,
        currencyCode: String?,
        quantityUnit: String? = nil,
        onUpsert: @escaping @MainActor (ChartDrawing) -> Void,
        onDelete: @escaping @MainActor (UUID) -> Void,
        onEditDrawing: @escaping @MainActor (UUID) -> Void,
        onEditPlan: @escaping @MainActor (UUID) -> Void
    ) {
        self.controller = controller
        self.drawings = drawings
        self.plans = plans
        self.currentPrice = currentPrice
        self.scope = scope
        self.currencyCode = currencyCode
        self.quantityUnit = quantityUnit
        self.onUpsert = onUpsert
        self.onDelete = onDelete
        self.onEditDrawing = onEditDrawing
        self.onEditPlan = onEditPlan
    }
}
