# Pulse 交接文档

最后更新：2026-09-30（图表工具操作优化）

## 最新补充：图表操作优化

- 自动显示附近计划价位，远端提示增加距离百分比，点击展开，适配按钮恢复自动范围。
- 主窗口分时左侧增加相对昨收的百分比轴，与右侧价格轴共用刻度并避让 0% 标签；无有效昨收时隐藏，不使用开盘价代替。
- 选中线段和临时测量支持 Delete/Backspace，测量可通过边框或结果卡选择、右键清除。原生文字编辑快捷键保留。
- 新增默认关闭的「吸附」按钮及菜单开关：K 线贴近 OHLC，分时贴近真实行情点，阈值八个屏幕点；远处保持自由价格，整条趋势线移动不改变形状。
- 完整构建通过：`build/pulse-chart-followup-build.log`；21 项 UI 测试通过：`build/chart-followup-ui-tests.log`；Core 和同步格式没有改动。隔离演示验证了百分比对齐、计划展开/恢复、线段删除、测量删除、吸附和平移。
- 剩余细节：快速点标签立即 Delete 可能等待点击识别；点线段选择后 Delete 已验证。标签双击编辑保留，下一轮可继续优化单击识别。
- 本轮不发布、不改版本号；操作优化和记录提交推送。未修改真实交易/计划。

## 当前进展：图表工具首版（2026-09-30）

本节为最新状态，详细设计和使用说明见 `CHART-TOOLS-DESIGN.md`。下方保留此前开发记录。

- 已实现主窗口水平线、趋势线、临时区间测量；点击创建、拖动调整、双击标签精确编辑、右键锁定/删除、Esc 取消、会话级撤销/重做。
- 买卖计划直接投影到分时及各周期 K 线；默认显示进行中计划，可显示历史。支持同价分组、相邻标签错位、越界提示、适配计划、标签打开现有计划编辑页并返回行情；不会自动记录成交。
- 水平线跨周期，趋势线绑定原周期，分时绑定实际交易日；保存真实 UTC 时间与价格。所需历史尚未加载时提示，不扭曲锚点。
- 绘图预览只更新叠加层，完成后保存一次；价格对象限制在价格区域，保留成交量与实际 B/S 成交标记。原有缩放、平移、重置、十字光标保留。
- `WatchItem.drawings` 已接通 Store、移出自选历史、同步合并和归档。删除标记对同 UUID 的编辑优先；撤销删除用新 UUID 恢复，会话历史重映射到新 ID。
- 同步文件 v3 读取 v1/v2/v3；归档 v2 读取 v1/v2。新版遇到未来文件版本停止同步并提示更新，两台 Mac 必须同时更新，不能继续混用已有旧客户端。
- 便携归档保留原有边界：只导出分组中的标的，不包含移出自选后仅保留的历史。保留历史仍能本地保存、同步并在重新加入自选时恢复。
- 构建 `BUILD SUCCEEDED`（`build/pulse-chart-tools-build.log`）；Core 404 项 Swift Testing + 7 项 XCTest（`build/chart-tools-core-tests.log`）、UI 5 项测试（`build/chart-tools-ui-tests.log`）全通过；真实会话对象的独立验证通过（`build/chart-session-validation.log`）。
- 本机隔离演示验证画线/趋势/测量/锁定/编辑/隐藏、计划编辑/适配、跨周期、缩放/平移/重置/光标、文字撤销及重做后删除。四语言资源检查与 diff 检查通过，未修改真实金融数据。
- 本轮未执行真实第二台 Mac 的画线同步；自动测试覆盖双方独立新增、并发删除与编辑、保留历史、幂等合并和归档恢复。更新两台后应补人工 iCloud 验收。
- 未发布、未修改应用版本号；代码与交接文档一起提交推送至 `origin/main`。

代码入口：`ChartDrawing.swift`、`ChartAnnotationOverlay.swift`、`MainChartDrawingSession.swift`、`MainChartDrawingEditor.swift`、`MainChartKeyboardMonitor.swift`、`MainInstrumentView.swift`。新增文件已纳入生成工程，工程及构建目录不入库。

## 当前进展：主窗口第二版（2026-09-30）

本节为最新状态，下方保留首版与此前同步开发记录。

