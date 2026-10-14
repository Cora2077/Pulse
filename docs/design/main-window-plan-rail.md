# 主窗口标的页：常驻计划栏（Plan Rail）

2026-10-14。设计：主 Agent（GPT-6.1 Sol）；实现：WorkBuddy deepseek-v4.1-flash。

## 问题

主窗口标的页（`MainInstrumentView`）底部是 tabPicker（持仓 / 交易记录 / 交易计划 / 买入理由）+ tabContent。
计划清单只存在于 `.plans` tab 内；默认 `.position` tab 下，用户只能在 K 线图上看到计划的横向虚线与小标签，
看不到"有几条计划、什么价位、什么状态"。窄版弹窗页（`DetailView`）已内联展示计划区（最多 2 行 + "还有 N 条"），
主窗口没有对等物。

## 设计决策

在底部区域右侧增加一条**常驻计划栏**，与 tab 内容等高，专门回答"当前最该盯哪几条计划"：

```
──────────── 图表 ────────────
开高低收 strip
──────────────────────────────
[tabPicker                ] ┆ 交易计划 · 2      查看全部 +
[tabContent（持仓等）       ] ┆ 卖 54.00 ×300   [待成交]
                            ┆ 卖 59.50 ×673   [待成交]
                            ┆ …（可滚动）
```

- 位置：`dashboard` 底部，`Divider` 之下；左侧为原有 tabPicker + tabContent（弹性宽），
  右侧 `Divider` + 计划栏（固定宽 328pt）。
- 显示条件（三者同时满足，否则布局与今天完全一致）：
  1. 底部区域可用宽度 ≥ 1120pt（窗口最小 960，窄窗口不牺牲 tab 内容）；
  2. `selectedTab != .plans`（该 tab 本身就是完整计划列表，避免重复）；
  3. 该标的存在 `displayState == .waiting` 的计划（无活跃计划即无"要盯"的内容，整条隐藏，无空态）。
- 栏头（34pt，与 tabPicker 行高对齐）：左 `交易计划 · N`（N = 待成交条数，10pt medium secondary）；
  右 `查看全部`（10pt plain，点击切到 `.plans` tab）+ `+` 图标按钮（新增计划，仅 `symbolSupportsPosition`，
  路由与 plansTab 的添加一致）。
- 列表：`ScrollView + LazyVStack`，**复用现有 `planRow(_:)`**——行点击进编辑器、状态徽章菜单、
  跨账户路由、到价徽章全部继承，零新交互逻辑。
- 排序（与 plansTab 的"最近更新"刻意不同，本栏是分诊视角）：有效报价下
  已到价优先 → 距现价 |plan.price − quote.price| 升序 → updatedAt 倒序 → id 兜底；
  无有效报价时 updatedAt 倒序。最接近触发条件的计划永远在最上。

## 交互流

- 点行 → 计划编辑器（沿用 `planRow` 的账户选择逻辑）。
- 点状态徽章 → 与 plansTab 相同的 `PlanActionMenu`。
- `查看全部` → 切到 `.plans` tab（此时栏自动隐藏，完整列表占满全宽）。
- `+` → 新建计划页。

## 验收

1. `scripts/dev-mac.sh --build` 编译通过。
2. `--main-window-demo --tactical-board-selftest` 通过，新增三张真实原生渲染：
   `plans-instrument-rail-light.png` / `plans-instrument-rail-dark.png`（1240×760，默认持仓 tab，栏可见）、
   `plans-instrument-rail-narrow.png`（1000×760，栏不出现）。
3. 改动面仅：`MainInstrumentView.swift`、`TacticalBoardSelfTest.swift`、4 个 `Localizable.strings`
   （新增 `main.plans.rail.all` = 查看全部 / See All / すべて表示 / 전체 보기）。
4. `.plans` tab、`planRow`、图表标注逻辑零改动。

---

# 第二轮：悬浮面板 K 线的计划虚线（2026-10-14 追加）

## 问题

菜单栏悬浮面板（`DetailView`，PopoverRootView 承载）的小 K 线创建图表时**没有传 `annotations:`**，
所以计划虚线完全不显示；主窗口（`MainInstrumentView`）有。用户原始诉求其实是这里。

## 设计决策

给悬浮面板的两个图表（`IntradayChartView` / `CandlestickChartView`）挂上 **browse 模式、只读** 的
`ChartAnnotationConfiguration`：

