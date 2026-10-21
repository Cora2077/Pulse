import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class FuyaoBoardsController {
    struct Detail {
        var constituents: FuyaoTimed<[FuyaoConstituent]>?
        var quotes: [SymbolID: Quote] = [:]
        var strength: FuyaoRelativeStrength?
        var attemptedAt: Date?
        var errors: [String: String] = [:]
    }
    private(set) var catalogs: [Bool: FuyaoTimed<[FuyaoBoard]>] = [:]
    private(set) var quotes: [SymbolID: Quote] = [:]
    private(set) var details: [String: Detail] = [:]
    private(set) var loadingCatalog: Set<Bool> = []
    private(set) var loadingDetails: Set<String> = []
    private(set) var errors: [Bool: String] = [:]
    private(set) var epoch = 0
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var benchmark: (time: Date, candles: [Candle])?

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider; self.available = available
    }
    func reset() {
        epoch += 1
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        catalogs = [:]; quotes = [:]; details = [:]; errors = [:]
        loadingCatalog = []; loadingDetails = []; benchmark = nil
    }
    private func valid(_ captured: Int) -> Bool { captured == epoch && available() && !Task.isCancelled }

    func loadCatalog(industry: Bool, force: Bool = false) async {
        guard available() else { return }
        let key = "catalog-\(industry)"
        if let task = tasks[key] { await task.value; return }
        if !force, let data = catalogs[industry], Date.now.timeIntervalSince(data.fetchedAt) < 300 { return }
        let captured = epoch
        loadingCatalog.insert(industry); errors[industry] = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == captured { self.loadingCatalog.remove(industry); self.tasks[key] = nil } }
            do {
                let catalog = try await self.provider.boardCatalog(industry: industry)
                guard self.valid(captured) else { return }
                self.catalogs[industry] = catalog
                // Index identities take a batch endpoint, with no per-symbol meta fan-out.
                let symbols = catalog.value.compactMap(\.symbol)
                for start in stride(from: 0, to: symbols.count, by: 100) {
                    do {
                        let rows = try await self.provider.quotes(for: Array(symbols[start..<min(start + 100, symbols.count)]))
                        guard self.valid(captured) else { return }
                        for quote in rows { self.quotes[quote.symbol] = quote }
                    } catch {
                        guard self.valid(captured) else { return }
                        self.errors[industry] = FuyaoResearchController.message(error)
                        if case ProviderError.rateLimited = error { break }
                    }
                }
            } catch {
                guard self.valid(captured) else { return }
                self.errors[industry] = FuyaoResearchController.message(error)
            }
        }
        tasks[key] = task
        await task.value
    }

    func loadDetail(_ board: FuyaoBoard, force: Bool = false) async {
        guard available(), let symbol = board.symbol else { return }
        let key = "detail-" + board.thscode
        if let task = tasks[key] { await task.value; return }
        if !force, let attempted = details[board.thscode]?.attemptedAt,
           Date.now.timeIntervalSince(attempted) < 300 { return }
        let captured = epoch
        loadingDetails.insert(board.thscode)
        var detail = details[board.thscode] ?? Detail()
        detail.errors = [:]; details[board.thscode] = detail
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == captured {
                    self.loadingDetails.remove(board.thscode); self.tasks[key] = nil
                    self.details[board.thscode]?.attemptedAt = .now
                }
            }
            do {
                let bars = try await self.provider.candles(for: symbol, period: .day, count: 45)
                let benchmarkBars: [Candle]
                if let cached = self.benchmark, Date.now.timeIntervalSince(cached.time) < 300 { benchmarkBars = cached.candles }
                else {
                    benchmarkBars = try await self.provider.candles(for: SymbolID(market: .sh, code: "000300"), period: .day, count: 45)
                    guard self.valid(captured) else { return }
                    self.benchmark = (.now, benchmarkBars)
                }
                guard self.valid(captured) else { return }
                self.details[board.thscode]?.strength = .calculate(board: bars, benchmark: benchmarkBars)
            } catch {
                guard self.valid(captured) else { return }
                self.details[board.thscode]?.errors["区间强弱"] = FuyaoResearchController.message(error)
                if case ProviderError.rateLimited = error { return }
            }
            do {
                let members = try await self.provider.boardConstituents(thscode: board.thscode)
                guard self.valid(captured) else { return }
                self.details[board.thscode]?.constituents = members
                let rows = try await self.provider.constituentQuotes(members.value)
                guard self.valid(captured) else { return }
                var bySymbol: [SymbolID: Quote] = [:]
                for quote in rows { bySymbol[quote.symbol] = quote }
                self.details[board.thscode]?.quotes = bySymbol
            } catch {
                guard self.valid(captured) else { return }
                self.details[board.thscode]?.errors["成分股"] = FuyaoResearchController.message(error)
            }
        }
        tasks[key] = task
        await task.value
    }
}