- 首版已提交并推送至 `origin/main`：`28050a1 Add native main window with charts and plan overview`。第二版已完成，代码与本交接记录一同提交；未发布、未修改版本号。
- 用户确认双 Mac 同步使用正常；本轮不再安排同步验证。按要求不做币种汇总，不添加保存提示。
- 新增 `PositionValuation` 共享估值：持仓盈亏按所选成本口径计算，总盈亏按平均成本浮动盈亏加已实现盈亏计算；手续费已包含在账本成本与已实现结果中，不重复扣除。校准后的总盈亏仍保留此前已实现结果。
- 主窗口、菜单栏详情、持仓页、自选行、盈亏排序和分享快照统一使用所选成本口径；平均/摊薄切换不改变总盈亏。已实现结果始终可查看，并提示不要重复相加。
- 左栏底部增加「持仓总览」入口：当前持仓/平仓历史、搜索、共享成本口径切换、逐标的成本与盈亏列；可展开每笔交易、手续费及交易后的数量/均价，点击名称回到标的详情。只显示标的明细及数量统计，不汇总金额。
- 持仓总览十列均可排序：标的、数量、成本、持仓盈亏、总盈亏、现价、今日盈亏、已实现盈亏、市值、手续费。上方选择字段并切换升降序，也可点击列标题排序，再次点击同列反向。数字字段首次选择默认降序；缺失/非有限值在两个方向均排末尾，同值按名称及标的标识稳定排序。排序仅影响展示，不改自选顺序或同步数据。
- 排序控件旁增加「恢复默认排序」，一键返回标的名称升序，已默认时按钮禁用。完整构建通过（`build/pulse-sort-reset-build.log`）；本机实际验证从数量降序点击恢复后回到标的升序。
- 人民币成本省略 `CNY` 前缀，适用于总览成本列及展开记录中的平均成本；其他币种标识与交易价格单位保留。
- 「交易计划」升级为主窗口专用表格：状态与到价筛选，代码/名称/备注搜索，到价优先/标的/目标价/差距排序；编辑和更改状态在标的旁即可操作。缺行情显示「—」并排末尾，不误判到价。原菜单栏计划页保留。
- 交易录入明确显示价格币种与数量单位，未改变输入绑定或保存流程。四语言文案已补齐。
- 追加视觉优化：主窗口计划方向使用现有买入/卖出配色，半粗文字、浅底胶囊与细描边；随浅色/深色模式调整透明度。完整构建通过（`/private/tmp/pulse-plan-direction-build.log`），隔离演示确认买卖标签区分明确、行列保持对齐。

### 第二版实际验证

| 项目 | 结果 |
|---|---|
| 完整 Debug 应用构建 | `BUILD SUCCEEDED`；包含最终字段排序、买卖颜色与 CNY 成本标签优化；最新日志 `build/pulse-holdings-sort-build.log` |
| PulseCore 回归测试 | 394 项 Swift Testing / 41 个套件 + 5 项 XCTest，全部通过；新增 6 项覆盖成本口径、手续费、空头、旧持仓、平仓与校准；日志 `/private/tmp/pulse-position-valuation-core-tests-full.log` |
| 原生隔离演示 | 平均成本下持仓 -50、已实现 +250、总盈亏 +200；摊薄成本切换后总盈亏保持 +200；成本记录单位与币种明确；无行情保留成本并显示未知盈亏；无行情平仓总盈亏 +40；总览可跳转详情；交易输入显示 USD/股 |
| 原生计划流程 | 修改目标价保存返回总览，到价计数即时更新；只看已到价；标记完成自动移出该筛选；已完成筛选与备注搜索正确。最小窗口下筛选、编辑和状态入口可用 |
| 原生持仓排序 | 菜单十个字段均可选；市值升降序和无行情行始终排末尾；数量表头点击选择并再次点击反向；手续费、今日盈亏降序与固定演示数值一致；最小窗口控件完整显示 |
| 工作区检查 | `git diff --check` 通过；四语言键/格式检查通过；未修改真实交易或计划 |

已正常重启本机开发应用并打开新版持仓总览。隔离演示进程已停止；演示数据不写入真实持仓或同步目录。

代码入口：`Packages/PulseCore/Sources/PulseCore/Models/PositionValuation.swift`、`PulseMac/Sources/MainHoldingsView.swift`、`PulseMac/Sources/MainPlanListView.swift`。新增文件已由 XcodeGen 纳入本机工程；生成工程不入库。

