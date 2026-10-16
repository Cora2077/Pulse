# PulseActivity + PulseWidgets 集成说明

面向主代理（Lead）。本文件说明公开 API、Lead 需要添加的 target 配置、以及**必须在真机上才能验证**的条件。
范围：`Packages/PulseActivity/**`、`PulseWidgets/**`。本 worker 没有改动 `project.yml`、`PulseIOS`、`PulseCore` 或任何其他文件。

验证状态（本机实测）：

- `swift test --package-path Packages/PulseActivity`：**101 tests / 12 suites 全通过**（macOS，纯 policy 与 payload）。
- iOS 18 SDK 全量 codegen 构建（`-swift-version 6 -strict-concurrency=complete`，含 ActivityKit coordinator）：**0 error / 0 warning**。
- PulseWidgets 全量 codegen 构建（WidgetKit + ActivityKit, iOS 18 target）：**0 error / 0 warning**。
- Widget `#Preview` 宏在 standalone `swiftc` 下不可用（缺 plugin server）；preview 的**构造体**已用等价探针单独 typecheck 通过，见 §七。
- **未做**：签名、安装、真机运行、APNs 推送、Watch 镜像渲染。这些在本机无法验证，见文末。

---

## 一、包结构

```
Packages/PulseActivity/
  Package.swift                       # iOS 18 / macOS 14，无外部依赖
  INTEGRATION.md                      # 本文件
  Sources/PulseActivity/
    PulseActivityState.swift          # payload、quote unit、状态、plan digest + 计划同步元数据、staleness
    PulseActivityAttributes.swift     # ActivityAttributes 身份 + ActivityContent + 深链接
    PulseTrackingPolicy.swift         # 纯自动关注 policy + 持久偏好 + 持久预算 ledger + capability 门控 + runtime status 文案
    PulseActivityBridging.swift       # ActivityKit conformance（iOS-gated）+ 格式化（含 points）+ session id
    PulseActivityCoordinator.swift    # ActivityKit 生命周期（iOS-gated）
  Tests/PulseActivityTests/
    PulseActivityStateTests.swift     # payload / 格式化 / 深链接 / staleness / 解码兼容
    PulseTrackingPolicyTests.swift    # policy / 偏好持久化 / 预算 ledger / reconcile 决策

PulseWidgets/                         # 还不是 SwiftPM 包：它是 widget extension 的源码目录
  Sources/
    PulseWidgetsBundle.swift          # @main WidgetBundle + ActivityConfiguration + previews
    PulseActivityPresentation.swift   # 展示层解析（视图不读时钟；计划同步状态与行情时间分离）
    PulseLiveActivityViews.swift      # 锁屏 / 灵动岛（minimal 只放方向 glyph）/ Watch 小卡
    PulseWidgetStyle.swift            # 品牌蓝、红涨绿跌、波形 glyph
    PulseWidgetDeepLink.swift         # 深链接 scheme
```

`PulseWidgets/` 故意**没有** `Package.swift`：widget extension 必须是 Xcode target（需要 Info.plist、`NSExtension`、entitlements、独立 bundle id），做成 SwiftPM 包反而会误导。Lead 按下面的 target 配置接入。

---

## 二、公开 API

### 2.1 Payload（App / Widget / APNs 共用）

```swift
public struct PulseActivityInstrument: Codable, Hashable, Sendable {
    var symbolKey, displayName, identityText, currencyCode: String
    var unit: PulseQuoteUnit              // .currency（默认）| .points
    var price, change: Double
    var changePercent: Double?          // nil = 源没有昨收，绝不伪造
    var quoteSourceTime: Date           // 源时间，不是收到时间
    var sourceDelay: TimeInterval?      // 源自报延迟
    var marketPhase: PulseMarketPhase
}

public enum PulseQuoteUnit: String { case currency, points }

public struct PulseActivityPlanDigest: Codable, Hashable, Sendable {
    var priceConditionReachedCount: Int  // 到价待确认
    var manualReviewCount: Int           // 手工条件待复核
    var remainingPlanCount: Int          // 待办计划数（按计划计，不按股数/金额）
    var asOf: Date?                      // 计划数据自身的确认时间，绝不借用行情时间
    var revision: String?                // 同步层版本号，本模块不解析
    var syncState: PulsePlanSyncState    // 缺字段解码为 .unavailable
    var actionableCount: Int { get }     // 前两者之和
    var needsSyncWarning: Bool { get }
    func syncLabel(asOf: Date) -> String // "计划待同步" / "计划 10 分钟前确认" / ""
}

public struct PulseActivityState: Codable, Hashable, Sendable {
    var primary: PulseActivityInstrument
    var plans: PulseActivityPlanDigest
    var status: PulseActivityStatus
    var staleDate: Date
    var quoteSourceTime: Date
    var sessionID: String?
}
```

