# 待开发功能列表

2026-09-30 记。这里放**已明确要做、但还没动手**的功能。做完一项就移进对应的设计文档（如 `CHART-TOOLS-DESIGN.md`）或直接删掉这里。

> 已完成并移出：
> - **计划卡片按现价估算成本 / 利润差**（2026-09-30 实现，口径 `TradePlan.costDelta(from:)`，展示层 `PulseMac/Sources/PlanCostText.swift`）。
> - **均线与 MACD 指标系统**（2026-09-30 实现）：计算在 `PulseCore/Models/ChartIndicators.swift`（SMA / EMA / MACD 纯函数 + 单测）；渲染在 `CandlestickChartView`（均线用 `LineMark`，MACD 复用底部 band，见 `ChartBands`）；配置与配色在 `PulseUI/ChartIndicatorConfiguration.swift`；开关与图例在 `MainInstrumentView.indicatorMenu` + `CandleIndicatorLegend`。

（当前没有待办项。）
