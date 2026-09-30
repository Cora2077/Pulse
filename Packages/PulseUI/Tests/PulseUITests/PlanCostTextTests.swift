import Foundation
import Testing
import PulseCore
@testable import PulseUI

/// The money the chart tag puts under the price.
///
/// These check the figure and the direction, which is where a chart tag can
/// quietly disagree with the list surfaces that answer the same question. The
/// wording itself belongs to the localization tables and is checked there; a
/// test bundle ships no `.strings` table, so asserting on the rendered sentence
/// would only ever assert that the bundle is empty.
struct PlanCostTextTests {
    private func plan(kind: TradePlan.Kind, price: Double, quantity: Double = 100,
                      status: TradePlan.Status = .active) -> TradePlan {
        TradePlan(id: UUID(), kind: kind, price: price, quantity: quantity, status: status)
    }

    @Test("A group total matches the plans it is made of")
    func groupTotalMatchesItsParts() throws {
        // Two buys at one price differ only in size, so the tag's single figure
        // has to be the sum rather than one plan's.
        let plans = [plan(kind: .buy, price: 200, quantity: 100),
                     plan(kind: .buy, price: 200, quantity: 300)]

        let grouped = try #require(PlanCostText.summary(for: plans, current: 212.6))
        #expect(grouped.tone == .paysMore)
        // (212.6 − 200) × 400, not the 1,260 one plan alone would report.
        #expect(abs(grouped.amount - ((212.6 - 200) * 400)) < 0.000_001)
        #expect(abs(grouped.amount - 5_040) < 0.000_001)
    }

