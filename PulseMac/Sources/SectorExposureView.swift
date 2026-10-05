import SwiftUI
import PulseCore
import PulseUI

struct SectorExposureView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var onlyPositions = true
    @State private var sectorDrafts: [SymbolID: String] = [:]
    @State private var limitDrafts: [String: String] = [:]
    @State private var error: String?
    /// The account open when this sheet loaded. Its drafts are typed against one
    /// ledger, and the sector limit store can be re-pointed while it is up.
    @State private var frozenAccount: BrokerageAccountID?

    /// Non-nil only when the store still holds the ledger these drafts came
    /// from.
    private var accountMatchesDraft: Bool {
        frozenAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    /// The account this sheet's writes are destined for.
    private var draftAccount: BrokerageAccountID {
        frozenAccount ?? appState.watchlist.activeBrokerageAccountID
    }

    private var items: [WatchItem] {
        appState.watchlist.allItems.filter { $0.supportsPosition && (!onlyPositions || $0.hasPosition) }
    }
    private var allocation: PortfolioAllocation.Result {
        PortfolioAllocation.calculate(positions: appState.watchlist.allItems.map { item in
            .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                  price: appState.market.quote(for: item.symbol)?.price,
                  currencyCode: item.symbol.currencyCode, supportsPosition: item.supportsPosition)
        })
    }
    private var sectors: [SectorExposure] {
        SectorExposure.make(allocation: allocation, sectors: Dictionary(uniqueKeysWithValues:
            appState.watchlist.allItems.map { ($0.symbol, $0.tradingProfile?.sector ?? "") }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("板块暴露").font(.system(size: 23, weight: .semibold))
                    Text("按你填写的板块合并个股与 ETF，分币种统计绝对市值")
                        .font(.caption).foregroundStyle(.secondary)
                    // Classification and limits are written into one account's
                    // record; naming it is what stops a sheet left open across a
                    // switch from labeling the new account's instruments.
                    HStack(spacing: 5) {
                        Circle().fill(AccountIdentity.dotColor(draftAccount)).frame(width: 5, height: 5)
                        Text("记入账号：\(AccountIdentity.title(draftAccount))")
                            .font(.caption)
                            .foregroundStyle(accountMatchesDraft
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sectors.isEmpty { Text("暂无可计价持仓").foregroundStyle(.secondary) }
                    ForEach(sectors) { sector in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(sector.name).font(.headline)
                                Text(sector.currencyCode).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f%%", sector.percent)).font(.headline.monospacedDigit())
                                    .foregroundStyle(isOver(sector) ? Color.orange : .primary)
                            }
                            ProgressView(value: min(100, sector.percent), total: 100).tint(isOver(sector) ? .orange : .accentColor)
                            HStack {
                                Text(PriceFormatter.money(sector.exposure, currencyCode: sector.currencyCode)).font(.caption.monospacedDigit())
                                Text("\(sector.holdings.count) 个持仓").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("提醒上限").font(.caption)
                                TextField("不设", text: limitBinding(sector))
                                    .textFieldStyle(.roundedBorder).frame(width: 60)
                                    .accessibilityLabel("\(sector.currencyCode) \(sector.name) 提醒上限")
                                Text("%").font(.caption)
                                Button("保存上限") { saveLimit(sector) }.controlSize(.small)
                            }
                            Text(sector.holdings.map(\.name).joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Divider()
                    HStack {
                        Text("标的分类").font(.headline)
                        Spacer()
                        Toggle("仅持仓", isOn: $onlyPositions).toggleStyle(.checkbox).font(.caption)
                    }
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.resolvedDisplayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(item.symbol.displayCode).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }.frame(width: 205, alignment: .leading)
                            TextField("例如：半导体、新能源", text: sectorBinding(item))
                                .textFieldStyle(.roundedBorder).accessibilityLabel("\(item.resolvedDisplayName) 板块")
                            Button("保存") { saveSector(item) }.controlSize(.small)
                        }
                    }
                }
            }
            Toggle("板块超限时发送系统通知", isOn: Binding(
                get: { appState.planAlerts.sectorEnabled },
                set: { value in Task { await appState.planAlerts.setSectorEnabled(value) } }
            )).font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("不含现金；未分类仍计入总敞口。缺报价未计入 \(allocation.excludedMissingQuoteCount) 项。ETF 按手动标签整体归类，不穿透成分；上限按证券账号保存并随账本同步；每个账号的同一板块及上限每天最多通知一次。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 650, idealWidth: 700, minHeight: 460, idealHeight: 630)
            .onAppear {
                if frozenAccount == nil { frozenAccount = appState.watchlist.activeBrokerageAccountID }
            }
            // The drafts describe the previous account's instruments. Nothing is
            // re-pointed: they are dropped, and the sheet reloads from the
            // ledger now selected.
            .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, newID in
                guard newID != frozenAccount else { return }
                // Still open over the new ledger: the drafts describe the
                // previous account's instruments. Nothing is re-pointed; they
                // are dropped, and the account this sheet writes into is frozen
                // from the one now selected.
                frozenAccount = newID
                sectorDrafts = [:]
                limitDrafts = [:]
                error = nil
            }
    }
    private func isOver(_ sector: SectorExposure) -> Bool {
        appState.sectorLimits.limits[sector.id].map { sector.percent > $0 } ?? false
    }
    private func sectorBinding(_ item: WatchItem) -> Binding<String> {
        Binding(get: { sectorDrafts[item.symbol] ?? item.tradingProfile?.sector ?? "" },
                set: { sectorDrafts[item.symbol] = $0 })
    }
    private func limitBinding(_ sector: SectorExposure) -> Binding<String> {
        Binding(get: { limitDrafts[sector.id] ?? appState.sectorLimits.limits[sector.id].map { String(format: "%g", $0) } ?? "" },
                set: { limitDrafts[sector.id] = $0 })
    }
    private func saveSector(_ item: WatchItem) {
        guard accountMatchesDraft else {
            error = "当前账号已切换，分类不会写入其他账号。请关闭后重新打开。"
            return
        }
        var profile = item.tradingProfile ?? TradingProfile()
        profile.sector = sectorBinding(item).wrappedValue
        if appState.watchlist.setTradingProfile(profile, for: item.symbol) { error = nil }
        else { error = "分类保存失败，请检查标的和输入。" }
    }
    private func saveLimit(_ sector: SectorExposure) {
        guard accountMatchesDraft else {
            error = "当前账号已切换，上限不会写入其他账号。请关闭后重新打开。"
            return
        }
        let raw = limitBinding(sector).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty && Double(raw) == nil { error = "上限请输入 0 到 100 之间的正数，留空表示不设。"; return }
        if appState.sectorLimits.setLimit(raw.isEmpty ? nil : Double(raw), for: sector.id) { error = nil }
        else { error = "上限请输入 0 到 100 之间的正数，留空表示不设。" }
    }
}
