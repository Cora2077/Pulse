import Foundation

// 基金业绩三个端点的网络层。
//
// 三个请求**各自独立失败**：区间收益挂了不该连带净值一起消失。所以组合方法
// 收集每个端点的错误，把成功的部分照常返回，由界面分别说明。

extension FuyaoProvider {
    /// 一只基金的业绩快照：区间收益 + 最大回撤 + 最新净值。
    ///
    /// - Parameter navRange: 净值序列的区间。省略时上游只返回**最新一条**，
    ///   这是契约行为，不是缺数据。
    public func fundPerformance(
        for symbol: SymbolID,
        navRange: FuyaoPerformanceWindow? = nil
    ) async throws -> FuyaoFundPerformance {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        var errors: [String: String] = [:]
        var periods: [FuyaoPerformancePeriod] = []
        var navs: [FuyaoFundNavPoint] = []
        var anySucceeded = false

        // 1) 区间收益（含同类平均与排名）。
        var returns: [String: Double] = [:]
        var ranks: [String: Int] = [:]
        do {
            let data = try await fetchResearchData(path: Self.fundReturnsPath, query: [
                .init(name: "thscode", value: thscode),
            ])
            try Task.checkCancellation()
            (returns, ranks) = try Self.parseFundReturns(data: data)
            anySucceeded = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errors["区间收益"] = FuyaoProvider.researchMessage(error)
            if Self.isRateLimited(error) { throw error }
        }

        // 2) 最大回撤。全为负值百分数。
        var drawdowns: [String: Double] = [:]
        do {
            let data = try await fetchResearchData(path: Self.fundDrawdownsPath, query: [
                .init(name: "thscode", value: thscode),
            ])
            try Task.checkCancellation()
            drawdowns = try Self.parseFundDrawdowns(data: data)
            anySucceeded = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errors["最大回撤"] = FuyaoProvider.researchMessage(error)
            if Self.isRateLimited(error) { throw error }
        }

        // 3) 净值点位。`nav_type` 显式要两类，这样字段一定成对出现。
        do {
            var query: [URLQueryItem] = [
                .init(name: "thscode", value: thscode),
                .init(name: "nav_type", value: "unit,adj"),
            ]
            if let navRange { query.append(.init(name: "range", value: navRange.rawValue)) }
            let data = try await fetchResearchData(path: Self.fundNavPath, query: query)
            try Task.checkCancellation()
            navs = try Self.parseFundNavs(data: data)
            anySucceeded = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errors["净值"] = FuyaoProvider.researchMessage(error)
            if Self.isRateLimited(error) { throw error }
        }

        guard anySucceeded else {
            // 三个都失败：报出来，让调用方回退，而不是返回一个"成功但空"的答案。
            throw ProviderError.badResponse("fuyao fund-performance: all endpoints failed")
        }

        for window in FuyaoPerformanceWindow.allCases {
            let period = FuyaoPerformancePeriod(
                window: window,
                returnPercent: returns[window.returnKey],
                peerAveragePercent: returns[window.peerAverageKey],
                rank: ranks[window.rankKey],
                rankTotal: ranks[window.rankTotalKey],
                drawdownPercent: drawdowns[window.drawdownKey]
            )
            // 三个字段全空的行没有信息量，不占位置。
            if period.returnPercent != nil || period.rank != nil || period.drawdownPercent != nil {
                periods.append(period)
            }
        }

        return FuyaoFundPerformance(
            thscode: thscode,
            periods: periods,
            navs: navs,
            fetchedAt: .now,
            errors: errors
        )
    }

    // MARK: - 解析

    /// `returns` 的顶层是 `data.item[]`，单条记录里同时混着数值与排名。
    /// 取第一条含任一已知键的记录；缺失的键保持 nil。
    static func parseFundReturns(data: Data) throws -> (values: [String: Double], ranks: [String: Int]) {
        guard let row = try firstItem(data: data, endpoint: "fund-returns") else { return ([:], [:]) }
        var values: [String: Double] = [:]
        var ranks: [String: Int] = [:]
        for window in FuyaoPerformanceWindow.allCases {
            for key in [window.returnKey, window.peerAverageKey] {
                if let raw = double(row, key), raw.isFinite { values[key] = raw }
            }
            for key in [window.rankKey, window.rankTotalKey] {
                if let raw = integer(row, key), raw >= 0 { ranks[key] = raw }
            }
        }
        return (values, ranks)
    }

