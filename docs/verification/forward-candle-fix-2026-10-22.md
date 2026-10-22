# 前复权日K无数据 · 缺陷修复

2026-10-22，Asia/Shanghai。用户报告：长鑫科技（688825.SH）现货与持仓正常，日K显示「暂无数据 / 当前数据源没有该标的的日K数据」。

## 根因

两个问题叠加，**都不是数据源的问题**。

### 1. 腾讯对「从未除权」的标的只返回未复权序列

`TencentProvider` 的前复权解析写死只取 `qfq<interval>` 这个键；取不到就抛 `symbolNotFound`。

但腾讯的契约是：**只有当标的经历过除权时才会给出 `qfq*` 序列**。实证（2026-10-22 直接请求）：

| 标的 | 除权历史 | 返回的键 |
| --- | --- | --- |
| `sz001309` | 有 | `qfqday`、`qt`、`mx_price`… |
| `sh600519` | 有（多次分红） | `qfqday`、`qt`、`mx_price`… |
| `sh688825` | 无（2026-07-27 上市） | `day`、`qt`、`mx_price`… |

所以 `qfqday` 缺失在这个场景里不是"源不支持"，而是"无需复权"——两条序列按构造完全相同。

原实现"fail closed"（未复权绝不冒充前复权）这条纪律本身正确，但它把"没有复权序列"与"复权序列取不到"混为一谈。

### 2. 失败的取数被标注成"数据源没有该标的"

`RefreshEngine.loadCandles` 捕获任何错误后返回空数组（这是有意的降级），但界面只看到"空"，便渲染成「当前数据源没有该标的的日K数据」——把一次暂时性失败说成了关于标的的事实。

## 修复

| 文件 | 改动 |
| --- | --- |
| `Packages/PulseCore/Sources/PulseCore/Providers/TencentProvider.swift` | 前复权键缺失时，**仅当整个响应不含任何 `qfq*` 键**才回退到未复权序列；只要存在任一 `qfq` 键仍抛 `symbolNotFound` |
| `Packages/PulseCore/Sources/PulseCore/Store/MarketStore.swift` | 新增 `clearError()`，只清最后错误、不动缓存 |
| `PulseMac/Sources/DetailView.swift`、`MainInstrumentView.swift` | 空状态按 `market.lastError` 分流：失败态用警示图标与「暂时无法加载…」；无错误时保留「数据源没有该标的…」原文案 |
| `PulseMac/Resources/zh-Hans.lproj/Localizable.strings` | 新增 `chart.loadFailed`、`chart.loadFailedHint` |
| `Packages/PulseCore/Tests/PulseCoreTests/CandleAdjustmentTests.swift` | 把原先断言"只有 day 就必须抛错"的用例改为反映真实契约；新增"存在其他 qfq 区间时必须抛错"的反向用例 |

回退条件的精确含义：**这份响应里连一个 `qfq*` 键都没有**。若源确实会复权（存在任何 `qfq` 键），缺失对应区间说明请求本身出了问题，仍然报错——不给"拿未复权冒充复权"留后门。

## 验证

| 验证 | 结果 |
| --- | --- |
| 逐源逐复权实测 | `tencent-forward` 由 `FAILED symbolNotFound` → `rows=58`；`fuyao-forward` 保持 `rows=58` |
| 端到端链路 | `composite-none/forward` 与 `engine-none/forward` 均 `rows=58` |
| 定向单测 | `CandleAdjustmentTests` + `TencentHistoryTests` 20 项通过（含新的反向用例） |
| 完整 Core 回归 | 1147 项、113 套件通过 |
| 空状态渲染 | `detail-failed-light/dark`（警示态）与 `detail-empty-light/dark`（原有文案）四张已目检：两个分支文案、图标、深浅色均正确 |
| 真实接口 | 安装后的 App 同轮研究契约检查全部通过 |
| 安装 | `/Users/cora/Applications/FFF.app` 已更新并验签，旧版备份于 `FFF-backups/FFF-before-candle-fix-20261022-143152.app` |

## 后续补齐：错误生命周期

修复上线后复查发现，`lastError` 只在失败时写入、成功时从不清除。这让新的分支逻辑在相反方向出错：一次抖动之后，即使后续真的"没有数据"，界面也会一直说"加载失败"。

已一并修正：**错误只描述最近一次尝试**。

| 位置 | 改动 |
| --- | --- |
| `RefreshEngine.loadCandles` 成功路径 | 清除 `lastError` |
| `RefreshEngine` 报价轮成功路径 | 清除 `lastError` |
| `MarketStore.invalidateCandles(for:)` | 新增，供显式重试与测试绕过 TTL |
| `MarketErrorLifecycleTests` | 3 项：失败写入 / 成功后消除 / 清错误不动缓存 |

验证：完整 Core 回归 1150 项、114 套件通过；已重新安装并验签。

## 受影响范围

- 不止 688825：**所有从未除权的新股与次新股**在选「前复权」时都受影响。当日无除权事件时前复权与不复权本就等价，因此回退不会改变任何价格。
- 已除权标的的行为未变：仍取 `qfqday`，不回退。

## 未验证 / 不声称

- 只实测了 `sz001309`、`sh600519`、`sh688825` 三只，未穷举科创板/北交所的新股命名差异。
- 未验证腾讯在"上市首日即除权"等极端情形下的键组合。
- iOS 端仍使用不含扶摇的 Composite（见 `IPhoneAppState`），本次修复对两端同样生效，但手机端未做真机验证。
