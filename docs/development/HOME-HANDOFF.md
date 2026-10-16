# 回家继续开发：2026-10-16 接力说明

## 先看这里（比旧状态文档优先）

用户最新要求：把今天的开发源码安全提交推送，回家在另一台电脑继续。当前以“可继续开发的检查点”交接，不宣称所有 Mac 页面已经完整移植。

**用户最重要的产品要求：iPhone 还原现有 Mac 里亲自调整过的设计，不要自行换产品逻辑。**

## 在家启动

先取得本次推送的分支，再在仓库根目录操作。需要完整 Xcode、可用的 iOS 模拟器运行时，以及 XcodeGen。生成的 Xcode 工程和构建缓存不入库。

```bash
git pull --ff-only
xcodegen generate
scripts/dev-ios.sh --run --demo
```

脚本会自动选择本机可用的 iPhone 模拟器，不要照搬办公室的设备 UUID。验收模式使用隔离的合成数据。模拟器构建不要求购买开发者账号，也不需要导入办公室的证书。

如果家中尚未克隆：仓库是 `https://github.com/Cora2077/Pulse.git`。推送完成后的聊天回复会给出分支和提交号；若本地已有未提交修改或拉取不允许快进，先保留它们，不能强制 reset。

## 今天的源码已经包含

- 真实 iPhone 今日/自选/计划/账户、成交与复盘、ActivityKit 与 Widget 扩展、共享同步基础和 Node 私人推送桥。
- 同花顺行业指数、三星/海力士中文名、行情提供器修正，以及同日进行的中韩分时时间轴相关源码与测试。
- 本轮 Mac 还原：把原 Mac 的工作台模型提取到 [共享模型](../../SharedAppSupport/TradingWorkbenchBoard.swift)，两端用同一份计算和文案；直接复用 Mac 事件控制器、用途文案和颜色。
- 自选的自定义/涨幅/今日盈亏/总盈亏/市值排序，自动排序只读，手动顺序保存校验冻结账户和分组。
- 新建计划通过搜索选择任意可交易标的；选择/取消不加入自选，保存校验通过才一起创建标的和计划，重试不重复。

## 最近验证到哪一步

- 原 Mac 工作台的未修改验收逻辑，已经在 iPhone 单元测试中直接执行通过。
- 大屏 K：17 项应用单元测试 + 7 项 UI 测试通过。
- 小屏 N：深色大字、新计划搜索/取消/保存、排序菜单/调整面板 3 项 UI 测试通过；截图已经目检。
- Core 完整回归 1027 项通过，Mobile 85 项、Sync 52 项、Activity 101 项、Node 推送桥 153 项通过。
- Mac 按原稳定签名编译通过，未覆盖已安装的日用 App。
- 交接前最后一轮 iPhone 编译通过。

**比 K/N 测试更晚的小改动，已编译但需要回家补跑针对性 UI 测试：**

1. 新建计划按钮移到计划页顶部，避免计划多时要滚到底。
2. 新现金账户买入计划的资金意图默认自有，编辑旧计划不改旧意图，和 Mac 一致。
3. 工作台“补齐历史复盘”直接切到账户的复盘页。
4. 复盘页的待写/已写使用共享 Mac 的 retrospective 判定：仅有备注或空复盘对象不能算完成，校准记录不混入待复盘。

回家先运行下面的针对性测试，再继续逐页还原：

```bash
scripts/dev-ios.sh --test
swift test --package-path Packages/PulseCore
swift test --package-path Packages/PulseMobile
swift test --package-path Packages/PulseSync
swift test --package-path Packages/PulseActivity
(cd Services/PulsePushBridge && node --test)
```

更详细的本轮口径与未覆盖项见 [Mac 一致性说明](iphone-mac-parity.md)。

## 接下来最值得做

- 给“历史复盘入口 → 复盘页”的跳转加一条 UI 测试，确认刚改的入口可直接操作。
- 按 Mac 检查剩余页面，不把摘要当完整编辑器：独立仓位池、份额核对、风险计算器、完整事件日历及复盘定位仍需逐页对齐。
- 真实 iCloud 双设备、真实 APNs、Watch 镜像和物理 iPhone 安装尚未验收。局域网同步只是讨论过，**还没有实现**，不能称为已经能免费体验全部后台功能。
- 源码合并期间曾有另一路分组时间轴修改。保留相关修改；分组 ForEach 已显式指定 UUID/WatchlistGroup 以避免 SwiftUI 的泛型推断报错。继续时先看当前 diff，不要回滚别的工作。

## 哪些东西有意没上传

- 真实账本、Mac 用户偏好、iPhone Air 沙盒数据及其本地备份。办公室 Air 看到的是一次性本地副本，不是已完成的双向自动同步；家里模拟器没有这些数据是正常的。
- 任何 Apple/券商/云服务/模型令牌、私钥、签名证书、环境凭据、配置账号库。
- Xcode 生成工程、DerivedData、SwiftPM 缓存、模拟器状态、`.dsh-home`/`.dsh-progress`/`.archify`、临时日志。

不要为继续开发而索取聊天中的密码或令牌，不要把个人数据补进 Git。Mac 日用安装必须用可用的稳定签名，不能为了跑起来就用 ad-hoc 覆盖；没有签名条件时先只做模拟器或编译验收。

## 工人模型

遵循 [AGENTS.md](../../AGENTS.md)：常规工人 Step-5-Preview，困难任务可选择 Kimi K3，主代理负责架构和金融数据安全。办公室的 DSH 登录状态不随 Git 迁移，家中需用本机已有配置。
