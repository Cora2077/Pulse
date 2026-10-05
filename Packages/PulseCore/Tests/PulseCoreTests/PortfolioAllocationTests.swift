import Testing
@testable import PulseCore

@Suite("Portfolio allocation")
struct PortfolioAllocationTests {
    private let aapl = SymbolID(market: .us, code: "AAPL")
    private let msft = SymbolID(market: .us, code: "MSFT")
    private let btc = SymbolID(cryptoBase: "BTC", quote: "USDT")
    private let spx = SymbolID(index: .sp500)

    private func position(
        _ symbol: SymbolID,
        _ quantity: Double,
        _ price: Double?,
        currency: String? = "USD",
        supportsPosition: Bool = true
    ) -> PortfolioAllocation.Position {
        .init(symbol: symbol, name: symbol.displayCode, quantity: quantity, price: price,
              currencyCode: currency, supportsPosition: supportsPosition)
    }

    @Test("Currencies stay separate and duplicate symbols count once")
    func separatesCurrenciesAndDeduplicates() {
        let result = PortfolioAllocation.calculate(positions: [
            position(aapl, 2, 100), position(aapl, 2, 100),
            position(btc, 1, 50_000, currency: "USDT")
        ])

        #expect(result.currencies.count == 2)
        #expect(result.currencies.first { $0.code == "USD" }?.totalExposure == 200)
        #expect(result.currencies.first { $0.code == "USDT" }?.totalExposure == 50_000)
        #expect(result.currencies.allSatisfy { $0.holdings.count == 1 })
    }

    @Test("Invalid quotes are excluded and unsupported or flat positions do not count")
    func excludesInvalidAndUnsupported() {
        let result = PortfolioAllocation.calculate(positions: [
            position(aapl, 2, nil),
            position(msft, 1, .infinity),
            position(spx, 1, 100, supportsPosition: false),
            position(btc, 0, nil)
        ])

        #expect(result.currencies.isEmpty)
        #expect(result.excludedMissingQuoteCount == 2)
    }

    @Test("Gross exposure labels shorts by signed quantity and sums top three")
    func shortAndTopThree() throws {
        let result = PortfolioAllocation.calculate(positions: [
            position(aapl, -2, 100), position(msft, 1, 50),
            position(SymbolID(market: .us, code: "NVDA"), 1, 25),
            position(SymbolID(market: .us, code: "GOOG"), 1, 25)
        ])
        let currency = try #require(result.currencies.first)

        #expect(currency.totalExposure == 300)
        #expect(currency.holdings.first?.isShort == true)
        #expect(abs(currency.topThreeConcentration - 275.0 / 300 * 100) < 0.0001)
    }

    @Test("Planned buy covers a short before measuring the resulting exposure")
    func plannedBuyCoversShort() throws {
        let result = PortfolioAllocation.calculate(
            positions: [position(aapl, -5, 100), position(msft, 1, 100)],
            plannedBuy: .init(symbol: aapl, quantity: 7)
        )

        let plan = try #require(result.plannedBuy)
        #expect(plan.totalExposure == 300)
        #expect(plan.percent == 200.0 / 300 * 100)
    }

    @Test("A full cover of the only short has zero resulting exposure")
    func plannedBuyFullyCoversSoleShort() throws {
        let result = PortfolioAllocation.calculate(
            positions: [position(aapl, -3, 100)],
            plannedBuy: .init(symbol: aapl, quantity: 3)
        )

        let plan = try #require(result.plannedBuy)
        #expect(plan.totalExposure == 0)
        #expect(plan.percent == 0)
    }

    @Test("After-buy preview recalculates percentages and leaves other currencies alone")
    func previewAfterBuyRecalculatesPortfolio() throws {
        let result = try #require(PortfolioAllocation.previewAfterBuy(
            positions: [position(aapl, 2, 100), position(msft, 2, 100), position(btc, 1, 50_000, currency: "USDT")],
            plannedBuy: .init(symbol: aapl, quantity: 2)
        ))
        let usd = try #require(result.currencies.first { $0.code == "USD" })
        let usdt = try #require(result.currencies.first { $0.code == "USDT" })

        #expect(usd.totalExposure == 600)
        #expect(usd.holdings.first { $0.symbol == aapl }?.percent == 400.0 / 600 * 100)
        #expect(abs(usd.holdings.reduce(0) { $0 + $1.percent } - 100) < 0.0001)
        #expect(usdt.totalExposure == 50_000)
        #expect(usdt.holdings.first?.percent == 100)
    }

    @Test("After-buy preview covers and exits a short using signed quantity")
    func previewAfterBuyCoversShort() throws {
        let partial = try #require(PortfolioAllocation.previewAfterBuy(
            positions: [position(aapl, -5, 100), position(msft, 1, 100)],
            plannedBuy: .init(symbol: aapl, quantity: 3)
        ))
        let partialUSD = try #require(partial.currencies.first { $0.code == "USD" })
        #expect(partialUSD.totalExposure == 300)
        #expect(partialUSD.holdings.first { $0.symbol == aapl }?.quantity == -2)
        #expect(partialUSD.holdings.first { $0.symbol == aapl }?.percent == 200.0 / 300 * 100)

        let full = try #require(PortfolioAllocation.previewAfterBuy(
            positions: [position(aapl, -3, 100)],
            plannedBuy: .init(symbol: aapl, quantity: 3)
        ))
        #expect(full.currencies.isEmpty)
        #expect(full.excludedUnrepresentableCurrencyCodes.isEmpty)
    }

    @Test("A per-currency total that overflows is reported and omitted")
    func skipsUnrepresentableCurrencyTotal() {
        let result = PortfolioAllocation.calculate(positions: [
            position(aapl, 1, .greatestFiniteMagnitude),
            position(msft, 1, .greatestFiniteMagnitude)
        ])

        #expect(result.currencies.isEmpty)
        #expect(result.excludedUnrepresentableCurrencyCodes == ["USD"])
    }

    @Test("After-buy preview retains per-currency overflow reporting")
    func previewAfterBuyReportsOverflow() throws {
        let result = try #require(PortfolioAllocation.previewAfterBuy(
            positions: [position(aapl, 1, .greatestFiniteMagnitude / 4), position(msft, 1, 100)],
            plannedBuy: .init(symbol: aapl, quantity: 4)
        ))

        #expect(result.currencies.isEmpty)
        #expect(result.excludedUnrepresentableCurrencyCodes == ["USD"])
    }

    @Test("Fully covering a large short preserves smaller remaining exposure")
    func fullCoverPreservesSmallRemainingExposure() throws {
        let positions = [position(aapl, -1, 1e20), position(msft, 1, 100)]
        let plan = PortfolioAllocation.PlannedBuy(symbol: aapl, quantity: 1)
        let result = try #require(PortfolioAllocation.calculate(positions: positions, plannedBuy: plan).plannedBuy)
        #expect(result.totalExposure == 100)
        #expect(result.percent == 0)
        #expect(PortfolioAllocation.previewAfterBuy(positions: positions, plannedBuy: plan)?.currencies.first?.totalExposure == result.totalExposure)
    }
}
