# 参与开发

感谢你愿意花时间。这个仓库是一个**个人在用的 macOS 行情与记账工作台**，不是团队产品；因此流程比大型开源项目轻，但边界比一般项目严——因为这个应用会碰到真实的财务记录。

先读这三份：

- [README](README.md)——项目概况与一页导览
- [AGENTS.md](AGENTS.md)——本仓库的**模型/agent 分工约定**（这不是人类贡献者文档，但它说明了实现与评审如何分权）
- [文档索引](docs/README.md)——设计与审计文档入口

## 环境准备

需要：

- macOS 14+
- 完整的 **Xcode 26+**
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` 是工程来源，不直接改 `.xcodeproj`）
- **Rust / Cargo**——用于编译内嵌的 Longbridge SDK

Longbridge SDK 的版本、提交和桥接补丁由 [scripts/build-longbridge-plugin.sh](scripts/build-longbridge-plugin.sh) 固定，**不要**在本机随手升级它。

## 构建

```bash
# 编译，不关闭、不替换正在运行的日常应用
scripts/dev-mac.sh --build

# 编译并启动构建产物
scripts/dev-mac.sh --verify
```

产物默认在 `build/DerivedData/Build/Products/Debug/FFF.app`。

## 测试与 PR 检查

```bash
# 默认都是离线 fixture／隔离存储测试，不启用实时行情测试
swift test --disable-sandbox --package-path Packages/PulseCore
swift test --disable-sandbox --package-path Packages/PulseUI

# 聚焦成交、同步与 review 边界
swift test --disable-sandbox --package-path Packages/PulseCore \
  --filter 'TradeMutationTests|ScopedAccountSyncMergeTests|ReviewBoundaryTests'
```

`--disable-sandbox` 用于 SwiftPM 编译插件/宏的兼容检查，**不代表**测试会读取真实账户数据。

Core 同时包含 XCTest 和 Swift Testing。汇总数量时要**计入两种框架**，参数化测试另有 case 数——只报 XCTest 的数字会低估覆盖。

原生回归必须**直接调用构建产物并带 `--main-window-demo`**。它会使用一次性的离线数据域、虚构标的，并跳过真实数据源凭据：

```bash
build/DerivedData/Build/Products/Debug/FFF.app/Contents/MacOS/FFF \
  --main-window-demo --trade-mutation-selftest --export-render-base64 \
  > build/native-trade-review.log 2>&1

build/DerivedData/Build/Products/Debug/FFF.app/Contents/MacOS/FFF \
  --main-window-demo --review-boundary-selftest --export-render-base64 \
  > build/native-boundary-review.log 2>&1
```

这些检查驱动真实 SwiftUI/AppKit 视图并导出原生渲染。**Core 通过不等于 UI 交互通过**；源码审查也不能代替实际截图检查。

CI 由 [FFF Checks](.github/workflows/checks.yml) 在 push、PR 和手动运行时执行两个包的离线测试及 macOS 编译。它不安装、不发布、不使用签名凭据。

> 要让这些检查成为**强制合并门禁**，维护者还需在分支保护／Rulesets 中要求 `PulseCore tests`、`PulseUI tests` 和 `macOS compile`。**仅新增 workflow 文件不会修改远端分支保护。**

## 代码组织

| 部分 | 职责 |
| --- | --- |
| [PulseCore](Packages/PulseCore/Package.swift) | 模型、数据源、账本回放、持久化、同步、计划进度与 agent 命令 |
| [PulseUI](Packages/PulseUI/Package.swift) | 共享图表、行情与盈亏展示组件 |
| macOS 应用 | 主窗口、菜单栏、账户操作、计划工作流、通知和本地 MCP |

关键边界规则（账户写入、计划操作、持久化）由 `PulseCore` 实现。**不要在各个页面各写一套校验**。

核心大文件仍在逐步拆分。迁移时保留行为回归，**避免同时修改存储格式和多个职责**。

## 签名

本地脚本优先复用钥匙串中的 `Fight For Free Local Development`，其次使用可用的 Apple 签名身份。**它不会默默回退到 ad-hoc。**

没有稳定身份时，请配置身份，或只做隔离编译检查。**不要用临时签名的产物替换日常应用**——那会让钥匙串授权反复弹出。

`PULSE_ALLOW_AD_HOC=1 scripts/dev-mac.sh --build` 仅用于隔离编译（例如一次性 CI runner），**不能用其产物更新日常安装**。

证书标识、私钥、凭据和真实账户数据**不得**提交到仓库。

## 提交与 PR

- 一个 PR 做一件事。行为改动附带对应测试，并说明**验证命令与实际输出**。
- 提交前跑一遍上面两个包的离线测试。
- 涉及界面时，附上原生渲染截图；只贴源码 diff 不足以说明视觉结果。
- 不要提交 `build/`、`DerivedData/`、日志、`.env`、证书、私钥或任何真实财务数据。

## 数据与隐私红线

这是硬性要求，不是建议：

1. **不要**在 issue、PR、测试、截图或文档里放**真实**的自选、持仓、成交、现金、账户名或截图。
   复现问题请使用虚构数据。
2. **不要**提交数据源凭据、钥匙串内容、MCP 令牌或同步文件。同步文件是可读 JSON，等同于私密财务记录。
3. **不要**提交签名证书标识、私钥或 `*.p8` / `*.p12` / `*.pem` 等材料。
4. 遥测是可选的，且受应用设置与构建配置控制。**不要**把账户、标的、数量、价格、凭据或令牌加入诊断/遥测内容。

## Agent 与自动化贡献

本仓库有明确的模型分工约定，见 [AGENTS.md](AGENTS.md)。若要使用自动化 agent 提交改动，请遵守同样的边界：

- 主 agent 负责需求、架构、验收标准与**最终评审**；实现由受限 worker 完成。
- 给 worker 明确的**文件归属**和验收检查，发送自包含、有界的任务。
- worker **不得**签名/安装应用、commit/push、联系他人或执行账户操作。
- 不要把聊天记录、密钥、凭据或真实账户数据交给 worker。

## 安全

漏洞请不要开公开 issue，见 [SECURITY.md](SECURITY.md)。

## 上游

本项目派生自 [fatwang2/Pulse](https://github.com/fatwang2/Pulse)，感谢上游的市场数据、图表和 macOS 基础实现。

本仓库的 FFF 改动是独立的开发分支，**不代表**上游产品的商业版本承诺，也不提供上游产品的购买或支持。上游的商标与品牌归其权利人所有。
