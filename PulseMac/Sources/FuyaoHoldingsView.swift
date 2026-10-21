import SwiftUI
import PulseCore
import PulseUI

struct FuyaoSingleFundView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    private var controller: FuyaoHoldingsController { appState.research.holdings }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("披露持仓穿透").font(.system(size: 12, weight: .semibold))
                Spacer()
                if controller.loading.contains(symbol) { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await controller.load(symbol, force: true) } }.controlSize(.small)
                    .disabled(controller.loading.contains(symbol))
            }
            if let report = controller.reports[symbol] { FuyaoFundDisclosureContent(report: report) }
            else if !controller.loading.contains(symbol) { Text("来源尚未返回可用的股票持仓披露。").font(.caption).foregroundStyle(.secondary) }
            if let error = controller.errors[symbol] { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.task(id: "\(symbol.description)-\(appState.research.generation)") {
            await controller.load(symbol)
        }
    }
}

struct FuyaoFundDisclosureContent: View {
    let report: FuyaoFundHoldings
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("报告期 \(ResearchFormat.day(report.report.endDate)) · \(report.report.reportTypeName ?? report.report.reportType)")
                Spacer()
                Text("获取 \(ResearchFormat.time(report.fetchedAt))")
            }.font(.caption2).foregroundStyle(.secondary)
            Text("已披露股票权重 \(report.disclosedWeightPercent.map { String(format: "%.2f%%", $0) } ?? "不可估算") · \(report.holdings.count) 只")
                .font(.system(size: 11, weight: .medium))
            Text("按定期披露估算，不代表实时持仓；未披露部分保留未知。")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(report.holdings.sorted { ($0.weightPercent ?? -1) > ($1.weightPercent ?? -1) }) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                        Text(row.thscode + (row.thscode.contains(".") ? "" : " · 市场待确认")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.weightPercent.map { String(format: "%.2f%%", $0) } ?? "权重未知").monospacedDigit()
                }.font(.system(size: 11)).padding(.vertical, 3)
                Divider().opacity(0.4)
            }
        }
    }
}

struct FuyaoPortfolioLookThroughView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var onlyOverlap = true
    private var controller: FuyaoHoldingsController { appState.research.holdings }
    private var items: [WatchItem] { appState.watchlist.allItems.filter { $0.supportsPosition && $0.positionQuantity != 0 } }
    private var allocation: PortfolioAllocation.Result {
        PortfolioAllocation.calculate(positions: items.map { item in
            .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                price: appState.market.quote(for: item.symbol)?.price,
                currencyCode: appState.market.quote(for: item.symbol)?.currencyCode ?? item.symbol.currencyCode,
                supportsPosition: item.supportsPosition)
        })
    }
    private var types: [SymbolID: InstrumentType] {
        var types = controller.types
        for item in items where types[item.symbol] == nil && item.symbol.market != .sh && item.symbol.market != .sz {
            types[item.symbol] = item.resolvedInstrumentType
        }
        return types
    }
    private var result: [FuyaoLookThrough.Currency] {
        FuyaoLookThrough.calculate(allocation: allocation, types: types, reports: controller.reports)
    }
    private var key: String {
        appState.watchlist.activeBrokerageAccountID.rawValue + "|" + items.map { $0.symbol.description }.sorted().joined(separator: ",")
            + "|\(appState.fuyaoResearchAvailable)|\(appState.research.generation)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ETF 持仓穿透").font(.title2.bold())
                    Text("\(AccountIdentity.title(appState.watchlist.activeBrokerageAccountID)) · 按最近披露估算多头市值，分币种展示")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !controller.loading.isEmpty { ProgressView().controlSize(.small) }
                Button("刷新披露") { Task { await load(force: true) } }.disabled(!controller.loading.isEmpty || !appState.fuyaoResearchAvailable)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !appState.fuyaoResearchAvailable {
                ContentUnavailableView("请连接同花顺扶摇", systemImage: "network", description: Text("连接并启用后，可查看基金披露持仓与重合敞口。"))
            } else {
                Toggle("只看重合持仓", isOn: $onlyOverlap).toggleStyle(.checkbox).font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(result) { currency in FuyaoLookThroughContent(currency: currency, onlyOverlap: onlyOverlap) }
                        if result.isEmpty { Text("当前账户暂无可按行情估值的多头持仓。").foregroundStyle(.secondary) }
                        ForEach(items) { item in
                            if let error = controller.errors[item.symbol] {
                                Text("\(item.resolvedDisplayName)：\(error)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("缺少报价的持仓 \(allocation.excludedMissingQuoteCount) 项未计入分母；现金不在分母。空头另列，不与多头抵消。披露时点可能不同；未经确认的海外代码别名不合并。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(22).frame(minWidth: 700, idealWidth: 850, minHeight: 500, idealHeight: 680)
            .task(id: key) { await load() }
    }
    private func load(force: Bool = false) async {
        guard appState.fuyaoResearchAvailable else { return }
        let account = appState.watchlist.activeBrokerageAccountID
        for item in items {
            guard !Task.isCancelled, account == appState.watchlist.activeBrokerageAccountID else { return }
            await controller.load(item.symbol, knownType: item.resolvedInstrumentType, force: force)
        }
    }
}

struct FuyaoLookThroughContent: View {
    let currency: FuyaoLookThrough.Currency
    var onlyOverlap = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(currency.code).font(.headline); Spacer(); Text("多头市值 \(money(currency.totalLongExposure))").font(.caption.monospacedDigit()) }
            Text("未穿透 / 未覆盖 \(money(currency.unresolvedAmount))（\(String(format: "%.1f%%", currency.unresolvedAmount / currency.totalLongExposure * 100))）")
                .font(.caption).foregroundStyle(.secondary)
            if currency.excludedShortExposure > 0 { Text("另有空头敞口 \(money(currency.excludedShortExposure))，未参与本页多头估算").font(.caption).foregroundStyle(.secondary) }
            ForEach(currency.funds) { fund in
                HStack {
                    Text(fund.name)
                    Text(fund.reportEnd.map { "报告期 " + ResearchFormat.day($0) } ?? "未取得披露")
                    Spacer()
                    Text("覆盖 \(fund.disclosedPercent.map { String(format: "%.1f%%", $0) } ?? "未知")")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            let rows = currency.exposures.filter { !onlyOverlap || $0.overlaps }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.name).fontWeight(.medium)
                        Text(row.thscode).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(row.amount)).monospacedDigit()
                        Text(String(format: "%.2f%%", row.percent)).monospacedDigit().frame(width: 66, alignment: .trailing)
                    }.font(.system(size: 12))
                    ForEach(row.components) { component in
                        HStack { Text(component.sourceName); Spacer(); Text(money(component.amount)).monospacedDigit() }
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
                Divider().opacity(0.4)
            }
            if rows.isEmpty { Text("当前已覆盖数据中没有重合持仓。").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func money(_ value: Double) -> String { PriceFormatter.money(value, currencyCode: currency.code) }
}
