# FFF · Fight For Free

FFF 是基于开源 [Pulse](https://github.com/fatwang2/Pulse) 改造的 macOS 行情、账户记账与交易计划工作台。应用显示为 **FFF**；内部工程、Swift 模块和历史存储标识仍沿用 Pulse，以保持兼容。

这是本仓库的开发版说明，不是上游 Pulse 商业版本的购买、安装或支持页面。

> **记录事实，不执行交易。** 成交录入记录用户已经发生的交易，不向券商下单。现金、预算和资金来源是本地记账信息，不等同于券商实时余额。行情和计划分析仅供参考，不构成投资建议。

## 主要功能与账户边界

- 行情、自选和图表：菜单栏及主窗口，支持证券、指数、基金、加密货币和贵金属；按市场和数据源选择行情与历史数据。
- 三个独立账本：**待确认记录**保存尚未归类的旧数据；**融资账户**支持自有资金和融资买入；**萌萌账户**支持普通买入。账户身份与资金来源是不同字段。
- 成交历史：在自己的账本内回放持仓、成本、费用和已实现盈亏；移出自选后历史仍保留。跨账户展示不会把不同账户合并成一个虚构的成本账本。
- 成交写入：用户入口使用候选校验及提交；编辑和删除核对打开表单时的原记录，避免覆盖同步更新。修改相关买卖及日期不能使健康的账户账本产生负持仓。旧导入与校准的空头兼容路径仍与新成交入口区分。
- 交易计划：买卖意向、条件、执行记录、复盘和仓位份额关联。真实成交进度优先于过时的原始状态；已经成交完毕的计划不会继续触发到价提醒。
- 仓位分账：按用途和资金来源组织份额；账本变化后需要核对的份额不会被自动伪造或重分配。
- 买卖方向固定为买红、卖绿，独立于“红涨绿跌/绿涨红跌”的行情与盈亏配色。
- 本地备份、文件夹同步和可选的本地 MCP 接口。

归类和纠正账户归属是**重新整理记录**，不是券商资金或证券转账；操作前需要核对关联成交、计划及份额。

计划列表、主窗口总览和个股页使用同一套菜单。修改状态及暂缓提醒按显式来源账户执行，不改变当前选择；打开编辑、成交、历史或删除表单时会统一进入来源账户，随后草稿保持绑定，切换到账户的同名计划不会重定向写入。同步后已变化的计划操作会被拒绝，需重新打开。

## 同步、冲突与备份

先把各台 Mac 更新到同一个当前 FFF 开发版本，再在数据与同步设置中选择同一个同步文件夹，例如 iCloud Drive 内的文件夹；旧版本的冲突选择规则不会因另一端更新而自动改变。每台 Mac 只写自己的 `Pulse-sync-<device-id>.json`，不会直接覆盖另一台设备的文件。云盘上传、下载和文件协调可能延迟，不能把“本机已写入”理解为另一端已经收到。

冲突选择的范围是：

1. 同一成交的不兼容修改：只选择该冲突记录，其他独立成交继续合并。
2. 现金、仓位预算、预算情景、板块上限：按冲突字段选择，不替换整份账户数据。
3. 跨账户归类、计划关联或合并后超卖：按依赖连接的**账户＋标的账本**整体选择。组内的成交、计划、份额和自选归属相互依赖，不能随意拼接；组外的独立变更继续保留。

界面会列出选择范围。当前同一来源 Mac 的按钮为已列冲突提供一次本机/远端选择，不是逐笔独立选择。选择不再意味着保留某台设备的全部账户数据。应用前保存双方快照，再校验完整候选；查看期间数据变化时，需要重新核对，不能强行覆盖。

同步文件包含可读的账户、成交、计划和账户资金设置。数据源凭据、钥匙串内容、MCP 令牌和设备本地偏好不随这些文件同步。请把同步目录和备份视为私密财务记录，不公开上传真实数据用于报错或测试。

## 本地开发

开发约束以 [AGENTS.md](AGENTS.md) 为准。需要 macOS、完整 Xcode 26+、XcodeGen，以及用于编译内嵌 Longbridge SDK 的 Rust/Cargo。SDK 版本、提交和桥接补丁由 [构建脚本](scripts/build-longbridge-plugin.sh) 固定。

```bash
# 编译，不关闭或替换正在运行的日常应用
scripts/dev-mac.sh --build

# 编译并启动构建产物（不是安装步骤）
scripts/dev-mac.sh --verify
```

[project.yml](project.yml) 是 Xcode 工程的来源；脚本会用 XcodeGen 生成工程。应用构建产物默认在 `build/DerivedData/Build/Products/Debug/FFF.app`。日常安装位置遵循工作区约定，不要把隔离演示应用当作日常版本。

### 保持本地签名稳定

本地脚本优先复用钥匙串中的 `Fight For Free Local Development`，其次使用可用的 Apple 签名身份。它不会默默回退到 ad-hoc。没有稳定身份时，先配置身份或进行明确的隔离编译检查，不要用临时签名替换日常应用，否则钥匙串授权可能反复出现。

`PULSE_ALLOW_AD_HOC=1 scripts/dev-mac.sh --build` 仅用于隔离编译（例如一次性 CI runner），不能用其产物更新日常安装。证书标识、私钥、凭据和真实账户数据不得提交到仓库。

## 测试与 PR 检查

```bash
# 默认均为离线 fixture/隔离存储测试，不启用实时行情测试
swift test --disable-sandbox --package-path Packages/PulseCore
swift test --disable-sandbox --package-path Packages/PulseUI

# 聚焦成交、同步和 review 边界
swift test --disable-sandbox --package-path Packages/PulseCore \
  --filter 'TradeMutationTests|ScopedAccountSyncMergeTests|ReviewBoundaryTests'
```

`--disable-sandbox` 用于 SwiftPM 编译插件/宏的兼容检查，不意味着读取真实账户数据。Core 同时包含 XCTest 和 Swift Testing；汇总数量时需计入两种框架，参数化测试另有 case 数。

原生回归必须直接调用构建产物并带 `--main-window-demo`。这会使用一次性的离线数据域、虚构标的，并跳过真实数据源凭据；不要省略该参数：

```bash
build/DerivedData/Build/Products/Debug/FFF.app/Contents/MacOS/FFF \
  --main-window-demo --trade-mutation-selftest --export-render-base64 \
  > build/native-trade-review.log 2>&1

build/DerivedData/Build/Products/Debug/FFF.app/Contents/MacOS/FFF \
  --main-window-demo --review-boundary-selftest --export-render-base64 \
  > build/native-boundary-review.log 2>&1
```

这些检查驱动真实 SwiftUI/AppKit 视图并导出原生渲染。Core 通过不等于 UI 交互通过；源码审查也不能代替实际截图检查。真实双机云盘同步、在线行情与通知权限应在单独的人工作业中验证，不由上述离线测试宣称覆盖。

[FFF Checks](.github/workflows/checks.yml) 在 push、PR 和手动运行时执行两个包的离线测试及 macOS 编译，不安装、不发布，不使用签名凭据。工具链与现有发布工作流一致，runner 缺少所选 Xcode 时会明确失败。

要让这些检查成为**强制合并门禁**，仓库维护者还需在分支保护/Rulesets 中要求 `PulseCore tests`、`PulseUI tests` 和 `macOS compile`。仅新增 workflow 文件不会自动修改远端分支保护。

## 工程职责

| 部分 | 职责 |
| --- | --- |
| [PulseCore](Packages/PulseCore/Package.swift) | 模型、数据源、账本回放、持久化、同步、计划进度与 agent 命令 |
| [PulseUI](Packages/PulseUI/Package.swift) | 共享图表、行情与盈亏展示组件 |
| macOS 应用 | 主窗口、菜单栏、账户操作、计划工作流、通知和本地 MCP |
| [成交校验](Packages/PulseCore/Sources/PulseCore/Store/TradeMutationValidation.swift) | 纯 payload/回放校验及可操作的错误原因 |
| [账户同步合并](Packages/PulseCore/Sources/PulseCore/Store/WatchlistAccountSyncMerge.swift) | 账户与字段冲突、依赖分组及完整候选校验 |
| [成交候选](Packages/PulseCore/Sources/PulseCore/Store/TradeLedgerMutation.swift) | 回放缓存和旧记录元数据保留，不直接写入存储 |
| [计划候选](Packages/PulseCore/Sources/PulseCore/Store/TradePlanMutation.swift) | 配置规范化、修订记录及份额绑定校验 |
| [归属校验](Packages/PulseCore/Sources/PulseCore/Store/BrokerageClassificationValidation.swift) | 来源账户引用、关联成交进度和全量候选结构校验 |
| [本地持久化](Packages/PulseCore/Sources/PulseCore/Store/WatchlistPersistenceCodec.swift) | 兼容存储格式、读写校验和重复数据规范化 |
| [计划菜单](PulseMac/Sources/PlanActionMenu.swift) | 共用可用操作和显式来源账户路由 |
| [买卖展示](PulseMac/Sources/TradeSidePresentation.swift) | 与涨跌设置无关的方向颜色和徽标 |
| [仓位卡片](PulseMac/Sources/PortionCardFace.swift)／[操作表单](PulseMac/Sources/PoolAllocationSheets.swift) | 从仓位主页面拆出的卡片渲染、转移、来源标记和核对表单 |

核心大文件仍在逐步拆分；迁移应保留行为回归，避免同时修改存储格式和多个职责。账户写入、计划操作及持久化的边界规则由核心实现，不应在各页面各写一套校验。

## MCP、数据源与隐私

MCP 是可选的本机 loopback 接口，需显式开启并使用钥匙串中的 Bearer 令牌。它可读写自选、记账成交和计划，不代表获得券商下单权限。该令牌具有本地写入能力，不要写进源码或测试报告。

行情由市场路由的数据源提供，可能包括 Tencent、Yahoo、Binance、Sina、Naver、交易所公开数据和可选的 Longbridge。免费接口没有可用性承诺，可能延迟、限流或变更；无法解析来源时间的腾讯报价会被拒绝，而不是伪造为当前时间。连接 Longbridge 的权限和行情权益取决于用户自己的账户。

TelemetryDeck 是否启用取决于构建配置和应用设置；应用的采集边界见 [PulseTelemetry.swift](PulseMac/Sources/PulseTelemetry.swift)。构建时没有应用标识则不启用该构建的分析上报。不要把账户、标的、数量、价格、凭据或令牌加入诊断/遥测内容。

## 发布与上游

现有 [发布入口](.github/workflows/release.yml) 和 [签名发布流程](.github/workflows/release-macos.yml) 是单独的人工流程。测试/重构不会自动触发签名发布或上传；发布身份、凭据、版本和环境审核需要维护者明确确认。

感谢上游 Pulse 的市场数据、图表和 macOS 基础实现。上游产品、下载与支持渠道属于上游项目，本仓库的 FFF 改动不应被当作其商业版本承诺。

许可证见 [MIT License](LICENSE)，保留原有版权与授权声明。