## 首版记录（2026-09-30）

本节为首版完成时的记录，下方继续保留此前同步与 WorkBuddy 的开发记录。

- 首版基线为 `d727b0a`；主窗口、计划总览入口及盈亏标签修复一起作为首版提交。未发布，也未修改版本号。
- 新增普通可调整大小的主窗口，默认 1200×800，内容最小 960×680；原菜单栏和钉住窗口保留。菜单栏自选页新增「打开主窗口」，应用菜单提供 `⌘1`，启动时恢复本机主窗口可见偏好。
- 左栏独立管理当前分组、搜索和「全部 / 持仓 / 活跃计划」筛选，支持拖动分栏；搜索可查看标的并添加到当前组。
- 右侧提供分时、1/5/15/30/60 分 K、日/周/月 K；下方是持仓、交易记录、交易计划、买入理由。交易、计划、持仓校准沿用现有编辑表单，在右侧页内操作；交易和计划保存后回到对应标签。
- 主窗口、菜单栏与钉住窗口共用同一 AppState 和业务数据。新的 `DetailMarketDataController` 按标的计数详情消费者，共用已有行情推送，合并相同的进行中 K 线请求；不在自选组内的标的共用一份备用轮询。
- 主窗图表按周期定时刷新；不可见、最小化、进入编辑页时停止图表刷新。选中标的和窗口状态留在本机，不加入云同步。
- 四种语言的新文案已补齐。DEBUG `--main-window-demo` 使用隔离偏好与固定行情、持仓和计划；禁用真实凭据、行情网络、同步、MCP、遥测和更新启动。
- 后续盈亏核对：修正主窗把含已实现收益的总盈亏填到「持仓盈亏」标签下的问题，改为分别显示所选成本口径的持仓盈亏与总盈亏；无行情时均价回退到真实持仓成本。修复构建通过，日志 `/private/tmp/pulse-pnl-label-build.log`。本次用户反馈的正负号问题已确认来自交易输入错误，未改核心计算公式。
- 补齐发现遗漏的入口：主窗左栏底部固定「交易计划」总览按钮（全部标的、共几条及到价数量），总览可进入标的详情和计划编辑，保存返回总览；自选页「更多」菜单首项新增文字版「打开主窗口」，菜单栏与钉住窗口均可使用。完整构建通过（`/private/tmp/pulse-plan-overview-build.log`），隔离原生演示已验证总览、编辑保存返回和标的跳转。

### 本次实际验证

| 项目 | 结果 |
|---|---|
| 完整 Debug 应用构建 | `BUILD SUCCEEDED`；日志 `/private/tmp/pulse-main-window-build.log` |
| PulseCore 回归测试 | 388 项 Swift Testing / 40 个套件 + 5 项 XCTest，全部通过；日志 `/private/tmp/pulse-main-window-core-tests.log` |
| DEBUG `--detail-market-selftest` | 3/3 通过：同标的消费者取消与轮询生命周期、同 K 线请求共享且单方取消不中断另一方、不同请求结果隔离；日志 `/private/tmp/pulse-detail-market-selftest.log` |
| 原生窗口演示验收 | 分时、1 分 K、月 K 可显示；交易价格修改保存回记录页；计划修改保存回计划页；理由编辑保存；切换标的；搜索匹配、无结果及清除；设置页点击当前标的返回；缩小窗口和加宽侧栏布局检查通过 |
| 工作区检查 | `git diff --check` 通过；未改动真实持仓和同步目录 |

构建产物：`build/DerivedData/Build/Products/Debug/Pulse Dev.app`。开发验收使用独立标识 `app.pulse.mac.mainpreview` 的临时副本和演示数据。补齐总览入口后，确认本机没有未保存编辑，已正常退出并启动新版 Pulse；原生界面确认左栏底部入口出现，且已打开真实数据的计划总览（只读）。临时演示进程已停止。

代码入口：`MainWindow.swift` / `MainWindowView.swift`（窗口与导航），`MainWatchlistSidebar.swift`（左栏），`MainInstrumentView.swift`（右侧图表与业务页），`DetailMarketDataController.swift`（共享行情），`MainWindowDemo.swift` / `DetailMarketDataSelfTest.swift`（DEBUG 验收）。新增文件已由 XcodeGen 纳入本机生成的工程；工程本身不入库。

