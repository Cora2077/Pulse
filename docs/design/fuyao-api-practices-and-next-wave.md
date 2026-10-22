# 扶摇 API 最佳实践与 FFF 下一轮功能设计

2026-10-22，Asia/Shanghai。

**范围与证据**：逐节读过 `https://fuyao.aicubes.cn/llms-full.txt`（2026-10-22 抓取，14861 行）与仓库现有实现；对照 [此前接口评估](../verification/fuyao-api-evaluation-2026-10-20.md)、[行情刷新验收](../verification/fuyao-fast-refresh-2026-10-20.md)、[六项研究验收](../verification/fuyao-features-2026-10-21.md)，并**重新核对了 2026-10-20 那轮留下的只读响应存档**（`/private/tmp/fuyao-probe-20261020/`，不含 Key）。本轮**没有发起新的线上请求**，没有改数据源配置、账本或日常 App。

证据分三层，后文按层标注：
1. **文档契约**——「可用 / 客户端专用 / 敬请期待」全部照抄官方原文。
2. **既有实测**——10-20 存档能直接核对的事实，集中在 §2.4，并已据此修正设计（竞价量单位、状态枚举、财务指标 id 集合）。
3. **仍未验证**——§6 列出 8 项，写明"验不过就不做什么"。

---

## 0. 一页结论

1. 扶摇的问题不在数据质量，而在三条契约纪律：**`code` 才是业务状态**、**标的类型决定端点**、**时间与未知不能被顺手填平**。FFF 现有实现已经守住大部分，新增端点必须继续守，而不是"按 REST 常识"接。
2. FFF 已接入 22 条路径，覆盖行情与六项研究。**可用而未接入**的高价值能力集中在七处：除权事件、龙虎榜、集合竞价、财务指标、基金业绩、交易日历、打新。
3. 本轮设计 7 项：P0 两项解决"会算错/会看错"的问题（除权与计划价格口径、龙虎榜重复行），P1 三项补盘前与基本面，P2 两项做基础设施与低频日历。
4. 新增请求预算见下表，合计约 **240 次/日**；对照现行 1 秒目标轮询（连续 4 小时约 14,400 次）约 1.7%。唯一需要临时提高优先级的是 9:15–9:25 竞价窗口，有硬上限且窗口结束即停。

   | 项 | 频次 | 上限/日 |
   | --- | --- | --- |
   | P0-1 除权 | 每标的 1 次，缓存 7 天 | 20（按 20 个有活跃计划的标的） |
   | P0-2 龙虎榜 + 监管 | 300s 缓存，页签切换才请求 | 30 |
   | P1-3 竞价 | 窗口内每 5s 一批 | 126（硬上限） |
   | P1-4 财务指标 | 展开财报才请求，4 期 × 24h 缓存 | 40（按 10 个标的） |
   | P1-5 基金业绩 | 3 端点/标的/小时 | 15（按 5 只 ETF） |
   | P2-6 交易日历 | 1 次/日 | 1 |
   | P2-7 打新 | 6 组合/6 小时，展开才请求 | 6 |

   竞价一项占全部新增预算的一半以上，这也是它必须独立设上限、且明确"窗口结束即停"的原因。
5. 明确不做 6 类，理由见 §5：客户端专用 4 项、敬请期待 3 项、期货期权、全市场 dump、公告解读（缺列表端点）、快讯（`tag_id` 无定义）。

---

## 1. 扶摇 API 最佳实践

### 1.1 十三条规则（依据 → FFF 现状 → 差距）

| # | 规则 | 文档依据 | FFF 现状 | 差距 / 动作 |
| --- | --- | --- | --- | --- |
| 1 | 用信封 `code` 判业务结果，HTTP 只判传输；**429 例外**：无论响应体是否带标准信封都按限流处理 | 接口总览「响应信封」 | `decodePayload` 与 `HTTPClient` 双重检查 | 无 |
| 2 | 错误分两类：源故障（网络/5xx/限流）才进熔断；`2001/2003/2004/3xxx` 是请求或权限问题 | 错误码表；`CompositeProvider.noteFailure` | `ProviderError.shouldTrip` 已分类，`2004` 特判为权限类 | 新端点把 `3002`（数据未就绪）当"暂无数据"而非故障 |
| 3 | 批量端点先去重再控上限（**≤100 token**），服务端按入参顺序返回 | `prices/snapshot`、`valuations/snapshot`、`auction/snapshot` | 行情与成分股按 100 分批 | 估值现为单码调用，P1-4 顺带改批量 |
| 4 | 单码端点（`historical`、`corporate-actions`、`constituents`、`fund/market/*`）**不接受逗号**，不要并行轰炸 | 各端点参数说明 | 所有请求共用 actor 级 0.5s 最小间隔 | 竞价窗口单独开口，见 P1-3 的优先级规则 |
| 5 | 限流是动态策略，不是契约数字；只做降并发 + 退避，**不立即重试** | 「调用频率与限流」；`4001`/`429` | 429 停后续批次 + 30s 冷却 | 无 |
| 6 | 省略参数 ≠ 不限制。逐端点确认缺省语义 | 涨跌停池省略 `date_ms` 回退"**自然日**"；龙虎榜省略 `date` 取**上一交易日** | 涨跌停池显式传 `date_ms`（正确做法） | 新端点先读"默认值"列再写调用 |
| 7 | 复权口径显式且**不可混缓存**；基金日线只有前复权 | `adjust=none/forward/backward`；`fund/market/historical` 仅前复权 | 股票默认 `none`、图表 `forward` 分缓存；基金日线交腾讯 | 除权事件单独立模型，不回写价格（P0-1） |
| 8 | 三种时间分开：**上游就绪时间**、**业务日期**、**本机接收时间**；缺失保持未知 | `data.timestamp` 为"最新上游有效时间"，可为 `null` | `FuyaoTimed{value,dataTime,fetchedAt}`；缺时间的批次整批不采纳 | 新端点沿用，禁止 `now` 顶替 |
| 9 | 单位与量纲按端点核对；**文档未声明的量不展示** | `auction_volume`、`limit-break-pool.turnover`、`fund/market/snapshot.volume` 均无单位声明 | 现有端点只取明示单位字段（股/元/百分数） | 竞价卡不展示成交量，只展示价、额、量比 |
| 10 | 日期参数三种格式、窗口各不相同；**请求前本地校验**，别等 `1002/1003` | `yyyy-MM-dd` / `yyyyMMdd` / 毫秒戳；一年窗口 vs 五年窗口 | 各调用点自行换算 | 交易日历校准（P2-6），并为龙虎榜/统计提供候选日 |
| 11 | 重复行不是脏数据，聚合前先定**分组键** | 龙虎榜 `count > stock_count`（当日榜 + 3 日榜）；机构席位 `department_id` 可重复；港股重复递表 | 涨跌停池按 `thscode` 去重 | 龙虎榜必须按 `range_days` 分组（P0-2 的核心约束） |
| 12 | 空 ≠ 降级：空数组可能表示上游降级 | 异动解读原文明说"空列表也可能表示服务降级" | 部分失败保留成功项 | 列表类新功能要有"无法确认"态，而非"无数据" |
| 13 | 能力边界要可见：客户端专用、敬请期待**不进设计**，也不要用空态伪装成功能 | 6 项客户端专用、3 项敬请期待 | 设置页已说明可用性 | §5 列表化，避免下次重复评估 |

