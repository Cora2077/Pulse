# MCP 当前开放范围（2026-10-04）

目前没有开放所有功能。以 MCPToolAdapter 注册表为准，而不是界面是否支持。

| 范围 | 读取 | 修改 |
| --- | --- | --- |
| 证券账号 | 列出账号；按 account_id 读取账号内自选和持仓 | 基础交易、分组、逻辑和计划修改均按 account_id 隔离；暂不支持归属分配 |
| 自选 / 分组 / 排序 / 标的搜索 | 支持 | 支持 |
| 持仓账本 / 成交 / 持仓校准 | 支持；融资和计划快照部分嵌套在原始数据里 | 支持基础成交字段与校准；不支持全部融资和复盘字段 |
| 交易计划 | 有持仓历史的自选标的可读计划、条件和历史 | 仅基础买卖方向、价格、数量、状态和备注；尚缺用途池、融资意图、条件和事件关联的写入口 |
| 仓位池 / 持仓验证 | list_positions 可读 allocation 中的分块、验证和资金来源 | 尚未开放转移、拆分、资金来源标记、验证编辑、核对与撤销 |
| 事件日历 | 持仓标的的手工事件可随 list_positions 读取 | 尚无事件增删改、时间线和全局事件列表工具 |
| 今日工作台 / 资金预算 / 预演 | 尚无聚合与预算读取工具 | 尚无现金、池预算、预演场景工具 |
| 交易复盘 | 成交附带的复盘信息部分可读 | 尚无复盘、检查点的专用修改工具 |
| 行情 | 读取共享的缓存行情；搜索标的 | 尚无主动刷新、分时/K线专用工具 |
| 备份 / 同步 / 设置 | 尚无专用工具 | 尚无专用工具 |

账号功能启用后，所有涉及账号数据的基础工具必须显式给出 account_id（unassigned / financing / mengmeng），遗漏会返回 account_required。调用其他账号的数据操作不会改变界面当前选择。行情与标的搜索属于共享市场数据，不要求账号。

基础工具共 19 个：list_brokerage_accounts、list_watchlists、list_positions、get_quotes、search_symbols、create_group、rename_group、delete_group、reorder_groups、reorder_symbols、set_thesis、set_trade_plan、delete_trade_plan、add_symbol、remove_symbol、record_trade、update_trade、delete_trade、calibrate_position。

后续补齐优先级：仓位与验证操作 → 计划执行/条件/事件关联 → 工作台、日历与资金预演 → 复盘与备份管理。每一步先复用现有业务校验，再补工具与防串账号测试。
