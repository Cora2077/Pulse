# ETF / 基金业绩与回撤 · 实现验收

2026-10-22，Asia/Shanghai。对应设计 [扶摇 API 最佳实践与下一轮设计](../design/fuyao-api-practices-and-next-wave.md) 的 P1-5。

## 交付内容

| 层 | 文件 | 职责 |
| --- | --- | --- |
| Core 模型 | `Models/FuyaoFundPerformance.swift` | 周期枚举、期间值、净值点位、格式化 |
| Core 网络 | `Providers/FuyaoProvider+FundPerformance.swift` | 三端点组合、**失败隔离**、原始键名解析 |
| Mac 控制器 | `FuyaoFundPerformanceController.swift` | 按标的缓存，1h TTL，失败保留旧数据 |
| Mac 界面 | `FuyaoFundPerformanceView.swift` | 自适应表格（宽四列 / 窄折叠）、净值行、脚注 |

## 三个端点合成一份答案，单位并不一致

| 端点 | 单位 | 陷阱 |
| --- | --- | --- |
| `performance/returns` | 百分数原值 | `19.66` 就是 +19.66%，不再乘 100；`peer_average_*` 与 `rank_*` 只覆盖部分周期 |
| `performance/drawdowns` | **负值**百分数 | 负号是契约的一部分，取绝对值会丢方向 |
| `performance/nav` | 净值点位 | `adj_nav` 是**复权净值，不等于累计净值**；不传 `range` 只回最新一条 |

## 实现中发现的四个真实缺陷

### 1. `.convertFromSnakeCase` 让自建 CodingKey 失效

最初用自建 `CodingKey` 遍历容器读 `return_year`、`rank_total_year`。但这些键名经过 `.convertFromSnakeCase` 后变成 `returnYear`、`rankTotalYear`，按契约键名查永远查不到——两个桶都是空的。

改为手工拆信封（`JSONSerialization`）+ 按原始键名取值，完全绕开 key 策略。这是本项最关键的一处修正。

### 2. Int 先于 Double 解码是必须的

第一版先试 `Double` 再试 `Int`，结果所有排名都进了小数桶，整数桶为空（`12` 能成功解成 `Double`）。反过来才对：窄类型先试。

### 3. 回撤有 10 个周期，收益只有 8 个

`drawdowns` 还返回 `nowyear`（今年以来）与 `now`（成立以来），而 `returns` 没有对应键。第一版周期枚举漏了这两个，回撤数据被静默丢弃了 2 项。

### 4. 部分失败必须说明"缺的是哪一块"

初版把错误笼统写成「区间收益：请求受限」，但同一页上收益列仍显示数据——自相矛盾。改为「X 本轮未取到（原因），其余数据仍为来源原值」，并让渲染 fixture 内部一致（只有净值失败时，净值行才缺失）。

## 口径决定

1. **失败隔离**：三个端点各自 try，一个失败不影响其余；只有三个都失败才抛错，而不是返回"成功但空"。
2. **限流即停**：遇到限流立即抛出，不再继续打后两个端点。
3. **净值字段按 `nav_type` 可选读**：未请求的类型不会有该键，读出来是 nil 而不是 0。
4. **净值点只留正值**：`≤ 0` 与非有限值不是可信净值，丢弃。
5. **窄窗口折行而非裁切**：330pt 里塞四列会把回撤列挤出可视区，改用 `ViewThatFits` 在窄窗口把同类平均与排名降到第二行。
6. **只用方向着色**：跑赢同类标红、跑输标绿（本地习惯），不判断该不该买。

## 请求预算

3 端点 × 1h TTL = 每标的每小时 3 次；只在基金详情页展开「业绩与回撤」时触发。

## 验证

| 验证 | 结果 |
| --- | --- |
| 定向单元测试 | `FuyaoFundPerformanceTests` 11 项通过（百分数原值、回撤负号、净值双口径、空行丢弃、周期合并、跑赢判定、排名越界、顺序与过滤、三端点全失败报错、部分失败保留其余、格式化） |
| 完整 PulseCore 回归 | 1173 项、116 套件通过 |
| 原生渲染 | `fund-performance-light`（460×430）四列完整；`fund-performance-narrow-dark`（330×470）折行后无裁切；两者均已目检 |
| 真实接口 | `fund-performance ok periods=10 returns=10 drawdowns=10 nav=true errors=[]`——10 个周期、收益与回撤各 10 项、净值可用、无部分失败 |
| 安装 | 已更新 `/Users/cora/Applications/FFF.app` 并验签 |

## 顺带修掉的测试可信度问题

验收过程中发现 `--research-live-selftest` 一轮会打 20+ 个真实请求，**必然触发动态限流**，而原实现把限流也算作契约失败，导致同一命令多次运行得到不同的失败清单。已改为把「限流」与「真实失败」分开统计并分别报告；只有真实失败才让这一轮判负。修正后重跑：`ok failures= throttled=`，全部通过。

## 未验证 / 不声称

- 只用 `510300`（沪深 300 ETF）做过真实请求，未覆盖货币基金、QDII、LOF、分级基金等品种。
- 未验证 `range` 参数对净值序列的实际长度影响（当前只取最新一条，不传 `range`）。
- 不计算年化、夏普、超额收益，不做同类排名变化趋势，不评价基金好坏。
- 基金行业配置未接入（两套时间键，无法与其他数据直接 join）。
