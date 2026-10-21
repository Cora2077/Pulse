import Foundation

// 同花顺板块（行业 / 概念）目录、成分股，以及板块相对基准的区间强弱。
//
// 这里只有纯值：目录与成分股是来源原样转述的引用数据，相对强弱是本地计算。
// 缓存、刷新时机与界面呈现都由调用方决定。

/// 同花顺板块目录中的一行（行业或概念）。身份是来源的完整 thscode。
public struct FuyaoBoard: Identifiable, Codable, Hashable, Sendable {
    /// 完整代码，如 `886042.TI`。
    public let thscode: String
    /// 来源发布的展示名称。
    public let name: String
    /// Pulse 身份：仅当 thscode 是合法的 6 位 `88` 开头 `.TI` 代码时存在。
    /// 板块代码不一定在本地目录里，因此名称取来源发布值。
    public let symbol: SymbolID?

    public var id: String { thscode }

    /// 由来源行构造；`symbol` 按 thscode 校验后推导。
    public init(thscode: String, name: String) {
        self.thscode = thscode
        self.name = name
        self.symbol = Self.boardSymbol(thscode: thscode, name: name)
    }

    /// 显式给出身份（解码或测试用）。
    public init(thscode: String, name: String, symbol: SymbolID?) {
        self.thscode = thscode
        self.name = name
        self.symbol = symbol
    }

    /// 只接受 `{6 位数字，88 开头}.TI` 这一种形态；其余代码没有可映射的身份。
    static func boardSymbol(thscode: String, name: String) -> SymbolID? {
        guard let code = thiBoardCode(thscode) else { return nil }
        return SymbolID(sectorIndex: SectorIndexID(code: code, name: name))
    }

    /// 校验 `.TI` 板块代码并返回纯代码；不合法时返回 nil。
    static func thiBoardCode(_ thscode: String) -> String? {
        let parts = thscode.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "TI" else { return nil }
        let code = String(parts[0])
        guard code.utf8.count == 6, code.hasPrefix("88"),
              code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return code
    }
}

/// 同花顺板块成分股中的一行。
public struct FuyaoConstituent: Identifiable, Codable, Hashable, Sendable {
    /// 完整代码，如 `600519.SH`。
    public let thscode: String
    public let name: String
    /// Pulse 身份：`.SH` / `.SZ` 可映射；`.BJ` 代码保留在模型中但 `symbol` 为 nil
    /// （本项目暂无北京市场）。
    public let symbol: SymbolID?

    public var id: String { thscode }

    /// 由来源行构造；`symbol` 按 thscode 校验后推导。
    public init(thscode: String, name: String) {
        self.thscode = thscode
        self.name = name
        self.symbol = Self.shareSymbol(thscode: thscode)
    }

    /// 显式给出身份（解码或测试用）。
    public init(thscode: String, name: String, symbol: SymbolID?) {
        self.thscode = thscode
        self.name = name
        self.symbol = symbol
    }

    /// 6 位数字代码后的 `.SH` / `.SZ` 映射为普通股票身份（不猜测指数身份）。
    static func shareSymbol(thscode: String) -> SymbolID? {
        guard let (code, market) = shareCode(thscode) else { return nil }
        return SymbolID(market: market, code: code)
    }

    /// 合法的 `.SH` / `.SZ` 成分股代码及其市场；`.BJ` 与其它后缀返回 nil。
    static func shareCode(_ thscode: String) -> (code: String, market: Market)? {
        let parts = thscode.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let code = String(parts[0])
        guard code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        switch parts[1] {
        case "SH": return (code, .sh)
        case "SZ": return (code, .sz)
        default: return nil
        }
    }
}

/// 一个板块相对基准的区间强弱，单位为百分点（板块区间涨幅 − 基准区间涨幅）。
///
/// 日期按 Asia/Shanghai 日历归一；锚点固定为基准最新有效交易日，板块必须有
/// 同一天的有效收盘。5 日与 20 日的基期分别是基准最新日之前的第 5 个、第 20 个
/// 交易日——绝不把两侧日期交集压缩成 5 / 20 日。任何一段缺基期或数值非有限
/// 时，该段结果为 nil，其余段照常给出。
public struct FuyaoRelativeStrength: Codable, Hashable, Sendable {
    /// 计算所用的基准最新有效日（Asia/Shanghai 零点）。
    public let dataTime: Date?
    /// 5 日相对强弱，百分点。
    public let fiveDay: Double?
    /// 20 日相对强弱，百分点。
    public let twentyDay: Double?
    /// 板块自身 5 日区间涨幅，百分数（`5.2` 表示 5.2%）。
    public let boardFiveDay: Double?
    /// 板块自身 20 日区间涨幅，百分数。
    public let boardTwentyDay: Double?

    public init(
        dataTime: Date?,
        fiveDay: Double?,
        twentyDay: Double?,
        boardFiveDay: Double?,
        boardTwentyDay: Double?
    ) {
        self.dataTime = dataTime
        self.fiveDay = fiveDay
        self.twentyDay = twentyDay
        self.boardFiveDay = boardFiveDay
        self.boardTwentyDay = boardTwentyDay
    }

