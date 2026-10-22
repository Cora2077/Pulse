import SwiftUI
import PulseCore

struct FuyaoIntelligenceView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID

    private var state: FuyaoResearchController.Intelligence {
        appState.research.intelligence[symbol] ?? .init()
    }
    private var supportedMarket: Bool {
        (symbol.market == .sh || symbol.market == .sz) && symbol.sectorIndex == nil && symbol.indexID == nil
    }
    private var requestKey: String {
        "\(symbol.description)|\(appState.fuyaoResearchAvailable)|\(appState.research.generation)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !supportedMarket {
                    empty("个股情报目前支持沪深 A 股。")
                } else if !appState.fuyaoResearchAvailable {
                    empty("在设置中连接并启用同花顺扶摇后，可查看个股新闻、异动解读和热榜。")
                } else {
                    if state.type == .etf || state.type == .fund {
                        FuyaoSingleFundView(symbol: symbol)
                    } else {
                        FuyaoIntelligenceContent(state: state) {
                            Task { await appState.research.loadIntelligence(symbol, force: true) }
                        }
                        if state.type == .equity {
                            Divider()
                            FuyaoCorporateActionsView(symbol: symbol)
                            Divider()
                            FuyaoFinancialsView(symbol: symbol)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: requestKey) {
            guard supportedMarket, appState.fuyaoResearchAvailable else { return }
            while !Task.isCancelled {
                await appState.research.loadIntelligence(symbol)
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The same content renders in the live page and the isolated native harness.
struct FuyaoIntelligenceContent: View {
    let state: FuyaoResearchController.Intelligence
    var onRefresh: () -> Void = {}
    @State private var expandedNews: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let type = state.type, type != .equity {
                empty("当前标的不是 A 股股票，个股新闻与热榜暂不适用。")
            } else {
                rankSection
                anomalySection
                newsSection
            }
            ForEach(state.errors.keys.sorted(), id: \.self) { key in
                Label("\(key)：\(state.errors[key] ?? "获取失败")", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Label("个股情报", systemImage: "newspaper").font(.system(size: 12, weight: .semibold))
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
            if let time = state.attemptedAt {
                Text("获取于 \(Self.time(time))").font(.caption2).foregroundStyle(.secondary)
            }
            Button("刷新", action: onRefresh)
                .controlSize(.small).disabled(state.loading)
        }
    }

    @ViewBuilder private var rankSection: some View {
        if let hot = state.hotStock {
            HStack(spacing: 10) {
                Label("24 小时热榜 第 \(hot.rank) 名", systemImage: "flame")
                    .font(.system(size: 11, weight: .medium))
                if let change = hot.rankChange, change != 0 {
                    Text("\(change > 0 ? "上升" : "下降") \(abs(change)) 名")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let time = state.hotListTime { sourceTime(time) }
            }
        } else if state.hotListLoaded {
            Text("本次热榜前 100 名未出现；不代表没有市场关注。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let ranks = state.ranking, !ranks.value.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(Array(ranks.value.suffix(7).enumerated()), id: \.offset) { _, point in
                        VStack(spacing: 3) {
                            Text("\(point.rank)").monospacedDigit().fontWeight(.medium)
                            Text(Self.day(point.date))
                                .foregroundStyle(.secondary)
                        }.font(.caption2)
                    }
                }
            }
            Text("近期每日热榜排名，越小越靠前；日期按北京时间。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var anomalySection: some View {
        if let batch = state.anomalies {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("同花顺异动解读").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if let time = batch.dataTime { sourceTime(time) }
                }
                if batch.value.isEmpty {
                    Text("来源当前没有该股票的异动解读。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(batch.value.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        if !row.tag.isEmpty { Text(row.tag).font(.caption).fontWeight(.medium) }
                        Text(row.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        if !row.keywords.isEmpty {
                            Text(row.keywords.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !batch.value.isEmpty {
                    Text("以上为来源解读，不代表已证实的涨跌原因。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
        }
    }

    @ViewBuilder private var newsSection: some View {
        if let news = state.news {
            Text("相关新闻").font(.system(size: 11, weight: .semibold))
            if news.value.isEmpty { empty("来源暂未返回相关新闻。") }
            ForEach(news.value, id: \.id) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        if let url = row.url {
                            Link(destination: url) {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text(row.title).multilineTextAlignment(.leading)
                                    Image(systemName: "arrow.up.right").font(.system(size: 8))
                                }
                            }.buttonStyle(.plain)
                        } else { Text(row.title) }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    if let summary = row.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(expandedNews.contains(row.id) ? nil : 2)
                            .onTapGesture {
                                if !expandedNews.insert(row.id).inserted { expandedNews.remove(row.id) }
                            }
                    }
                    HStack(spacing: 8) {
                        Text(row.source?.isEmpty == false ? row.source! : "来源未提供")
                        Text(row.publishedAt.map(Self.time) ?? "发布时间未知")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Divider().opacity(0.5)
            }
        } else if state.loading { empty("正在获取情报…") }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sourceTime(_ date: Date) -> some View {
        Text("数据 \(Self.time(date))").font(.caption2).foregroundStyle(.secondary)
    }
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = shanghai
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = shanghai
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
