import Foundation

/// One headline from Tonghuashun's per-stock news timeline. Source text is
/// carried as published; nothing here is rendered or interpreted.
public struct FuyaoNewsItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String?
    public let source: String?
    /// Upstream publish time. Nil when the feed omitted it — never filled in
    /// from the local clock.
    public let publishedAt: Date?
    /// Only an absolute HTTP/HTTPS link is kept.
    public let url: URL?

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        source: String? = nil,
        publishedAt: Date? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.source = source
        self.publishedAt = publishedAt
        self.url = url
    }
}

/// Why a stock moved, as the vendor's snapshot explains it.
public struct FuyaoAnomaly: Codable, Hashable, Sendable {
    public let thscode: String
    public let name: String
    public let text: String
    public let keywords: [String]
    public let tag: String

    public init(thscode: String, name: String, text: String, keywords: [String] = [], tag: String) {
        self.thscode = thscode
        self.name = name
        self.text = text
        self.keywords = keywords
        self.tag = tag
    }
}

/// One row of the A-share heat list. Absence from the list says only that the
/// stock was not in this board, not that it has no attention.
public struct FuyaoHotStock: Codable, Hashable, Sendable {
    public let thscode: String
    public let name: String
    /// One-based position on the board.
    public let rank: Int
    /// Movement against the previous board; nil when the feed did not say.
    public let rankChange: Int?
    public let trend: String?

    public init(thscode: String, name: String, rank: Int, rankChange: Int? = nil, trend: String? = nil) {
        self.thscode = thscode
        self.name = name
        self.rank = rank
        self.rankChange = rankChange
        self.trend = trend
    }
}

/// One day's heat rank for a stock.
public struct FuyaoRankPoint: Codable, Hashable, Sendable {
    public let thscode: String
    /// Midnight of the day in Asia/Shanghai.
    public let date: Date
    public let rank: Int

    public init(thscode: String, date: Date, rank: Int) {
        self.thscode = thscode
        self.date = date
        self.rank = rank
    }
}

/// A vendor answer paired with the times needed to judge its freshness.
/// `dataTime` is the upstream's own timestamp and stays nil when it has none;
/// `fetchedAt` is when this device received the answer.
public struct FuyaoTimed<Value: Sendable & Codable & Hashable>: Codable, Hashable, Sendable {
    public let value: Value
    public let dataTime: Date?
    public let fetchedAt: Date

    public init(value: Value, dataTime: Date?, fetchedAt: Date) {
        self.value = value
        self.dataTime = dataTime
        self.fetchedAt = fetchedAt
    }
}
