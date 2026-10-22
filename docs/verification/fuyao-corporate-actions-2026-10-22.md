# 除权除息事件与计划价格口径 · 实现验收

2026-10-22，Asia/Shanghai。对应设计 [扶摇 API 最佳实践与下一轮设计](../design/fuyao-api-practices-and-next-wave.md) 的 P0-1。

## 交付内容

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Core 模型 | `Packages/PulseCore/Sources/PulseCore/Models/FuyaoCorporateAction.swift` | 事件值、序列查询、`FuyaoPlanPriceBasisNotice.notices` 命中判定（纯函数） |
| Core 网络 | `Packages/PulseCore/Sources/PulseCore/Providers/FuyaoProvider+CorporateActions.swift` | 单码请求与防御式解析 |
| Mac 缓存 | `PulseMac/Sources/FuyaoCorporateActionsController.swift` | 串行队列、24h 内存 / 7d 持久缓存、失败保留旧副本 |
| Mac 界面 | `PulseMac/Sources/FuyaoCorporateActionsView.swift`、`FuyaoPlanPriceBasisNoticeView.swift` | 个股情报页小节、计划详情/卡片提示 |
| 接线 | `FuyaoIntelligenceView.swift`、`FuyaoResearchController.swift`、`PlanWorkflowViews.swift`、`PlanListView.swift` | 入口与 reset 生命周期 |

## 口径决定（与设计的差异需记录）

1. **事件类型靠两个数值隐式区分**。`dividend_per_share` 与 `per_share_bonus` 同时为 0（或缺失）的行没有价格影响，解析阶段直接丢弃；界面因此不会出现"除权 0 元"这种空行。
2. **配股不可得，界面明说**。REST 端点不含 `allotment_ratio` / `allotment_price`（只在全市场 Parquet dump 里）。界面固定写"仅含现金分红与送股；配股不在本数据内"，绝不由"没有配股记录"推断"没有配股"。
3. **非零点的时间戳被拒绝**。上游给的是北京日历日零点；带时分秒的 `ex_date_ms` 说明口径不清，解析时丢弃该行，而不是把它四舍五入到某一天。
4. **回显代码不一致即整份拒收**。端点会在 `data.thscode` 回显入参；与请求不一致时抛 `badResponse`，避免把别的票的分红记到这只票上。
5. **单标的失败 ≠ 来源失败**。刷新失败时保留上一次成功的序列，只在该标的条目上记 `lastError`；全景 `lastError` 只留给"从未成功过、连兜底副本都没有"的情况。否则一只票的权限问题会被界面说成整个数据源不可用。
6. **没有数据不等于没有除权**。`notices` 只统计已有事件序列的标的，无缓存的标的一律不提示。

## 命中规则

三条同时成立才提示：计划 `status == .active`、`plan.createdAt < 除权日`、该次除权 `hasCash || hasBonus`；且除权日必须 `<= asOf`（未来预告不提前提示）。界面措辞固定为"请复核"，无任何自动改价入口。

## 验证

| 验证 | 结果 |
| --- | --- |
| 定向单元测试 | `FuyaoCorporateActionsTests` 10 项通过（解析/去重/空事件/拒收外来代码/序列查询/命中矩阵/未来除权/多事件排序） |
| 完整 PulseCore 回归 | 1133 项、112 套件通过 |
| 原生隔离自测 | 33 项检查通过（新增缓存去重、失败保留、命中判定、无缓存不提示、取消不回写） |
| 原生渲染 | `corporate-actions-light`（460×300）与 `corporate-actions-narrow-dark`（320×340）已目检：数字与提示行一致、深色可读、窄版不溢出 |
| 真实接口 | 安装后的 App 静默读取已保存凭据：`corporate-actions rows=30 latest=2026-06-26 cash=28.02423 bonus=0.0`；同轮 17 项真实契约检查全部通过 |
| 安装 | `/Users/cora/Applications/FFF.app` 已更新，签名验证通过（同一证书与标识），旧版备份于 `FFF-backups/FFF-before-corporate-actions-20261022-135346.app` |

**渲染检查时发现并修掉的缺陷**：自测最初另画了一个"同形"的行来渲染，用了 `%.4g` 格式化，导致渲染图显示 `23.96` 而真实提示显示 `23.957`。已把行抽成独立组件 `FuyaoCorporateActionRow`，真实界面与渲染检查共用同一份实现——渲染图此后显示的就是应用里那个数字。

## 未验证 / 不声称

- 只用一个标的（600519）做过真实请求，未覆盖同日多条事件、长期停牌后补分红等边界。
- 未验证盘中发布时点（除权事件通常盘后更新，本轮未取时间序列）。
- 未做图表除权标记（设计里列为可选延伸，本轮不做）。
- 未改任何计划价格、成本或账本；提示是纯展示。