### 1.2 三条 FFF 已固化、应继续遵守的本地纪律

- **研究与报价共用一个凭据与一条节流预算**：研究请求向在途报价让出时隙，避免"打开板块就被行情挤死"或反过来。
- **缺失/非法时间戳不入库**：整批拒绝好过用 `now` 冒充；单批失败只损失该批。
- **权限类 `2004` 不熔断整源**：否则一个基金请求会带走全部 A 股报价。

---

## 2. FFF 现状盘点

### 2.1 已接入：22 条路径

| 能力 | 路径 | 位置 |
| --- | --- | --- |
| 股票 / 指数 / ETF 快照 | `/api/a-share/prices/snapshot`、`/api/a-share-index/prices/snapshot`、`/api/fund/market/snapshot` | `FuyaoProvider.swift` |
| 股票 / 指数日线 | `/api/a-share/prices/historical`、`/api/a-share-index/prices/historical` | 同上 |
| 标的检索（类型与名称的唯一来源） | `/api/meta/tickers/search` | 同上 |
| 个股新闻 / 异动 / 热榜 / 排名走势 | `/api/news/stock/timeline-list`、`special-data/anomaly-analysis-stock`、`hot-stock-list`、`hot-stock-rank-trend` | `FuyaoProvider+Intelligence.swift` |
| 市场情绪（统计 + 三池） | `special-data/limit-up-statistics`、`limit-up-pool`、`limit-down-pool`、`limit-break-pool` | `FuyaoProvider+Sentiment.swift` |
| 板块目录 / 成分股 | `/api/a-share-index/catalog/ths-index-list`、`constituents/ths-stock-list` | `FuyaoProvider+Boards.swift` |
| 三张报表 / 估值 | `/api/a-share/financials/{income,balance,cash-flow}-statements`、`valuations/snapshot` | `FuyaoProvider+Financials.swift` |
| ETF 披露持仓 | `/api/fund/portfolio/stock-report-dates`、`stock-history` | `FuyaoProvider+FundHoldings.swift` |

### 2.2 可用但未接入（按对本 App 的价值分档）

| 档 | 能力 | 端点 | 说明 |
| --- | --- | --- | --- |
| 高 | 除权除息事件流 | `GET /api/a-share/corporate-actions/adjustment-factors` | 单码、`from/to` 为 `YYYY-MM-DD`；只给每股分红与送股比，**不含配股** |
| 高 | 龙虎榜 | `GET /api/a-share/special-data/dragon-tiger-list` | 一次全量不分页；`board_type=all/org/hot_money`；当日榜与 3 日榜同响应 |
| 高 | 集合竞价快照 | `GET /api/a-share/auction/snapshot` | `thscodes` ≤100，`stage=live/final`；放量与未匹配量是差异化字段 |
| 高 | 财务指标五类 | `GET /api/a-share/financials/indicators` | 单码 + `report=yyyy-N`；`value` 为原始字符串，百分比按百分数原值 |
| 中高 | 基金净值 / 区间收益 / 回撤 | `/api/fund/performance/{nav,returns,drawdowns}` | 收益与回撤均为百分数原值；`nav` 不传 `range` 只回 1 条 |
| 中 | 交易日历 | `GET /api/a-share/calendar/trading-days` | 固定窗口 `[今日-1年, 今日]`，无入参；可校验本地表 |
| 中 | 严重异动 / 重点监控 | `GET /api/a-share/special-data/abnormal-monitor-list` | `size ≤ 30`；`end_date_ms=null` 表示**仍在监控** |
| 中 | 打新日历 | `GET /api/a-share/ipo/calendar-list` | 必须同时给 `market` 与 `status`，一个完整日历要 6 次调用 |
| 低 | 竞价机会筛选 / 风向标 | `special-data/auction-stock-opportunities`、`auction/short-term-benchmark` | 18 个 `warn_type` 无官方释义；`grade/explain` 是字符串；量单位未定义 |
| 低 | 连板天梯 | `GET /api/a-share/special-data/limit-up-ladder` | 固定 30 日 × 每板最多 4 只，不能当"该板全部股票" |
| 低 | 个股机构交易详情 | `special-data/dragon-tiger-stock-institution` | 一日榜/三日榜各一条，席位按"条数"语义不去重 |
| 低 | 基金资产/行业配置 | `/api/fund/portfolio/{asset,industry}-allocation` | 两套时间键（毫秒 vs `2026Q2`），无法直接 join |

### 2.3 不可用（本轮直接排除）

| 能力 | 状态 | 依据 |
| --- | --- | --- |
| 市场成交额预测、筹码形态、新增概念、宽基 ETF 净流入、资讯事件库 | **客户端专用** | 文档原文「该能力暂未开放外部接入」/「仅在同花顺AI客户端内提供」 |
| 股票基础信息、个股 → 同花顺指数反查、指数概况（含权重） | **敬请期待** | 原文「正在规划中」，且未给出路径 |
| 期货 / 期权 | 可用但无关 | 无 snapshot 端点；期权无 IV/Greeks/持仓，契约厚度不足以撑任何 UI |

