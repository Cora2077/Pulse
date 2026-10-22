import Foundation

// A 股财务指标（成长 / 盈利 / 偿债 / 营运 / 现金流五类）。
//
// 这个模型存在的理由不是"把 JSON 转成 struct"，而是**单位**。上游把每个指标
// 的值都塞进同一个 `value` 字符串字段，百分比、倍数、周转次数混在一起，只有
// 指标名（`index_id`）才知道该怎么读。所以这里配一张目录表：认识的 id 才有
// 标题与单位，不认识的 id 保留原始值但**不展示**——宁可少一行，也不把一个
// 百分数当倍数印出来。
//
// 另一个实测事实：`index_id` 不是封闭枚举。2026-10-20 的真实返回里，`growth`
// 组给出的 5 个 id 与官方文档表格列出的并不一致（文档列的 3 个没出现，实际
// 出现的 4 个文档没列），`cash-flow` 组还比文档少一个。因此解析一律"全收、
// 按 id 查表"，绝不因为"不在文档里"就丢掉整组。

/// 一个指标的单位。上游不声明单位，只能按指标语义定。
public enum FuyaoIndicatorUnit: String, Codable, Sendable {
    /// 百分数值（`15.19` 表示 15.19%）。展示时加 `%`，绝不二次乘 100。
    case percent
    /// 倍数（流动比率、已获利息倍数等），无单位。
    case multiple
    /// 周转次数，展示为"次"。
    case times

    public var suffix: String {
        switch self {
        case .percent: "%"
        case .multiple: ""
        case .times: "次"
        }
    }
}

/// 指标的展示定义。只有在这张表里的 id 才会出现在界面上。
public struct FuyaoIndicatorDefinition: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let unit: FuyaoIndicatorUnit
}

/// 五类能力。顺序与契约一致。
public enum FuyaoIndicatorAbility: String, Codable, CaseIterable, Sendable, Identifiable {
    case growth
    case profitability
    case solvency
    case operation
    case cashFlow = "cash-flow"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .growth: "成长"
        case .profitability: "盈利"
        case .solvency: "偿债"
        case .operation: "营运"
        case .cashFlow: "现金流"
        }
    }
}

/// 一个指标值。`rawValue` 保留上游字符串（含尾随小数位），`value` 是解析结果。
/// 上游缺失是 `null`，解析失败也留 nil——两者都不补零。
public struct FuyaoIndicatorValue: Codable, Hashable, Sendable, Identifiable {
    public let indexID: String
    public let rawValue: String?
    public let value: Double?

    public var id: String { indexID }

    public init(indexID: String, rawValue: String?, value: Double?) {
        self.indexID = indexID
        self.rawValue = rawValue
        self.value = value
    }

    /// 目录表里的定义；未知 id 为 nil，界面据此隐藏而不是猜单位。
    public var definition: FuyaoIndicatorDefinition? {
        FuyaoIndicatorCatalog.definition(for: indexID)
    }

    /// 带单位的展示文本。未知单位、缺失值都返回 nil，由界面显示占位符。
    public var displayText: String? {
        guard let definition, let value, value.isFinite else { return nil }
        return FuyaoIndicatorCatalog.text(value, unit: definition.unit)
    }
}

/// 一类能力的指标集合。
public struct FuyaoIndicatorGroup: Codable, Hashable, Sendable, Identifiable {
    public let ability: FuyaoIndicatorAbility
    /// 上游返回的全部指标，按上游顺序。
    public let values: [FuyaoIndicatorValue]

    public var id: String { ability.rawValue }

    public init(ability: FuyaoIndicatorAbility, values: [FuyaoIndicatorValue]) {
        self.ability = ability
        self.values = values
    }

    /// 有展示定义的指标，按目录顺序（而不是上游顺序）排，让跨报告期的位置稳定。
    /// 同一 id 若出现多次（上游重复），只保留第一条。
    public var displayable: [FuyaoIndicatorValue] {
        var seen: Set<String> = []
        return values
            .filter { $0.definition != nil && seen.insert($0.indexID).inserted }
            .sorted { lhs, rhs in
                let left = FuyaoIndicatorCatalog.order(of: lhs.indexID)
                let right = FuyaoIndicatorCatalog.order(of: rhs.indexID)
                return left == right ? lhs.indexID < rhs.indexID : left < right
            }
    }
}