**红线（有测试守护，`payloadIsRedacted`）**：整个 payload 里**没有**持仓数量、成本、余额、盈亏、账户名、计划备注字段。不是"默认不填"，而是类型层面不存在。`PulseActivityPlanDigest` 只携带计数。

`staleDate` 由**源时间 + 相位窗口**推导，绝不取 `Date()`。测试 `staleDateIsSourceDerived` 固定这一点。

**两个时钟互不冒充（新增）**：行情的 `quoteSourceTime` 与计划的 `plans.asOf`/`syncState` 是**独立**字段。行情刚更新不代表计划已确认，反之亦然。Widget 会同时显示两者（见 §三）。

**向后兼容解码（新增，两条都有测试）**：

| 缺什么 | 解码成什么 | 为什么不是别的 |
|---|---|---|
| `plans.syncState` / `asOf` / `revision` | `syncState = .unavailable`，`asOf = nil` | 缺失≠已同步。缺字段的旧 payload 若解成 `.synced`，锁屏会对一个年龄未知的计划显示"已同步" |
| `instrument.unit` | `.currency` | 旧 payload 只有货币报价这一种；这是唯一不会改变既有显示的取值 |
| `plans` 整体缺失 | 三个计数为 0 | 与旧行为一致（Node 端也这么默认） |
| 枚举收到未知值（如 `syncState: "reconciling"`） | **解码失败** | 与既有策略一致：本 build 解释不了的 payload 不能被当成能解释的推送/渲染 |

### 2.2 状态

```swift
public enum PulseActivityStatus { case live, stale, marketClosed, pausedToday,
    disabled, permissionRequired, remoteUnavailable, noCandidate }
public enum PulseMarketPhase  { case preMarket, regular, lunchBreak, postMarket,
    overnight, closed, unknown }
public enum PulseChangeDirection { case up, down, flat }
```

- `pausedToday`（今日暂停）与 `disabled`（永久关闭）是**两个独立 case**，互不冒充。
- `remoteUnavailable` 专门用于"未配置远程服务"：它让调用方可以如实说"仅本机前台"，而不是把前台成功包装成后台成功。

### 2.3 自动关注 policy（纯函数，macOS 可测）

```swift
public struct PulseActivityCandidate {   // held OR activePlan OR pinned
    var symbolKey: String
    var held, hasActivePlan, pinned: Bool
    var actionablePlanCount: Int
    var qualifies: Bool { held || hasActivePlan || pinned }
}

public struct PulseTrackingPreferences: Codable, Hashable, Sendable {
    var enabled: Bool                 // 总开关
    var pausedSessionID: String?      // 按 session 暂停，不是按日期
    var pinnedSymbolKey: String?
    mutating func pauseToday(sessionID:at:)
    mutating func resumeToday(at:)    // 只有显式用户操作会调用
    mutating func setEnabled(_:at:)
    mutating func pin(symbolKey:at:)
}

public enum PulseTrackingPolicy {
    static func decide(context:preferences:) -> PulseTrackingDecision
    static func order(_:pinnedSymbolKey:) -> [PulseActivityCandidate]
    static func reconciledPrimary(currentlyShowing:decision:preferences:) -> PulseActivityCandidate?
    static func automaticStartBudget(forAttempts: Int) -> Bool
    static func canStartAutomatically(ledger:sessionID:) -> Bool
    static func reconcileAction(currentlyShowing:decision:preferences:
                                hasActivityFor:isAutomatic:attemptsInSession:) -> PulseReconcileDecision
}

public enum PulseReconcileAction: String {
    case start            // 唯一会花掉自动开始预算的动作
    case update           // 已存在的活动收到新内容；不花预算
    case holdIncumbent    // 排序第一变了但仍显示旧标的；不花预算
    case budgetExhausted  // 本 session 自动预算已用完
    case none             // 无候选或被门控拒绝；现有活动被收掉
}
```

**`reconcileAction` 修正了两个真实缺陷（每个都有测试）**：