### 2.4 此前探针存档的实测核对（2026-10-20 只读样本）

`/private/tmp/fuyao-probe-20261020/` 存有 2026-10-20 那轮的原始只读响应（不含 Key）。本轮重新读取核对，**据此修正了三处仅凭文档做出的设计假设**，设计已按实测改写：

| # | 文档写法 | 实测 | 对设计的影响 |
| --- | --- | --- | --- |
| 1 | `auction_volume` 单位未声明 | 两只标的均满足 `auction_amount ÷ auction_price = auction_volume × 100`（茅台 15425 股、平安银行 540700 股，误差 < 0.001%），即字段单位是**手**（1 手 = 100 股） | 竞价量**可以展示**，按"手"显示并注明换算；仍需在真实竞价窗口复验（见 §6 第 1 条） |
| 2 | 文档只以 `auction_phase` / `data_status` 的示例值说明阶段，未给取值清单 | 实测返回 `auction_phase="closed"`、`data_status="final"`，说明至少还有文档未列出的取值 | 状态解析必须是**开放字符串**，未知值按"状态未知"处理，不能写死 `ready/final` 判断 |
| 3 | 财务指标 `index_id` 与文档表格一致 | `growth` 组实际返回 5 项，其中 4 项文档未列（`calculate_operating_income_yoy_growth_ratio`、`calculate_operating_profit_yoy_growth_ratio`、`calculate_parent_holder_net_profit_yoy_growth_ratio`、`fixed_asset_invest_expansion_ratio`）；文档列的 `net_profit_yoy_growth_ratio` 等 3 项未出现。`cash-flow` 组少了文档列的 `operating_cash_net_yoy_growth_ratio` | `index_id` **不是封闭枚举**；展示白名单必须能命中实际 id，并对未知 id 降级 |

同一存档还确认了两条与设计相关的事实：

- **龙虎榜**：`trade_date=2026-10-19`（探针在 10-20 收盘后执行）证实"省略 `date` 取上一交易日"；`count=72`、`stock_count=67`、行数 72，`range_days` 分布 `{1: 55, 3: 17}`——重复行确实存在，且**有 4 行 `thscode` 为 `null`**（如 `301139` 元道退，仅 `ticker` 可用），另有 6 行 `.BJ`。
- **涨跌停统计**：`page_boards` 与 `exact_boards` 两套口径同时存在且不可互相校验（`five_plus` 档为合并档位），与 §1.1 第 11 条一致。

---

## 3. 设计

### P0-1 除权除息事件与计划价格口径复核

**要解决的问题**：项目用**不复权**价做真实成交价与计划触发价，用**前复权**画图。除权日不复权序列会出现真实断层，而计划的触发价是除权前设的——它没变，但它在序列里的相对位置变了。今天应用对此**完全沉默**：用户只知道价格"忽然跌了"，不知道为什么，也不知道该不该改计划。

**数据来源**
- `GET /api/a-share/corporate-actions/adjustment-factors?thscode=&from=&to=`（单码、`YYYY-MM-DD`、事件按 `ex_date_ms` 降序）。
- 事件类型由两字段隐式区分：`dividend_per_share`（每股现金分红，税前，元）+ `per_share_bonus`（每股送股比，`0.1` = 10 送 1）。两者同为 0 的行为无意义事件，丢弃。
- **配股不在此端点**（`allotment_ratio/allotment_price` 只在 market-dumps 的 Parquet 里）。界面必须写"配股与更早的特殊除权不在本数据内"，不能把"没有配股记录"说成"没有配股"。

**Core 模型**（新文件 `Models/FuyaoCorporateAction.swift`）

```swift
public struct FuyaoCorporateAction: Codable, Hashable, Sendable, Identifiable {
    public let thscode: String
    public let exDate: Date            // Asia/Shanghai 当日零点
    public let cashPerShare: Double?   // 税前，元；0 视为无现金分红
    public let bonusPerShare: Double?  // 0.1 = 10送1；0 视为无送股
    public var id: Date { exDate }
    public var hasCash: Bool { (cashPerShare ?? 0) > 0 }
    public var hasBonus: Bool { (bonusPerShare ?? 0) > 0 }
}
public struct FuyaoCorporateActionSeries: Codable, Hashable, Sendable {
    public let thscode: String
    public let actions: [FuyaoCorporateAction]   // 降序，已去重、已过滤空事件
    public let fetchedAt: Date
}
```

**计划口径提示**（纯派生，不落库、不改价）：给定 `plan` 与 `series`，命中条件为 `plan.status == .active` 且 `plan.createdAt < 最近一次 exDate` 且该事件 `hasCash || hasBonus`。文案只说事实：

> 该计划创建于 2026-06-19 除权除息之前（每股派 23.957 元、每股送 0.1 股）。不复权价格序列在该日出现断层，触发价相对位置已改变，请复核；本应用不会自动改价。

**调用计划与缓存**
- 只在两处触发：个股「情报」页签挂载时；工作台/计划页对有**活跃计划**的标的做一次后台补全。
- 每标的 1 次请求；内存 TTL 24h；持久化一份小型缓存（最多 200 个 thscode，TTL 7 天）避免每次冷启动重拉。事件本身一年只变几次，7 天足够。
- 最坏预算：20 个有活跃计划的标的 / 日 = **20 次**。

**界面**
1. 个股详情 →「情报」页签新增**除权除息**小节（最近 3 次）：日期、每股分红、每股送转；标注"仅现金分红与送股；配股不在本数据"。
2. 计划详情与计划卡片（仅在命中上述条件时）一行橙色提示 + 帮助气泡；措辞固定为"请复核"，无任何自动动作。
3. 图表除权标记列为**可选延伸**：在 `CandlestickChartView` 的日线标记层增加一种"除权"标记（与成交标记同层、不同图形）。不做则不影响本项验收。

**边界（不做）**
- 不自动改计划价格、不自动重算成本、不计算红利税、不推断分红到账。
- 不把前复权序列的断层解释为"下跌"；不把除权事件写进本机账本或同步文件。
- 不展示配股比例（无数据源），也不据"缺失"推断没有配股。