首版未额外验证配置数据源后的实时行情；用户已确认双 Mac 同步使用正常。已有 dormant history 三方合并的 thesis 保留问题未包含在本次主窗口范围内。首版构建存在旧文件 `TradeEntryView.swift` 日期编辑的 actor 隔离警告和 `PositionHubView.swift` 未使用局部变量警告。

### 第二版范围（用户确认）

2026-09-30 用户确认双机同步目前使用正常，先提交推送首版，再开发第二版：统一各界面的持仓盈亏与总盈亏口径；将主窗计划总览升级为支持筛选、排序和编辑的表格；增加持仓总览和成本构成明细；交易价格与数量标明单位。**不做币种汇总，不加保存提示，不安排额外双机同步验收。**

## 先读这个（2026-09-29 晚续记）

**工作区状态**：改动全部已 commit + push，`main` 与 `origin/main` 同步，工作区干净。今天共 **6 个 commit**：

| commit | 内容 |
|---|---|
| `ce3286e` | Mac 间同步功能（iCloud 占位符、缓存 UUID 一致性） |
| `a045c86` | 钉住窗口加宽 340 → 520pt |
| `910ff9a` | 交易手续费 + 成本口径切换（加权/摊薄）+ 总盈亏 |
| `08513a5` | 投资逻辑（thesis）字段 |
| `6401d7b` | 交接文档入库 |
| 本次 | 交易计划系统（详见下节） |

**完整开发记录在 `.workbuddy/memory/2026-09-29.md`**（很长，含全部踩坑过程与代码细节）；长期项目笔记在 `.workbuddy/memory/MEMORY.md`。**接手前先读这两份。**

### 今天新踩的坑（memory 里有详细版）

1. **本地化条目必须整行匹配** —— 用 Edit 加 `.strings` 条目时，若 `old_string` 只取 key 而不含 `= "value";`，行尾会残留成 `"..."; = "持仓";`，**一行两个 `=` 会让整个表从该行起失效，界面全变成原始 key**。且 **`plutil -lint` 报 OK，抓不到这个问题**。
2. **`.sheet` 在 accessory 应用里会关掉整个窗口** —— App 是 `LSUIElement`（无 Dock 图标），sheet 是独立窗口，点输入框抢焦点失败 → 窗口被系统关闭。**改用页内内联编辑。**
3. **`Menu` 会同时压缩 label 的宽和高** —— 放 `stat`（依赖 `maxWidth: .infinity`）会宽度塌陷，放两行 VStack 会裁掉第二行。**改用 `Button` + `.buttonStyle(.plain)`。**
4. **`.app` 目录的 mtime 不更新** —— Xcode 增量构建只重写 `Contents/MacOS/` 里的二进制；判断版本要看**二进制**的时间。
5. **macmini 上的 `rsync` 是 openrsync**，不认 `--delete`，报 `server receiver mode requires two argument`。**用 `scp -r`。**
6. **新字段要接 5 条链路**（`WatchItem` 手写 Codable 的 4 处 + `normalizedItems` 去重合并 + `mergeItem` 三方合并 + 归档导入导出 + MCP）—— 少接一条就**静默丢数据**，尤其同步那条。
7. **`ditto` 与 `cp -R` 拷出来的 `.app` 文件数不同不是缺文件**：`Sparkle.framework` 内部是软链，`ditto` 保留（~74 个文件）、`cp -R` 展开成实体（~179 个），等价。构建时 `.strings` 被编成**二进制 plist**，`grep` 数不到 key（得 0），要用 `plutil -p`。
8. **同一 bundle id 只能跑一个实例**（共用 UserDefaults 与同一个同步文件）；换构建后必须重启进程，判定跑的是不是新代码要 `lsof -p <pid> | grep debug.dylib` **比 size**，进程路径会骗人。

### 交易计划系统（本次新增，两台都要升到这版）