1. **预算跟"实际显示的主标的"走，不跟排序第一走。** 旧 coordinator 用 `decision.primary` 判断 `hasExisting`：当保留 incumbent、而排序第一已变成别的标的时，它会为一个已经在显示的活动记一次 start，白耗预算；预算用完后还会**拒绝更新 incumbent 本身**。
2. **只有真正的 start 花预算。** update / hold / 拒绝都是 0。`PulseReconcileDecision.attemptsConsumed` 只可能是 0 或 1。

**门控顺序**：`disabled` → `pausedToday` → `marketClosed` → `permissionDenied` → `noCandidate`。

**已实现的产品规则（每条都有测试）**：

| 规则 | 测试 |
|---|---|
| held OR plan OR pinned，不是 AND | `ruleIsOrNotAnd` |
| 不需要每日手动开始，`decide` 无"开始"参数 | 全部 policy 测试 |
| 暂停按 session，跨日自动恢复，无需用户操作 | `pauseGate` |
| 暂停与关闭互不覆盖 | `pauseAndDisableDiffer` |
| 休市不自作主张（pre/post/overnight/lunch 都不算开市） | `marketClosedGate` |
| 无远程服务时 `foregroundOnly == true` | `foregroundOnlyIsDeclared` |
| 固定主标的优先，且 tick 不会轮换主标的 | `pinnedWins` / `incumbentIsHeld` |
| 自动启动有**每 session 预算**（<2 次），不循环 | `automaticStartBudget` |
| 预算跨启动持久，重启/系统 ended 都不归还 | `budgetSurvivesRelaunch` / `relaunchLoopIsBounded` |
| 只有用户显式 resume 才重开预算 | `userResumeReopensBudget` / `onlyUserResumeReopens` |
| 保留 incumbent 与 update 都不花预算 | `holdIncumbentDoesNotSpendBudget` / `updateDoesNotSpendBudget` |

**没有绕开系统 8 小时限制**：模块内没有任何定时器、没有重启循环、没有后台任务。`automaticStartBudget` 只**减少**启动次数。

### 2.4 持久偏好与持久预算

```swift
public struct PulseTrackingPreferenceStore {
    init(defaults: UserDefaults,
         key: String = defaultKey,             // "pulse.activity.tracking.preferences.v1"
         budgetKey: String = defaultBudgetKey) // "pulse.activity.tracking.start-budget.v1"
    func load() -> PulseTrackingPreferences
    func loadResult() -> PulseTrackingStoreSnapshot   // 带 load 原因：.loaded/.empty/.corrupt
    func save(_:)
    func mutate(_:) -> PulseTrackingPreferences

    // 持久自动开始预算（同一 defaults / app group）
    func loadBudget() -> PulseAutomaticStartLedger
    func saveBudget(_:)
    @discardableResult func claimAutomaticStart(inSession:at:) -> PulseAutomaticStartLedger
    @discardableResult func refundAutomaticStart(inSession:at:) -> PulseAutomaticStartLedger
    @discardableResult func clearAutomaticStartBudget(sessionID:at:) -> PulseAutomaticStartLedger
}

public struct PulseAutomaticStartLedger: Codable, Hashable, Sendable {
    var sessionID: String?
    var attempts: Int
    var updatedAt: Date?
    func attempts(inSession: String) -> Int     // 其它 session 一律返回 0
    mutating func recordStart(inSession:at:)
    mutating func clear(sessionID:at:)          // 只清指定 session
}
```

**缺失/损坏的 blob 不构成授权（已强化）**：`load()` 在 `.empty` 与 `.corrupt` 两种情况下都返回 `consentNotYetGiven`（`enabled = false`），**不再**返回 `trackingEnabled`。用 `loadResult()` 拿到 `.empty`/`.corrupt` 以便如实告诉用户。旧测试曾断言损坏时 `enabled == true`——那正是要修掉的 bug，已改为断言 `false`。

`PulseTrackingPreferences(enabled:)` 的 `enabled` **没有默认值**是刻意的：每个构造点都必须说明它的含义，使"没有存储偏好"无法悄悄变成"同意"。`PulseTrackingPreferences.trackingEnabled`（true）仅供**纯上下文**使用——preview、单元测试；绝不作为磁盘读取的回落值。

**预算持久化语义（本 worker 的核心修正）**：

