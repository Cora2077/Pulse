import Foundation

// 同花顺板块（行业 / 概念）目录、成分股与成分股报价。所有请求都走
// `fetchResearchData`，与行情共用同一凭据与节流；模型是纯值，缓存交给调用方。
//
// 除“成分股报价”之外的两个端点都只回引用数据：`data.timestamp` 是上游的
// 就绪时间，缺失时保持 nil，绝不写成 `now`。

extension FuyaoProvider {
    // MARK: - 公开查询

    /// 同花顺行业（`industry`）或概念（`cn_concept`）板块目录。单标签一次
    /// 全量返回，无分页；只保留合法的 6 位 `88` 开头 `.TI` 代码并按原顺序去重。
    public func boardCatalog(industry: Bool) async throws -> FuyaoTimed<[FuyaoBoard]> {
        let tag = industry ? Self.industryBoardTag : Self.conceptBoardTag
        let data = try await fetchResearchData(path: Self.boardCatalogPath, query: [
            .init(name: "tag", value: tag),
        ])
        try Task.checkCancellation()
        return try Self.parseBoardCatalog(data: data, fetchedAt: Date.now)
    }

    /// 单个板块当前的成分股。`thscode` 会被 `trim().toUpperCase()` 标准化；
    /// 逗号列表不被接受，因此每次只问一个板块。
    public func boardConstituents(thscode: String) async throws -> FuyaoTimed<[FuyaoConstituent]> {
        let code = thscode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, !code.contains(",") else {
            throw ProviderError.clientError(status: 400, detail: "fuyao ths-stock-list: invalid thscode")
        }
        let data = try await fetchResearchData(path: Self.boardConstituentsPath, query: [
            .init(name: "thscode", value: code),
        ])
        try Task.checkCancellation()
        return try Self.parseBoardConstituents(data: data, fetchedAt: Date.now)
    }

