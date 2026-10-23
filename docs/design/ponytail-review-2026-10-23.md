# Ponytail 审查：先恢复完整行情，不再叠加替代系统

2026-10-23。按已读取的 Ponytail full 规则审查：最小而完整的改动，复用既有链路，不缩减用户需求。本轮为源码审查，不是新版本验收；除撤销被用户否决的版本外，不安装新方案。

## 已处理与仍未处理

- 已回退日常 App 至本机采样补线之前的签名版本，二进制与备份逐文件摘要相同；安装后的既有离线检查通过。
- 被否决的候选源码与测试归档在 `build/rejected-sparkline-candidate-20261023-150003`，生产源码恢复至提交 `c45b9b5`。没有删除主分支已有测试，没有动持仓、账户、成交或凭据。
- 分钟历史接口不稳定的根因没有因此消失。回退只撤销错误方案，不代表分时问题已修好。

## 1. 最高优先级：把完整行情当成一条完整需求

用户临时加一只自选，必须和盯了一整天的标的一样，从服务端取得所需历史；冷启动、重启、切股票不能以本机采集过报价为前提。本机快照补线方案不满足这条，所以撤销，不继续为它补持久化、状态机和更多界面。

现价与历史可以来自不同提供方，但数据角色不能混淆：最新价不能冒充分钟 OHLC，日线不能推导分时，累计成交量不能当单分钟量。复用现有 `QuoteProvider → CompositeProvider → RefreshEngine → 图表` 链路，不另建报价记录系统。

目前已核对：扶摇公开 A 股快照可提供最新价，其公开价格历史接口仅日线；已有 Longbridge 实现声明支持分钟 K 线，但本轮没有核验当前账户权限与实际返回，不能写成“已有可靠备用源”。腾讯分钟接口曾返回下午数据，后续观察到 WAF 501，这也是不能把“有数组”当“实时历史完整”的原因。