- `plans`：`BrokerageBoardReader.displayPlans(symbol).map(\.chartPlan)`，与主窗口完全同源；
  非活跃计划由 overlay 按 `showsHistoricalPlans = false`（默认）过滤，与主窗口默认观感一致。
- `drawings: []` 且 `controller.showsDrawings = false`：悬浮面板只看计划，不渲染用户画线。
- `scope`：`minute1`（分时）→ `.intraday(day:)`（沿用主窗口的 session day 求法），其余周期 → `.candles(period:)`。
- 四个回调中三个是 no-op（browse 且无画线，永远不会触发）；`onEditPlan` 按 chart id 找回 entry 后
  走悬浮面板自己的 `openPlanEditor(entry.plan.id)`——点计划标签直接进该计划的编辑页。
- 交互零新逻辑：浏览模式下的拖拽平移、双击复位、滚轮缩放、十字线全部沿用主窗口已验证的路径
  （图表在 `annotations != nil` 时自动把自身手势让给 overlay 子视图，CandlestickChartView L242 附近）。

## 验收

1. 编译通过；`--main-window-demo --tactical-board-selftest --plan-status-only` 通过。
2. fixture 给 PLANQA 种 minute1（锚定当日 09:30 市场时区，390 根）与 day（180 根）确定性蜡烛，
   基准价 105、波幅让 110 与 102 计划线落在可视区间内（140 线超界，呈现边缘提示也算正确行为）。
3. 渲染证据：`plans-detail-light.png`（分时，现有产物内容升级）+ 新增
   `plans-detail-chart-day-light.png` / `plans-detail-chart-day-dark.png`（日 K 带计划虚线与标签）。
4. 改动面仅 `DetailView.swift` 与 `TacticalBoardSelfTest.swift`；无新文案（标签复用既有本地化键）。

---

# 第三轮：悬浮面板计划标签遮挡与适配缩放陷阱（2026-10-14 追加）

## 问题（真实数据复现）

1. **遮挡**：悬浮面板小图上，计划标签是富卡片（宽 plot×0.36≈108pt、两行 30pt）。
   两个卖出计划都超界时，提示卡堆在图表右上，直接盖住最近走势（用户截图 1/2）。
2. **适配缩放陷阱**：点超界标签 → `controller.focusedPlanPrice = price`，图表重新缩放纳入计划价
   （用户截图 2 的"压扁"状态）。主窗口的出口是工具栏「适配计划」按钮
   （`clearPlanFocusOrToggleFit`）；悬浮面板没有工具栏，`focusedPlanPrice` 无任何代码路径清除 → 困住。

## 设计决策

### A. overlay 紧凑标签模式（`usesCompactPlanLabels`，默认 false）

- `ChartAnnotationConfiguration` 新增开关，主窗口不传 → 零变化；DetailView 传 true。
- 紧凑尺寸：`width = min(max(plot×0.22, 52), 76)`、`height = 15` 单行（面积约 -70%）；
  中心点右移：`plot.maxX - min(max(plot×0.11, 30), 44)`，更贴右缘。
- 紧凑内容：`[● 到价] [↑/↓ 超界箭头] 买/卖 价格 [×数量]` 单行 9pt；数量、成本行让位给
  图下方 200pt 处的交易计划区与 tooltip（信息零损失，遮挡大减）。
- focused 视觉：被适配缩放的价位胶囊加边色 15% 填充（两种模式都加，主窗口也受益），
  提示"再点一次恢复"。

### B. 适配缩放可退出（overlay 行为修复，主窗口同步受益）

- `ChartAnnotationController` 新增 `togglePlanFocus(_:)`（同价再点即清除）与 `clearPlanFocus()`。
- 超界标签点击 = 切换 focus（原来只进不出）；双击复位视图同时清 focus。
- 超界标签 tooltip 追加一行操作提示（新 key `chart.annotation.plan.focusHint`，4 语言）。

### C. 验收

- PulseUI 单测（Swift Testing）：toggle 设置/同价清除/异价切换 + clearPlanFocus。
- 编译 + `--plan-status-only` 渲染：既有 3 张悬浮面板图自动呈现紧凑标签，逐张人工复核。
- 改动面：PulseUI 两源文件 + PulseUI Tests + DetailView（1 行）+ 4 个 strings（各 1 键）。
