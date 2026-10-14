# FFF · Fight For Free

**一个 macOS 上的行情、账户记账与交易计划工作台：把「今天要看什么、计划要占用多少钱、成交后该记什么」放在同一个菜单栏应用里，而不是分散在券商 App 和表格之间。**

FFF 基于开源 [Pulse](https://github.com/fatwang2/Pulse) 改造，是一个**个人在用的开发版**。应用显示为 **FFF**；内部工程、Swift 模块和历史存储标识仍沿用 Pulse，以保持兼容。

> **记录事实，不执行交易。** 成交录入记录用户已经发生的交易，不向券商下单。现金、预算和资金来源是本地记账信息，不等同于券商实时余额。行情和计划分析仅供参考，不构成投资建议。

<p align="center">
  <img src="assets/readme/pulse-screenshot-en-01.png" width="32%" alt="自选列表：菜单栏弹出窗口中的多标的迷你行情" />
  <img src="assets/readme/pulse-screenshot-en-02.png" width="32%" alt="标的详情：分时／日 K 图表与市场数据" />
  <img src="assets/readme/pulse-screenshot-en-03.png" width="32%" alt="成交录入：价格、数量与交易后持仓预览" />
</p>

<p align="center"><sub>自选列表 · 标的详情 · 成交录入（截图取自上游 Pulse 界面；本仓库的构建显示为 FFF）</sub></p>

## 它解决什么问题

行情工具通常止步于「看价格」，记账工具通常止步于「记流水」。FFF 的取舍是让这两件事共用一套账户口径：

- **看**——菜单栏和主窗口里的证券、指数、基金、加密货币和贵金属；按市场和数据源选择行情与历史数据。
- **记**——成交回放持仓、成本、费用和已实现盈亏；移出自选后历史仍保留。
- **计划**——买卖意向、条件、执行记录、复盘和仓位份额关联。
- **核对**——跨账户展示**不会**把不同账户合并成一个虚构的成本账本。

## 主要功能与账户边界

- **三个独立账本**：**待确认记录**保存尚未归类的旧数据；**融资账户**支持自有资金和融资买入；**萌萌账户**支持普通买入。账户身份与资金来源是不同字段。
- **成交历史**：在自己的账本内回放。跨账户展示不会把不同账户合并成一个虚构的成本账本。
- **成交写入**：用户入口使用候选校验及提交；编辑和删除核对打开表单时的原记录，避免覆盖同步更新。修改相关买卖及日期不能使健康的账户账本产生负持仓。
- **交易计划**：真实成交进度优先于过时的原始状态；已经成交完毕的计划不会继续触发到价提醒。
- **仓位分账**：按用途和资金来源组织份额；账本变化后需要核对的份额不会被自动伪造或重分配。
- **配色**：买卖方向固定为**买红、卖绿**，独立于「红涨绿跌／绿涨红跌」的行情与盈亏配色。
- **本地优先**：本地备份、文件夹同步，以及可选的本机 MCP 接口。

归类和纠正账户归属是**重新整理记录**，不是券商资金或证券转账；操作前需要核对关联成交、计划及份额。

## 跨设备与备份

每台 Mac 只写自己的 `Pulse-sync-<device-id>.json`，不直接覆盖另一台设备的文件。冲突按**依赖范围**选择：单笔成交、单个字段（现金/预算/板块上限），或整个「账户＋标的账本」组。应用选择前保存双方快照并校验完整候选。

同步文件是**可读 JSON**，包含账户、成交、计划和账户资金设置。凭据、钥匙串内容、MCP 令牌和设备本地偏好**不参与同步**。

完整的冲突规则、备份保留策略和恢复流程见 **[文件夹同步与备份](docs/operations/sync-and-backup.md)**。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| **[文档索引](docs/README.md)** | **全部文档的入口，按设计和审计分类** |
| [图表工具设计](docs/design/chart-tools.md) | 画线、测量、计划自动画线、双轴与吸附 |
| [仓位资金来源](docs/design/funding-source.md) | 普通资金／融资／未标注作为份额属性 |
| [账户归属重构](docs/design/ownership-refactor.md) | 真实账本归属、待确认历史与跨账户成交 |
| [整体交易流程](docs/design/system-experience.md) | 工作台、资金与仓位池、计划台账、复盘衔接 |
| [日常交易纪律](docs/design/trading-discipline.md) | 仓位分账、多逻辑卡片、交易前检查 |
| [提醒、复盘、分布与备份](docs/design/workflows.md) | 到价提醒、交易复盘、仓位分布、备份与恢复 |
| [**MCP 本机接口**](docs/mcp.md) | **开放范围、19 个工具、账号隔离与令牌边界** |
| [文件夹同步与备份](docs/operations/sync-and-backup.md) | 多机同步、冲突选择、备份与恢复 |
| [多账号适配梳理](docs/audits/multi-account-audit.md) | 各页面与写入路径的账号隔离核对 |
| [账户归属审计报告](docs/audits/ownership-audit.md) | 重构前的缺陷复现与验证范围 |
| [DSH iCloud 同步插件](docs/operations/dsh-icloud-sync.md) | DeepSeek Harness 配置层的 iCloud 双向同步 |
| [交接记录](docs/operations/sync-handoff.md) | 早期交接：代码地图与构建环境（历史快照） |
| [待开发功能](docs/roadmap.md) | 已明确要做但尚未动手的功能 |

设计文档描述**现在应该如何工作**；审计报告记录**某一时刻曾经观察到什么**，其中描述的问题可能是修复前的行为。读法见[文档索引](docs/README.md)开头的说明。

## 本地开发

开发约束以 [AGENTS.md](AGENTS.md) 为准，贡献流程见 **[CONTRIBUTING.md](CONTRIBUTING.md)**。需要 macOS、完整 Xcode 26+、XcodeGen，以及用于编译内嵌 Longbridge SDK 的 Rust/Cargo。

```bash
# 编译，不关闭或替换正在运行的日常应用
scripts/dev-mac.sh --build

# 编译并启动构建产物（不是安装步骤）
scripts/dev-mac.sh --verify
```

测试与原生回归命令、`--main-window-demo` 的用途、以及本地签名为什么**不能**回退到 ad-hoc，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 工程职责

| 部分 | 职责 |
| --- | --- |
| [PulseCore](Packages/PulseCore/Package.swift) | 模型、数据源、账本回放、持久化、同步、计划进度与 agent 命令 |
| [PulseUI](Packages/PulseUI/Package.swift) | 共享图表、行情与盈亏展示组件 |
| macOS 应用 | 主窗口、菜单栏、账户操作、计划工作流、通知和本地 MCP |

核心大文件仍在逐步拆分；迁移应保留行为回归，避免同时修改存储格式和多个职责。账户写入、计划操作及持久化的边界规则由核心实现，**不应在各页面各写一套校验**。

## 数据源、隐私与安全

行情由市场路由的数据源提供，可能包括 Tencent、Yahoo、Binance、Sina、Naver、交易所公开数据和可选的 Longbridge。免费接口没有可用性承诺，可能延迟、限流或变更；无法解析来源时间的腾讯报价会被拒绝，而不是伪造为当前时间。

MCP 是可选的本机 loopback 接口，需显式开启并使用钥匙串中的 Bearer 令牌；该令牌具有本地写入能力。遥测是否启用取决于构建配置和应用设置，构建时没有应用标识则不启用。

漏洞请勿开公开 issue——见 **[SECURITY.md](SECURITY.md)**。

## 发布与上游

现有[发布入口](.github/workflows/release.yml)和[签名发布流程](.github/workflows/release-macos.yml)是单独的人工流程。测试/重构不会自动触发签名发布或上传。

感谢上游 Pulse 的市场数据、图表和 macOS 基础实现。上游产品、下载与支持渠道属于上游项目，本仓库的 FFF 改动**不应**被当作其商业版本承诺。

许可证见 [MIT License](LICENSE)，保留原有版权与授权声明。