- 一条计划 = 在什么价位买/卖多少：`TradePlan`（kind/price/quantity/status/note），挂在 `WatchItem.plans`。
- **到价与否不落盘** —— `isReached(at:)` 每次渲染用现价现算。两台 Mac 各自锁一个布尔只会互相触发无意义的同步往返。
- 入口：详情页底部「交易计划」区块（只读，点行 push 到 `PlanEditorView` 编辑；**没有用 sheet**，理由同坑 2）；首页底部状态栏右侧常驻 chip（`N 条 · M 到价`，到价时变强调色）→ 跨标的 `PlanListView`（到价置顶，点行进详情，右键改/放弃/恢复）。
- 新文件：`TradePlan.swift`、`TradePlanOverview.swift`、`PlanEditorView.swift`、`PlanListView.swift`；测试 `TradePlanTests`（15 例）+ `TradePlanOverviewTests`（9 例）。`PositionReturnRoute` 加了 `planList`（否则总览页进编辑页保存后会跳错地方）。
- 验证基线：**380 个测试 / 40 个套件**全部通过；完整 Debug 构建 SUCCEEDED（mini 实测）。
- ⚠️ **旧版读到不认识的 `plans` 字段会在写回时把它删掉**（与 thesis 同款数据丢失）。两台 Mac 必须都升到本版再继续用。

### 各机当前状态

- **Mac mini**（`CoradeMac-mini-7`，局域网 192.168.31.123/140）：已装完整 Xcode 27.0 + xcodegen + Rust，**能独立构建**（首次 2m22s）。`~/Applications/Pulse Dev.app` 已是最新构建（dylib 30274272 字节）。⚠️ 下面「macmini 只有 CommandLineTools、不能构建」的旧结论已作废。
- **主力机**（`MacBigBook`，Tailscale 100.108.129.117，局域网不见）：直接跑 `build/DerivedData/.../Pulse Dev.app`，`~/Applications` 里**没有**安装副本。SSH 已授权 mini 的公钥。

### 待办

- **iCloud 双机实测**（唯一没做的）：macmini 打开 `~/Applications/Pulse Dev.app` → 选 `iCloud Drive/PulseSyncTest` → 与本机双向同步。**本机已配置好并写出了同步文件，iCloud 链路已验证通**（macmini 已收到同一文件）。
- macmini 的**屏幕共享仍连不上**：需在它的「系统设置 → 通用 → 共享」里关掉「远程管理」、打开「屏幕共享」（两者互斥）。

## 用户已确定的方向

- 在当前开源 fork 上开发自己的版本，目标是两台 Mac 同步使用。
- 没有付费 Apple Developer 会员，已选择 **iCloud Drive 共享文件夹**，不走 CloudKit。
- 主 agent 负责设计与审查；实现优先交给 Luna xhigh，适合的只读工作可交给 ECNU。
- 当前工作区保留此前 Codex 和 WorkBuddy 的改动，尚未 commit / push / 发布。

## 功能和使用方式

两台 Mac 安装同一版当前 fork，在 **设置 → 数据与同步 → 选择文件夹** 中选择 iCloud Drive 的同一个文件夹。也可选择其他网盘在两台 Mac 间同步的目录。

- 每台安装持有独立 device UUID，仅写自己的 `Pulse-sync-<device-id>.json`。
- 启动、手动同步、本地修改后 1.5 秒防抖，以及运行中约 60 秒轮询。
- 同步自选、分组、顺序、置顶、持仓交易与移出自选后的历史。
- 凭据、Keychain、MCP token、设备设置、当前选中分组留在本机。
- 每个目录、每个 peer 保存上次已读快照，以它为 base 做三方合并。
- 同笔交易的不兼容编辑或删除会提示选择本机或对方；选择作用于该 peer 当前列出的全部交易冲突。应用前在本地保留双方快照备份，最多 8 份。
- 文件是可读 JSON。网盘上传下载存在延迟；本机成功写入不等于另一台已收到。
- v2 文件保留亚秒时间精度，可读取 v1 ISO-8601 文件；旧版应用不能读取 v2，双机应同步升级。

## 代码地图

