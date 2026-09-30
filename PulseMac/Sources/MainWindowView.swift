import SwiftUI
import PulseCore

struct MainWindowView: View {
    private enum Overview: Hashable {
        case holdings
        case plans
    }

    @Environment(AppState.self) private var appState
    @State private var selectedSymbol: SymbolID?
    @State private var route: PopoverRoute?
    @State private var overview: Overview?
    @State private var refreshGeneration = 0
    @AppStorage("pulse.mainWindow.selectedSymbol.v1") private var selectedSymbolStorage = ""

    var body: some View {
        HStack(spacing: 0) {
            MainWatchlistSidebar(
                selectedSymbol: sidebarSelection,
                onShowHoldings: { showOverview(.holdings) },
                onShowPlans: { showOverview(.plans) }
            )
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .environment(\.pulseHost, .mainWindow)
        .environment(\.mainRefreshGeneration, refreshGeneration)
        .frame(minWidth: 960, minHeight: 680)
        .onAppear { restoreSelectedSymbol() }
        .onChange(of: selectedSymbol) { _, symbol in
            storeSelectedSymbol(symbol)
            if symbol != nil { route = nil }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.engine.poke()
                    refreshGeneration &+= 1
                } label: {
                    Label(PulseLocalization.localizedString("action.refreshNow"), systemImage: "arrow.clockwise")
                }
                .help(PulseLocalization.localizedString("action.refreshNow"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        overview = nil
                        route = nil
                    } label: {
                        Label(PulseLocalization.localizedString("main.dashboard"), systemImage: "chart.xyaxis.line")
                    }
                    Divider()
                    Button {
                        overview = nil
                        route = .settings
                    } label: {
                        Label(PulseLocalization.localizedString("main.settings"), systemImage: "gearshape")
                    }
                    Button {
                        overview = nil
                        route = .dataSettings
                    } label: {
                        Label(PulseLocalization.localizedString("main.data"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        overview = nil
                        route = .appearanceSettings
                    } label: {
                        Label(PulseLocalization.localizedString("settings.section.appearance"), systemImage: "paintpalette")
                    }
                } label: {
                    Label(PulseLocalization.localizedString("main.settings"), systemImage: "gearshape")
                }
                .menuIndicator(.hidden)
            }
        }
    }

    @ViewBuilder private var detailContent: some View {
        if case .some(.plan(let symbol, let planID, let returnRoute)) = route {
            PlanEditorView(
                symbol: symbol,
                planID: planID,
                returnRoute: returnRoute,
                route: routeBinding
            )
        } else if overview == .holdings {
            MainHoldingsView(onSelect: selectSymbol)
        } else if overview == .plans {
            MainPlanListView(route: routeBinding)
        } else {
            routedDetailContent
        }
    }

    @ViewBuilder private var routedDetailContent: some View {
        switch route {
        case .some(.settings):
            SettingsView(route: routeBinding)
        case .some(.dataSettings):
            DataSettingsView(route: routeBinding)
        case .some(.appearanceSettings):
            AppearanceSettingsView(route: routeBinding)
        case .some(.providerList(let kind)):
            ProviderListView(kind: kind, route: routeBinding)
        case .some(.providerDetail(let id)):
            if let descriptor = appState.providerDescriptors.first(where: { $0.id == id }) {
                ProviderDetailView(descriptor: descriptor, route: routeBinding)
            } else {
                emptyDetail
            }
        case .some(.mcpSettings):
            MCPSettingsView(route: routeBinding)
        case .some(.planList):
            MainPlanListView(route: routeBinding)
        case .some, .none:
            if let selectedSymbol {
                MainInstrumentView(symbol: selectedSymbol)
            } else {
                emptyDetail
            }
        }
    }

    private var routeBinding: Binding<PopoverRoute> {
        Binding(
            get: { route ?? .settings },
            set: { newRoute in
                switch newRoute {
                case .detail(let symbol):
                    selectSymbol(symbol)
                case .planList:
                    overview = .plans
                    route = nil
                case .plan:
                    overview = .plans
                    route = newRoute
                case .list:
                    overview = nil
                    route = nil
                default:
                    overview = nil
                    route = newRoute
                }
            }
        )
    }

    private var sidebarSelection: Binding<SymbolID?> {
        Binding(
            get: { selectedSymbol },
            set: { symbol in
                if let symbol { selectSymbol(symbol) }
                else { overview = nil; route = nil }
            }
        )
    }

    private func selectSymbol(_ symbol: SymbolID) {
        selectedSymbol = symbol
        storeSelectedSymbol(symbol)
        overview = nil
        route = nil
    }

    private func showOverview(_ value: Overview) {
        overview = value
        route = nil
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(PulseLocalization.localizedString("main.empty.selection"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restoreSelectedSymbol() {
        guard !selectedSymbolStorage.isEmpty,
              let data = Data(base64Encoded: selectedSymbolStorage),
              let symbol = try? JSONDecoder().decode(SymbolID.self, from: data) else {
            selectedSymbol = appState.watchlist.items.first?.symbol
            return
        }
        selectedSymbol = symbol
    }

    private func storeSelectedSymbol(_ symbol: SymbolID?) {
        guard let symbol, let data = try? JSONEncoder().encode(symbol) else {
            selectedSymbolStorage = ""
            return
        }
        selectedSymbolStorage = data.base64EncodedString()
    }
}

struct PulseCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(PulseLocalization.localizedString("main.openWindow")) {
                openWindow(id: MainWindow.id)
                MainWindow.activate()
            }
            .keyboardShortcut("1", modifiers: .command)
        }
    }
}
