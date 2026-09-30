import SwiftUI
import PulseCore
import PulseUI

/// Inline form hosted in the chart pane. Editing never writes while fields are
/// changing; the host commits one complete drawing when Save is pressed.
struct MainChartDrawingEditor: View {
    let drawing: ChartDrawing
    let symbol: SymbolID
    let currencyCode: String?
    let onSave: (ChartDrawing) -> Bool
    let onCancel: () -> Void

    @State private var horizontalPrice: Double
    @State private var startPrice: Double
    @State private var endPrice: Double
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var note: String
    @State private var color: ChartDrawingColor
    @State private var lineWidth: Double
    @State private var isLocked: Bool
    @State private var showsValidation = false

    init(
        drawing: ChartDrawing,
        symbol: SymbolID,
        currencyCode: String?,
        onSave: @escaping (ChartDrawing) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.drawing = drawing
        self.symbol = symbol
        self.currencyCode = currencyCode
        self.onSave = onSave
        self.onCancel = onCancel
        switch drawing.geometry {
        case .horizontal(let price):
            _horizontalPrice = State(initialValue: price)
            _startPrice = State(initialValue: price)
            _endPrice = State(initialValue: price)
            _startTime = State(initialValue: .now)
            _endTime = State(initialValue: .now)
        case .trend(let start, let end):
            _horizontalPrice = State(initialValue: start.price)
            _startPrice = State(initialValue: start.price)
            _endPrice = State(initialValue: end.price)
            _startTime = State(initialValue: start.time)
            _endTime = State(initialValue: end.time)
        }
        _note = State(initialValue: drawing.note ?? "")
        _color = State(initialValue: drawing.style.color)
        _lineWidth = State(initialValue: drawing.style.lineWidth)
        _isLocked = State(initialValue: drawing.isLocked)
    }

    private var isHorizontal: Bool {
        if case .horizontal = drawing.geometry { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(PulseLocalization.localizedString("main.chart.drawingEditor.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(PulseLocalization.localizedString("action.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if isHorizontal {
                        priceField("main.chart.drawingEditor.price", value: $horizontalPrice)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                priceField("main.chart.drawingEditor.startPrice", value: $startPrice)
                                anchorTime("main.chart.drawingEditor.startTime", date: startTime)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                priceField("main.chart.drawingEditor.endPrice", value: $endPrice)
                                anchorTime("main.chart.drawingEditor.endTime", date: endTime)
                            }
                        }
                    }

                    TextField(PulseLocalization.localizedString("main.chart.drawingEditor.note"), text: $note)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 16) {
                        Picker(PulseLocalization.localizedString("main.chart.drawingEditor.color"), selection: $color) {
                            ForEach(ChartDrawingColor.allCases, id: \.self) { option in
                                Text(PulseLocalization.localizedString("main.chart.drawingColor.\(option.rawValue)"))
                                    .tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()

                        HStack(spacing: 6) {
                            Text(PulseLocalization.localizedString("main.chart.drawingEditor.lineWidth"))
                                .foregroundStyle(.secondary)
                            TextField("", value: $lineWidth, format: .number.precision(.fractionLength(1...2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 62)
                        }
                        Toggle(PulseLocalization.localizedString("main.chart.drawingEditor.locked"), isOn: $isLocked)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                    if showsValidation {
                        Text(PulseLocalization.localizedString("main.chart.drawingEditor.saveFailed"))
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func priceField(_ key: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(PulseLocalization.localizedString(key))
                .foregroundStyle(.secondary)
            if let currencyCode {
                Text(currencyCode).foregroundStyle(.tertiary)
            }
            TextField("", value: value, format: .number.precision(.fractionLength(0...8)))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .accessibilityLabel(PulseLocalization.localizedString(key))
        }
    }

    private func anchorTime(_ key: String, date: Date) -> some View {
        HStack(spacing: 8) {
            Text(PulseLocalization.localizedString(key)).foregroundStyle(.secondary)
            Text(marketDateTime(date))
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.system(size: 10))
    }

    private func marketDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.timeZone = symbol.market.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func save() {
        guard lineWidth.isFinite, lineWidth > 0 else { showsValidation = true; return }
        let geometry: ChartDrawingGeometry
        if isHorizontal {
            guard horizontalPrice.isFinite, horizontalPrice > 0 else { showsValidation = true; return }
            geometry = .horizontal(price: horizontalPrice)
        } else {
            guard startPrice.isFinite, startPrice > 0, endPrice.isFinite, endPrice > 0 else {
                showsValidation = true
                return
            }
            let start = ChartAnchor(time: startTime, price: startPrice)
            let end = ChartAnchor(time: endTime, price: endPrice)
            guard start.isValid, end.isValid else { showsValidation = true; return }
            geometry = .trend(start: start, end: end)
        }

        var updated = drawing
        updated.geometry = geometry
        updated.style = ChartDrawingStyle(color: color, lineWidth: lineWidth)
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.isLocked = isLocked
        updated.updatedAt = .now
        guard updated.isValid, onSave(updated) else {
            showsValidation = true
            return
        }
    }
}