| 文件 | 职责 |
|---|---|
| `Packages/PulseCore/Sources/PulseCore/Store/WatchlistSyncSnapshot.swift` | 快照、三方合并、交易冲突处理 |
| `Packages/PulseCore/Sources/PulseCore/Store/WatchlistSyncWireCodec.swift` | v1/v2 编解码、版本与重复 ID 校验 |
| `Packages/PulseCore/Sources/PulseCore/Store/WatchlistStore.swift` | 快照导出、应用、仅本地编辑触发的回调 |
| `PulseMac/Sources/FolderSyncController.swift` | 安全作用域书签、文件协调、后台 IO、调度与冲突状态 |
| `PulseMac/Sources/DataSettingsView.swift` | 同步配置和冲突处理界面 |
| `PulseMac/Sources/SettingsView.swift` | 设置首页同步状态 |
| `PulseMac/Sources/AppState.swift` | 创建与启动控制器；selftest 不启动同步 |
| `Packages/PulseCore/Tests/PulseCoreTests/WatchlistSyncMergeTests.swift` | 合并与 store 回调回归测试 |
| `Packages/PulseCore/Tests/PulseCoreTests/WatchlistSyncWireCodecTests.swift` | 精度、旧格式兼容、异常输入测试 |
| `PulseMac/Resources/{en,zh-Hans,ja,ko}.lproj/Localizable.strings` | 四语言同步文案 |
| `project.yml` / `PulseMac/Pulse.entitlements` | 用户所选目录读写和书签权限 |

## WorkBuddy 已完成并保留的工作

- 识别 iCloud 隐藏占位符 `.Pulse-sync-<uuid>.json.icloud`，请求下载对端文件。
- 修复 `ownDeviceID` 重复声明等编译问题。
- 保留休眠历史条目的名称来源、类型和创建时间。
- 清理 store 回调状态与导入界面分支。
- 设置首页显示同步关闭、开启、需处理状态。
- 安装 Xcode / XcodeGen；`.gitignore` 忽略 `/.workbuddy/`。

## 本轮继续修复

- 交易推导的持仓缓存使用确定性 UUID，避免每次合并生成不同 ID 导致反复写回。
- 首次合并按分组 ID 优先匹配，保留改名后两端独立添加的成员。
- 删除最后一笔交易时清除旧持仓缓存，覆盖本机/对方两种冲突方向。
- v2 wire codec 保留时间精度；拒绝不支持的版本、重复分组/标的/交易/批次 ID。
- 本机同步文件仍是 iCloud 占位符时等待下载，避免直接覆盖。
- 验证所选目录真实存在；切换目录或关闭同步后，丢弃旧异步任务的状态结果。
- 目录同步基线使用本地 scope UUID，并迁移旧的路径键，避免目录改名后丢失基线。

## 验证状态

**已完成（2026-09-29，WorkBuddy 接续验证）**

| 项目 | 结果 |
|---|---|
| `swift test`（PulseCore 全套） | ✅ **347 个测试 / 38 个套件全部通过** |
| 完整 Debug 构建（xcodebuild + xcodegen） | ✅ **BUILD SUCCEEDED** |
| 代码告警 | 无 |

```bash
cd Packages/PulseCore && swift test --disable-sandbox -Xswiftc -disable-sandbox

cd /Users/cora/Projects/Pulse
~/.local/bin/xcodegen generate
xcodebuild -project Pulse.xcodeproj -scheme PulseMac -configuration Debug \
  -derivedDataPath build/DerivedData TELEMETRYDECK_APP_ID= \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ENABLE_USER_SCRIPT_SANDBOXING=NO \
  OTHER_SWIFT_FLAGS="-disable-sandbox" build
```

**尚未验证：真实双 Mac 的 iCloud 上传、占位符下载和冲突界面操作。自动化核心测试及编译不能替代这项实测。**

## 本轮验收发现（WorkBuddy）

### 已修复：本机推导的持仓缓存 UUID 与合并侧不一致

`WatchlistStore.applyTransactions` 构造缓存 lot 时用 `CostLot(price:quantity:)`，id 走默认 `UUID()` 即**随机**；而合并侧 `WatchlistSyncMerge` 用 `derivedLedgerLotID(for:)` 生成**确定性** id（SHA256(symbol)，UUID v5 形式）。两侧不一致的后果：

1. 本机记一笔交易 → 缓存 lot 得到随机 id `R`，写进自己的同步文件；
2. 对端合并后得到确定性 id `D`，`result.snapshot != local` → 对端**多写一次**自己的文件；
3. 本机读到 `D`，与本地 `R` 不同，再应用、再写一次。

不是死循环（一轮后双方收敛到 `D`），但**每笔本地交易都额外多一轮同步往返和一次多余写盘** —— 正是「避免反复写回」想消除的那类扇出。codex 已修掉 `mergeItem` 与 `replaceTransaction` 两处，漏了本机这一处。