    /// 成分股报价：这些已知是交易所股票，直接走 `a-share` 批量快照，
    /// 绕过逐代码的类型解析（那是每只股票一次 meta 请求）。
    ///
    /// 只请求可映射的 `.SH` / `.SZ` 代码，按完整 thscode 去重后每 100 个一批。
    /// 每一批的报价时间都取该批响应的 `data.timestamp`（就绪时间），缺失时不
    /// 会以 `now` 顶替。单批失败只损失该批；限流拒绝则停止后续批次，避免风暴；
    /// 已有成功批次照常返回，全部失败才抛出。
    public func constituentQuotes(_ constituents: [FuyaoConstituent]) async throws -> [Quote] {
        guard !constituents.isEmpty else { return [] }

        // 以完整 thscode 为身份：600519.SH 与 000001.SZ 互不相干。
        var seen: Set<String> = []
        var plans: [(thscode: String, symbol: SymbolID)] = []
        for constituent in constituents {
            guard let (code, market) = FuyaoConstituent.shareCode(constituent.thscode),
                  constituent.symbol == SymbolID(market: market, code: code),
                  seen.insert(constituent.thscode).inserted else { continue }
            plans.append((constituent.thscode, SymbolID(market: market, code: code)))
        }
        guard !plans.isEmpty else { return [] }

        var rows: [String: Quote] = [:]
        var names: [String: String] = [:]
        for constituent in constituents {
            let name = constituent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, names[constituent.thscode] == nil { names[constituent.thscode] = name }
        }

        var lastError: (any Error)?
        var refusal: (any Error)?
        batches:
        for batch in plans.chunked(into: 100) {
            try Task.checkCancellation()
            let scope = Scope(group: .shares, codes: batch.map(\.thscode))
            do {
                let data = try await fetchResearchData(
                    path: Self.shareSnapshotPath,
                    query: [.init(name: "thscodes", value: scope.codes.joined(separator: ","))]
                )
                try Task.checkCancellation()
                // 就绪时间缺失的批次不能以 `now` 冒充：该批整批不采纳。
                let timestamp = try Self.batchTimestamp(data: data, scope: scope)
                let parsed = try Self.parseSnapshot(data: data)
                for plan in batch {
                    guard var quote = parsed[plan.thscode] else { continue }
                    quote.symbol = plan.symbol
                    quote.currencyCode = plan.symbol.market.currencyCode
                    quote.timestamp = timestamp
                    if let name = names[plan.thscode] { quote.name = name }
                    // 同一 thscode 只由一批携带；首答为准。
                    if rows[plan.thscode] == nil { rows[plan.thscode] = quote }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // 限流：停止后续批次，不再制造请求风暴。
                if Self.isQuotaRefusal(error) {
                    refusal = error
                    break batches
                }
                lastError = error
            }
        }

        guard !rows.isEmpty else {
            // 有批次被限流则如实上报限流；否则上报最后一次失败；都没有则是
            // 响应里不含可用行，并非来源故障。
            if let refusal { throw refusal }
            if let lastError { throw lastError }
            return []
        }
        return plans.compactMap { rows[$0.thscode] }
    }

    // MARK: - 解析

    /// 板块目录。`fetchedAt` 是调用方记录的接收时间。
    static func parseBoardCatalog(data: Data, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoBoard]> {
        let payload = try decodePayload(BoardListPayload.self, from: data, endpoint: "ths-index-list")
        var seen: Set<String> = []
        let boards = (payload.item ?? []).compactMap { item -> FuyaoBoard? in
            guard let code = item.thscode?.boardText,
                  FuyaoBoard.thiBoardCode(code) != nil,
                  seen.insert(code).inserted else { return nil }
            return FuyaoBoard(thscode: code, name: item.name?.boardText ?? code)
        }
        return FuyaoTimed(
            value: boards,
            dataTime: millisecondDate(payload.timestamp),
            fetchedAt: fetchedAt
        )
    }

    /// 板块成分股。`.BJ` 代码保留在模型中（`symbol` 为 nil），只接受合法
    /// 的 6 位数字 `.SH` / `.SZ` / `.BJ` 代码，并按代码去重。
    static func parseBoardConstituents(data: Data, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoConstituent]> {
        let payload = try decodePayload(BoardListPayload.self, from: data, endpoint: "ths-stock-list")
        var seen: Set<String> = []
        let rows = (payload.item ?? []).compactMap { item -> FuyaoConstituent? in
            guard let code = item.thscode?.boardText,
                  Self.isConstituentThscode(code),
                  seen.insert(code).inserted else { return nil }
            return FuyaoConstituent(thscode: code, name: item.name?.boardText ?? code)
        }
        return FuyaoTimed(
            value: rows,
            dataTime: millisecondDate(payload.timestamp),
            fetchedAt: fetchedAt
        )
    }

    /// 合法的 6 位数字代码加 `.SH` / `.SZ` / `.BJ` 后缀。
    static func isConstituentThscode(_ thscode: String) -> Bool {
        if FuyaoConstituent.shareCode(thscode) != nil { return true }
        let parts = thscode.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "BJ" else { return false }
        let code = String(parts[0])
        return code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    // MARK: - 线格式

    static let boardCatalogPath = "/api/a-share-index/catalog/ths-index-list"
    static let boardConstituentsPath = "/api/a-share-index/constituents/ths-stock-list"
    static let shareSnapshotPath = "/api/a-share/prices/snapshot"
    static let industryBoardTag = "industry"
    static let conceptBoardTag = "cn_concept"

    /// 指数列表与成分股列表共用同一形状：`data.timestamp` 与 `data.item[]`。
    struct BoardListPayload: Decodable {
        let timestamp: Double?
        let item: [BoardListItem]?
    }

    struct BoardListItem: Decodable {
        let thscode: String?
        let name: String?
    }
}

private extension String {
    /// 去掉首尾空白后的非空文本；空白即缺失。
    var boardText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
