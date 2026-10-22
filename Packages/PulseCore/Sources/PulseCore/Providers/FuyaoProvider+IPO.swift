import Foundation

// 打新日历：六个查询（沪深/京市 × 三阶段）合并成一份日历。
//
// 每个查询独立失败：一个阶段查不到不该让整张日历消失。全部失败才抛错，
// 否则调用方无从区分"今天确实没有新股"与"请求挂了"。

extension FuyaoProvider {
    /// 六个组合全部拉取。部分失败保留成功项。
    public func ipoCalendar() async throws -> FuyaoIPOCalendar {
        var lists: [FuyaoIPOList] = []
        var anySucceeded = false
        for market in FuyaoIPOMarket.allCases {
            for stage in FuyaoIPOStage.allCases {
                do {
                    let data = try await fetchResearchData(path: Self.ipoCalendarPath, query: [
                        .init(name: "market", value: market.rawValue),
                        .init(name: "status", value: stage.rawValue),
                    ])
                    try Task.checkCancellation()
                    lists.append(try Self.parseIPOList(
                        data: data, market: market, stage: stage, fetchedAt: .now))
                    anySucceeded = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = Self.researchMessage(error)
                    lists.append(FuyaoIPOList(market: market, stage: stage, entries: [],
                                              fetchedAt: .now, error: message))
                    // 限流后停止后续查询，不再制造请求风暴。
                    if Self.isRateLimited(error) { break }
                }
            }
        }
        guard anySucceeded else {
            throw ProviderError.badResponse("fuyao ipo-calendar: all queries failed")
        }
        return FuyaoIPOCalendar(lists: lists, fetchedAt: .now)
    }

    static func parseIPOList(
        data: Data,
        market: FuyaoIPOMarket,
        stage: FuyaoIPOStage,
        fetchedAt: Date
    ) throws -> FuyaoIPOList {
        let payload = try decodePayload(IPOListPayload.self, from: data, endpoint: "ipo-calendar-list")
        var entries: [FuyaoIPOEntry] = []
        var seen: Set<String> = []
        for row in payload.item ?? [] {
            guard let ticker = row.ticker?.trimmedIPO, !ticker.isEmpty else { continue }
            let thscode = row.thscode?.trimmedIPO?.uppercased()
            // 回显的市场若与请求不符，以响应为准（它是这份数据实际所属）。
            let entry = FuyaoIPOEntry(
                thscode: thscode,
                ticker: ticker,
                name: row.name?.trimmedIPO ?? ticker,
                subscriptionCode: row.subscriptionCode?.trimmedIPO,
                subscriptionDate: beijingDay(of: row.subscriptionDate),
                listingDate: beijingDay(of: row.listingDate),
                issuePrice: row.issuePrice.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                market: market,
                stage: stage
            )
            guard seen.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        return FuyaoIPOList(market: market, stage: stage, entries: entries, fetchedAt: fetchedAt)
    }

    static let ipoCalendarPath = "/api/a-share/ipo/calendar-list"

    struct IPOListPayload: Decodable {
        let item: [IPORow]?
    }

    struct IPORow: Decodable {
        let thscode: String?
        let ticker: String?
        let name: String?
        let subscriptionCode: String?
        let subscriptionDate: String?
        let listingDate: String?
        let issuePrice: Double?
    }
}

private extension String {
    var trimmedIPO: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