**验收**
- 构造合成序列：一笔除权在 3 个计划创建日之间，只提示 1 条计划；除权后创建的计划不提示。
- 取消/已完成计划、非沪深标的、无事件标的均不出现提示。
- 事件降序、同日重复事件去重、`cash=0 && bonus=0` 被过滤。
- 权限失败（`2004`）时该小节显示"当前凭据不可读取除权数据"，不影响其他情报项。

**测试**：`FuyaoCorporateActionsTests`（解析 / 去重 / 空事件 / 口径提示命中矩阵）、`FuyaoCorporateActionsSelfTest`（缓存与取消回写）。

---

### P0-2 复盘 · 资金与监管（龙虎榜 + 严重异动）

**要解决的问题**：复盘目前只有"我做了什么"和"当时的盘面情绪"，缺"谁在买、谁在被监管"。龙虎榜是 A 股复盘最通用的一份资金面证据，且是 `fuyao-feature-plan.md` 里已登记的后续候选。

**数据来源**
- `GET /api/a-share/special-data/dragon-tiger-list?board_type=all|org|hot_money&date=yyyy-MM-dd`
  - 固定全量、不分页；省略 `date` 时**即使今天是交易日也取上一个交易日**（文档原文如此；"为什么不含当天"属推断，§6 第 3 条实测时一并确认）。
  - `count` 可能大于 `stock_count`：同一股票可能同时有当日榜（`range_days=1`）与 3 日榜（`range_days=3`）。**任何按股票的聚合必须先按 `range_days` 分组**，否则金额重复计入。
  - `change`、`net_rate`、`org_net_rate`、`hot_money_net_rate` 是**小数**（`0.0999` = +9.99%）；金额字段是**元**。
- `GET /api/a-share/special-data/dragon-tiger-stock-institution?thscode=&date=&range_days=`（个股下钻，可选）
- `GET /api/a-share/special-data/abnormal-monitor-list?state=current|history&page=&size=`（`size ≤ 30`；`end_date_ms = null` 表示**仍在监控**，不是缺失）

**Core 模型**（新文件 `Models/FuyaoDragonTiger.swift`、`Models/FuyaoAbnormalMonitor.swift`）

```swift
public enum FuyaoDragonTigerBoard: String, Codable, CaseIterable, Sendable {
    case all
    case org
    case hotMoney = "hot_money"
}
public struct FuyaoDragonTigerRow: Codable, Hashable, Sendable, Identifiable {
    /// 可为 nil：实测有 4 行 `thscode` 为 null，只剩 `ticker` 与 `name`。
    public let thscode: String?
    public let ticker: String
    public let name: String
    public let rangeDays: Int            // 1 = 当日榜，3 = 三日榜；分组键
    public let changeFraction: Double?   // 小数
    public let netValue: Double?         // 元
    public let netRate: Double?          // 小数
    public let buyValue: Double?, sellValue: Double?
    public let orgNetValue: Double?, orgNetRate: Double?
    public let orgBuyCount: Int?, orgSellCount: Int?
    public let hotRank: Int?, limitReason: String?, concepts: [String]
    /// 去重键：thscode 优先，缺失时退回 ticker；再与 range_days 组合，
    /// 因为同一股票会同时有当日榜与三日榜两行（实测 count 72 > stock_count 67）。
    public var id: String { "\(thscode ?? ticker)|\(rangeDays)" }
    /// 能否映射到本 App 的沪深身份：`.BJ` 与 null thscode 都不行，
    /// 与 `FuyaoConstituent` 的既有处理一致。
    public var symbol: SymbolID? { thscode.flatMap(FuyaoConstituent.shareSymbol) }
}
public struct FuyaoDragonTigerDay: Codable, Hashable, Sendable {
    public let boardType: FuyaoDragonTigerBoard
    public let tradeDate: Date           // 业务日期，取响应 trade_date，不本地推算
    public let dataTime: Date?           // 上游就绪时间，可 nil
    public let stockRows: [FuyaoDragonTigerRow]
    public let hotMoneyRows: [FuyaoHotMoney]   // board_type=hot_money 时非空
    public let recordCount: Int?, stockCount: Int?
}
```

`FuyaoAbnormalMonitor` 保留 `monitorLabel` 原文（`1/2` = 严重异动，其它 = 重点监控），**不硬编码类型码**；`endDate == nil` 渲染为"监控中"。

**界面**
1. **今日工作台**新增「资金与监管」卡（与现有情绪卡同一行，宽度自适应）：
   - 龙虎榜：机构净买 Top 5、游资净买 Top 5、命中自选/持仓的行（标"自选命中"）。
   - 监管：命中持仓/自选的当前监控记录条数 + 最近一条的标签。
   - 卡片头常驻业务日期（`trade_date`），并写"收盘后发布"；**无法映射身份的 4 类行不计入自选命中**，只在详情页以代码列表出现。
2. **详情 sheet**：三个页签（全部 / 机构 / 游资）+ 日期选择器（默认上一交易日，可回看一年内）；列表按 `range_days` 分段，段头写"当日榜 1 日 / 三日榜 3 日（金额与当日榜不可相加）"。
3. **个股「情报」页**新增「龙虎榜」小节：该股最近一次上榜的 `range_days`、净买入、机构家数；点击展开席位（走机构详情端点，可选）。
4. **交易复盘详情**新增「当日资金面（收盘后发布）」小节：**实时查询、不冻结**进入 `FuyaoMarketContext`。理由：龙虎榜在收盘后才有，而复盘背景的语义是"记录时已观察到"，把盘后数据混进去会伪造时点。

**缓存与优先级**：`all` 榜 300s；`org`/`hot_money` 页签切换时才请求，各自 300s；异动监控 300s。全部走 `fetchResearchData`（向报价让行）。最坏预算：打开工作台 2 次 + 切换两个页签 2 次 + 个股下钻 2 次 ≈ **10 次/日**（按 5 分钟缓存计），缓存失效后重复打开另有 10–20 次，仍可忽略。

**边界（不做）**
- 不把龙虎榜解读成因果或推荐；游资名称、`limit_reason` 原样展示。
- 机构金额与三日榜金额**不相加、不跨榜求和**；不做营业部排行榜（`department-history` 分页上限 30、`total` 可为 `null`，做排行会失真）。
- 不做"龙虎榜预测次日"这类叙事。
- 空榜（当日无记录）显示"当日无上榜记录"，而不是"获取失败"。

