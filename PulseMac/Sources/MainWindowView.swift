import SwiftUI
import PulseCore

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedSymbol: SymbolID?
    @State private var route: PopoverRoute?
    @State private var refreshGeneration = 0
    @AppStorage("pulse.mainWindow.selectedSymbol.v1") private var selectedSymbolStorage = ""

    var body: some View {
        HStack(spacing: 0) {
            MainWatchlistSidebar(selectedSymbol: sidebarSelection, onShowPlans: { route = .planList })
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
                        route = nil
                    } label: {
                        Label(PulseLocalization.localizedString("main.dashboard"), systemImage: "chart.xyaxis.line")
                    }
                    Divider()
                    Button {
                        route = .settings
                    } label: {
                        Label(PulseLocalization.localizedString("main.settings"), systemImage: "gearshape")
                    }
                    Button {
                        route = .dataSettings
                    } label: {
                        Label(PulseLocalization.localizedString("main.data"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
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
            PlanListView(route: routeBinding)
        case .some(.plan(let symbol, let planID, let returnRoute)):
            PlanEditorView(
                symbol: symbol,
                planID: planID,
                returnRoute: returnRoute,
                route: routeBinding
            )
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
                    selectedSymbol = symbol
                    storeSelectedSymbol(symbol)
                    route = nil
                case .list:
                    route = nil
                default:
                    route = newRoute
                }
            }
        )
    }

    private var sidebarSelection: Binding<SymbolID?> {
        Binding(
            get: { selectedSymbol },
            set: { symbol in
                selectedSymbol = symbol
                route = nil
            }
        )
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