/// 一个报告期的五类指标。
public struct FuyaoIndicatorSet: Codable, Hashable, Sendable {
    public let thscode: String
    /// 报告期标识，`yyyy-N`（`N`：1 一季报 / 2 中报 / 3 三季报 / 4 年报）。
    public let report: String
    public let groups: [FuyaoIndicatorGroup]
    public let fetchedAt: Date

    public init(thscode: String, report: String, groups: [FuyaoIndicatorGroup], fetchedAt: Date) {
        self.thscode = thscode
        self.report = report
        self.groups = groups
        self.fetchedAt = fetchedAt
    }

    /// 报告期的人类可读形式，例如 `2026-2` → `2026 中报`。
    public var reportTitle: String {
        let parts = report.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let index = Int(parts[1]) else { return report }
        let name = switch index {
        case 1: "一季报"
        case 2: "中报"
        case 3: "三季报"
        case 4: "年报"
        default: "第 \(index) 期"
        }
        return "\(year) \(name)"
    }

    /// 非空分组，保持契约顺序。
    public var nonEmptyGroups: [FuyaoIndicatorGroup] {
        let order = FuyaoIndicatorAbility.allCases
        return groups
            .filter { !$0.displayable.isEmpty }
            .sorted { (order.firstIndex(of: $0.ability) ?? .max) < (order.firstIndex(of: $1.ability) ?? .max) }
    }

    /// 某个 id 的值（用于跨报告期比较）。
    public func value(of indexID: String) -> Double? {
        groups.lazy.flatMap(\.values).first { $0.indexID == indexID }?.value
    }
}

/// 指标目录与格式化。
public enum FuyaoIndicatorCatalog {
    /// 已确认标题与单位的指标。**没在这张表里的 id 不展示**——上游不声明单位，
    /// 猜错单位比少一行更糟。
    ///
    /// `alias` 说明：上游同一指标存在带 `calculate_` 前缀与不带前缀两种写法
    /// （2026-10-20 实测），两者归一到同一 id。
    private static let entries: [(id: String, title: String, unit: FuyaoIndicatorUnit, aliases: [String])] = [
        // 成长
        ("operating_income_yoy_growth_ratio", "营业收入同比增长率", .percent,
         ["calculate_operating_income_yoy_growth_ratio"]),
        ("parent_holder_net_profit_yoy_growth_ratio", "归母净利润同比增长率", .percent,
         ["calculate_parent_holder_net_profit_yoy_growth_ratio", "net_profit_yoy_growth_ratio"]),
        ("operating_profit_yoy_growth_ratio", "营业利润同比增长率", .percent,
         ["calculate_operating_profit_yoy_growth_ratio"]),
        ("total_assets_growth_ratio", "总资产增长率", .percent, []),
        // 盈利
        ("index_weighted_avg_roe", "净资产收益率", .percent, []),
        ("index_deduct_weighted_avg_roe", "扣非加权净资产收益率", .percent, []),
        ("sale_gross_margin", "销售毛利率", .percent, []),
        ("sale_net_interest_ratio", "销售净利率", .percent, []),
        ("total_assets_net_ratio", "总资产收益率", .percent, []),
        // 偿债
        ("assets_debt_ratio", "资产负债率", .percent, []),
        ("current_ratio", "流动比率", .multiple, []),
        ("quick_ratio", "速动比率", .multiple, []),
        // 现金比率按合同是百分数（实测 114.7 表示 114.7%），不是倍数。
        ("cash_ratio", "现金比率", .percent, []),
        ("earned_interest_multiple", "已获利息倍数", .multiple, []),
        // 营运
        ("total_assets_turnover_ratio", "总资产周转率", .times, []),
        ("inventory_turnover_ratio", "存货周转率", .times, []),
        ("current_assets_turnover_ratio", "流动资产周转率", .times, []),
        ("receive_account_turnover_ratio", "应收账款周转率", .times, []),
        ("long_term_debt_equity_ratio", "长期负债权益比率", .multiple, []),
        // 现金流
        ("net_profit_cash_content", "净利润现金含量", .percent, []),
        ("cash_operating_index", "现金营运指数", .multiple, []),
        ("operating_cash_flow_net_divide_income", "销售现金比率", .percent, []),
        ("cash_meet_invest_ratio", "现金满足投资比率", .multiple, []),
        ("operating_cash_net_yoy_growth_ratio", "经营现金流净额增长率", .percent, []),
    ]