**验收**
- 同一 `thscode` 同时存在 `range_days=1` 与 `3` 时，列表出现两行且不合并；任何汇总数字都不含重复。
- `board_type=hot_money` 时 `stock_items` 为空数组，UI 不显示空表。
- 省略 `date` 时展示的上游业务日期必须是接口回传的 `trade_date`，不能本地推算。
- `end_date_ms = null` 的监控记录显示"监控中"而不是被过滤。
- 限流时保留已成功的榜单，只标记失败页签。

**测试**：`FuyaoDragonTigerTests`（分组键、金额不相加、hot_money 空数组、date 回显、`count>stock_count`）、`FuyaoAbnormalMonitorTests`（null 语义、label 原文）。

---

### P1-3 盘前竞价卡（9:15–9:25）

**要解决的问题**：盘前阶段目前只有"待准备计划"和"资金"，没有任何市场侧输入；而 9:15–9:25 是 A 股唯一一个"信息先于成交"的窗口。`fuyao-feature-plan.md` 已把它列为候选，前置条件是"先验证实时阶段和成交量单位"。

**已实测的部分（§2.4 第 1、2 条）**：`auction_volume` 是**手**（`amount ÷ price = volume × 100`，两只标的误差 < 0.001%），因此量可以展示，标"手"并注明 1 手 = 100 股。同时实测 `auction_phase` 返回 `closed`、`data_status` 返回 `final`，都**超出文档示例给出的取值**。

**仍需实测的部分（必须先做，否则不做「实时 vs 终态」的区分）**：文档没有说明 `live` 在 9:15–9:20（可撤单）与 9:20–9:25（不可撤单）的差异，也没说 `final` 何时可用。§6 第 1 条要求用真实 Key 在真实竞价窗口抓 3 天样本，确认：`live` 是否随撤单变化、`data_status` 在新阶段会出现哪些值、终态在 9:25 后多快就绪。**在拿到这些之前，卡片只做「只读快照 + 数据状态原文」，不声称"实时/终态"。**

**数据来源**：`GET /api/a-share/auction/snapshot?thscodes=<≤100>&stage=live|final`
- 字段：`auction_price`（元）、`auction_pct`（**百分数原值**）、`auction_amount`（元）、`auction_volume`（**手**，实测换算）、`auction_volume_ratio`（倍）、`auction_turnover_pct`（百分数）、`pre_close_price`。
- `auction_unmatched`（未匹配量）单位仍未声明 → **不展示**。
- `data_status` 为 `not_ready` / 停牌时**仍返回** `data.timestamp`，必须靠状态字段判空，不能靠时间戳。
- `auction_phase` 与 `data_status` 都按**开放字符串**处理：已知值做映射，未知值原样显示并标注"状态未知"；不得写死 `ready`/`final` 去判断。

**会话语义（必须先补的模型）**：`TradingCalendar.state` 目前把沪深 9:15 起算作 `.regular`（"Includes the opening call auction"）。竞价卡需要独立判断，不能靠 `.regular` 猜：

```swift
public enum AShareOpeningPhase: Sendable { case preAuction, auctionCancellable, auctionLocked, silent, none }
// 9:15–9:20 可撤单 / 9:20–9:25 不可撤单 / 9:25–9:30 静默 / 其余 none
// 只在 sh|sz、且 ExchangeCalendar.isTradingDay 为真时成立
```

`ExchangeCalendar` 对沪深只覆盖 2026 年，超出范围回退工作日规则——竞价卡必须在"未核验年份"上显示"节假日表未覆盖"，而不是静默按工作日开卡。

**界面**
- 盘前阶段工作台新增「竞价」卡：按 |`auction_pct`| 排序的前 N 只（N = 自选 ∩ 沪深，上限 100），列：名称、竞价价、竞价涨跌幅、竞价金额、竞价量（手）、量比、状态标记。
- 9:25:30 后切换为「今日开盘」摘要（保留最后一次快照，不再请求）。
- 停牌/`not_ready` 的行显示"未就绪"，不参与排序。
- 卡脚常驻一行事实：`阶段 closed · 数据 final · 采样 09:25:03`，用上游原文而非本 App 的推断词。

**调用计划与优先级（唯一需要开口的地方）**
- 窗口：交易日 9:15:00–9:25:30，每 **5 秒**最多 1 批（≤100 标的），9:25:30 后**立即停止**，当日不再请求。
- 窗口内优先级与报价轮询同级，其他研究请求继续让行；窗口外一律不请求。
- 硬上限：`(9:15–9:25:30) 630s ÷ 5s ≈ 126 批/日`，无重试、无补偿请求。
- `stage` 选择：9:25:00 前用 `live`；9:25:00–9:25:30 用一次 `final` 收口（这一条在 §6 实测确认后再定稿）。

**边界（不做）**
- 不做竞价预测、不做"竞价强度打分"、不把竞价涨幅当作开盘后会延续的信号。
- 不覆盖北交所（当前无该市场）、不覆盖 ETF/指数（竞价快照端点只声明 A 股）。
- 不写入计划、不触发提醒；竞价卡是只读观察。
- 可选延伸：若当天确实观察过竞价，可把最后一次快照冻结进复盘背景（`FuyaoMarketContext` 新增可选字段）。不做不影响本项。

**验收**
- 窗口外打开工作台不产生任何竞价请求；窗口结束后计时器必须停。
- 未知 `auction_phase`/`data_status` 不导致整卡空白，也不被误标为实时或终态。
- 100 只以上自选只取上限 100 并明示"仅前 100"。
- `not_ready`/停牌不渲染成 0。
- 竞价量按"手"展示，与 `auction_amount ÷ auction_price` 的人工核对一致。

**测试**：`FuyaoAuctionTests`（解析、`data_status` 判空、100 上限、去重）、`FuyaoOpeningPhaseTests`（时段边界、非交易日、未核验年份）、自测覆盖"窗口闭包停表"。

---

### P1-4 财务关键指标（五类）

**要解决的问题**：现有财报区只有三张报表的原始科目与 5 个估值倍数。用户要回答"这家公司赚不赚钱、杠杆高不高"还得自己算。五类指标就是同花顺已经算好的答案。

