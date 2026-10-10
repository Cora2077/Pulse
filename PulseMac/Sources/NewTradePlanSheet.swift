import SwiftUI
import PulseCore
import PulseUI

/// Keeps instrument selection and the existing editor in one local sheet.
struct NewTradePlanSheet: View {
    let account: BrokerageAccountID
    let onCreated: (TradePlan) -> Void
    let onClose: () -> Void
    @State private var selection: SymbolInfo?
    @State private var route: PopoverRoute

    init(account: BrokerageAccountID, initialSymbol: SymbolInfo? = nil,
         onCreated: @escaping (TradePlan) -> Void, onClose: @escaping () -> Void) {
        self.account = account
        self.onCreated = onCreated
        self.onClose = onClose
        _selection = State(initialValue: initialSymbol)
        _route = State(initialValue: initialSymbol.map { .plan($0.symbol, nil, .planList) } ?? .list)
    }

    var body: some View {
        Group {
            if let selection {
                PlanEditorView(symbol: selection.symbol, planID: nil, returnRoute: .planList,
                               route: $route, account: account, newSymbolInfo: selection,
                               onSaved: onCreated)
            } else {
                PlanSymbolChooser(account: account, onSelect: { info in
                    route = .plan(info.symbol, nil, .planList)
                    selection = info
                }, onCancel: onClose)
            }
        }
        .frame(width: 520, height: 560)
        .onChange(of: route) { _, value in
            if value == .planList { onClose() }
        }
    }
}

private struct PlanSymbolChooser: View {
    let account: BrokerageAccountID
    let onSelect: (SymbolInfo) -> Void
    let onCancel: () -> Void
    @Environment(AppState.self) private var appState
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var remoteResults: [SymbolInfo] = []
    @State private var remoteQuery = ""
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var retryToken = 0

    private struct SearchRequest: Equatable {
        let query: String
        let retry: Int
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var accountMatches: Bool { appState.watchlist.activeBrokerageAccountID == account }

    private var rows: [SymbolInfo] {
        let needle = normalizedQuery
        var seen = Set<SymbolID>()
        let local = appState.sharedWatchlist.items.filter { item in
            item.supportsPosition && (needle.isEmpty
                || item.resolvedDisplayName.localizedCaseInsensitiveContains(needle)
                || item.symbol.displayCode.localizedCaseInsensitiveContains(needle))
        }.map { item in
            SymbolInfo(symbol: item.symbol, name: item.resolvedDisplayName,
                       type: item.resolvedInstrumentType ?? .equity,
                       displayNameSource: item.displayNameSource)
        }
        let remote = !needle.isEmpty && remoteQuery == needle ? remoteResults : []
        return (local + remote).filter { info in
            WatchItem(symbol: info.symbol, displayName: info.name,
                      instrumentType: info.type).supportsPosition && seen.insert(info.symbol).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PulseLocalization.localizedString("plan.newPlan"))
                    .font(.system(size: 17, weight: .semibold))
                Text(PulseLocalization.localizedString("plan.new.account", AccountIdentity.title(account)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            AccountDraftNotice(account: account).padding(.horizontal, 16)
            searchField
                .padding(.horizontal, 16).padding(.bottom, 10)
            if rows.isEmpty {
                Text(PulseLocalization.localizedString(
                    normalizedQuery.isEmpty ? "plan.new.empty" : "plan.new.noMatches"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { info in symbolRow(info) }
                    }
                    .padding(.horizontal, 10)
                }
            }
            if let searchError {
                HStack(spacing: 8) {
                    Text(PulseLocalization.localizedString("plan.new.searchError", searchError))
                        .foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(PulseLocalization.localizedString("main.search.retry")) { retryToken += 1 }
                }
                .font(.caption).controlSize(.small).padding(.horizontal, 16).padding(.top, 8)
            }
            HStack {
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .onAppear { searchFocused = true }
        .task(id: SearchRequest(query: normalizedQuery, retry: retryToken)) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(PulseLocalization.localizedString("main.search.placeholder"), text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel(PulseLocalization.localizedString("main.search.placeholder"))
            if isSearching { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 12)).padding(9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private func symbolRow(_ info: SymbolInfo) -> some View {
        Button { onSelect(info) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.resolvedDisplayName).font(.system(size: 13)).lineLimit(1)
                    Text("\(info.symbol.displayCode) · \(info.symbol.market.rawValue.uppercased())")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.pressable).disabled(!accountMatches)
    }

    private func search() async {
        let needle = normalizedQuery
        remoteResults = []
        remoteQuery = ""
        searchError = nil
        isSearching = !needle.isEmpty
        guard !needle.isEmpty else { return }
        defer { if !Task.isCancelled, needle == normalizedQuery { isSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(280))
            try Task.checkCancellation()
            let results = try await appState.search(needle)
            try Task.checkCancellation()
            guard needle == normalizedQuery else { return }
            remoteResults = results
            remoteQuery = needle
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, needle == normalizedQuery else { return }
            searchError = error.localizedDescription
        }
    }
}