| 事件 | 对预算的影响 | 依据 |
|---|---|---|
| 自动 start 请求**之前** | **先占用**（`claimAutomaticStart`），防止请求无回音却能买第二次 | `relaunchLoopIsBounded` |
| 系统 `.ended` / `.dismissed` | **不清零**。`.ended` 什么都不做；`.dismissed` 只按 session 记 pause | `endingDoesNotRefund` |
| App 重启 / 新 store 实例 | **不清零**。计数在 app group defaults 里 | `budgetSurvivesRelaunch` |
| 下一个 session | 自动满预算（不靠定时器，也不靠 reset 调用） | `newSessionHasFullBudget` |
| 请求抛出、未创建任何活动 | **退还**（唯一合法退回路径） | `refundIsBounded` / `failedStartIsRefunded` |
| 用户显式 `resumeToday()` | 重开当前 session 预算（**唯一**重置路径） | `onlyUserResumeReopens` |
| 用户显式 start（`isAutomatic: false`） | 不占预算、也不受预算限制 | `userStartIsNotBudgeted` |

`clear(sessionID:)` 只影响匹配的 session；损坏的 ledger 读作"未花费"——只会导致比实际更少的自动启动，不会导致无限循环。

### 2.5 ActivityKit coordinator（仅 iOS，`@MainActor`）

```swift
@MainActor public protocol PulseActivityDataSource: AnyObject {
    func activityAttributes() -> PulseActivityAttributes
    func activityState(now: Date) -> PulseActivityState?    // nil => 结束活动
    func trackingCandidates() -> [PulseActivityCandidate]
    func currentMarket() -> (key: String, phase: PulseMarketPhase, timeZone: TimeZone)
}

@MainActor public protocol PulseActivityTokenDelegate: AnyObject {
    func activityDidReceiveUpdateToken(_ token: Data, forActivityID: String)
    func activityDidReceivePushToStartToken(_ token: Data, forAttributesType: String)
    func activityDidInvalidateToken(_ token: Data)
}

@MainActor public final class PulseActivityCoordinator {
    init(dataSource:preferencesStore:staleness:capability:)
    private(set) var status: PulseActivityRuntimeStatus
    weak var tokenDelegate: PulseActivityTokenDelegate?

    @discardableResult func reconcile(now:isAutomatic:) async -> PulseActivityStatus?
    func endAllActivities(now:) async
    func endActivity(symbolKey:dismissalPolicy:) async
    func pauseToday(now:) async
    func resumeToday(now:) async
    func startObservingPushTokens(attributesType:)
    func observeUpdateTokens(of:)     // 供启动时发现的既有活动调用
    func observeState(of:)
}
```

**令牌处理**：`pushToStartTokenUpdates` / `pushTokenUpdates` 的 `Data` **只**交给 `tokenDelegate`。coordinator 内部只保留一个去重 `Set<Data>`（内存），**不日志、不打印、不落盘、不上传**。没有任何 `print`/`Logger` 记录令牌。**本地路径不读任何凭据、不发任何网络请求**（模块内没有 `URLSession`/`Network`/`Keychain`）。

**activity state 观察**：

- `.dismissed` 被当作"今日暂停"处理（`pauseToday`，按 session 作用域）。
- `.ended` **不归还自动开始预算**（旧代码在这里 `removeAll()`，正是"结束/重启可无限再拉"的漏洞）。`.ended` 是系统生命周期事件，不是用户决定，因此不授予任何东西。仅置 `lastChangeWasLocal = false`。
- `.stale`/`.active`/`.pending` 不额外动作。
- **代码注释明确写了**：系统是否及时上报 dismissal 必须真机验证，不能承诺；下一次前台 reconcile 才是兜底。

**唯一的重置路径是用户**：`resumeToday(now:)` 先清 pause，再 `clearAutomaticStartBudget(sessionID:)`，然后 `reconcile(isAutomatic: false)`。没有任何自动路径或生命周期事件会调用 ledger 的重置。

**如实的能力声明（新增门控）**：

```swift
public enum PulseActivityCapability { case foregroundOnly, remotePushConfigured, remotePushUnavailable }
public static func effective(_ declared:hasPushToStartToken:) -> PulseActivityCapability
public var capabilityDescription: String
public var canStartRemotely: Bool   // status.capability == .remotePushConfigured
```

**`remotePushConfigured` 需要真实 push-to-start token**：仅"代码里写了远程分支"不构成能力。在 ActivityKit 真的把 push-to-start token 交给本进程之前，`declared == .remotePushConfigured` 会降级为 `.foregroundOnly`。token 只是**必要不充分**条件——它证明本机可被寻址，**不**证明 APNs 接受我们的 key、也**不**证明某次投递会送达。因此：