**数据来源**：`GET /api/a-share/financials/indicators?thscode=&report=yyyy-N`（`N`: 1 一季报 / 2 中报 / 3 三季报 / 4 年报）
- `value` 是**原始数值字符串**（保精度），`null` 表示上游缺失；百分比类按百分数值表达（`89.12` = 89.12%），周转率为次、倍数为倍。
- 固定五组顺序：`growth / profitability / solvency / operation / cash-flow`。

**Core 模型**（新文件 `Models/FuyaoFinancialIndicators.swift`）

```swift
public struct FuyaoIndicator: Codable, Hashable, Sendable, Identifiable {
    public let indexID: String          // 契约字段名，如 sale_gross_margin
    public let rawValue: String?        // 原始字符串；nil = 上游缺失
    public let value: Double?           // 解析成功才有；解析失败保持 nil
    public var id: String { indexID }
}
/// 固定五组，顺序与契约一致：growth / profitability / solvency / operation / cash-flow。
public enum FuyaoIndicatorAbility: String, Codable, CaseIterable, Sendable {
    case growth, profitability, solvency, operation
    case cashFlow = "cash-flow"
}
public struct FuyaoIndicatorGroup: Codable, Hashable, Sendable, Identifiable {
    public let ability: FuyaoIndicatorAbility
    public let indicators: [FuyaoIndicator]
    public var id: String { ability.rawValue }
}
public struct FuyaoIndicatorSet: Codable, Hashable, Sendable {
    public let report: String           // "2026-2"
    public let groups: [FuyaoIndicatorGroup]
}
```

**`index_id` 不是封闭枚举**（实测见 §2.4 第 3 条）：`growth` 组实际返回的 4 个 id 文档未列，文档列的 3 个又未出现。因此解析一律"全收、按 id 查表"，未知 id 保留原始值与数值、仅在无展示定义时隐藏，**绝不因为 id 不在文档表格里就丢弃整组**。取值用 `calculate_` 前缀与无前缀两套写法都能命中同一指标，查表要做归一化（去 `calculate_` 前缀后匹配）。

**展示白名单**（按**实际返回的 id** 定，首版 10 项）：`index_weighted_avg_roe`（净资产收益率）、`index_deduct_weighted_avg_roe`（扣非加权 ROE）、`sale_gross_margin`（销售毛利率）、`sale_net_interest_ratio`（销售净利率）、`assets_debt_ratio`（资产负债率）、`current_ratio`（流动比率）、`calculate_operating_income_yoy_growth_ratio`（营业收入同比增长率）、`calculate_parent_holder_net_profit_yoy_growth_ratio`（归母净利润同比增长率）、`net_profit_cash_content`（净利润现金含量）、`cash_meet_invest_ratio`（现金满足投资比率）。每项标注单位类别（%、次、倍），`nil` 显示 `--`。

**调用计划**：展开财报折叠区才请求；先用三张报表已有的最新 4 个报告期，逐期 1 次请求（单码端点，不可批），TTL 24h。最坏 4 次/标的/日。`2026-2` 在 2026-10-20 实测可用，说明半年报口径在 10 月已就绪（见 §2.4）。

**顺带修正**：`valuation(for:)` 目前单码调用，改为一次最多 100 个批量的 `valuations/snapshot`（同一端点，已有批量能力），为将来的自选估值总览留出余量。

**边界**：不生成"估值分位"（接口明确不提供历史估值）；不对指标下投资结论；不把 `value` 的字符串精度丢掉后用于计算。

**验收**：`report` 非法（`2026-5`）本地拒绝，不发请求；百分比指标按原值展示不带 `%` 二次乘 100；缺失显示 `--` 而不是 0；五组顺序固定。

**测试**：`FuyaoFinancialIndicatorTests`（字符串精度、null、百分比口径、report 校验、五组顺序）。

---

### P1-5 ETF / 基金业绩与回撤

**要解决的问题**：「ETF 穿透」目前只有披露持仓，没有"这只 ETF 自己表现如何"。用户配置了 ETF 却看不到它的区间收益与回撤，等于只有仓位没有绩效。

**数据来源**
- `GET /api/fund/performance/nav?thscode=&range=&nav_type=unit,adj`：不传 `range` **只返回最新一条**；`adj_nav` 是**复权净值，不等于累计净值**（文案必须区分）。
- `GET /api/fund/performance/returns?thscode=`：`return_week/month/tmonth/hyear/year/...` 全部**百分数原值**，另有 `peer_average_*` 与 `rank_*/rank_total_*`。
- `GET /api/fund/performance/drawdowns?thscode=`：全部为**负值百分数**（`-12.5` 表示 -12.5%），**负号是契约的一部分**。

**界面**：ETF 详情 →「情报」页 → 新增「基金业绩」小节：近 1 月 / 3 月 / 1 年收益、同类平均、同类排名（`rank/total`）、最大回撤（保留负号）、最新单位净值与复权净值及净值日期。三块数据用同一 `fetchedAt` 标注。

**缓存**：3 次请求/标的/小时；只在 ETF/LOF 且 `情报` 页可见时触发。

**边界**
- 不做基金诊断、不做投资风格、不做经理业绩（`dimensions` 等字段是"保留上游结构"的半开放契约，字段名文档未展开，防御式解析成本高、收益低）。
- 不把 `adj_nav` 叫作"累计净值"；不把回撤取绝对值。
- 不把基金行业配置写回 FFF 的手动板块分类（`SectorLimitSettings` 是用户手写的，不能被上游覆盖）。

**验收**：不传 `range` 时只显示 1 个点位并写"最新净值"；同一基金两类净值分栏；回撤保留负号；`3002`（无数据）显示"暂未披露"而非错误。

**测试**：`FuyaoFundPerformanceTests`（range 缺省、nav_type 缺键、负回撤、同类排名缺失）。

---

### P2-6 交易日历校准

**要解决的问题**：本地 `ExchangeCalendar` 对沪深只核验了 **2026 年**，2027 年起静默回退到"工作日"规则；而板块 5/20 日相对强弱、龙虎榜/情绪历史日期、复盘"上一交易日"都依赖交易日。现在没有任何地方能发现本地表错了。

