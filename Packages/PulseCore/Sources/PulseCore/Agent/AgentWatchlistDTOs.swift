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

    public init(
        symbol: AgentInstrument,
        quantity: Double,
        averageCost: Double?,
        costBasis: Double,
        realizedPnL: Double,
        transactions: [AgentTransaction],
        quote: AgentQuoteSnapshot?,
        thesis: String? = nil,
        plans: [AgentTradePlan] = []
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

    public init(
        id: UUID,
        kind: String,
        price: Double,
        quantity: Double,
        status: String,
        note: String? = nil,
        reached: Bool? = nil,
        createdAt: Date,
        updatedAt: Date
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
    }
}

public struct AgentTransaction: Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var price: Double
    public var quantity: Double
    /// Trade day as `YYYY-MM-DD` in the user's local calendar.
    public var date: String

    public init(id: UUID, kind: String, price: Double, quantity: Double, date: String) {
        self.id = id
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.date = date
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
    public var date: Date
    public var id: UUID?

    public init(
        symbol: AgentSymbolRef,
        kind: AgentTradeKind,
        quantity: Double,
        price: Double,
        date: Date,
        id: UUID? = nil
    ) {
        self.symbol = symbol
        self.kind = kind
        self.quantity = quantity
        self.price = price
        self.date = date
        self.id = id
    }
}

public enum AgentTradeKind: String, Sendable {
    case buy
    case sell
}
