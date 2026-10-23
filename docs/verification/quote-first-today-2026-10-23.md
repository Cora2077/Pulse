# 今日行情优先：验收记录

2026-10-23，Asia/Shanghai。产品依据为用户“9–15 只持仓、主要看行情、几乎不写投资逻辑”的明确反馈。设计说明见 [今日行情优先](../design/quote-first-today.md)。

## 交付

现有“今日工作台”新增行情/待办切换，默认行情；持仓/自选与市场范围可切换。表格沿用当前账户与现有行情数据，无新增 API 或轮询。日涨跌幅不依赖持仓成本。旧大卡原型及其回显投资逻辑、任意收益阈值和“今天不用管”文案已删除，没有接入生产。

点行情行通过既有图表 overlay 打开标的，返回清除额外摘要面板，保留原工作台实例。此路径做了代码审查，未执行真实账户上的自动点击回放。

## 验证结果

- `scripts/dev-mac.sh --build`：通过，继续复用稳定的本地开发签名与凭据 broker。
- `swift test --package-path Packages/PulseCore`：1191 项 / 118 套件通过。
- 新增 `--main-window-demo --holding-quotes-selftest`：29 项通过；构建产物与安装后的日常 App 均执行通过。包含真实 `WatchlistStore` 合成双账户隔离、行情只读及计划阈值隔离；渲染前后账本与计划快照相等。
- `--main-window-demo --workflow-selftest`：通过。
- `--main-window-demo --tactical-board-selftest`：通过，保留原待办测试入口的表现。
- 原生 `NSHostingView` 渲染：常见窗口内容区深浅色下可同时显示 15 条；窄视图不裁切最新价和涨跌幅；待办视图仍可正常呈现。截图全部为合成账户与虚构价格，不含真实持仓。

覆盖场景：缺报价、缺昨收、合法零涨跌、延迟、过期、休市参考、未来报价、无计划/已结束/非法计划、重复标的、空账户、价格变化不自动换位、多个账户的持仓/计划不串用。

## 已知测试问题（未计入通过）

既有 `--main-window-demo --brokerage-account-selftest` 返回 1，未输出失败位置。同一命令在更新前已安装的旧版中也返回 1。本轮未修改该综合自测或账户写入逻辑，也没有把它跳过后宣称全量自测通过。新行情投影的账户隔离另由上述 29 项中的真实合成账户检查覆盖。该既有综合自测失败的具体断言尚未定位。

## 原生截图

- [工作台行情 · 浅色](../design/prototypes/workbench-quotes-light.png)
- [工作台行情 · 深色](../design/prototypes/workbench-quotes-dark.png)
- [窄视图 · 深色](../design/prototypes/quotes-narrow-dark.png)
- [原有待办 · 浅色](../design/prototypes/workbench-tasks-light.png)

## 安装

已更新 `/Users/cora/Applications/FFF.app`，验签通过。更新前副本保留在 `FFF-backups/FFF-before-quote-first-20261023-102158.app`。安装后执行离线原生测试，随后恢复正常启动；未读取或截图用户真实账户做演示，未修改凭据。

本轮不声称实现 T+1 可卖数量、自动交易、涨跌停封单判断或交易建议；不根据投资逻辑的填写情况惩罚或打断使用。