- token **只能把声明往下压**，永远不能把一个真正的前台-only build 升级成远程可用（`tokenCannotUpgradeForegroundOnly`）。
- `remotePushConfigured` 的文案是"本机已可被远程服务寻址…但这**不代表**推送已被验证可达"，**没有**任何"已验证/已送达/推送已可用"的措辞（`remoteWordingIsNotASuccessClaim`）。
- `Activity.request(..., pushType: nil)`：本模块走 foreground-only 路径，不请求 push token 的远程启动能力。

**`PulseActivityRuntimeStatus` 与 `capabilityDescription` 已移到纯层**（`PulseTrackingPolicy.swift`），因此这段面向用户的文案在 macOS 上可测，不需要 iOS 设备。

### 2.6 格式化（与视图共享）

```swift
public enum PulseActivityFormat {
    static func price(_:currencyCode:unit:) -> String   // unit 决定精度；见下
    static func unitLabel(currencyCode:unit:) -> String // "点" 或货币码，空码返回 ""
    static func priceWithUnit(_:currencyCode:unit:) -> String
    static func change(_:currencyCode:unit:) -> String
    static func changePercent(_:Double?) -> String      // nil => "—"，不显示 +0.00%
    static func sourceTime(_:timeZone:) -> String       // 市场本地时区
    static func freshness(quoteSourceTime:sourceDelay:asOf:) -> String  // "10 分钟前 · 源延迟"
    static func timeZone(forMarketKey:) -> TimeZone
}
```

**精度规则（`unit` 先行，货币其次）**：

| 输入 | 精度 | 例 |
|---|---|---|
| `unit == .points`（指数） | **恒定 2 位**，`KRW`/`JPY` 的整数规则**不适用** | `3,245.67 点`；韩国指数 `2,654.31` |
| `currencyCode == "JPY"/"KRW"` | 0 位 | KOSPI 股票 `72,300 KRW` |
| 其它货币 | 2 位；`|value| < 1` 时 4 位 | `1,680.50` / `0.6182` |

关键点：**不能因为"市场是韩国"就把指数截成整数**。指数的点数不是韩元金额，所以精度由 `unit` 而不是 `currencyCode` 决定。测试 `pointsPrecisionAndUnit` 与 `indexIsNotTruncatedByItsMarketCurrency` 固定这两条。

**`currencyCode` 永远是合法的 3–4 位字母码**（指数也用其市场的真实货币码，如上证指数用 `CNY`）。"这是指数"由 `unit` 表达，**不**用伪码（如 `POINTS`）塞进 `currencyCode`——Node 推送服务的校验是 `^[A-Z]{3,4}$`，伪码会被直接拒绝。测试 `indexKeepsARealCurrencyCode` 守护这一点。

### 2.7 深链接（**只读**）

```swift
public enum PulseDeepLink { case instrumentDetail(symbolKey: String), plans(planID: String?), planInbox }
func url(scheme:) -> URL?
var actionTitle: String   // 查看详情 / 查看计划 / 查看待办计划
```

**这个 enum 就是写操作的契约**：没有任何下单/记成交/改计划/删除的 case。测试 `destinationsAreReadOnly` 断言生成的 URL 不含 `trade`/`order`/`buy`/`sell`/`fill`/`create`/`delete`。要从锁屏交易，必须显式改这个类型。

---

## 三、PulseWidgets 表现

