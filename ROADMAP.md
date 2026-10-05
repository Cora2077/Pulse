# 待开发功能列表

2026-09-30 记。这里放**已明确要做、但还没动手**的功能。做完一项就移进对应的设计文档（如 `CHART-TOOLS-DESIGN.md`）或直接删掉这里。

> 已完成并移出：
> - **计划卡片按现价估算成本 / 利润差**（2026-09-30 实现，口径 `TradePlan.costDelta(from:)`，展示层 `PulseMac/Sources/PlanCostText.swift`）。
> - **均线与 MACD 指标系统**（2026-09-30 实现）：计算在 `PulseCore/Models/ChartIndicators.swift`（SMA / EMA / MACD 纯函数 + 单测）；渲染在 `CandlestickChartView`（均线用 `LineMark`，MACD 复用底部 band，见 `ChartBands`）；配置与配色在 `PulseUI/ChartIndicatorConfiguration.swift`；开关与图例在 `MainInstrumentView.indicatorMenu` + `CandleIndicatorLegend`。

（当前没有待办项。）

2026-09-30 补充完成：交易计划到价提醒、交易复盘、按币种的仓位分布和计划买入预估、每日本地备份及预览恢复。入口、数据边界和验证方法见 [WORKFLOWS-DESIGN.md](WORKFLOWS-DESIGN.md)。

2026-10-01 补充完成：买入风险测算、手动板块分类与上限提醒、今日工作台、完整轮次策略分析、持仓及关注事件日历。边界与数据格式见 [WORKFLOWS-DESIGN.md](WORKFLOWS-DESIGN.md)。

已完成仓位分账、计划条件、实际成交关联、现金与池容量、多计划预演、今日任务和修改历史，见 [WORKFLOWS-DESIGN.md](WORKFLOWS-DESIGN.md)。冷静期和更细的行为标签仍为草案，见 [TRADING-DISCIPLINE-DESIGN.md](TRADING-DISCIPLINE-DESIGN.md)。
