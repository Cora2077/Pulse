# 跟踪分区 · 中韩行情同轴方案

状态：**已实现**（macOS 端；iOS 端无分时小图，故不接入）。
预览图：[korea-china-tracking-preview.png](./korea-china-tracking-preview.png)（832x1466 @2x）
渲染脚本：[render-tracking-preview.swift](./render-tracking-preview.swift)

实现落点：

| 改动 | 文件 |
|---|---|
| `projected(to:)` / `axisBounds(for:reference:)` / `axisFraction(for:reference:bounds:)` | `Packages/PulseCore/Sources/PulseCore/Market/IntradayTrend.swift` |
| `referenceMarket:` 参数 + `plotSession` / `axisBounds` | `Packages/PulseUI/Sources/PulseUI/IntradaySparklineView.swift` |
| `isChinaAligned(_:)` / `setChinaAligned(_:for:)` + `LocalPreferences` 兼容解码 | `Packages/PulseCore/Sources/PulseCore/Store/SharedWatchlist.swift` |
| 分组标签右键菜单 | `PulseMac/Sources/WatchlistGroupBar.swift` |
| `WatchAxisStrip` + `WatchRow.referenceMarket` | `PulseMac/Sources/WatchlistView.swift` |
| 两个菜单文案 | `PulseMac/Resources/zh-Hans.lproj/Localizable.strings` |

测试：`PulseCore` 1033 通过（新增 8），`PulseUI` 49 通过（新增 6）。
两个 target 均编译通过。

**iOS 不接入的原因**：`PulseIOS` 全仓没有任何 `Canvas`，列表行里没有分时小图
（`WatchQuoteRow` 只显示名称、代码、价格、涨跌幅）。在 iOS 加这个开关会是一个
控制不了任何东西的死控件，所以没有加。

## 1. 为什么只做「跟踪」

「跟踪」分区天然是中韩混排的（兆易创新、三星电子、韩国综合指数、SK海力士），
其他分区（持仓 / 指数 / 美股 / 行业）各自单一市场，没有对齐需求。

只在跟踪分区应用方案 B，其他分区保持现有行为不变 —— 这是本次需求的边界。
「跟踪」不是特判：开关挂在分组 ID 上，用户想给任何分组开都行。

## 2. 关键约束：行内没有 x 轴

跟踪分区的 sparkline 每行只有约 48pt 宽、25pt 高
（`MainWatchlistSidebar.swift:425-427`、`WatchlistView.swift:1981-1988`）。
在这个尺寸上画「一条北京时间轴 + 三段色带」是不可读的。

所以**分区级共享一条轴**，而不是每行一条轴：

- 分区顶部一条窄轴，标 09:00 / 09:30 / 11:30 / 13:00 / 15:30 / 15:00（北京时间）
- 每一行的 sparkline **按同一个北京时间轴定位**，宽度等于轴宽
- 行内不重复画轴，只画线

这样同一时刻在所有行里是同一个 x，跨行可比较，又不占行高。

## 3. 分区级 vs 行级

| | 行内小轴（否） | 分区共享轴（是） |
|---|---|---|
| 每行可独立比较 | 可以 | 可以 |
| 跨行同一时刻对齐 | 不行（各自原点不同） | **可以** |
| 占高 | +14pt/行 | 一次性 14pt |
| 可读性 | 48pt 内塞 6 个刻度 = 糊 | 一条 340pt 轴 |

## 4. 行为矩阵（核心）

参考市场固定为 **A 股（.sh）**，轴 = 北京时间 08:00–15:00。

只在**开启了时间轴同步的分组**生效；未开启的分组行为与现在逐像素一致。

| 符号市场 | 数据是否映射到北京轴 | 行内显示 |
|---|---|---|
| .sh / .sz | 是，原点固定 | 实线 + 午休断开 |
| .kr / .kq | **是，+1h 后投影** | 实线连续，穿过午休带 |
| .hk | 是（港股 09:30–16:10，本身跨午休） | 实线 + 午休断开 |
| .jp | 是（东京 09:00–15:30，无时差） | 实线连续 |
| .us | **否，保持现有独立轴** | 现状不变 |

美股不并入：美股盘前 04:00–盘后 20:00 ET，与 A 股无时段重叠，
强行投影会把 A 股轴拉长 4 倍。跟踪分区若含美股股，该行回退到现有渲染。

## 5. 午休带

11:30–13:00 一条贯通所有行的淡色竖带（`amber.opacity(0.14)`），
含义是「中国午休 · 韩国仍交易」。

三条实现约束（预览里逐条验过）：

1. **带子不能越过最后一行**。带子是逐行背景，不是一条从轴顶拉到卡片底的长条 ——
   后者会伸出数据之外，看起来像渲染错误
2. **带子从坐标轴条顶部就开始**，轴条本身坐在带子里面，不是悬在带子上方
3. **分隔线在带子之上仍然可见**，所以逐行背景优于整块矩形

这一条带同时解决三件事：
1. 解释中国行为什么断开
2. 解释韩国行为什么在这里单独延伸
3. 让用户看见「午休期间韩国涨了多少」—— 这是本方案真正的信息增量

## 6. 与现有代码的衔接

`IntradayTradingSession` 已为 `.kr`/`.kq` 建模为无折叠连续轴
（`IntradayTrend.swift:51-55`），中国午休也已建模
（`TradingCalendar.swift:116`）。要做的不是改轴，而是加投影：

1. `IntradayTradingSession.projected(to:)` —— 把边界按目标时区重新读一遍
2. `IntradayTradingSession.axisBounds(for:reference:)` —— 分区共享的时钟窗口
3. `IntradaySparklineView` 增加 `referenceMarket:` 参数；为 nil 时行为与现在完全一致
4. 跟踪分区顶部新增 `WatchAxisStrip`，渲染共享轴与午休带
5. 右键菜单读 `SharedWatchlist.isChinaAligned(_:)` 切换