- 蓝色 FFF 波形（`PulseWaveGlyph`，`brandBlue`），中文文案，红涨绿跌（`PulseWidgetStyle.up/down`）。
- **所有** family 都显示真实源时间：`SourceTimeLabel` 用 `presentation.sourceTimeText`，`now` 从 timeline entry / activity context 传入，`PulseActivityPresentation` **不读时钟**。过期显示橙色 + "待更新"。
- 锁屏：名称、完整身份、价格、涨跌、源时间（含秒）、单位、精简待办、状态徽章、只读深链接。**默认无账户/数量/金额/收益**（payload 里也没有）。
- **单位显示**：指数显示 `点`，股票显示货币码。由 `presentation.unitText` 统一给出，视图不再直接打印 `currencyCode`（否则指数会显示 `POINTS` 这类伪码）。
- **计划待同步会实际显示（新增）**：`PlanTodoLine` 在非 compact family 上追加 `presentation.planSyncText`（如 `计划待同步`，橙色）。`planSyncText` 由 `plans.syncState` 决定——**不再**看 `status == .remoteUnavailable`。旧实现把两件无关的事混在一起：没有推送服务的设备即使计划已确认也会被警告，有服务的设备即使计划过期也不警告。现在 `needsPlanSyncWarning` 直接读 `plans.syncState`。
- **行情新 / 计划旧可以同时显示**：`SourceTimeLabel` 显示行情源时间，`PlanTodoLine` 显示计划同步状态，两者独立，不会合并成一句假的统一"刚刚更新"。`PulseWidgetsBundle` 里有 `锁屏 · 行情新但计划待同步` 与 `锁屏 · 指数(点)` 两个 preview 专门覆盖。
- 灵动岛：expanded（leading 身份 + trailing 价格涨跌 + bottom 源时间/待办/链接）、compactLeading（波形）、compactTrailing（涨跌%）、**minimal（短方向 glyph，按方向着色）**。
  - **minimal 不再塞完整长价格**：该槽位大约只有一个字符宽，`1,234.56` 或带分组的指数点位放不下；强行 `minimumScaleFactor` 缩到看不清，比一个诚实的箭头更差。现在只显示 `arrow.up.right` / `arrow.down.right` / `minus`，连百分比也不放（`+1.83%` 同样超宽）。要看数字就展开。
- **iOS 18 Watch 智能叠放**：`.supplementalActivityFamilies([.small])` + `@Environment(\.activityFamily)` 在 `PulseActivityFamilyView` 里分支到 `PulseWatchSmallView`（单主标的：名称、价格、涨跌、源时间、一条精简待办）。
- Widget 不联网：`PulseWidgets` 没有 import `URLSession`/`Network`，没有任何网络调用，只渲染系统给的 state。

---

## 四、Lead 需要添加的 target 配置

### 4.1 `project.yml`（Lead 独占，worker 未改）

```yaml
packages:
  PulseActivity:
    path: Packages/PulseActivity
```

**关键点**：`PulseActivity` 的 `Package.swift` 声明 `platforms: [.macOS(.v14), .iOS(.v18)]`。如果 Mac app 也依赖它，Mac 侧只有纯 policy/payload 可编译（活动相关代码全部 `#if canImport(ActivityKit) && os(iOS)`），不会影响 macOS 构建。

### 4.2 iPhone app target 需要

1. `platform: iOS`，`deploymentTarget: "18.0"`（`.supplementalActivityFamilies` 与 `activityFamily` 都是 iOS 18+）。
2. 依赖 `package: PulseActivity`。
3. **Info.plist**：`NSSupportsLiveActivities = YES`；`NSSupportsLiveActivitiesFrequentUpdates` 仅在确需高频更新时开启（会额外耗电，建议先不开）。
4. **URL scheme**：`CFBundleURLTypes` 加上 app 的 scheme（`app.pulse.ios`）。Deep link 默认用该值。
5. **App Group**（`group.app.pulse`）：`PulseTrackingPreferenceStore(defaults:)` 必须传 app group suite，否则 widget 读不到偏好。目前 worker 只提供 store，**没有**替你决定 suite 名。
6. App 内实现 `PulseActivityDataSource`（把行情/计划/持仓映射成 payload 与候选人）和 `PulseActivityTokenDelegate`。
7. **前台 reconcile 接点**：`scenePhase == .active`、行情刷新后、用户改动关注偏好后，调用 `await coordinator.reconcile(now:)`。这是唯一会创建/更新活动的路径。

### 4.3 Widget extension target 需要

1. `type: app-extension`，`platform: iOS`，`deploymentTarget: "18.0"`。
2. `sources: [PulseWidgets/Sources]`，依赖 `package: PulseActivity`。
3. `Info.plist`：主键 `NSExtension` → `NSExtensionPointIdentifier = com.apple.widgetkit-extension`。没有它 widget 不会加载。
4. `@main` 是 `PulseWidgetsBundle`（`WidgetBundle`）。**注意**：widget extension 的 `@main` 与 app 的 `@main` 不冲突，但该 target 不能再有第二个 `@main`。
5. 与 app 相同的 App Group entitlement（若要让 widget 读偏好）。
6. `PulseWidgetDeepLinkScheme` 会先读 extension Info.plist 的 `PulseDeepLinkScheme`；不设则用 `app.pulse.ios`。建议在 app 与 extension 都显式设置，避免不一致。
7. **不要**给 extension 加 `NSSupportsLiveActivities`（那是 app 的键）。

### 4.4 Watch 小卡

