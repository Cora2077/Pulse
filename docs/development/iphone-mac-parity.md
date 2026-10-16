# iPhone：按现有 Mac 设计对齐（2026-10-16）

本轮按用户要求，不重新发明工作台：以现有 Mac 的行为、计算与文案为基准。以下不是“全部 Mac 功能均已移植”的声明。

## 已落地

### 今日工作台

- 将 [Mac 工作台](../../PulseMac/Sources/TradingWorkbenchView.swift) 原有的纯数据模型原样提取到 [共享工作台模型](../../SharedAppSupport/TradingWorkbenchBoard.swift)，两端编译同一份任务分组、阶段排序、行情健康判断、复盘日期、持仓判断、资金投影、风险防守和板块暴露计算。
- Mac 的现金设置适配仍留在 Mac 内；iPhone 从当前账户的共享设置读取现金、用途上限和板块上限，不混用不同账户或币种。
- iPhone 直接复用 [Mac 事件控制器](../../PulseMac/Sources/TradingEventsController.swift) 与 [用途名称/配色](../../PulseMac/Sources/PositionPoolPresentation.swift)，不是另外编造事件、颜色或用途。
- [手机今日页](../../PulseIOS/Sources/Views/TodayView.swift) 按原工作台顺序呈现：范围和阶段、市场时点、三种独立计数、按标的归并的任务、选中标的摘要、资金摘要、风险防守、板块暴露。只把双栏改成适合手机的纵向排布。
- 删除重复罗列少数等待计划的旧版“今日待办”和独立重复的“需要你确认”卡片。到价、待核对、今日待复盘各有单位，不合成一个虚假的待办总数。
- 自动关注不再占首页主位置；它仍是 iOS 锁屏/活动辅助功能，不是 Mac 的工作台任务本身。

### 自选排序

- [手机自选页](../../PulseIOS/Sources/Views/WatchlistView.swift) 支持自定义顺序、涨幅、今日盈亏、总盈亏、持仓市值。默认自定义，保留导入的组内顺序。
- 自动排序只读：置顶优先、区内指标降序、缺失和非有限数值置后、并列保持原相对顺序，不为行情刷新写回分组。
- 自定义顺序提供拖动面板；取消不写入，完成才调用共享 Core。账户或分组在编辑中发生变化则拒绝覆盖。置顶/移除用可工作的长按菜单，替代 ScrollView 内不生效的 swipeActions。
- 手机自选仍以界面明确选择的账户为口径，未暗中跨账户累加。

### 新建计划

- [新建计划面板](../../PulseIOS/Sources/Views/NewTradePlanPhoneSheet.swift) 按 Mac 的“搜索选标的 → 同一面板编辑”流程工作，可搜本地及行情源，不要求先加入自选。
- 选择标的时只保存草稿上下文，不加入自选；取消不修改分组或账本。
- [共享计划工作流](../../Packages/PulseMobile/Sources/PulseMobile/PlanWorkflow.swift) 新增可选的新标的信息；[Core 保存边界](../../Packages/PulseCore/Sources/PulseCore/Store/WatchlistStore.swift) 在完整候选校验通过后一次性创建标的、计划和成员关系。无效计划不留下空标的，也不产生先写再回滚窗口。
- 新计划 UUID 固定，重复保存同一份已落地草稿仍采用原计划；账户冻结、原记录版本校验及真实成交分离规则保持。

## 本轮验收证据

- 大屏 iPhone 完整原生测试 K：17 项应用层单元测试、7 项实际 UI 测试全部通过。结果包 `/tmp/fff-parity-20261016-k`，日志 `/tmp/fff-parity-k.log`。
- 单元测试直接执行未修改的 [Mac 原工作台验收逻辑](../../PulseMac/Sources/WorkbenchSelfTest.swift)，覆盖原来的市场范围、事件窗口、复盘日期、持仓判断、板块/资金、计划身份与阶段顺序。
- [新增手机测试](../../PulseIOSUnitTests/MacParityTests.swift) 验证自动排序不写数据、缺失稳定置后、取消选标的不新增、无效计划不留成员、账户/分组变化时拒绝排序写入，以及新计划重试不重复。
- [实际 UI 测试](../../PulseIOSUITests/WorkbenchUITests.swift) 已走通“搜索不在自选里的 TSLA → 取消且不添加 → 再次搜索并保存 → 自选出现 TSLA”和排序菜单/拖动面板，不只检测静态文案。
- Core 完整回归：1027 项通过；Mobile：85 项通过；Sync：52 项通过；Activity：101 项通过；推送服务：153 项通过。
- Mac 使用原稳定签名编译成功，未覆盖日用 App。
- iPhone Air 已安装本轮版本，安装前将其已有的本地账本副本在模拟器私有目录作了备份。没有重读、覆盖 Mac 原始账本，也没有把 Air 的记录回写 Mac。
- 大屏默认与深色大字截图已人工检查。小屏 L/M 遇到合并期间分组视图的 SwiftUI 泛型推断错误；给原分组循环标明 UUID 身份和 WatchlistGroup 元素类型，未改变分组行为，随后小屏 N 的深色大字、新计划搜索/取消/保存、排序菜单/调整面板 3 项 UI 测试全部通过。结果包 `/tmp/fff-parity-small-20261016-n`。
- 脚本已逐字核对：共享工作台模型与原 Mac 模型一致，仅移走 Mac 专用现金设置适配，并把未改变逻辑的纯复盘判定放入共享模型；没有改计算或文案。

## 不冒充已完成的范围

- 本轮对齐工作台、排序与新建计划。Mac 独立的仓位池编辑、风险计算器、完整事件日历和日志定位等页面仍需逐页核对；手机已有摘要与部分入口不能当作它们的完整替代。
- 工作台内持仓判断目前能展示并打开标的；尚不能宣称与 Mac 的独立份额核对面板完全等价。
- iCloud/APNs 真机端到端、Watch 镜像以及长期自动活动的外部条件不因这轮界面改动而变成“已验收”。
- 真实 Air 数据只用于本机目检，不保存进可发布的文档截图；自动测试均使用隔离的合成数据。