已改为复用同一个 `derivedLedgerLotID`（并把该函数由 `private` 提升为模块内可见）。改后 347 测试与完整构建均仍通过。

### 复核通过（未发现问题）

- `WatchlistSyncWireCodec` 已真正接入 `FolderSyncController`，`encode` / `decode` 均走 codec，v1 → v2 兼容路径成立。
- iCloud 占位符：对端文件与本机自身文件都有等待下载处理；本机文件仍是占位符时抛 `ownFilePendingDownload` 而不是覆盖。
- 目录基线改用 scope UUID（`folderIdentity`），并带旧路径键迁移。
- 切换目录用代际号 `folderSelectionGeneration` 丢弃过期异步结果。
- `replaceTransaction` 在交易清空时同时清掉 lots 缓存，两个冲突方向都覆盖。
- 合并确定性：`mergeItem`、`mergeLots`、`replaceTransaction` 全部使用 `derivedLedgerLotID`。


## 构建环境与命令

- Xcode 27.0 (27A266a)：`/Applications/Xcode.app`，xcode-select 已指向它。
- XcodeGen 2.46.0：`~/.local/bin/xcodegen`。
- 当前无开发者签名证书，Debug 构建使用 ad hoc 签名。
- WorkBuddy 曾设置用户级 `IDEPackageSupportDisableManifestSandbox`；仍在生效（解析 SPM 依赖需要，不要清掉）。

### 是否需要 `-disable-sandbox`，取决于 agent 的执行环境

- **Codex 的执行环境：不需要。** 用下面的基础命令直接构建即可，也不必改 `scripts/dev-mac.sh`。
- **WorkBuddy 的执行环境：需要。** 该沙箱建不起受限沙箱（`sandbox-exec -p '(deny default)…'` 报 `sandbox_apply: Operation not permitted`），而 `swiftc` 会用它沙箱化 `swift-plugin-server`，于是**所有宏**（`@Observable` 等）展开失败，报 `'swift-plugin-server' produced malformed response`。此时必须追加：
  ```
  OTHER_SWIFT_FLAGS="-disable-sandbox"
  ```
  测试同理：`swift test --disable-sandbox -Xswiftc -disable-sandbox`。

⚠️ **这个参数只对坏沙箱环境成立，不要写进 `project.yml`，也不要提交进仓库。**

```bash
# 基础命令（Codex 环境直接可用）
cd /Users/cora/Projects/Pulse
~/.local/bin/xcodegen generate
xcodebuild -project Pulse.xcodeproj -scheme PulseMac -configuration Debug \
  -derivedDataPath build/DerivedData TELEMETRYDECK_APP_ID= \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  ENABLE_USER_SCRIPT_SANDBOXING=NO build
# WorkBuddy 环境在此之上追加： OTHER_SWIFT_FLAGS="-disable-sandbox"

cd Packages/PulseCore
swift test
# WorkBuddy 环境： swift test --disable-sandbox -Xswiftc -disable-sandbox
```

### 建议（未实施）

若希望 `dev-mac.sh` 在两边的环境下都能直接跑，加一段探测而不是无条件追加：

```bash
if ! sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /usr/bin/true >/dev/null 2>&1; then
  XCODE_ARGS+=("OTHER_SWIFT_FLAGS=-disable-sandbox")
fi
```

Debug App：`build/DerivedData/Build/Products/Debug/Pulse Dev.app`。

## 双机验收步骤

1. 两台 Mac 安装本轮同一构建，各选择 iCloud Drive 中的同一个专用文件夹。
2. A 添加分组、自选及一笔交易，等网盘传输后在 B 点立即同步；确认交易金额、数量和分组正确。
3. 两台各新增不同交易，再同步；两笔均应保留。
4. 两台离线修改同一交易为不同价格，恢复联网后同步；应出现冲突，选择后检查双方最终收敛。
5. 删除交易/自选后同步；旧文件不应恢复已删除内容，保留历史不应重新加入自选。
6. 对尚未下载的 iCloud 文件验证等待和重试；目录改名、停用和重新选择后确认基线与冲突状态正确。

以上为此前同步开发阶段的验收建议与记录。最新提交、推送及验证状态以文档顶部为准；未执行网站更新日志或版本发布，不应把原项目的下一版本号直接当作这个 fork 的发布计划。
