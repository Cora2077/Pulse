import SwiftUI
import PulseCore

struct FuyaoCapturedContextView: View {
    @Environment(AppState.self) private var appState
    let key: FuyaoContextKey
    var body: some View {
        DisclosureGroup("记录时的市场背景 · 本机留存") {
            FuyaoCapturedContextContent(context: appState.marketContexts.context(for: key))
                .padding(.top, 7)
        }.font(.system(size: 12, weight: .medium))
    }
}
struct FuyaoCapturedContextContent: View {
    let context: FuyaoMarketContext?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context {
                Text("留存 \(ResearchFormat.fullTime(context.capturedAt)) · 以下为记录时已获取的数据")
                    .font(.caption2).foregroundStyle(.secondary)
                if let statistics = context.statistics {
                    Text("盘面 \(ResearchFormat.day(statistics.value.tradeDate))：涨停 \(statistics.value.limitUp.map(String.init) ?? "未知") 家，封板率 \(statistics.value.sealRate.map { String(format: "%.1f%%", $0 * 100) } ?? "未知")")
                        .font(.caption)
                }
                if let heat = context.hotStock {
                    Text("24 小时热榜 第 \(heat.rank) 名 · 数据 \(context.hotDataTime.map(ResearchFormat.time) ?? "时间未知")").font(.caption)
                }
                ForEach(context.boards, id: \.thscode) { board in
                    Text("\(board.name)：近 5 日相对沪深 300 \(board.strength.fiveDay.map { String(format: "%+.2f 个百分点", $0) } ?? "数据不足") · 锚点 \(board.strength.dataTime.map(ResearchFormat.day) ?? "未知")")
                        .font(.caption)
                }
                ForEach(context.anomalies?.value ?? [], id: \.text) { row in
                    Text("同花顺解读：" + row.text).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(context.news?.value ?? []) { news in
                    VStack(alignment: .leading, spacing: 3) {
                        if let url = news.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { Link(news.title, destination: url).font(.caption) }
                        else { Text(news.title).font(.caption) }
                        Text("\(news.source ?? "来源未知") · \(news.publishedAt.map(ResearchFormat.time) ?? "发布时间未知")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !context.hasData { Text("留存时没有可用研究缓存，未补入后续数据。").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("本机未留存此记录的市场背景。旧记录、补录的历史成交及其他设备的记录不会用当前盘面补造。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("本机最多保留最近 1000 条研究背景，暂不随账本同步或备份；来源解读保留原意，不代表确定因果。")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
