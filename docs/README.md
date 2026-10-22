# 文档索引

这里是 FFF（Fight For Free）的开发文档入口。根目录的 [README](../README.md) 是一页导览；本页按用途列出全部文档。

仓库里有两类文档，**目的不同，读法也不同**：

- **设计文档**（`design/`）描述系统**现在应该如何工作**，是对当前实现的规格。
- **审计报告**（`audits/`）记录某一时刻**曾经观察到什么**，其中描述的问题可能是修复前的行为。阅读时先看文首的日期与基线说明，再看末尾的交付状态。

## 设计与规格

| 文档 | 内容 |
| --- | --- |
| [图表工具设计](design/chart-tools.md) | 画线、测量、交易计划自动画线；双轴百分比、计划适配范围、吸附与删除操作 |
| [仓位资金来源](design/funding-source.md) | 普通资金／融资买入／未标注作为份额的独立属性；按数量拆分与汇总口径 |
| [账户归属重构](design/ownership-refactor.md) | 真实账本归属规则、待确认历史的收敛、跨账户分批成交与界面分工 |
| [整体交易流程](design/system-experience.md) | 今日工作台、资金与仓位池、计划台账、事件时间轴与盘后复盘的衔接 |
| [日常交易纪律](design/trading-discipline.md) | 仓位分账、多逻辑卡片、交易前检查。**仓位分账与计划条件已落地；冷静期仍为草案** |
| [提醒、复盘、分布与备份](design/workflows.md) | 到价提醒、交易复盘、按币种的仓位分布、本地备份与恢复边界 |
| [待开发功能](roadmap.md) | 已明确要做但尚未动手的功能；已完成项指向对应设计文档 |
| [扶摇功能实施清单](design/fuyao-feature-plan.md) | 个股情报、板块强弱、ETF 穿透、情绪、财报与复盘背景的逐项状态 |
| [扶摇 API 最佳实践与下一轮设计](design/fuyao-api-practices-and-next-wave.md) | 13 条接口纪律、22 条已接入路径盘点、7 项新功能设计（除权口径、龙虎榜、竞价、财务指标、基金业绩、交易日历、打新）与请求预算 |
| [扶摇端点契约摘要](design/fuyao-endpoint-contracts-2026-10-22.md) | 50 节逐端点摘录（49 个端点/端点组 + 跨端点共性坑）：参数、单位、窗口限制与 null 语义；标注客户端专用 6 项、敬请期待 3 项 |

## 审计与验证记录

| 文档 | 内容 |
| --- | --- |
| [多账号适配梳理](audits/multi-account-audit.md) | 各页面与写入路径的账号隔离逐项核对，以及跨账户成交展示的调整 |
| [账户归属审计报告](audits/ownership-audit.md) | 重构前的缺陷复现（R1–R4）、模型与展示问题（D1–D3）、验证范围与重构交付状态 |
| [扶摇行情与一秒刷新验收](verification/fuyao-fast-refresh-2026-10-20.md) | 行情类型路由、复权与时间戳、独立刷新调度、真实接口及原生验证 |
| [扶摇研究功能验收](verification/fuyao-features-2026-10-21.md) | 六项功能的数据口径、Core/原生/真实接口验证与交付边界 |
| [除权事件与计划口径验收](verification/fuyao-corporate-actions-2026-10-22.md) | P0-1 的口径决定、命中规则、10 项单测/33 项原生自测/17 项真实接口与渲染检查 |
| [龙虎榜与严重异动验收](verification/fuyao-capital-flow-2026-10-22.md) | P0-2 的实测约束如何落进代码、区间与身份口径、14 项单测/46 项原生自测/20 项真实接口 |
| [前复权日K无数据修复](verification/forward-candle-fix-2026-10-22.md) | 腾讯对从未除权标的只返回未复权序列的契约、回退条件的精确边界，以及失败态与空态的文案分流 |
| [财务五类指标验收](verification/fuyao-financial-indicators-2026-10-22.md) | P1-4 的单位目录表设计（% / 倍 / 次）、`index_id` 非封闭枚举的实测、12 项单测与真实接口验证 |
| [基金业绩与回撤验收](verification/fuyao-fund-performance-2026-10-22.md) | P1-5 的三端点单位差异、`.convertFromSnakeCase` 导致自建 CodingKey 失效的修正、失败隔离与自适应表格 |
| [交易日历校准验收](verification/fuyao-trading-days-2026-10-22.md) | P2-6 的覆盖边界（区间外为未知而非休市）、真实比对结果（243 日、0 差异）与只提示不写回的差异检测 |
| [打新日历验收](verification/fuyao-ipo-2026-10-22.md) | P2-7 的两个代码（申购/交易）分离、未定值处理、北交所无身份的展示、六查询失败隔离 |

审计用的探针代码保留在 [audit/](../audit/)，`audit/ownership-2026-10-12/` 是 2026-10-12 那一轮的证据，不属于持续回归测试目标。改动相关逻辑时应补充断言正确行为的新回归测试，而不是复用这些探针。

## 运行与运维

| 文档 | 内容 |
| --- | --- |
| [MCP 本机接口](mcp.md) | 如何开启、已经开放的 19 个工具、尚未开放的写入口，以及令牌边界 |
| [文件夹同步与备份](operations/sync-and-backup.md) | 多台 Mac 之间如何同步、冲突选择的范围、备份与恢复的边界 |
| [DSH iCloud 同步插件](operations/dsh-icloud-sync.md) | DeepSeek Harness 的插件清单与配置层通过 iCloud Drive 双向同步的设计 |
| [交接记录](operations/sync-handoff.md) | 早期开发交接：代码地图、构建环境坑与各机版本状态。**历史快照，日期为 2026-09-30** |

## 参与开发

| 文档 | 内容 |
| --- | --- |
| [CONTRIBUTING](../CONTRIBUTING.md) | 环境准备、构建、测试、PR 检查、签名与提交边界 |
| [SECURITY](../SECURITY.md) | 漏洞报告渠道、支持范围与安全边界（MCP 令牌、同步文件、遥测） |
| [AGENTS](../AGENTS.md) | 本仓库的模型分工约定：主 Agent 负责需求与最终评审，实现经受限 worker 完成 |

## 给读者的提示

- 文档以**中文**为主，源码注释与代码标识符以**英文**为主。应用界面支持中文、English、日本語、한국어。
- 设计文档里的验收数字（测试项数、渲染张数）是**当时那一轮**的记录。要判断当前状态，请以最新一次提交和 CI 结果为准。
- 涉及金额、成本、盈亏的口径以 [账户归属重构](design/ownership-refactor.md) 与对应的 `PulseCore` 实现为准；本目录不重复定义算法。