`.supplementalActivityFamilies([.small])` 只负责**声明**支持。实际出现在 Apple Watch 智能叠放还需要：iPhone 与 Watch 已配对、Watch 上装了对应 app、系统决定展示。**代码无法强制**。

---

## 五、必须在真机/签名环境验证的条件（本机未验证）

明确区分「编译通过」与「真机可用」：

| 项 | 状态 |
|---|---|
| policy / payload / staleness / 偏好持久化 / 持久预算 / 格式化 / 解码兼容 | ✅ 本机 macOS 测试通过（101 tests / 12 suites） |
| iOS 18 编译（含 ActivityKit coordinator） | ✅ 本机 iOS SDK codegen 通过，strict concurrency 0 warning |
| Widget 源码编译（WidgetKit + ActivityKit） | ✅ 本机 iOS SDK codegen 通过 |
| Widget `#Preview` 构造体 typecheck | ✅ 等价探针单独通过（宏本身在本机 standalone `swiftc` 下不可用） |
| **Live Activity 实际出现在锁屏/灵动岛** | ❌ 需签名 + 真机 + 系统权限 |
| **APNs push-to-start / update** 令牌收发 | ❌ 需付费开发者账号、APNs key、远程服务；本模块**不含**任何推送服务调用 |
| `remotePushConfigured` 门控在真机上的实际行为 | ❌ 需真机收到真实 push-to-start token 才能观察到升级；本机只验证了纯函数分支 |
| 系统是否及时上报 `.dismissed` | ❌ 需真机验证；代码注释已声明不承诺 |
| `.ended` 不归还预算在真机上的行为 | ❌ 需真机跨 8 小时验证；本机用持久 ledger 的等价测试覆盖 |
| Apple Watch 智能叠放实际渲染 | ❌ 需配对设备；`supplementalActivityFamilies` 只是声明 |
| 灵动岛/锁屏在深色/浅色/常亮下的视觉 | ❌ 需真机截图；worker 未做原生渲染验收 |

**诚实结论**：在没有签名、没有设备、没有远程服务的情况下，本 worker **只**验证了编译与纯逻辑。**没有**假装测试过 APNs 或 Watch 镜像，也**没有**调用任何真实推送服务。

---

## 六、与 Node 推送服务的 wire 契约（只读对方代码，未修改）

`Services/PulsePushBridge` 由另一 worker 拥有。本 worker **只读**其 `src/payload.js` 并运行其校验器确认兼容性，**没有**修改 `Services/**`。实测（本机 `node`，未安装依赖，直接 require 校验模块）：

| 载荷 | 结果 |
|---|---|
| 旧 `plans`（只有三个计数） | ✅ 接受 |
| 新 `plans`（+`asOf`/`revision`/`syncState`） | ✅ 接受，且 **spread 透传**，`asOf` 还会被规范化成 `asOfUnix` |
| 指数用真实货币码 + `unit: "points"` | ✅ 接受（`currencyCode` 通过 `^[A-Z]{3,4}$`） |
| 指数用伪码 `currencyCode: "POINTS"` | ❌ **被拒绝**（too-long）——这正是改用 `unit` 字段的原因 |
| KOSPI 股票 `KRW` | ✅ 接受 |

**待办（给 Node worker / Lead，本 worker 未改）**：`validateInstrument` 是显式白名单重建，会把新增的 `primary.unit` **丢掉**。需要在 `validateInstrument` 里加 `unit`（默认 `"currency"`，允许 `"points"`）并透传，否则服务端发起的指数更新会在设备上按货币精度渲染。字段默认值建议：缺失即 `"currency"`（向后兼容）。

---

## 七、已知取舍与留给 Lead 的决定