    /// id（含别名）→ 定义 与 id → 目录序号，一起构建，避免依赖初始化顺序。
    private static let table: (definitions: [String: FuyaoIndicatorDefinition], order: [String: Int]) = {
        var definitions: [String: FuyaoIndicatorDefinition] = [:]
        var order: [String: Int] = [:]
        for (offset, entry) in entries.enumerated() {
            let definition = FuyaoIndicatorDefinition(id: entry.id, title: entry.title, unit: entry.unit)
            definitions[entry.id] = definition
            order[entry.id] = offset
            for alias in entry.aliases {
                definitions[alias] = definition
                order[alias] = offset
            }
        }
        return (definitions, order)
    }()

    /// 精确 id 或别名对应的定义。
    public static func definition(for indexID: String) -> FuyaoIndicatorDefinition? {
        if let hit = table.definitions[indexID] { return hit }
        // 上游对同一指标存在带 `calculate_` 前缀与不带前缀两种写法；归一再查一次。
        if indexID.hasPrefix("calculate_") {
            return table.definitions[String(indexID.dropFirst("calculate_".count))]
        }
        return nil
    }

    /// 目录中的稳定顺序，用于让同一指标在不同报告期落在同一位置。
    static func order(of indexID: String) -> Int {
        if let hit = table.order[indexID] { return hit }
        if indexID.hasPrefix("calculate_") {
            return table.order[String(indexID.dropFirst("calculate_".count))] ?? Int.max
        }
        return Int.max
    }

    /// 按单位格式化。百分数直接加 `%`（上游已是百分数值），倍数与次数保留有限小数。
    public static func text(_ value: Double, unit: FuyaoIndicatorUnit) -> String {
        guard value.isFinite else { return "—" }
        switch unit {
        case .percent:
            return trimmed(value, digits: 2) + "%"
        case .multiple:
            return trimmed(value, digits: 2)
        case .times:
            return trimmed(value, digits: 2) + "次"
        }
    }

    /// 定点后去掉多余尾零，不做"好看"的舍入。展示层复用同一份格式化，
    /// 避免"变化量"与"指标值"用两套小数位写法。
    public static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        // 避免 "-0" 这种符号残留。
        return text == "-0" ? "0" : text
    }

    /// 校验报告期参数 `yyyy-N`。**本地校验**，不把明显写错的期次发出去换 `1002`。
    public static func isValidReport(_ report: String) -> Bool {
        let parts = report.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, let year = Int(parts[0]),
              (1990...2100).contains(year) else { return false }
        // 期次是单个数字 `1`…`4`。`2026-01` 与 `2026-04` 不是契约形式，
        // 接受它们会让"校验通过"与"上游接受"变成两件事。
        let index = parts[1]
        guard index.count == 1, let value = Int(index), (1...4).contains(value) else { return false }
        return true
    }

    /// 由财报表的 `fiscalYear` 与 `fiscalPeriod` 拼出报告期标识。
    ///
    /// 上游财报表用 `Q1`…`Q4` 标注期次；若出现无法识别的写法就返回 nil，
    /// 由调用方跳过该期，而不是猜一个期次出来。
    public static func report(fiscalYear: Int, fiscalPeriod: String) -> String? {
        let text = fiscalPeriod.uppercased().trimmingCharacters(in: .whitespaces)
        let index: Int?
        if text.hasPrefix("Q"), let value = Int(text.dropFirst()) {
            index = value
        } else if text == "H1" {
            index = 2
        } else if text == "H2" || text == "A" || text == "ANNUAL" {
            index = 4
        } else if let value = Int(text) {
            index = value
        } else {
            index = nil
        }
        guard let index, (1...4).contains(index), (1990...2100).contains(fiscalYear) else { return nil }
        return "\(fiscalYear)-\(index)"
    }
}