**数据来源**：`GET /api/a-share/calendar/trading-days`（无入参，固定 `[今日-1年, 今日]`，返回 `date_ms` + `yyyyMMdd`）。**窗口只到"今天"，不能用来查未来节假日**——这一点必须写进 UI 与注释，否则会变成"用上游日历替代本地表"的错误承诺。

**设计**
- Core 新增 `VerifiedTradingDays`（值类型）：保存最近一次成功获取的交易日集合与 `fetchedAt`；提供 `contains(_:)`、`previousTradingDay(before:)`、`lastN(_:)`。
- `TradingCalendar` 增加**可选**注入点：查询"过去一年内的某天是否交易日 / 上一个交易日"时优先用它；超出窗口或未加载时回退现有 `ExchangeCalendar`，并在返回值上标明来源（`.verified` / `.fallback`）。
- 消费方：板块强弱 5/20 日锚点计算、龙虎榜/情绪的日期选择器（避免 `1002`）、复盘"上一交易日"定位。
- 设置页「扶摇」区块新增一行状态：`交易日历：已校准 2026-10-21（覆盖 2025-10-22 起）` 或 `未校准，使用本地表`。本地表与上游对过去一年的差异若 > 0，显示"本地节假日表与上游有 N 天差异"，只在设置页提示，不改任何历史成交日期。

**缓存**：1 次/日，持久化；失败不覆盖已有成功副本（与现有"部分失败保留成功"一致）。

**边界**：不改变 `PositionTransaction.date` 的本机民用日语义；不用它推断未来休市；不在后台静默改写历史。

**验收**：跨年（2027-01-04）查询时仍标明"本地表未覆盖"，不冒充已核验；离线时回退不报错；差异检测只提示不写回。

**测试**：`FuyaoTradingDayTests`（窗口外回退、来源标记、上一交易日、离线保留旧副本）。

---

### P2-7 打新日历

**要解决的问题**：事件日历目前只覆盖持仓/自选标的的财报、分红、解禁。打新是唯一一类"标的不在自选里但用户关心"的事件。

**数据来源**：`GET /api/a-share/ipo/calendar-list?market=sh_sz|bj&status=upcoming|subscribable|awaiting_listing`
- 两个参数都必填；一个完整日历需要 **6 次**调用。
- `ticker`（股票代码）与 `subscription_code`（申购代码）是**两个字段**；`listing_date`、`issue_price` 未定就是 `null`。
- **没有中签率、没有申购上限**——不做这两列。

**界面**：事件日历页新增「打新」来源筛选（与现有按标的的事件并列，作为独立分组）：申购日、上市日、发行价、申购代码、市场。空状态写明"仅覆盖沪深与北交所公开日历"。

**调用计划**：6 次/6 小时，只在该分组展开时请求；不与自选事件共用缓存键。

**边界**：不新建自选标的、不创建提醒、不计算收益率；北交所标的可展示但不可加入自选（`Market` 无对应值，`FuyaoConstituent` 已有"`.BJ` 保留在模型中、`symbol` 为 nil"的先例，沿用同一处理）。

**验收**：`subscription_code ≠ ticker` 时两列都显示；未定值显示"待定"；北交所行标记"不可加入自选"。

**测试**：`FuyaoIPOTests`（6 组组合、null 价格、两码分离、`.BJ` 不映射）。

---

## 4. 实施顺序与写作用域

按"先修口径、再补信息、最后做基础设施"排。每项都是**独立可验收**的小批，写作用域不重叠，可并行给不同 worker。

**实施状态（按项更新）**：P0-1 已实现并安装，见[除权事件验收](../verification/fuyao-corporate-actions-2026-10-22.md)；P0-2 已实现并安装，见[龙虎榜与严重异动验收](../verification/fuyao-capital-flow-2026-10-22.md)；P1-4 已实现并安装，见[财务五类指标验收](../verification/fuyao-financial-indicators-2026-10-22.md)；P1-5 已实现并安装，见[基金业绩与回撤验收](../verification/fuyao-fund-performance-2026-10-22.md)；P2-6 已实现并安装，见[交易日历校准验收](../verification/fuyao-trading-days-2026-10-22.md)（实测本地表与上游一致，价值转为可验证护栏）；P2-7 已实现并安装，见[打新日历验收](../verification/fuyao-ipo-2026-10-22.md)。仅 P1-3 竞价卡仍为设计（卡在真实竞价窗口实测）。

| 顺序 | 项 | Core 新增/改动 | Mac 新增/改动 | 测试 |
| --- | --- | --- | --- | --- |
| 1 | P0-1 除权 | `Models/FuyaoCorporateAction.swift`、`Providers/FuyaoProvider+CorporateActions.swift` | `FuyaoCorporateActionsController.swift`、`FuyaoIntelligenceView.swift`（插小节）、`PlanWorkflowViews.swift`（提示） | `FuyaoCorporateActionsTests` |
| 2 | P0-2 龙虎榜 | `Models/FuyaoDragonTiger.swift`、`Models/FuyaoAbnormalMonitor.swift`、`Providers/FuyaoProvider+DragonTiger.swift` | `FuyaoCapitalFlowController.swift`、`FuyaoCapitalFlowView.swift`、`TradingWorkbenchView.swift`（插卡）、`TradeJournalView.swift`（插小节） | `FuyaoDragonTigerTests`、`FuyaoAbnormalMonitorTests` |
| 3 | P1-4 财务指标 | `Models/FuyaoFinancialIndicators.swift`、`Providers/FuyaoProvider+Financials.swift` | `FuyaoFinancialsView.swift`、`FuyaoFinancialsController.swift` | `FuyaoFinancialIndicatorTests` |
| 4 | P1-5 基金业绩 | `Providers/FuyaoProvider+FundPerformance.swift` | `FuyaoIntelligenceView.swift`（ETF 分支）、`FuyaoFundPerformanceController.swift` | `FuyaoFundPerformanceTests` |
| 5 | P1-3 竞价 | `Market/AShareOpeningPhase.swift`、`Models/FuyaoAuction.swift`、`Providers/FuyaoProvider+Auction.swift` | `FuyaoAuctionCard.swift`、`TradingWorkbenchView.swift` | `FuyaoAuctionTests`、`FuyaoOpeningPhaseTests` |
| 6 | P2-6 交易日历 | `Market/VerifiedTradingDays.swift`、`Market/TradingCalendar.swift`（注入点）、`Providers/FuyaoProvider+Calendar.swift` | `DataSettingsView.swift`（状态行）、`FuyaoBoardsController.swift`（锚点） | `FuyaoTradingDayTests` |
| 7 | P2-7 打新 | `Models/FuyaoIPO.swift`、`Providers/FuyaoProvider+IPO.swift` | `TradingEventsView.swift`（分组） | `FuyaoIPOTests` |

