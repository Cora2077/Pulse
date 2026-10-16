import SwiftUI
import Observation
import PulseCore
import PulseUI

// MARK: - Workbench root
//
// The whole phone workbench. Everything on screen reads live `IPhoneAppState`
// values; there is not one hard-coded array standing in for application data.
// The root owns only navigation and presentation state — never a ledger write.
//
// Contract notes that shape this file:
// - No `AppKit` anywhere. A sheet is still a UIKit hosting controller, so its
//   background is pinned explicitly instead of relying on a transparent host.
// - Every money figure that could be missing renders as an em dash, never 0.
// - Currencies are never summed across markets without a stated rate.
public struct WorkbenchRootView: View {
    @Environment(IPhoneAppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var route: WorkbenchRoute?
    @State private var isPresentingSettings = false
    @State private var tradeEntry: TradeEntryContext?
    @State private var pendingURLNotice: String?

    // One navigation path per stack, so a route can target the tab that owns it.
    @State private var todayPath: [WorkbenchRoute.Destination] = []
    @State private var watchlistPath: [WorkbenchRoute.Destination] = []
    @State private var plansPath: [WorkbenchRoute.Destination] = []
    @State private var accountPath: [WorkbenchRoute.Destination] = []

    public init() {}

    public var body: some View {
        @Bindable var state = state
        TabView(selection: tabBinding(state)) {
            NavigationStack(path: $todayPath) {
                TodayView(onOpenRoute: push)
                    .workbenchDestinations()
            }
            .workbenchTab("今日", systemImage: "sun.max", tag: 0)

            NavigationStack(path: $watchlistPath) {
                WatchlistView(onOpenRoute: push)
                    .workbenchDestinations()
            }
            .workbenchTab("自选", systemImage: "star", tag: 1)

            NavigationStack(path: $plansPath) {
                PlansView(onOpenRoute: push)
                    .workbenchDestinations()
            }
            .workbenchTab("计划", systemImage: "list.bullet.clipboard", tag: 2)

            NavigationStack(path: $accountPath) {
                AccountView(onOpenRoute: push)
                    .workbenchDestinations()
            }
            .workbenchTab("账户", systemImage: "person.crop.rectangle", tag: 3)
        }
        .tint(WorkbenchTheme.blue)
        // Every page can reach the one global action, which is the whole point of
        // putting "record a trade" here rather than in a fifth tab.
        .sheet(item: $tradeEntry) { context in
            TradeEntryView(context: context, onOpenRoute: push)
        }
        .sheet(isPresented: $isPresentingSettings) {
            SettingsSheet()
        }
        .overlay(alignment: .top) {
            if let message = pendingURLNotice {
                WorkbenchNoticeBanner(text: message) { pendingURLNotice = nil }
            }
        }
        .task { await state.runForegroundPolling() }
        .onChange(of: scenePhase) { _, phase in
            state.isForeground = phase == .active
        }
        .onOpenURL { url in
            guard url.scheme == "fff-pulse" else { return }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.host == "instrument", let key = query.first(where: { $0.name == "symbol" })?.value {
                let matches = state.watchlist.quoteSymbols.filter { $0.description == key }
                guard matches.count == 1, let symbol = matches.first else {
                    pendingURLNotice = "该关注标的已移除或身份不唯一，请从自选中重新打开。"
                    return
                }
                push(WorkbenchRoute(destination: .symbol(symbol), tab: WorkbenchRoute.watchlistTab))
                return
            }
            if url.host == "plans" {
                if let raw = query.first(where: { $0.name == "id" })?.value {
                    guard let id = UUID(uuidString: raw) else { pendingURLNotice = "计划链接无效，未产生任何改动。"; return }
                    push(WorkbenchRoute(destination: .plan(id, WorkbenchRoute.unresolvedSymbolMarker), tab: WorkbenchRoute.planTab))
                } else { state.selectedTab = WorkbenchRoute.planTab; plansPath = [] }
                return
            }
            // Deep links are read, never written. A link may only navigate; it
            // must not be able to produce a ledger entry on its own.
            switch WorkbenchRoute.parse(url) {
            case .some(let parsed):
                push(parsed)
            case .none:
                pendingURLNotice = "无法识别这个链接，已忽略，没有产生任何账本改动。"
            }
        }
        .environment(\.workbenchOpenRoute, push)
        .environment(\.workbenchPresentTradeEntry) { tradeEntry = $0 }
        .environment(\.workbenchOpenSettings) { isPresentingSettings = true }
        .environment(\.workbenchNotice) { pendingURLNotice = $0 }
    }

    /// Sends a route to the stack that owns it, switching tabs first when the
    /// destination lives in another one. A route from Today that names a plan
    /// therefore lands in the Plans stack rather than being pushed onto Today.
    private func push(_ route: WorkbenchRoute) {
        switch route.tab {
        case WorkbenchRoute.watchlistTab: watchlistPath = [route.destination]
        case WorkbenchRoute.planTab: plansPath = [route.destination]
        case WorkbenchRoute.accountTab: accountPath = [route.destination]
        default: todayPath = [route.destination]
        }
        state.selectedTab = route.tab
    }

    /// Tab selection is written through the state so the tab survives a view
    /// rebuild; the binding keeps SwiftUI's `TabView` and `state.selectedTab`
    /// from disagreeing.
    private func tabBinding(_ state: IPhoneAppState) -> Binding<Int> {
        Binding(get: { state.selectedTab }, set: { state.selectedTab = $0 })
    }
}

// MARK: - Tab bar chrome
//
// The v2 preview puts the record action inside a page header, so every page
// carries its own header button. This modifier sets the shared tab appearance
// (opaque bar, thin top hairline, blue selection) in one place.
extension View {
    func workbenchTab(_ title: String, systemImage: String, tag: Int) -> some View {
        self
            .tabItem { Label(title, systemImage: systemImage) }
            .tag(tag)
    }

