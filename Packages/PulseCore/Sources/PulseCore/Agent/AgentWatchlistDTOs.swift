import Foundation

public struct AgentSymbolRef: Hashable, Codable, Sendable {
    public var market: String
    public var code: String

    public init(market: String, code: String) {
        self.market = market
        self.code = code
    }
}

public struct AgentInstrument: Hashable, Codable, Sendable {
    public var market: String
    public var code: String
    public var displayCode: String
    public var name: String
    public var type: String?
    public var supportsPosition: Bool

    public init(
        market: String,
        code: String,
        displayCode: String,
        name: String,
        type: String?,
        supportsPosition: Bool
    ) {
        self.market = market
        self.code = code
        self.displayCode = displayCode
        self.name = name
        self.type = type
        self.supportsPosition = supportsPosition
    }
}

public struct AgentGroupSnapshot: Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var symbols: [AgentInstrument]

    public init(id: UUID, name: String, symbols: [AgentInstrument]) {
        self.id = id
        self.name = name
        self.symbols = symbols
    }
}

public struct AgentWatchlistSnapshot: Hashable, Codable, Sendable {
    public var groups: [AgentGroupSnapshot]

    public init(groups: [AgentGroupSnapshot]) {
        self.groups = groups
    }
}

public struct AgentPositionSnapshot: Hashable, Codable, Sendable {
    public var symbol: AgentInstrument
    public var quantity: Double
    public var averageCost: Double?
    public var costBasis: Double
    public var realizedPnL: Double
    public var transactions: [AgentTransaction]
    public var quote: AgentQuoteSnapshot?
    /// The user's own reason for holding this instrument, when they wrote one.
    public var thesis: String?
    /// What the user intends to do at which price. Rides along with the
    /// position so one read returns holdings and intentions together.
    public var plans: [AgentTradePlan]
    /// User-entered sector and risk prices, when available.
    public var tradingProfile: TradingProfile?
    /// User-entered instrument events.
    public var events: [InstrumentEvent]
    /// User-assigned holding portions, when initialized.
    public var positionAllocation: PositionAllocation?

    public init(
        symbol: AgentInstrument,
        quantity: Double,
        averageCost: Double?,
        costBasis: Double,
        realizedPnL: Double,
        transactions: [AgentTransaction],
        quote: AgentQuoteSnapshot?,
        thesis: String? = nil,
        plans: [AgentTradePlan] = [],
        tradingProfile: TradingProfile? = nil,
        events: [InstrumentEvent] = [],
        positionAllocation: PositionAllocation? = nil
    ) {
        self.symbol = symbol
        self.quantity = quantity
        self.averageCost = averageCost
        self.costBasis = costBasis
        self.realizedPnL = realizedPnL
        self.transactions = transactions
        self.quote = quote
        self.thesis = thesis
        self.plans = plans
        self.tradingProfile = tradingProfile
        self.events = events
        self.positionAllocation = positionAllocation
    }
}

public struct AgentTradePlan: Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var price: Double
    public var quantity: Double
    public var status: String
    public var note: String?
    /// Whether the plan's price condition holds at the cached quote. Null when
    /// no quote is cached — a plan is never "not reached" merely because the
    /// app has not heard from the market yet.
    public var reached: Bool?
    public var createdAt: Date
    public var updatedAt: Date
    /// User-maintained conditions. Pulse never assesses them itself; omitted
    /// rather than empty when the plan carries none.
    public var conditions: [TradePlanCondition]?
    /// Prior configurations, appended by the store each time an edit changes
    /// the plan. Omitted rather than empty when there is no history yet.
    public var history: [TradePlanRevision]?
    /// Quantity already filled against this plan, derived from the linked
    /// trades. Always present so a reader never has to recompute it.
    public var fillQuantity: Double
    /// Quantity still outstanding: the plan's size less `fillQuantity`, never
    /// negative.
    public var remainingQuantity: Double

    public init(
        id: UUID,
        kind: String,
        price: Double,
        quantity: Double,
        status: String,
        note: String? = nil,
        reached: Bool? = nil,
        createdAt: Date,
        updatedAt: Date,
        conditions: [TradePlanCondition]? = nil,
        history: [TradePlanRevision]? = nil,
        fillQuantity: Double = 0,
        remainingQuantity: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.status = status
        self.note = note
        self.reached = reached
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conditions = conditions
        self.history = history
        self.fillQuantity = fillQuantity
        self.remainingQuantity = remainingQuantity
    }
}