    @Test("A group takes its direction from the plan's own rule")
    func groupToneFollowsTheModel() throws {
        // A buy under its price is good news; a sell under its price is not.
        // The tone must come from `costDelta`, not from re-reading the sign.
        let buy = try #require(PlanCostText.summary(for: [plan(kind: .buy, price: 200)],
                                                   current: 180))
        #expect(buy.tone == .paysLess)
        #expect(!buy.tone.isAdverse)
        #expect(abs(buy.amount - 2_000) < 0.000_001)

        let sell = try #require(PlanCostText.summary(for: [plan(kind: .sell, price: 260)],
                                                    current: 212.6))
        #expect(sell.tone == .earnsLess)
        #expect(sell.tone.isAdverse)
        #expect(abs(sell.amount - ((260 - 212.6) * 100)) < 0.000_001)

        let profitableSell = try #require(PlanCostText.summary(for: [plan(kind: .sell, price: 260)],
                                                              current: 300))
        #expect(profitableSell.tone == .earnsMore)
        #expect(!profitableSell.tone.isAdverse)
    }

    @Test("Only the two adverse tones are flagged as warnings")
    func onlyAdverseTonesWarn() {
        #expect(TradePlan.CostTone.paysMore.isAdverse)
        #expect(TradePlan.CostTone.earnsLess.isAdverse)
        #expect(!TradePlan.CostTone.paysLess.isAdverse)
        #expect(!TradePlan.CostTone.earnsMore.isAdverse)
    }

    @Test("Every tone resolves to a distinct key so none can be left unwritten")
    func everyToneHasItsOwnKey() {
        let keys = TradePlan.CostTone.allCases.map(\.localizationKey)
        #expect(Set(keys).count == keys.count)
        for key in keys { #expect(key.hasPrefix("plan.cost.")) }
    }

    @Test("Only the two adverse tones name the action at the live quote")
    func onlyAdverseTonesNameAnAction() {
        // The prefix is the warning: "现价买入 多花 …" says what the reader
        // would be doing, which is the point of flagging it. The two pieces of
        // good news read fine without being told what to do, so they carry no
        // action — and a tone added later has to choose here rather than
        // inherit a label that may not describe it.
        #expect(TradePlan.CostTone.paysMore.actionKey == "plan.cost.buyNow")
        #expect(TradePlan.CostTone.earnsLess.actionKey == "plan.cost.sellNow")
        #expect(TradePlan.CostTone.paysLess.actionKey == nil)
        #expect(TradePlan.CostTone.earnsMore.actionKey == nil)

        // Naming the action must line up with colouring the line, or a tag
        // would be shouting about good news, or whispering about bad.
        for tone in TradePlan.CostTone.allCases {
            #expect((tone.actionKey != nil) == tone.isAdverse)
        }
    }

    @Test("The buy and sell actions are distinct sentences")
    func actionsDoNotCollide() {
        // A buy told to sell would be worse than no prefix at all, so the two
        // directions must not resolve to one label.
        let actions = TradePlan.CostTone.allCases.compactMap(\.actionKey)
        #expect(actions.count == 2)
        #expect(Set(actions).count == actions.count)
        for key in actions { #expect(key.hasPrefix("plan.cost.")) }
    }

    @Test("A settled plan contributes no money to its group")
    func settledPlansAreExcluded() throws {
        // A done buy must not be added to a live one at the same price: the tag
        // would then claim a size the user no longer holds.
        let mixed = [plan(kind: .buy, price: 200, quantity: 100),
                     plan(kind: .buy, price: 200, quantity: 900, status: .done)]
        let grouped = try #require(PlanCostText.summary(for: mixed, current: 210))
        let single = try #require(PlanCostText.summary(for: [mixed[0]], current: 210))
        #expect(grouped == single)
        #expect(abs(grouped.amount - 1_000) < 0.000_001)
    }

    @Test("Nothing to compare prints nothing rather than a zero")
    func emptyCasesPrintNothing() {
        // No quote at all is the common case outside trading hours.
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200)], current: nil) == nil)
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200)], current: 0) == nil)
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200)], current: .nan) == nil)
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200)], current: .infinity) == nil)
        // Sitting exactly on the price is a zero difference, which has no tone.
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200)], current: 200) == nil)
        // A plan with no size cannot be priced.
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200, quantity: 0)],
                                     current: 210) == nil)
        #expect(PlanCostText.summary(for: [], current: 210) == nil)
        // A cancelled plan is still nothing, on its own or in company.
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200, status: .cancelled)],
                                     current: 210) == nil)
        #expect(PlanCostText.summary(for: [plan(kind: .buy, price: 200, status: .done),
                                           plan(kind: .buy, price: 200, status: .cancelled)],
                                     current: 210) == nil)
    }

    @Test("The group figure equals the sum of its members")
    func groupFigureIsTheSumOfMembers() throws {
        // Chosen so each part is exact in binary: no rounding drift to hide behind.
        let plans = [plan(kind: .buy, price: 100, quantity: 50),
                     plan(kind: .buy, price: 100, quantity: 150)]
        let grouped = try #require(PlanCostText.summary(for: plans, current: 110))
        // (110 − 100) × 200 = 2000, not the 500 or 1500 a single member would give.
        #expect(abs(grouped.amount - 2_000) < 0.000_001)
        let parts = plans.compactMap { PlanCostText.summary(for: $0, current: 110) }
        #expect(abs(grouped.amount - parts.reduce(0) { $0 + $1.amount }) < 0.000_001)
    }

    @Test("A quote moving against the plan is the one worth flagging")
    func adverseToneMatchesTheWarning() throws {
        // The chart colours exactly these two, so the pairing is the feature.
        let payingMore = try #require(PlanCostText.summary(for: [plan(kind: .buy, price: 200)],
                                                          current: 220))
        #expect(payingMore.tone.isAdverse)
        let earningLess = try #require(PlanCostText.summary(for: [plan(kind: .sell, price: 200)],
                                                           current: 180))
        #expect(earningLess.tone.isAdverse)
        let payingLess = try #require(PlanCostText.summary(for: [plan(kind: .buy, price: 200)],
                                                          current: 180))
        #expect(!payingLess.tone.isAdverse)
        let earningMore = try #require(PlanCostText.summary(for: [plan(kind: .sell, price: 200)],
                                                           current: 220))
        #expect(!earningMore.tone.isAdverse)
    }
}
