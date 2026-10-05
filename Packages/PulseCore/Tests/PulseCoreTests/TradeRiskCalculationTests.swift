import Testing
@testable import PulseCore

@Suite("Trade risk calculation")
struct TradeRiskCalculationTests {
    @Test("Rejects invalid prices, limits, and non-finite inputs")
    func rejectsInvalidInputs() {
        #expect(TradeRiskCalculation.calculate(input(entry: .nan)) == nil)
        #expect(TradeRiskCalculation.calculate(input(entry: 90)) == nil)
        #expect(TradeRiskCalculation.calculate(input(fees: -1)) == nil)
        #expect(TradeRiskCalculation.calculate(input(slippage: -.infinity)) == nil)
        #expect(TradeRiskCalculation.calculate(input(step: 0)) == nil)
        #expect(TradeRiskCalculation.calculate(input(cap: .infinity)) == nil)
    }

    @Test("Rounds quantity down to the requested step")
    func roundsDownToStep() throws {
        let result = try #require(TradeRiskCalculation.calculate(input(
            budget: 25, fees: 5, slippage: 1, step: 0.25
        )))

        #expect(result.quantity == 1.75)
        #expect(result.estimatedLoss == 24.25)
        #expect(result.estimatedProfit == 28.25)
        #expect(abs(result.rewardRiskRatio - 28.25 / 24.25) < 0.000001)

        let decimalStep = try #require(TradeRiskCalculation.calculate(input(
            entry: 100, stop: 99, target: 101, budget: 0.3, step: 0.1
        )))
        #expect(decimalStep.quantity == 0.3)
    }

    @Test("Fees alone cannot fit inside the loss budget")
    func feesExceedBudget() {
        #expect(TradeRiskCalculation.calculate(input(budget: 5, fees: 5)) == nil)
    }

    @Test("Capital cap includes estimated round-trip fees")
    func capsInvestedAmount() throws {
        let result = try #require(TradeRiskCalculation.calculate(input(
            budget: 1_000, fees: 2, cap: 502
        )))

        #expect(result.quantity == 5)
        #expect(result.investedAmount == 502)
    }

    @Test("Corrects an overflowing quantity and rejects unrepresentable amounts")
    func handlesOverflow() throws {
        #expect(TradeRiskCalculation.calculate(input(budget: .greatestFiniteMagnitude, step: 1e-300)) == nil)
        let corrected = try #require(TradeRiskCalculation.calculate(input(
            entry: 1e308, stop: 5e307, target: 1.5e308,
            budget: 1e308, step: 1
        )))
        #expect(corrected.quantity == 1)
        #expect(corrected.investedAmount.isFinite)
        #expect(corrected.estimatedLoss.isFinite && corrected.estimatedLoss <= 1e308)
        #expect(TradeRiskCalculation.calculate(input(
            entry: 1e308, stop: 9e307, target: 1.5e308,
            budget: 1e308, step: 1
        )) == nil)
    }

    private func input(
        entry: Double = 100,
        stop: Double = 90,
        target: Double = 120,
        budget: Double = 100,
        fees: Double = 0,
        slippage: Double = 0,
        step: Double = 1,
        cap: Double? = nil
    ) -> TradeRiskCalculation.Input {
        .init(
            entryPrice: entry,
            stopPrice: stop,
            targetPrice: target,
            riskBudget: budget,
            roundTripFees: fees,
            adverseSlippagePerUnit: slippage,
            quantityStep: step,
            maximumInvestedAmount: cap
        )
    }
}