public struct AgentTransaction: Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var price: Double
    public var quantity: Double
    /// Trade day as `YYYY-MM-DD` in the user's local calendar.
    public var date: String
    /// Commission and other costs. Null when the entry carries no fee.
    public var fee: Double?
    /// The user's execution reason, when recorded.
    public var note: String?
    /// Post-trade review, when recorded.
    public var review: PositionTransactionReview?
    /// The immutable plan snapshot this fill was recorded from, when it was
    /// recorded from a plan. Lets a reader pair the trade back to the plan
    /// without re-deriving it from the current (possibly edited) plan.
    public var planExecution: TradePlanExecution?
    public var fundingSource: PositionFundingSource?
    public var brokerageAccountID: BrokerageAccountID?

    public init(
        id: UUID,
        kind: String,
        price: Double,
        quantity: Double,
        date: String,
        fee: Double? = nil,
        note: String? = nil,
        review: PositionTransactionReview? = nil,
        planExecution: TradePlanExecution? = nil,
        fundingSource: PositionFundingSource? = nil,
        brokerageAccountID: BrokerageAccountID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.date = date
        self.fee = fee
        self.note = note
        self.review = review
        self.planExecution = planExecution
        self.fundingSource = fundingSource
        self.brokerageAccountID = brokerageAccountID
    }
}

public struct AgentQuoteSnapshot: Hashable, Codable, Sendable {
    public var price: Double
    public var previousClose: Double
    public var changePercent: Double
    public var currencyCode: String?
    public var timestamp: Date
    public var marketState: String?

    public init(
        price: Double,
        previousClose: Double,
        changePercent: Double,
        currencyCode: String?,
        timestamp: Date,
        marketState: String?
    ) {
        self.price = price
        self.previousClose = previousClose
        self.changePercent = changePercent
        self.currencyCode = currencyCode
        self.timestamp = timestamp
        self.marketState = marketState
    }
}

public struct AgentMutation<Value: Sendable>: Sendable {
    public var value: Value
    public var didChangeSymbolUnion: Bool
    public var alreadyApplied: Bool

    public init(value: Value, didChangeSymbolUnion: Bool, alreadyApplied: Bool) {
        self.value = value
        self.didChangeSymbolUnion = didChangeSymbolUnion
        self.alreadyApplied = alreadyApplied
    }
}

public struct AgentTradeDraft: Sendable {
    public var symbol: AgentSymbolRef
    public var kind: AgentTradeKind
    public var quantity: Double
    public var price: Double
    /// Commission and other costs in account currency. `nil` keeps the entry
    /// fee-free, which is also how a share-split bridge is written.
    public var fee: Double?
    public var date: Date
    public var id: UUID?
    public var fundingSource: PositionFundingSource?

    public init(
        symbol: AgentSymbolRef,
        kind: AgentTradeKind,
        quantity: Double,
        price: Double,
        fee: Double? = nil,
        date: Date,
        id: UUID? = nil,
        fundingSource: PositionFundingSource? = nil
    ) {
        self.symbol = symbol
        self.kind = kind
        self.quantity = quantity
        self.price = price
        self.fee = fee
        self.date = date
        self.id = id
        self.fundingSource = fundingSource
    }
}

public enum AgentTradeKind: String, Sendable {
    case buy
    case sell
}