第 3 点的 nil 默认值保证持仓/指数/美股/行业四个分区零变化。

## 6b. 一个必须记住的坑：projected(to:) 本身不移动 x

实现过程中发现并修掉的真实缺陷，写在这里免得后人重犯。

`projected(to:)` 只**重读边界**（首尔 15:30 → 北京 14:30），它并不改变
`minuteOffset(for:)` 的度量方式 —— 那仍然是「距本会话开盘多少分钟」。
后果是两个长度不同的会话（首尔 390 分钟 vs 上海 240 分钟）会把同一个时刻
放在各自轴的不同比例上：

| | 韩国行 | 中国行 | 差 |
|---|---|---|---|
| 各自会话（投影前后都一样） | 372/390 = 95.4% | 192/240 = 80.0% | **53px** @348pt |

也就是说，`projected(to:)` 单独上线等于没上。真正对齐的是
`axisBounds` + `axisFraction`：两个会话按同一个北京时钟窗口度量，
同一时刻得到同一个比例。

这条是被一个断言「x 比例相等」的测试抓住的。断言 `minuteOffset` 相等的测试
会漏掉它 —— 两个 offset 在投影前后都各自自洽。**写这类测试要断言最终变成
x 的东西，不是中间量。**

## 6c. LocalPreferences 加字段必须写自定义 init(from:)

同一批发现的第二个真实缺陷。`SharedWatchlist.LocalPreferences` 是
`Codable`，`loadLocalPreferences()` 用 `try?` 解码：

```swift
if let decoded = try? JSONDecoder().decode(LocalPreferences.self, from: data) {
    local = decoded
}
```

Swift 合成的 decoder **不会**为缺失的键回落到默认值 —— 它抛
`keyNotFound`。而 `try?` 把这个错误吞掉，结果是老版本写下的
`localOrder.v1` blob 在新版本第一次启动时整个解码失败，
用户的 groupOrder / symbolOrder / pinnedSymbols **静默全部丢失**。

所以 `LocalPreferences` 自带一个逐键 `decodeIfPresent` 的 `init(from:)`。
**以后往这里加任何字段都必须走同样的路径。**

## 7. 验收

- 默认（未开过任何分组）：所有分区视觉与现在完全一致
- 跟踪分区开启后：同一时刻在兆易创新行与韩国综合指数行是同一个 x
- 11:30–13:00 之间：兆易创新无线段，韩国综合指数有连续线段
- 午休带下沿与最后一行下沿齐平，不伸出数据区
- 右键「关闭时间轴同步」后，跟踪分区回到现状；再开一次恢复
- 把「跟踪」改名成「盯盘」：开关状态不变（ID 未变）
- 开过同步的分组被删除，其 key 不影响任何残留状态
- 开启同步但分组里只有美股：不画顶部轴条，行按现状渲染
- 开关不同步到其他设备：另一台 Mac 上该分组仍是关的

## 8. 交互：分组标签右键菜单

一个布尔开关，**默认关**。在分组标签的右键菜单里切换：

| 菜单项 | 存储 |
|---|---|
| 开启时间轴同步 | `true` |
| 关闭时间轴同步 | `false`（默认，不存） |

默认关有两个好处：现有行为对所有人零变化；用户显式开过一次，
就知道这个轴是自己要的，不是系统猜的。

```swift
// PulseCore · LocalPreferences 增加一个字段
var chinaAlignedGroups: [String: Bool] = [:]   // key = 分组 ID

extension SharedWatchlist {
    public func isChinaAligned(_ groupID: UUID?) -> Bool {
        guard let groupID else { return false }
        return local.chinaAlignedGroups[groupID.uuidString] ?? false
    }

    public func setChinaAligned(_ value: Bool, for groupID: UUID) {
        if value {
            local.chinaAlignedGroups[groupID.uuidString] = true
        } else {
            local.chinaAlignedGroups.removeValue(forKey: groupID.uuidString)
        }
        saveLocalPreferences()
    }
}
```

关的时候把 key 删掉而不是存 `false`，`LocalPreferences` 里只留用户开过的分组，
 blob 不会随分组增删无限膨胀。

### 为什么放在 `LocalPreferences`

它已经是「UI-only 覆盖」的归处：`groupOrder`、`symbolOrder`、`pinnedSymbols`
全在这里，一个 Codable blob 存在 `pulse.sharedWatchlist.localOrder.v1`，
**明确不与任何设备同步**（`SharedWatchlist.swift:36-38`、`SharedWatchlist.swift:60`）。

时段同步是纯展示选择，不是金融状态，不配同步。一台 Mac 上开了，
另一台照样是关的 —— 这是对的：这是每台机器自己的看图偏好。

### 分组 ID 稳定性

`renameGroup` 只改 `groups[index].name`，**ID 不变**（`WatchlistStore.swift:569-576`），
所以按 ID 存的开关在改名后依然生效。「跟踪」改名成「盯盘」，同步照旧。

### 右键菜单位置

`WatchlistGroupBar.swift:66-82` 已有 contextMenu（新建 / 重命名 / 删除），
加一项即可，当前生效的那侧打勾。iOS 侧 `WatchlistView.swift:114-128` 同址加。

菜单文案：
- 开启时显示 `关闭时间轴同步`
- 关闭时显示 `开启时间轴同步`

### 一个渲染兜底

开关打开、但分组里没有任何可投影的行（例如纯美股分组）时，
**不画顶部轴条** —— 画一条没有行对齐它的轴比不画更误导。
可投影的市场：`.sh` `.sz` `.kr` `.kq` `.hk` `.jp`；`.us` 行永远按现状渲染。