证据：[扶摇能力](../../Packages/PulseCore/Sources/PulseCore/Providers/FuyaoProvider.swift#L119-L132)、[已有历史寻源](../../Packages/PulseCore/Sources/PulseCore/Providers/CompositeProvider.swift#L982-L1022)、[Longbridge 历史入口](../../Packages/PulseCore/Sources/PulseCore/Providers/Longbridge/LongbridgeProvider.swift#L91-L99)。

最小改法：先实测已有合法历史来源的股票/指数/ETF覆盖与权限，再修共同历史加载入口的时效和失败恢复。只有确认有后继来源时才能承诺自动切换；没有来源就属于必须补齐的数据能力，不能靠本地画线宣告解决。

验收从无缓存的新标的开始，至少包括当天分时、分钟 K、日/周/月 K、午休后、网络恢复和重启，不以固定演示持仓代替。

## 2. 高风险：前复权回退把“缺字段”当成“没有除权”

[TencentProvider](../../Packages/PulseCore/Sources/PulseCore/Providers/TencentProvider.swift#L273-L299) 在没有任何 `qfq*` 键时，把 `day/week/month` 当作前复权结果返回。但缺键本身不能证明这只股票从未除权，也可能是上游响应缺失。前一轮只观察了少数样本，没有建立通用契约。

更严重的是，[测试](../../Packages/PulseCore/Tests/PulseCoreTests/CandleAdjustmentTests.swift#L103-L122) 按这条推断改成接受普通序列；它验证的是实现自己的假设，不是独立证明价格口径正确。本项是已确认的规则风险，不声称已实测到真实标的错价。

最小改法：撤销无证据的通用回退。前复权字段缺失时换到可证明同口径的既有来源；没有同口径来源就明确失败。不能用“图总算有了”替代价格正确性。

## 3. 高优先级：图表错误会被别的请求清掉

[图表加载](../../Packages/PulseCore/Sources/PulseCore/Store/RefreshEngine.swift#L291-L312) 把失败写到共享 `lastError`，而[成功报价](../../Packages/PulseCore/Sources/PulseCore/Store/MarketStore.swift#L42-L51) 会清掉它。[详情页](../../PulseMac/Sources/DetailView.swift#L1042-L1064) 又凭这个共享字段判断“无数据”还是“加载失败”。

结果是：A 股票图表失败，任意一次成功报价就可能让提示改口；另一只股票出错也可能影响当前图表。这不是文案问题，是错误归属错误。

最小改法：图表失败状态跟随现有 `CandleCacheKey`，成功也只清当前键。不要再加一套全局健康总控层。

## 4. 高优先级：财务指标的刷新按钮并不刷新指标

[刷新入口](../../PulseMac/Sources/FuyaoFinancialsView.swift#L10-L19) 只调用报表加载，没有强制重取指标。[控制器](../../PulseMac/Sources/FuyaoFinancialsController.swift#L71-L100) 请求开始前就把所有待取报告期标为已尝试，失败/取消/限流后也不会正常重试。声明的 24h TTL 没参与判断。

最小改法：复用现有刷新入口，同时刷新报表与指标；只缓存成功记录，失败允许有节制地重试。删掉未生效的 TTL 宣称，不新增控制器或缓存框架。

## 5. 高优先级：财务展示包含两个未经充分成立的语义替换

- [相邻期比较](../../PulseMac/Sources/FuyaoFinancialsView.swift#L149-L155) 直接拿最新两份报告相减。若指标是累计口径，相邻季度长度不同，这不等于经营改善/恶化。最小改法是先删掉这列，或只在可证明可比的同期上展示，并明确期间；不要为保留一列而再拉更多数据。
- [指标别名](../../Packages/PulseCore/Sources/PulseCore/Models/FuyaoFinancialIndicators.swift#L169-L171) 把 `net_profit_yoy_growth_ratio` 归到“归母净利润同比”。净利润和归母净利润不能只因名字相近就合并。最小改法是分开定义，证据不足的不冒称。

## 6. 高优先级：限流被验收程序当成通过

[真实接口检查](../../PulseMac/Sources/FuyaoResearchAcceptance.swift#L388-L400) 单独统计限流是合理的，但[最终状态](../../PulseMac/Sources/FuyaoResearchAcceptance.swift#L474-L476) 只看失败列表，限流项存在时依然输出 `ok` 并返回成功。

最小改法：限流保留为“本轮未完成”，不能算通过；不必重做验证框架。按所改接口跑有界验证，避免每次改一行都重打全部研究接口。

## 7. 次优先级：打新日历部分失败的边界不完整

[限流处理](../../Packages/PulseCore/Sources/PulseCore/Providers/FuyaoProvider+IPO.swift#L13-L34) 只跳出阶段内循环，仍会进入另一个市场；[空态](../../PulseMac/Sources/FuyaoIPOView.swift#L46-L59) 在部分查询成功且无记录时可能先说“没有新股”，但其他市场/阶段尚未取得；错误又只按阶段合并，丢失市场维度。

最小改法：在原函数内停止后续请求并保留未完成范围；结果不全就说不全，不新建调度层。这些修复排在行情与价格口径之后。

## 产品上保留什么、停止什么

保留紧凑行情表、现有自选分组、账户账本、图表、计划核对与记录成交。它们符合用户的高频动作，不因一次审查全部推倒。

财报、龙虎榜、打新继续按需打开；先修其真实性与失败边界，不继续加竞价卡、AI归因、每日简报或另一套研究工作台。少写新系统，把已有按钮和已有数据做实。

## 改动顺序

先验证并打通新自选的服务端完整历史，同时收紧前复权口径；再修请求级错误归属；然后修刷新/重试和财务展示；最后修验收状态与辅助模块边界。每一步使用该路径的最小回归，不把测试数量当产品完成率。

本轮未核验当前 Longbridge 权限、未重新全量实测所有研究接口，也未修改这些已发现问题。风险：当前前复权异常回退与图表错误状态仍在日常版，不能把本审查当作它们已获修复的证明。