1. **`@preconcurrency import ActivityKit`**（coordinator 内）。Swift 6 语言模式下 ActivityKit 的 `Activity` 是 main-actor 隔离类，而 `update(_:)`/`end(_:dismissalPolicy:)` 标为 `@concurrent`，导致每个直接 `await` 都被判为 "sending 'activity' risks causing data races"。两行探针在 iOS 18 SDK 上可复现，属 SDK 注解不一致而非真实竞争。已用 `@preconcurrency` 局部放宽并写明理由，模块其余部分仍受完整 strict concurrency 检查。**SDK 注解修正后可移除**。
2. **`PulseActivityCoordinator` 不标 `@Observable`**：`@Observable` 宏在 standalone `swiftc` 下需要 plugin server（本机不可用），加它会牺牲可编译校验。`status` 是唯一可观察值，且 app 只在明确时机读它。若视图需要响应式，请在 app 侧包一层 `@Observable` view model。
3. **Watch 小卡复用同一个 `ActivityConfiguration`**：靠 `activityFamily` 分支，而不是声明第二个配置。好处是属性类型与 payload 唯一，watch 卡不会与手机漂移。
4. **`automaticStartLedger` 现在持久化在 app group defaults**。这是本次修正的核心：旧实现只在内存，`.ended` 还会 `removeAll()`，因此"系统 8 小时到期 → 活动结束 → 重启再拉起"可以无限循环。现在预算按稳定 session ID 持久化，`.ended` 不归还，只有用户显式 resume 才重开。**前提：Lead 必须给 `PulseTrackingPreferenceStore` 传 app group suite**，否则设备重启后预算仍在（同 suite），但如果你为每次启动新建 key 就会失效。
5. **`PulseWidgets` 只有 Live Activity**：没有加主屏 widget。加一个需要 timeline provider 与共享容器，半接线的版本等于 mock。`PulseWidgetsBundle` 里加一个 `Widget` 就是完整集成步骤。
6. **`PulseActivityFormat.timeZone(forMarketKey:)`** 靠 symbolKey 后缀推断时区，不依赖 `PulseCore.Market`（避免包依赖）。若 Lead 希望统一，可在 app 侧把 `Market.timeZone` 注入 payload。
7. **`PulseQuoteUnit` 需要 Node 端配合**：Swift 端会把 `unit` 编进 `primary`，但当前 `Services/PulsePushBridge/src/payload.js` 的 `validateInstrument` 用**显式字段白名单**重建对象（`out.xxx = ...`），因此 `unit` 会被**丢弃**而不是透传（`plans` 的 `asOf`/`revision`/`syncState` 因为用了 spread 而能保留）。这不影响本模块的编译与本地渲染，但会让**服务端发起的**指数更新在设备上按货币精度渲染。已在本文件 §八 列为待办给 Node worker / Lead，**本 worker 未改该文件**。

## 八、复现命令

```bash
# 纯逻辑测试（macOS）
swift test --disable-sandbox --package-path Packages/PulseActivity \
  --scratch-path /tmp/fff-ios-activity-build

# iOS 18 全量 codegen 构建（PulseActivity，含 ActivityKit coordinator）
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" \
  -swift-version 6 -strict-concurrency=complete \
  -module-cache-path /tmp/fff-ios-activity-build/mc \
  -emit-module -emit-library -static -module-name PulseActivity \
  -emit-module-path /tmp/fff-ios-activity-build/PulseActivity.swiftmodule \
  -o /tmp/fff-ios-activity-build/libPulseActivity.a \
  Packages/PulseActivity/Sources/PulseActivity/*.swift

# iOS 18 全量 codegen 构建（PulseWidgets）
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" \
  -swift-version 6 -strict-concurrency=complete \
  -module-cache-path /tmp/fff-ios-activity-build/mc \
  -I /tmp/fff-ios-activity-build -emit-library -static \
  -o /tmp/fff-ios-activity-build/libPulseWidgets.a \
  -module-name PulseWidgets PulseWidgets/Sources/*.swift
```

`-emit-library`（而非 `-typecheck`）是必要的：`-typecheck` 不会报出整模块的 strict-concurrency 诊断，早期的 `Task {}` 竞态就是只有 codegen 才暴露出来的。

```bash
# Widget preview 构造体 typecheck（绕开本机不可用的 #Preview plugin server）
# 探针复刻 PulseWidgetsBundle 里每个 preview 的参数组合，用一个临时
# PreviewProbe.swift 代替 #Preview 宏体，对同一组源文件做 -typecheck。
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -sdk "$SDK" \
  -swift-version 6 -strict-concurrency=complete \
  -module-cache-path /tmp/fff-ios-activity-build/mc -I /tmp/fff-ios-activity-build \
  -typecheck PulseWidgets/Sources/PulseActivityPresentation.swift \
  PulseWidgets/Sources/PulseLiveActivityViews.swift \
  PulseWidgets/Sources/PulseWidgetStyle.swift \
  PulseWidgets/Sources/PulseWidgetDeepLink.swift \
  /tmp/fff-ios-activity-build/PreviewProbe.swift

# wire 契约兼容性（只读 Services/PulsePushBridge，不需要 npm install）
node -e "const {validateState}=require('./Services/PulsePushBridge/src/payload.js'); /* … */"
```