**共同约束**
- 全部走 `fetchResearchData`（共享凭据与节流）；除竞价卡外不得新开优先级通道。
- 新端点解析一律在 Core 完成，Mac 层不碰 `Data`/JSON。
- 每个新模型都必须是纯值 + 可 `Codable`（便于自测合成数据），缓存与刷新时机留在调用方。
- 每项都要在 `FuyaoResearchSelfTest` 里加一条隔离自测（合成数据、断言请求数、断言取消不回写）。

## 5. 明确不做

| 项 | 理由 |
| --- | --- |
| 市场成交额预测 / 筹码形态 / 新增概念 / 宽基 ETF 净流入 / 资讯事件库 | 文档标注**客户端专用**，端外 `2004`。不做假入口 |
| 股票基础信息 / 个股→同花顺指数反查 / 指数权重 | **敬请期待**，无路径。板块只能"指数→成分股"单向查；个股所属板块改用"本机已缓存板块内匹配"并在文案说明范围 |
| 期货 / 期权看板 | 可用但无关：无 snapshot，期权缺 IV/Greeks/持仓；接入成本 ≫ 价值 |
| 全市场 Parquet dump + 本地筛选 | 日 K 明确 `adjusted=none`，复权因子端点又缺配股；要做必须先解决复权与**时点**质量（历史成分股、财报修订），是独立项目。当前仅作为"未来解决配股数据"的唯一途径登记 |
| 公告详情与解读 | 只有 `news/notice/detail?seq=`，**没有列表端点**喂 `seq`；`news/flash/*` 的 `tag_id` 也没有枚举，无法可靠串起来 |
| 快讯时间线 | `tag_id` 无公开枚举、翻页边界"由数据提供方决定"。需要先探测（§6 第 2 条），未探测前不进设计 |
| 连板天梯 / 竞价机会 18 类预警 | 前者每板只给 4 只、后者类型码无释义；做出来会误导为"全部" |

## 6. 上线前必须实测的清单（真实 Key，只读）

已在 §2.4 用 2026-10-20 的只读存档核对掉 3 项（竞价量的手数换算、`auction_phase/data_status` 取值、财务指标 id 集合），以下 8 项**仍未验证**，逐项说明验什么、验不过就不做什么：

1. **竞价阶段语义**：连续 3 个交易日 9:15–9:25 抓样本，确认 `stage=live` 在 9:20 前后是否变化、`data_status` 出现哪些值、`final` 何时就绪。验不过 → 竞价卡只显示快照与状态原文，不区分"实时/终态"。
2. **快讯**：探测 `tag_id` 有效值与 `seq` 游标行为，确认 `create_time_ms` 必须整除 1000 的实际报错。验不过 → 不做快讯。
3. **龙虎榜补充项**：再取 2 个交易日，核对 `hot_money_items[].rows` 与 `stock_items` 的重复关系、`org_net_value` 缺失比例。`count>stock_count`、`range_days` 分布、null `thscode` 已实测（72/67、`{1:55,3:17}`、4 行为 null），无需重测。
4. **除权**：取 1 只当年多次分红的标的，核对 `ex_date_ms` 时区、同日多条事件、`per_share_bonus=0` 与 `dividend=0` 的组合语义。验不过 → 只展示原始两条数值，不做"送转"文案。
5. **财务指标口径**：核对百分比类 `value` 与已披露报表能否对上（抽 1 期 1 个指标人工复算）。`2026-2` 可用性已实测。验不过 → 只展示原始字符串，不标注单位类别。
6. **基金三连**：核对 `nav` 的 `range` 缺省行为、`adj_nav` 与"累计净值"的实际差异、`drawdowns` 是否恒为负。
7. **打新**：6 组组合各取一次，确认 `null` 比例与 `.BJ` 标的是否带 `thscode`。
8. **交易日历**：与本地 `ExchangeCalendar` 对 2026 年逐日比对，记录差异天数（预期 0，若不为 0 优先修本地表）。

实测沿用既有方式：隐藏输入 + 匿名管道把 Key 传给隔离进程，Key 不进源码、文档、参数与日志；只读，不改日常数据源配置。

## 7. 来源

- [REST 总览](https://fuyao.aicubes.cn/docs/api-reference/overview/)、[完整聚合文档](https://fuyao.aicubes.cn/llms-full.txt)（2026-10-22 抓取）
- [除复权](https://fuyao.aicubes.cn/docs/api-reference/corporate-actions/)、[龙虎榜](https://fuyao.aicubes.cn/docs/api-reference/dragon-tiger-data/)、[营业部](https://fuyao.aicubes.cn/docs/api-reference/dragon-tiger-department/)、[个股机构](https://fuyao.aicubes.cn/docs/api-reference/dragon-tiger-institution/)
- [集合竞价](https://fuyao.aicubes.cn/docs/api-reference/auction/)、[竞价机会](https://fuyao.aicubes.cn/docs/api-reference/auction-opportunities/)、[异动股票](https://fuyao.aicubes.cn/docs/api-reference/abnormal-monitor/)
- [财务指标](https://fuyao.aicubes.cn/docs/api-reference/financial-indicators/)、[估值](https://fuyao.aicubes.cn/docs/api-reference/valuations/)、[交易日历](https://fuyao.aicubes.cn/docs/api-reference/calendar/)
- [基金净值与业绩](https://fuyao.aicubes.cn/docs/api-reference/fund-performance/)、[基金仓位与配置](https://fuyao.aicubes.cn/docs/api-reference/fund-portfolio/)、[A股打新](https://fuyao.aicubes.cn/docs/api-reference/a-share-ipo/)
- [全市场导出](https://fuyao.aicubes.cn/docs/api-reference/market-dumps/)、[MCP 概览](https://fuyao.aicubes.cn/docs/mcp/overview/)