    /// 取出信封里的第一条 `data.item[]`，保留上游的原始键名。
    ///
    /// 不用 `decodePayload`：那条路径的 `decodeKey` 策略会做 snake_case 转换，
    /// 而这里的键名（`return_year`、`rank_total_year`）是契约的一部分，转换后
    /// 就查不到了。手工拆信封是让键名保持原样的最直接办法。
    static func firstItem(data: Data, endpoint: String) throws -> [String: Any]? {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw ProviderError.badResponse("\(endpoint): \(error.localizedDescription)") }
        guard let object = root as? [String: Any] else {
            throw ProviderError.badResponse("\(endpoint): not an object")
        }
        // 业务错误即使 HTTP 200 也要按错误上报。
        if let code = object["code"] as? Int, code != 0 {
            let message = object["message"] as? String
            throw providerError(code: code, message: message, endpoint: endpoint)
        }
        let payload = object["data"] as? [String: Any]
        let items = payload?["item"] as? [[String: Any]]
        return items?.first
    }

    /// 数值可能以 Int、Double 或 NSNumber 出现，三种都接受。
    static func double(_ row: [String: Any], _ key: String) -> Double? {
        switch row[key] {
        case let value as NSNumber: return value.doubleValue.isFinite ? value.doubleValue : nil
        case let value as String: return Double(value).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// 只接受整数值；小数不截断成整数。
    static func integer(_ row: [String: Any], _ key: String) -> Int? {
        guard let value = double(row, key), value == value.rounded(), abs(value) < 9e15 else { return nil }
        return Int(value)
    }

    /// `drawdowns` 全为**负值百分数**，负号是契约的一部分。
    static func parseFundDrawdowns(data: Data) throws -> [String: Double] {
        guard let row = try firstItem(data: data, endpoint: "fund-drawdowns") else { return [:] }
        var result: [String: Double] = [:]
        for window in FuyaoPerformanceWindow.allCases {
            if let raw = double(row, window.drawdownKey), raw.isFinite {
                result[window.drawdownKey] = raw
            }
        }
        return result
    }

    /// 净值点位。`nav_type` 决定字段是否出现，这里两个都按可选读。
    static func parseFundNavs(data: Data) throws -> [FuyaoFundNavPoint] {
        let payload = try decodePayload(FundNavPayload.self, from: data, endpoint: "fund-nav")
        var byDate: [Date: FuyaoFundNavPoint] = [:]
        for row in payload.item ?? [] {
            guard let date = millisecondDate(row.navDate) else { continue }
            let unit = row.unitNav.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let adjusted = row.adjNav.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            guard unit != nil || adjusted != nil else { continue }
            // 同一日期重复时保留后一条（上游按升序返回，后者更新）。
            byDate[date] = FuyaoFundNavPoint(date: date, unitNav: unit, adjustedNav: adjusted)
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    // MARK: - 线格式

    static let fundReturnsPath = "/api/fund/performance/returns"
    static let fundDrawdownsPath = "/api/fund/performance/drawdowns"
    static let fundNavPath = "/api/fund/performance/nav"

    struct FundNavPayload: Decodable {
        let item: [NavRow]?
    }

    struct NavRow: Decodable {
        let navDate: Double?
        let unitNav: Double?
        let adjNav: Double?
    }
}

extension FuyaoProvider {
    /// 研究请求的错误文案，与 Mac 层的 `FuyaoResearchController.message` 同义。
    /// 放在 Core 里是因为三个端点的组合逻辑需要自己描述部分失败。
    static func researchMessage(_ error: any Error) -> String {
        guard let error = error as? ProviderError else { return "获取失败" }
        return switch error {
        case .rateLimited: "请求受限"
        case .sourceRefused: "来源暂时拒绝请求"
        case .clientError(let status, _):
            switch status {
            case 401: "授权不可用"
            case 403: "当前接口权限不可用"
            case 404: "来源暂无可用数据"
            default: "请求未被来源接受"
            }
        default: "获取失败"
        }
    }

    static func isRateLimited(_ error: any Error) -> Bool {
        if case ProviderError.rateLimited = error { return true }
        return false
    }
}