    /// Registers every pushable destination once per stack. Symbol and plan
    /// detail both resolve through live store lookups when they are shown, so a
    /// deleted record renders a "not found" state instead of a stale copy.
    func workbenchDestinations() -> some View {
        navigationDestination(for: WorkbenchRoute.Destination.self) { destination in
            switch destination {
            case .symbol(let symbol):
                SymbolDetailView(symbol: symbol)
            case .plan(let id, let symbol):
                PlanDetailView(symbol: symbol, planID: id)
            }
        }
    }
}

// MARK: - Routes
//
// A route names both its destination and the tab that owns it, so opening a
// plan from Today lands in the Plans stack instead of pushing onto Today.
struct WorkbenchRoute: Hashable {
    enum Destination: Hashable {
        case symbol(SymbolID)
        case plan(UUID, SymbolID)
    }

    var destination: Destination
    var tab: Int

    static let todayTab = 0
    static let watchlistTab = 1
    static let planTab = 2
    static let accountTab = 3

    /// Parses an inbound URL. Recognition only: no store lookup, no mutation.
    ///
    /// Accepted shapes, matched literally rather than by guesswork:
    /// - `<scheme>://symbol/<market>/<code>`
    /// - `<scheme>://plan/<uuid>` (resolved against the live plan list)
    ///
    /// Anything else returns nil so the caller can say so honestly instead of
    /// silently opening the first item in the list.
    static func parse(_ url: URL) -> WorkbenchRoute? {
        guard let host = url.host()?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "symbol":
            guard components.count == 2,
                  let market = Market(rawValue: components[0].lowercased()) else { return nil }
            return WorkbenchRoute(
                destination: .symbol(SymbolID(market: market, code: components[1])),
                tab: watchlistTab
            )
        case "plan":
            guard let raw = components.first, let id = UUID(uuidString: raw) else { return nil }
            // The URL carries only the plan id. Resolution to a symbol happens
            // in the destination view against the live store; a plan that no
            // longer exists shows "not found" rather than a fabricated record.
            return WorkbenchRoute(destination: .plan(id, unresolvedSymbolMarker), tab: planTab)
        default:
            return nil
        }
    }

    /// A plan route has no symbol until it is resolved. `.unassignedRoutePlaceholder`
    /// is that marker; `PlanDetailView` ignores the symbol for identity and
    /// resolves the real one from `state.planEntries`.
    static var unresolvedSymbolMarker: SymbolID { SymbolID(market: .us, code: "") }
}

// MARK: - Route environment actions

