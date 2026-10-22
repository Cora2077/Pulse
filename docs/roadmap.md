# 待开发功能列表

2026-09-30 记。这里放**已明确要做、但还没动手**的功能。做完一项就移进对应的设计文档（如 `docs/design/chart-tools.md`）或直接删掉这里。

> 已完成并移出：
> - **计划卡片按现价估算成本 / 利润差**（2026-09-30 实现，口径 `TradePlan.costDelta(from:)`，展示层 `PulseMac/Sources/PlanCostText.swift`）。
> - **均线与 MACD 指标系统**（2026-09-30 实现）：计算在 `PulseCore/Models/ChartIndicators.swift`（SMA / EMA / MACD 纯函数 + 单测）；渲染在 `CandlestickChartView`（均线用 `LineMark`，MACD 复用底部 band，见 `ChartBands`）；配置与配色在 `PulseUI/ChartIndicatorConfiguration.swift`；开关与图例在 `MainInstrumentView.indicatorMenu` + `CandleIndicatorLegend`。

当前已交付：[扶摇六项功能](design/fuyao-feature-plan.md)已通过代码、原生界面及真实接口验证，并更新日常 App；固定凭据组件解决本地重新编译后的重复授权问题。包含个股情报、板块强弱、ETF 持仓穿透、市场情绪、财报估值和复盘市场背景留存。

2026-10-22 已交付四项：P0-1 除权除息事件与计划价格口径复核（[验收](verification/fuyao-corporate-actions-2026-10-22.md)）、P0-2 龙虎榜与严重异动（[验收](verification/fuyao-capital-flow-2026-10-22.md)）、P1-4 财务五类关键指标（[验收](verification/fuyao-financial-indicators-2026-10-22.md)）、P1-5 基金业绩与回撤（[验收](verification/fuyao-fund-performance-2026-10-22.md)）、P2-6 交易日历校准（[验收](verification/fuyao-trading-days-2026-10-22.md)）、P2-7 打新日历（[验收](verification/fuyao-ipo-2026-10-22.md)），均已实现、验证并更新日常 App。同轮设计仅剩 P1-3 竞价卡未实现——它卡在真实竞价窗口实测（`stage=live` 在 9:20 前后的行为、`final` 就绪时点），未实测前不做「实时/终态」区分。另修复前复权日K无数据缺陷（[验收](verification/forward-candle-fix-2026-10-22.md)）。

2026-10-22 已设计、**尚未实现**：[扶摇 API 最佳实践与下一轮设计](design/fuyao-api-practices-and-next-wave.md)给出 7 项排期（除权口径复核、龙虎榜与严重异动、盘前竞价卡、财务五类指标、ETF 业绩与回撤、交易日历校准、打新日历）、请求预算与上线前实测清单；逐端点契约见[端点摘要](design/fuyao-endpoint-contracts-2026-10-22.md)。原 `fuyao-feature-plan.md` 的三条后续候选（龙虎榜、竞价卡、本地筛选）由该文档接续：前两项已进 P0-2 / P1-3，本地筛选仍维持"先解决复权与时点质量"的结论。

2026-09-30 补充完成：交易计划到价提醒、交易复盘、按币种的仓位分布和计划买入预估、每日本地备份及预览恢复。入口、数据边界和验证方法见 [工作流设计](design/workflows.md)。

2026-10-01 补充完成：买入风险测算、手动板块分类与上限提醒、今日工作台、完整轮次策略分析、持仓及关注事件日历。边界与数据格式见 [工作流设计](design/workflows.md)。

已完成仓位分账、计划条件、实际成交关联、现金与池容量、多计划预演、今日任务和修改历史，见 [工作流设计](design/workflows.md)。冷静期和更细的行为标签仍为草案，见 [交易纪律设计](design/trading-discipline.md)。
