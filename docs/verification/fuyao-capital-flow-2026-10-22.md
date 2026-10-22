# 龙虎榜与严重异动 · 实现验收

2026-10-22，Asia/Shanghai。对应设计 [扶摇 API 最佳实践与下一轮设计](../design/fuyao-api-practices-and-next-wave.md) 的 P0-2。

## 交付内容

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Core 模型 | `Models/FuyaoDragonTiger.swift` | 榜单日、按区间分组的行、游资聚合行、机构记录、监控记录；纯值 + 派生查询 |
| Core 网络 | `Providers/FuyaoProvider+DragonTiger.swift` | 三个端点的请求与防御式解析 |
| Mac 缓存 | `FuyaoDragonTigerController.swift` | 三张榜单独立缓存、监控缓存、命中判定 |
| Mac 界面 | `FuyaoCapitalFlowCard.swift`（工作台卡 + 复盘小节）、`FuyaoCapitalFlowView.swift`（详情窗口） | 摘要、分段表格、游资榜、监管区 |
| 接线 | `TradingWorkbenchView.swift`、`TradeJournalView.swift`、`FuyaoResearchController.swift` | 入口、sheet、reset 生命周期 |

## 实测约束如何落进代码

这些不是设计猜想，是 10-20 存档与 10-22 真实响应的观察结果：

| 观察 | 实测值 | 代码位置 |
| --- | --- | --- |
| 同一股票同时有当日榜与三日榜 | 10-20：`count=72` / `stock_count=67`，区间 `{1:55, 3:17}`；10-22：`records=67` / `stocks=62`，`ranges=[1,3]` | `rowsByRange` 是唯一可汇总的入口；`id` 用 `(身份, 区间)` 组合，两行不会被合并 |
| `thscode` 可为 null | 10-20 样本有 4 行只有 `ticker`/`name` | `FuyaoDragonTigerRow.thscode` 是可选；`symbol` 返回 nil；去重键退回 `ticker` |
| `.BJ` 行存在 | 10-20 样本有 6 行 | 保留在模型里，`symbol` 为 nil（本 App 无北交所市场） |
| 游资榜与股票表互斥 | 10-22：`hot_money_names=12`、`stock_rows=0` | `boardType` 决定渲染哪张表；三张榜单各自独立缓存 |
| `trade_date` 只能从响应读 | 10-22 返回 `2026-10-21`（上一交易日） | `tradeDate` 来自 `data.trade_date`，缺失即报错，绝不本地推算 |
| `end_date_ms = null` 表示监控中 | 10-22 当前 `ongoing=0` | `isOngoing` 为 true 时渲染"监控中"，不当作缺失丢弃 |
| 涨跌幅/占比是小数 | `change=0.0999` | 模型命名为 `changeFraction`/`netRate`，展示时乘 100 |

## 口径决定

1. **不做跨区间相加**。控制器不提供"总净买入"，界面分段展示，三日榜段头写"金额不可与当日榜相加"。
2. **命中判定只认当日榜**。`watchHits` 过滤 `range == .day`——把三日榜算进"今天这只票上榜了"会改变语义。
3. **区间未知不并进当日榜**。`range_days` 缺失时存为 `-1`，`range` 返回 nil，界面单独一段"区间未知"。
4. **机构席位是"条数"语义**。同一 `departmentID` 可重复出现（如 `THS59 机构专用` ×4），`groupedSeats` 保留出现次数，绝不把去重后的数量说成"营业部家数"。
5. **复盘小节实时查询、不冻结**。龙虎榜收盘后才有，而复盘背景快照的语义是"记录时已观察到"，混进去会伪造时点。这是与 `FuyaoMarketContext` 刻意的分工。
6. **空榜不等于失败**。当日无记录时显示"无上榜记录"，不是"获取失败"。

## 验证

| 验证 | 结果 |
| --- | --- |
| 定向单元测试 | `FuyaoDragonTigerTests` 14 项通过（区间分组/可空身份/北交所/单位/重复行/缺日期报错/榜类型回显/游资互斥/席位重复/监控 null 语义） |
| 完整 PulseCore 回归 | 1147 项、113 套件通过 |
| 原生隔离自测 | 46 项检查通过（新增：区间分组、可空身份、命中只认当日榜、缓存去重、游资榜独立缓存、监控 ongoing、取消不回写） |
| 原生渲染 | `capital-flow-light` / `capital-flow-dark`（800×460）已目检：列头只出现一次、三日榜段头可见、缺代码行灰阶可读、深色对齐正常；`workbench-cards-light`（900×260）确认两张研究卡并排时高度接近、无大片留白；`workbench-cards-narrow`（420×420）确认窄窗口正确折成纵向 |
| 真实接口 | 安装后的 App：`dragon-tiger records=67 stocks=62 ranges=[1,3]`、`dragon-tiger-hot-money hot_money_names=12 stock_rows=0`、`abnormal-monitors records=3 ongoing=0`；同轮 20 项全部通过 |
| 安装 | 已更新 `/Users/cora/Applications/FFF.app`，签名验证通过，旧版备份于 `FFF-backups/FFF-before-capital-flow-20261022-140507.app` |

**渲染检查中修掉的缺陷**：初版把"净买入 / 机构 / 涨跌"三个列头逐行重复，读到像每行各带单位；已改成表头只出现一次、逐行只显示数值。缺代码行的名称原本几乎不可见，改为次级灰阶保留可读性。

## 未验证 / 不声称

- 只跑了 2 个交易日的真实数据，未验证长期停牌、退市整理期、巨额上榜等边界；未验证历史日期选择器的完整交互。
- 未做营业部排行榜（`department-history` 分页上限 30 且 `total` 可为 null，做排行会失真）。
- 不解释资金为什么进出，不预测次日，不写入计划或账本。
- 机构席位详情端点已实现解析层与模型，但界面未展开到席位级别（保留给后续）。
