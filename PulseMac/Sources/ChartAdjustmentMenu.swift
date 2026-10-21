import SwiftUI
import PulseCore

struct ChartAdjustmentMenu: View {
    @Binding var adjustment: CandleAdjustment
    var body: some View {
        Menu {
            Picker("价格口径", selection: $adjustment) {
                Text("前复权").tag(CandleAdjustment.forward)
                Text("不复权").tag(CandleAdjustment.none)
            }
        } label: {
            Text(adjustment == .forward ? "前复权" : "不复权")
                .font(.system(size: 9, weight: .medium))
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("前复权消除分红送转造成的价格断层；不复权保留历史实际成交价格。")
        .accessibilityLabel("价格口径")
    }
}
