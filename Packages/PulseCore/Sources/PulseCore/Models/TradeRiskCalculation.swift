import Foundation

/// Position size for a cash long buy, sized to a loss budget and optional capital cap.
public enum TradeRiskCalculation {
    public struct Input: Sendable, Equatable {
        public let entryPrice: Double
        public let stopPrice: Double
        public let targetPrice: Double
        public let riskBudget: Double
        public let roundTripFees: Double
        public let adverseSlippagePerUnit: Double
        public let quantityStep: Double
        public let maximumInvestedAmount: Double?

        public init(
            entryPrice: Double,
            stopPrice: Double,
            targetPrice: Double,
            riskBudget: Double,
            roundTripFees: Double,
            adverseSlippagePerUnit: Double,
            quantityStep: Double,
            maximumInvestedAmount: Double? = nil
        ) {
            self.entryPrice = entryPrice
            self.stopPrice = stopPrice
            self.targetPrice = targetPrice
            self.riskBudget = riskBudget
            self.roundTripFees = roundTripFees
            self.adverseSlippagePerUnit = adverseSlippagePerUnit
            self.quantityStep = quantityStep
            self.maximumInvestedAmount = maximumInvestedAmount
        }
    }

    public struct Result: Sendable, Equatable {
        public let quantity: Double
        public let investedAmount: Double
        public let estimatedLoss: Double
        public let estimatedProfit: Double
        public let rewardRiskRatio: Double
    }

    /// Slippage applies once per unit to the stop and target estimate; fees are a fixed round-trip amount.
    /// Returns nil for invalid inputs, overflow, or when no whole step fits both limits.
    public static func calculate(_ input: Input) -> Result? {
        let values = [input.entryPrice, input.stopPrice, input.targetPrice, input.riskBudget,
                      input.roundTripFees, input.adverseSlippagePerUnit, input.quantityStep]
        guard values.allSatisfy(\.isFinite),
              input.entryPrice > input.stopPrice, input.stopPrice > 0,
              input.targetPrice > input.entryPrice,
              input.riskBudget > 0, input.roundTripFees >= 0,
              input.adverseSlippagePerUnit >= 0, input.quantityStep > 0,
              input.maximumInvestedAmount.map({ $0.isFinite && $0 > 0 }) ?? true,
              input.riskBudget > input.roundTripFees else { return nil }

        let lossPerUnit = input.entryPrice - input.stopPrice + input.adverseSlippagePerUnit
        let availableRisk = input.riskBudget - input.roundTripFees
        guard lossPerUnit.isFinite, lossPerUnit > 0, availableRisk.isFinite, availableRisk > 0 else { return nil }

        var maximumQuantity = availableRisk / lossPerUnit
        guard maximumQuantity.isFinite, maximumQuantity > 0 else { return nil }
        if let cap = input.maximumInvestedAmount {
            let availableCapital = cap - input.roundTripFees
            guard availableCapital > 0 else { return nil }
            let capitalQuantity = availableCapital / input.entryPrice
            guard capitalQuantity.isFinite, capitalQuantity > 0 else { return nil }
            maximumQuantity = min(maximumQuantity, capitalQuantity)
        }

        guard var quantity = floor(maximumQuantity, to: input.quantityStep), quantity > 0 else { return nil }
        if let result = result(quantity: quantity, input: input),
           result.estimatedLoss <= input.riskBudget,
           input.maximumInvestedAmount.map({ result.investedAmount <= $0 }) ?? true {
            return result
        }

        // A one-step correction covers floating-point rounding at the limit.
        quantity -= input.quantityStep
        guard quantity.isFinite, quantity > 0,
              let result = result(quantity: quantity, input: input),
              result.estimatedLoss <= input.riskBudget,
              input.maximumInvestedAmount.map({ result.investedAmount <= $0 }) ?? true else { return nil }
        return result
    }

    private static func floor(_ value: Double, to step: Double) -> Double? {
        var value = Decimal(value)
        var step = Decimal(step)
        guard !value.isNaN, !step.isNaN, step > 0 else { return nil }
        var units = Decimal()
        guard NSDecimalDivide(&units, &value, &step, .plain) != .overflow,
              !units.isNaN else { return nil }
        var wholeUnits = Decimal()
        NSDecimalRound(&wholeUnits, &units, 0, .down)
        var result = Decimal()
        guard NSDecimalMultiply(&result, &wholeUnits, &step, .plain) != .overflow,
              !result.isNaN else { return nil }
        let rounded = NSDecimalNumber(decimal: result).doubleValue
        return rounded.isFinite ? rounded : nil
    }

    private static func result(quantity: Double, input: Input) -> Result? {
        let investedAmount = input.entryPrice * quantity + input.roundTripFees
        let estimatedLoss = (input.entryPrice - input.stopPrice + input.adverseSlippagePerUnit) * quantity
            + input.roundTripFees
        let estimatedProfit = (input.targetPrice - input.entryPrice - input.adverseSlippagePerUnit) * quantity
            - input.roundTripFees
        let rewardRiskRatio = estimatedProfit / estimatedLoss
        guard investedAmount.isFinite, estimatedLoss.isFinite, estimatedProfit.isFinite,
              rewardRiskRatio.isFinite else { return nil }
        return Result(
            quantity: quantity,
            investedAmount: investedAmount,
            estimatedLoss: estimatedLoss,
            estimatedProfit: estimatedProfit,
            rewardRiskRatio: rewardRiskRatio
        )
    }
}