private struct WorkbenchOpenRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (WorkbenchRoute) -> Void = { _ in }
}
private struct WorkbenchPresentTradeEntryKey: EnvironmentKey {
    static let defaultValue: @MainActor (TradeEntryContext) -> Void = { _ in }
}
private struct WorkbenchOpenSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}
private struct WorkbenchNoticeKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var workbenchOpenRoute: @MainActor (WorkbenchRoute) -> Void {
        get { self[WorkbenchOpenRouteKey.self] }
        set { self[WorkbenchOpenRouteKey.self] = newValue }
    }
    var workbenchPresentTradeEntry: @MainActor (TradeEntryContext) -> Void {
        get { self[WorkbenchPresentTradeEntryKey.self] }
        set { self[WorkbenchPresentTradeEntryKey.self] = newValue }
    }
    var workbenchOpenSettings: @MainActor () -> Void {
        get { self[WorkbenchOpenSettingsKey.self] }
        set { self[WorkbenchOpenSettingsKey.self] = newValue }
    }
    var workbenchNotice: @MainActor (String) -> Void {
        get { self[WorkbenchNoticeKey.self] }
        set { self[WorkbenchNoticeKey.self] = newValue }
    }
}

// MARK: - Theme

enum WorkbenchTheme {
    /// The v2 preview's one accent. Follows the system blue rather than a fixed
    /// literal, so it stays legible in both appearances and in Increase Contrast.
    static let blue = Color.accentColor
    /// Up colour, per the Chinese convention the preview uses.
    static let up = ChangePalette.up
    static let down = ChangePalette.down
    static let warning = Color.orange

    /// The one up/down palette for the whole workbench. 红涨绿跌. Screens read
    /// this rather than each building their own, so a quote cannot be red on one
    /// page and green on another.
    static let palette = ChangePalette(redUp: true)

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .secondarySystemBackground)
    }
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        Color(uiColor: .systemBackground)
    }
    static func chipBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
    }
}

// MARK: - Shared formatting

enum WorkbenchFormat {
    /// The honest placeholder for a value we do not have. Used instead of 0
    /// everywhere a price, rate, or total is genuinely unknown.
    static let missing = "—"

    static func quantity(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return PriceFormatter.quantity(value)
    }

    static func price(_ value: Double?, market: Market?) -> String {
        guard let value, value.isFinite else { return missing }
        return PriceFormatter.price(value, market: market)
    }

    static func money(_ value: Double?, currencyCode: String?) -> String {
        guard let value, value.isFinite else { return missing }
        return PriceFormatter.money(value, currencyCode: currencyCode)
    }

    static func signedMoney(_ value: Double?, currencyCode: String?) -> String {
        guard let value, value.isFinite else { return missing }
        return PriceFormatter.signedMoney(value, currencyCode: currencyCode)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return PriceFormatter.percent(value)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func dayTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func currencyName(_ code: String?) -> String {
        guard let code else { return missing }
        switch code {
        case "CNY": return "人民币"
        case "HKD": return "港元"
        case "USD": return "美元"
        case "JPY": return "日元"
        case "KRW": return "韩元"
        default: return code
        }
    }
}

// MARK: - Quote staleness
//
// Staleness is stated, never hidden. A quote older than the freshness window is
// labelled with its real source time so an offline phone cannot look live.
enum QuoteFreshness {
    case live
    case delayed(TimeInterval)
    case stale(TimeInterval)

    static let freshWindow: TimeInterval = 300

    init(_ quote: Quote?, now: Date = .now) {
        guard let quote else { self = .stale(.infinity); return }
        let age = max(0, now.timeIntervalSince(quote.timestamp))
        if age < Self.freshWindow { self = .live }
        else if age < 3_600 { self = .delayed(age) }
        else { self = .stale(age) }
    }

    var label: String? {
        switch self {
        case .live: return nil
        case .delayed(let age): return "延后 \(Int(age / 60)) 分钟"
        case .stale: return "待更新"
        }
    }

    var isActionable: Bool {
        if case .live = self { return true }
        return false
    }
}

// MARK: - Shared components

/// A page title with the one global action on the trailing edge.
///
/// "Record a trade" is reachable from every page, as the design requires. A
/// trade always needs a concrete instrument, so the button opens a short symbol
/// chooser over the items this account already tracks rather than inventing a
/// blank form with no instrument in it.
struct WorkbenchHeader: View {
    let title: String
    var showsTradeEntry = true

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry
    @Environment(\.workbenchOpenSettings) private var openSettings

    @State private var isChoosingSymbol = false
    @State private var manualCode = ""
    @State private var manualMarket: Market = .us
    @State private var manualError: String?

