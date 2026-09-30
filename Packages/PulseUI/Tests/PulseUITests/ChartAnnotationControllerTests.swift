import Foundation
import Testing
import PulseCore
@testable import PulseUI

@MainActor
struct ChartAnnotationControllerTests {
    @Test("Delete removes only a selected drawing in the visible chart scope")
    func deleteSelectedDrawing() {
        let id = UUID()
        let drawing = ChartDrawing(id: id, geometry: .horizontal(price: 42))
        var deletedID: UUID?
        let controller = ChartAnnotationController()
        let configuration = makeConfiguration(controller: controller, drawing: drawing) { deletedID = $0 }
        controller.attach(configuration, visibleDrawingIDs: [id])

        controller.selectDrawing(id)
        #expect(controller.canDeleteSelected)
        #expect(controller.deleteSelected())
        #expect(deletedID == id)
        #expect(controller.selectedDrawingID == nil)
        #expect(!controller.canDeleteSelected)
    }

    @Test("A stale or out-of-scope drawing selection cannot be deleted")
    func ignoresInvisibleDrawingSelection() {
        let id = UUID()
        let drawing = ChartDrawing(id: id, geometry: .horizontal(price: 42))
        var deleteCount = 0
        let controller = ChartAnnotationController()
        let configuration = makeConfiguration(controller: controller, drawing: drawing) { _ in deleteCount += 1 }
        controller.attach(configuration, visibleDrawingIDs: [])

        controller.selectDrawing(id)
        #expect(!controller.canDeleteSelected)
        #expect(!controller.deleteSelected())
        #expect(deleteCount == 0)
    }

    @Test("A selected temporary measurement can be deleted and cleared independently")
    func deleteSelectedMeasurement() {
        let controller = ChartAnnotationController()
        let id = UUID()
        let drawing = ChartDrawing(id: id, geometry: .horizontal(price: 42))
        let configuration = makeConfiguration(controller: controller, drawing: drawing) { _ in }
        controller.attach(configuration, visibleDrawingIDs: [id])
        controller.selectDrawing(id)
        controller.setMeasurementAvailable(true)
        controller.selectMeasurement()

        #expect(controller.hasMeasurement)
        #expect(controller.isMeasurementSelected)
        #expect(controller.selectedDrawingID == nil)
        #expect(controller.canDeleteSelected)
        #expect(controller.deleteSelected())
        #expect(!controller.hasMeasurement)
        #expect(!controller.isMeasurementSelected)
        #expect(!controller.canDeleteSelected)
    }

    @Test("Clearing measurement does not discard drawing selection or reset pending state")
    func clearMeasurementPreservesDrawingSelection() {
        let controller = ChartAnnotationController()
        let id = UUID()
        let drawing = ChartDrawing(id: id, geometry: .horizontal(price: 42))
        let configuration = makeConfiguration(controller: controller, drawing: drawing) { _ in }
        controller.attach(configuration, visibleDrawingIDs: [id])
        controller.selectDrawing(id)
        controller.setMeasurementAvailable(true)
        controller.beginInteraction()
        let resetID = controller.transientResetID

        controller.clearMeasurement()

        #expect(controller.selectedDrawingID == id)
        #expect(!controller.hasMeasurement)
        #expect(controller.measurementClearID == 1)
        #expect(controller.transientResetID == resetID)
        #expect(controller.isInteracting)
    }

    @Test("Reset clears plan focus and temporary measurement selection")
    func resetTransientState() {
        let controller = ChartAnnotationController()
        controller.focusedPlanPrice = 18.5
        controller.setMeasurementAvailable(true)
        controller.selectMeasurement()

        controller.resetTransientState()

        #expect(controller.focusedPlanPrice == nil)
        #expect(!controller.hasMeasurement)
        #expect(!controller.isMeasurementSelected)
    }

    private func makeConfiguration(
        controller: ChartAnnotationController,
        drawing: ChartDrawing,
        onDelete: @escaping @MainActor (UUID) -> Void
    ) -> ChartAnnotationConfiguration {
        ChartAnnotationConfiguration(
            controller: controller,
            drawings: [drawing],
            plans: [],
            currentPrice: nil,
            scope: .all,
            currencyCode: nil,
            onUpsert: { _ in },
            onDelete: onDelete,
            onEditDrawing: { _ in },
            onEditPlan: { _ in }
        )
    }
}