    /// 无锚点日、无任何有效区间结果。
    public static let empty = FuyaoRelativeStrength(
        dataTime: nil, fiveDay: nil, twentyDay: nil, boardFiveDay: nil, boardTwentyDay: nil
    )

    public static let fiveDayLookback = 5
    public static let twentyDayLookback = 20

    /// 以基准最新有效交易日为锚点，计算板块相对基准的 5 日与 20 日强弱。
    public static func calculate(board: [Candle], benchmark: [Candle]) -> FuyaoRelativeStrength {
        let base = normalize(benchmark)
        guard let anchor = base.last, let anchorClose = anchor.close else { return .empty }

        let boardRows = normalize(board)
        let anchorKey = anchor.key
        let boardCloses = closeByDay(boardRows)
        guard let boardAnchorClose = boardCloses[anchorKey] else {
            // 板块缺少锚点当天的有效收盘：日期照实给出，所有区间结果为 nil。
            return FuyaoRelativeStrength(
                dataTime: anchor.day,
                fiveDay: nil,
                twentyDay: nil,
                boardFiveDay: nil,
                boardTwentyDay: nil
            )
        }

        var fiveDay: Double?
        var boardFiveDay: Double?
        if let index = baseIndex(before: base.count - 1, lookback: fiveDayLookback),
           let baseStart = base[index].close,
           let boardStart = boardCloses[base[index].key] {
            (
                fiveDay, boardFiveDay
            ) = pair(
                boardStart: boardStart,
                boardEnd: boardAnchorClose,
                benchmarkStart: baseStart,
                benchmarkEnd: anchorClose
            )
        }

        var twentyDay: Double?
        var boardTwentyDay: Double?
        if let index = baseIndex(before: base.count - 1, lookback: twentyDayLookback),
           let baseStart = base[index].close,
           let boardStart = boardCloses[base[index].key] {
            (
                twentyDay, boardTwentyDay
            ) = pair(
                boardStart: boardStart,
                boardEnd: boardAnchorClose,
                benchmarkStart: baseStart,
                benchmarkEnd: anchorClose
            )
        }

        return FuyaoRelativeStrength(
            dataTime: anchor.day,
            fiveDay: fiveDay,
            twentyDay: twentyDay,
            boardFiveDay: boardFiveDay,
            boardTwentyDay: boardTwentyDay
        )
    }

    // MARK: - 归一

    /// 一个按日归一后的收盘行；`close` 只在正数有限时为价格。
    private struct Row {
        let key: CalendarDay
        let day: Date
        let close: Double?
    }

    /// 按 Asia/Shanghai 日历归一交易日：同一交易日保留列表中最后一行（不
    /// 拼接或求和），随后按日期升序。无效 close 的行保留日期但不算价格，
    /// 因此“最新日无效”不会被误当成“板块没有这一天”而回退到更早一天。
    private static func normalize(_ candles: [Candle]) -> [Row] {
        var byDay: [CalendarDay: (order: Int, day: Date, close: Double?)] = [:]
        var nextOrder = 0
        for candle in candles {
            guard candle.time.timeIntervalSince1970.isFinite else { continue }
            let key = CalendarDay(candle.time, in: beijingTimeZone)
            let day = startOfDay(key)
            let close = validPrice(candle.close)
            if let existing = byDay[key], existing.order >= nextOrder {
                continue
            }
            byDay[key] = (nextOrder, day, close)
            nextOrder += 1
        }
        return byDay.keys.sorted().compactMap { key in
            byDay[key].map { Row(key: key, day: $0.day, close: $0.close) }
        }
    }

    private static func closeByDay(_ rows: [Row]) -> [CalendarDay: Double] {
        var closes: [CalendarDay: Double] = [:]
        for row in rows where closes[row.key] == nil {
            if let close = row.close { closes[row.key] = close }
        }
        return closes
    }

    /// 基准第 `anchorIndex` 行之前的第 `lookback` 个交易日的下标。
    private static func baseIndex(before anchorIndex: Int, lookback: Int) -> Int? {
        let index = anchorIndex - lookback
        return index >= 0 ? index : nil
    }

    private static func validPrice(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// 板块与基准的区间涨幅（百分数）及其差值（百分点）。
    private static func pair(
        boardStart: Double,
        boardEnd: Double,
        benchmarkStart: Double,
        benchmarkEnd: Double
    ) -> (relative: Double?, board: Double?) {
        guard let boardChange = changePercent(from: boardStart, to: boardEnd),
              let benchmarkChange = changePercent(from: benchmarkStart, to: benchmarkEnd) else {
            return (nil, nil)
        }
        return (boardChange - benchmarkChange, boardChange)
    }

    /// `(last - first) / first × 100`，仅当两端都是可用价格且结果有限。
    private static func changePercent(from first: Double, to last: Double) -> Double? {
        let result = (last - first) / first * 100
        guard result.isFinite else { return nil }
        return result
    }

    private static func startOfDay(_ key: CalendarDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        return calendar.date(from: DateComponents(year: key.year, month: key.month, day: key.day))
            ?? Date(timeIntervalSince1970: 0)
    }

    private static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!
}