    private var holdableItems: [WatchItem] {
        state.watchlist.items.filter(\.supportsPosition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isDemo {
                Text("模拟器验收 · 合成数据，不是你的账户")
                    .font(.caption2).foregroundStyle(.orange)
            }
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if showsTradeEntry {
                Button {
                    isChoosingSymbol = true
                } label: {
                    Label("记交易", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(WorkbenchTheme.blue.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("记录一笔已经完成的成交")
            }
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        }
        .sheet(isPresented: $isChoosingSymbol) {
            symbolChooser
        }
    }

    private var symbolChooser: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("选择要记录的标的。记成交记录的是已经完成的交易，不会向券商下单。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if holdableItems.isEmpty {
                        WorkbenchEmptyState(
                            icon: "star",
                            title: "这个账户还没有可记录的标的",
                            message: "先到「自选」关注一个标的，或在下面直接输入完整代码。",
                            actionTitle: "去关注标的",
                            action: {
                                isChoosingSymbol = false
                                state.selectedTab = WorkbenchRoute.watchlistTab
                            }
                        )
                    } else {
                        WorkbenchCard(padding: 12) {
                            VStack(spacing: 0) {
                                ForEach(Array(holdableItems.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Divider() }
                                    Button {
                                        present(symbol: item.symbol)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(state.displayName(item.symbol))
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 8)
                                            Text(item.symbol.description)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(minHeight: 42)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    WorkbenchSection(title: "手动输入代码") {
                        WorkbenchCard(padding: 12) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("市场", selection: $manualMarket) {
                                    ForEach(Market.allCases, id: \.self) { market in
                                        Text(market.displayName).tag(market)
                                    }
                                }
                                TextField("完整代码，例如 005930 或 AAPL", text: $manualCode)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.plain)
                                    .font(.subheadline)
                                if let manualError {
                                    Text(manualError)
                                        .font(.caption2)
                                        .foregroundStyle(WorkbenchTheme.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Button("用这个代码记成交") {
                                    let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !code.isEmpty else {
                                        manualError = "请先填写完整代码。"
                                        return
                                    }
                                    manualError = nil
                                    present(symbol: SymbolID(market: manualMarket, code: code))
                                }
                                .font(.subheadline.weight(.medium))
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle("记交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isChoosingSymbol = false }
                }
            }
        }
    }

    private func present(symbol: SymbolID) {
        isChoosingSymbol = false
        presentTradeEntry(.global(symbol: symbol, account: state.accountID))
    }
}

/// The active account, always visible at the top of a transaction surface.
struct ActiveAccountStrip<Accessory: View>: View {
    @Environment(IPhoneAppState.self) private var state
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.text.rectangle")
                .font(.caption2)
                .foregroundStyle(WorkbenchTheme.blue)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension ActiveAccountStrip where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A labelled value row. A `nil` value prints the em dash, so a missing number
/// can never be read as zero.
struct FactRow: View {
    let name: String
    let value: String
    var valueColor: Color = .primary
    var detail: String?
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
    }
}

/// A small tinted capsule for statuses that are not money.
struct WorkbenchTag: View {
    let text: String
    var color: Color = WorkbenchTheme.blue

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A section with a title and an optional trailing action.
struct WorkbenchSection<Content: View>: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(WorkbenchTheme.blue)
                }
            }
            content
        }
    }
}

/// The one card surface used across pages. `insetGrouped` styling is recreated
/// here rather than relying on `Form`, because these cards mix interactive and
/// static rows and must keep the same look inside a sheet.
struct WorkbenchCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WorkbenchTheme.cardBackground(colorScheme))
            )
    }
}

/// An honest empty state: what is missing, and what the user can do about it.
struct WorkbenchEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
    }
}

/// A visibly disabled capability, with the reason stated. Used instead of a
/// button that cannot work, and instead of one that silently does nothing.
struct WorkbenchUnavailableRow: View {
    let title: String
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One stat cell inside a valuation card. Missing input is an em dash.
struct StatCell: View {
    let label: String
    let value: String
    var tone: Color = .primary
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A flip toggle that names both states, because "暂停" and "关闭" are different
/// promises and the label must not blur them.
struct WorkbenchToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var onLabel = "已开启"
    var offLabel = "已关闭"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? onLabel : offLabel)
        }
        .padding(.vertical, 4)
    }
}

struct WorkbenchNoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("知道了", action: dismiss)
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The shared conflict/error dialog. It never offers to discard the draft;
/// closing it leaves the form exactly as the user filled it.
struct WorkbenchErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("未能保存", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func workbenchError(_ message: Binding<String?>) -> some View {
        modifier(WorkbenchErrorAlert(message: message))
    }
}
