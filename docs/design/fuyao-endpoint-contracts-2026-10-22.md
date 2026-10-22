# 扶摇 API 端点契约摘要（2026-10-22）

本文件是 [扶摇 API 最佳实践与下一轮设计](fuyao-api-practices-and-next-wave.md) 的**附录**：逐端点抄录 `https://fuyao.aicubes.cn/llms-full.txt`（2026-10-22 抓取，14861 行）里与 FFF 相关的参数、字段单位、窗口限制与 null 语义，供实现时直接对照。

**读法**
- 每节标题为 `名称 | METHOD /path`，其后是 `鉴权/权限`、`限流/窗口约束`、单行 `参数`、字段要点、`FFF 可用性`。
- 状态标注分三类：**可用** / **客户端专用**（文档原文「该能力暂未开放外部接入」）/ **敬请期待**（原文「正在规划中」且未给路径）。
- 除特别注明外**均未实测**；实测结论只写在设计与验证文档里，不写在这里。
- 摘要只保留影响调用的契约事实，省略示例 JSON。字段语义以官方原文为准。

---


## 除复权数据（复权因子事件流）| GET /api/a-share/corporate-actions/adjustment-factors
鉴权/权限：X-api-key。限流/窗口约束：未声明（from/to 均可选，可拉全历史）。状态：可用。
参数: thscode(str,必填,单只,不接受逗号) from(str,否,YYYY-MM-DD) to(str,否,YYYY-MM-DD)
字段: item[] 按 ex_date_ms 降序；ex_date_ms=除权除息日 00:00 毫秒；dividend_per_share=每股现金分红(税前,原币,非现金事件为0)；per_share_bonus=每股送股比例(0.1=10送1,纯现金为0)。不返回 event_type/record_date/adjust_factor，事件类型靠两字段隐式区分；配股字段不在此端点。
FFF 可用性: 仅原始事件流，复权因子需自行推导；要复权价直接用 prices/historical?adjust=forward|backward。

## 交易日历 | GET /api/a-share/calendar/trading-days
鉴权/权限：X-api-key。限流/窗口约束：固定窗口 [今日-1年, 今日]，无入参，不可扩窗。状态：可用。
参数: 无
字段: item[] 按时间升序；date_ms=该日 00:00 毫秒；date=同一天 yyyyMMdd。仅 A 股交易日，停市日不返回。
FFF 可用性: 无坑；但对账要用 date 字段而非 date_ms 自行格式化。

## A股集合竞价快照 | GET /api/a-share/auction/snapshot
鉴权/权限：X-api-key。限流/窗口约束：thscodes 单次最多 100 个（按去重前 token 数校验），服务端按请求顺序去重。状态：可用。
参数: thscodes(str,必填,逗号分隔,≤100 token) stage(enum,否,live|final,默认final)
字段: item[] 含 thscode/ticker/name；auction_price 元；auction_pct=竞价涨跌幅**百分数原值**；auction_volume **单位为手**（2026-10-20 实测：amount÷price = volume×100，两只标的误差<0.001%）、auction_amount 元；auction_unmatched（未匹配量，**单位仍未声明**）；auction_turnover_pct=竞价换手率(百分数)；auction_yesterday_ratio_pct=相对昨日成交量比例(百分数)；auction_volume_ratio=量比(倍数)；pre_close_price/open_price/last_price 元；float_market_cap 元。data.auction_phase/data.data_status **为开放字符串**：文档未给取值清单，实测出现 closed/final。
FFF 可用性: 停牌与 not_ready 也返回 data.timestamp，靠 data_status 判空；不要在竞价结束前用 stage=final 取终态。
## 短线风向标竞价基准 | GET /api/a-share/auction/short-term-benchmark
鉴权/权限：X-api-key。限流/窗口约束：未声明；date 显式传非交易日不自动回退。状态：可用。
参数: date(str,否,yyyy-MM-dd,默认上海当日)
字段: date(最终查询日)/date_ms(该日零点)；item[] 仅 thscode/ticker/name/auction_pct(**百分数原值**)/tags(字符串数组,如"高开","放量")。无金额、无量。
FFF 可用性: 只给标签与竞价涨幅，做「竞价异动」需与 auction/snapshot 的金额/量比合表。

## 集合竞价机会 | GET /api/a-share/special-data/auction-stock-opportunities
鉴权/权限：X-api-key。限流/窗口约束：date 须属于 auction-opportunity-dates 返回集合；size 1–20；page 从 1。状态：可用。
参数: date(str,否,YYYY-MM-DD) warn_types(str,否,逗号分隔18个码68710–68727,省略=全部) market(str,否,a_share|sh_sz_main|sh_a|sz_a|gem|star,默认a_share) exclude_st(bool,否,默认false) thscodes(str,否,≤50 token) sort_by(str,否,warn_time|warn_type) sort_order(str,否,desc|asc) page(int,否,1) size(int,否,1–20,默认20)
字段: data.mode=real_time|history；item[] 一股票可多条；warn_type 原始码（68710=涨停试盘），warn_name 新码未知时为 null 但保留原码；warn_timestamp 毫秒；bid_price 元；bid_change_ratio=**小数比例**；bid_amount/previous_amount 元；bid_volume/previous_volume **单位未定义**；explain/grade 保留原值字符串（如 "1.0"）可为 null；related_block 为 JSON 原值可为 null。pagination.total 可为 null，用 has_next 翻页。
FFF 可用性: 涨幅是小数、金额是元、量无单位，三套口径混在同一行；grade/explain 不要当数值解析。
## 集合竞价可选交易日期 | GET /api/a-share/special-data/auction-opportunity-dates
鉴权/权限：X-api-key。限流/窗口约束：未声明，无业务参数。状态：可用。
参数: 无
字段: dates[] 升序，实际保留范围由源决定；latest_date=默认历史查询日；source_updated_at 毫秒可为 null。
FFF 可用性: 必须先取本接口再传 date，否则越界报错而非空集。

## 龙虎榜榜单 | GET /api/a-share/special-data/dragon-tiger-list
鉴权/权限：X-api-key。限流/窗口约束：date 只支持一年内；显式非交易日=1002，超一年或晚于今天=1003。**固定全量返回、不分页**。状态：可用。
参数: board_type(enum,否,all|org|hot_money,默认all) date(str,否,yyyy-MM-dd,默认上一/最近交易日)
字段（2026-10-20 实测：count 72 / stock_count 67 / 行数 72，range_days {1:55, 3:17}；**有 4 行 thscode 为 null 只剩 ticker/name**，另有 .BJ 行）：count=上游记录数（**同一股票可能同时有当日榜与3日榜，count>stock_count**）；stock_count=去重股票数；stock_items[] 在 all/org 有值、hot_money 时为空数组；hot_money_items[] 仅 hot_money 时填充（name 游资名、buying 聚合净买入元、rows 关联股票）。stock_items 关键字段：change=**小数**涨跌幅；net_value/buy_value/sell_value/amount=元；net_rate/org_net_rate/hot_money_net_rate=**小数**占比；range_days：1=当日榜、3=三日榜（去重前先按它分组）；hot_rank 越小越前；org_buy_num/org_sell_num=机构家数；concept_list[].name；limit_reason。
FFF 可用性: 一个请求里混着"一日榜"和"三日榜"两套口径，按 thscode 聚合会重复计金额，必须先按 range_days 去重或分组。

## 个股机构交易详情 | GET /api/a-share/special-data/dragon-tiger-stock-institution
鉴权/权限：X-api-key。限流/窗口约束：date 省略=最近已完成交易日；查询范围一年。状态：可用。
参数: thscode(str,必填,单只) date(str,否,YYYY-MM-DD) range_days(int,否,1|3,省略=返回两类实际记录)
字段: item[] 一日榜与三日榜分别保留（最多 2 条），含 range_days/start_date/end_date；org_buy_value/org_sell_value/org_net_value=元可为 null；org_buy_num/org_sell_num=家数；org_net_rate=**小数**；buy_departments[]/sell_departments[] 每项 department_id+name，**同一 department_id（如 THS59 机构专用）在同一数组里重复出现，代表席位条数，不可按 id 去重**。
FFF 可用性: 席位数组是"条数"语义不是"集合"语义；区间金额不可与 dragon-tiger-list 的 org_net_value 直接相加。

## 营业部经典战绩 | GET /api/a-share/special-data/dragon-tiger-department-classic-record
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: department_id(str,必填)
字段: department_id/department_name(可 null)/organization_id(可 null)；classic_record 无战绩时为 null，含 thscode(可 null)/name(可 null)/board_pattern（原始"24天14板"文本，不要正则拆成结构）。
FFF 可用性: 排行前需先用 history 拿到 department_id；本接口只给一条代表战绩。
## 营业部历史上榜记录 | GET /api/a-share/special-data/dragon-tiger-department-history
鉴权/权限：X-api-key。限流/窗口约束：page 从 1；size 1–30，默认 30。状态：可用。
参数: department_id(str,必填) page(int,否,1) size(int,否,1–30,默认30) min_net_buy_amount(int,否,档位5000000|30000000|50000000|100000000,单位元) sort_field(str,否,trade_date|change_ratio|net_buy_amount) sort_dir(str,否,desc|asc)
字段: item[] 同股不同上榜记录**分别保留**（不去重）；thscode/name 可能 null 或空串，原样保留；trade_date 日期；change_ratio=**小数**；net_buy_amount=元可为 null（负值=净卖出）；rank_type=榜单区间码原值。pagination.total 可为 null。
FFF 可用性: 净买入为负是常态，排序前别取绝对值；空 thscode 要容忍。

## 异动监控（严重异动与重点监控）| GET /api/a-share/special-data/abnormal-monitor-list
鉴权/权限：X-api-key。限流/窗口约束：page 从 1；size 1–30，默认 30。状态：可用。
参数: state(str,否,current|history,默认current) page(int,否,1) size(int,否,1–30,默认30)
字段: start_date_ms=监控开始毫秒；end_date_ms=结束毫秒，**null 表示监控仍在进行**；monitor_type 原始码；monitor_label：1/2=严重异动，其它=重点监控（展示以 label 为准，不要硬编码 1/2）；thscode/name 可 null 或空串。
FFF 可用性: end_date_ms=null 不能当"数据缺失"丢弃，那正是当前在监控的票。

## 涨停股票池 | GET /api/a-share/special-data/limit-up-pool
鉴权/权限：X-api-key。限流/窗口约束：page≥1；size 1–200，默认 50；date_ms 省略回退"服务端当前自然日"（**不是最近交易日**）。状态：可用。
参数: date_ms(long,否,上海零点毫秒) page(int,否,1) size(int,否,1–200,默认50) sort_field(enum,否,last_price|continue_day_cnt|seal_money|limit_up_time,默认last_price) sort_dir(enum,否,asc|desc,默认desc)
字段: price_change_ratio_pct=**已乘100的百分数**；limit_up_time="HH:MM"字符串；limit_up_reason 空串标准化为 null；continue_day_text="首板"/"5天4板"，continue_day_cnt=连板计数；seal_money=当前封单额元，max_seal_money=峰值封单额元；is_st/is_new 仅展示不作筛选入参。后端固定取全部连板 + main,chinext,ssestar,north 四类板块，无板块参数。
FFF 可用性: 非交易日不传 date_ms 会拿到空/错日数据；封单额是元，排序值大，注意不要按"万元"展示。
## 跌停股票池 | GET /api/a-share/special-data/limit-down-pool
鉴权/权限：X-api-key。限流/窗口约束：page≥1；size 1–200，默认 50；date_ms 默认当前自然日。状态：可用。
参数: date_ms(long,否) page(int,否,1) size(int,否,1–200,默认50) sort_field(enum,否,last_limit_time|first_limit_time|last_price|price_change_ratio_pct|turnover_ratio_pct,默认last_limit_time) sort_dir(enum,否,asc|desc)
字段: price_change_ratio_pct=百分数原值（负）；turnover_ratio_pct=换手率百分数原值；first_limit_time/last_limit_time=上海时区 "HH:MM"；last_price 元。无连板/封单字段。
FFF 可用性: 与涨停池字段不对称（没有 seal_money/continue_day_cnt），UI 要分两套模型。
## 炸板股票池 | GET /api/a-share/special-data/limit-break-pool
鉴权/权限：X-api-key。限流/窗口约束：page≥1；size 1–200，默认 50；date_ms 默认当前自然日。状态：可用。
参数: date_ms(long,否) page(int,否,1) size(int,否,1–200,默认50) sort_field(enum,否,price_change_ratio_pct|open_times|last_price|turnover_ratio_pct|turnover,默认price_change_ratio_pct) sort_dir(enum,否,asc|desc)
字段: open_times=开板次数(int)；turnover=成交额（**文档未标单位，示例 1.25e9 与"元"一致，属未声明**）；turnover_ratio_pct=换手率百分数；price_change_ratio_pct=百分数原值。接口直接消费炸板集合，不做归因。
FFF 可用性: 炸板票不在涨停池里，情绪指标需三池并集后去重。
## 连板天梯 | GET /api/a-share/special-data/limit-up-ladder
鉴权/权限：X-api-key。限流/窗口约束：无入参；上游固定近 30 个交易日，每个板位最多 4 只。状态：可用。
参数: 无
字段: window.length=30；window.date_list[] 后端顺序（**未声明升/降序，需自排**）；window.board_caps 每板位上限=4；item[] 按日期，boards 固定 6 个键 two_board/three_board/four_board/five_board/six_board/seven_over，缺失补 []；每只含 board_num 连板数、seal_nextday（bool，**最近交易日固定 null**，无次日参考）、sign_level 上游标记等级。
FFF 可用性: 每板只给 4 只，不能当"该板全部股票"；seal_nextday=null 与 false 语义不同。

## 涨停强度与晋级统计 | GET /api/a-share/special-data/limit-up-statistics
鉴权/权限：X-api-key。限流/窗口约束：date 省略=当天或最近交易日；查询范围一年。状态：可用。
参数: date(str,否,YYYY-MM-DD)
字段: seal_rate=封板率**小数**（0.6478=64.79%）；touched_limit_up_stock_count=封板率的分母基数；limit_up_stock_count=封板家数；open_stock_count=涨停打开家数；page_boards[] 固定 5 档 one/two/three/four/five_plus，promotion_rate 为**小数**且 one 档为 null、five_plus 是合并档位不是五板整；exact_boards[] 板数 board_num≥2 且**只含实际返回的板数**（可能缺 4/5 板），不要假设连续。
FFF 可用性: page_boards（合并档位）与 exact_boards（精确家数）两套口径不可互相校验；晋级率口径不一致，别跨日算平均。

## 新股发行与申购（A股） | GET /api/a-share/ipo/calendar-list
鉴权/权限：X-api-key。限流/窗口约束：未声明；无分页。状态：可用。
参数: market(str,必填,sh_sz|bj) status(str,必填,upcoming|subscribable|awaiting_listing)
字段: 股票代码 ticker 与申购代码 subscription_code **是两个字段**（可不同）；listing_date 未定=null；issue_price 未定=null，单位元；thscode 可 null。无申购上限/中签率字段。
FFF 可用性: 必须两个参数都给；三种 status 要各调一次才能拼完整打新日历。

## 港股新股递表记录 | GET /api/hk-share/ipo/application-list
鉴权/权限：X-api-key。限流/窗口约束：page 从 1，**每页固定 50 条**；total 可能为 null，用 has_next。状态：可用。
参数: page(int,否,默认1)
字段: item[] 仅 company_name + application_date(可 null)；**同一公司的重复申请被保留**（去重需自行按公司名合并）。
FFF 可用性: 字段极薄，只能做递表流水；无股票代码、无价格。
## 港股认购与待上市日历 + 发行详情 | GET /api/hk-share/ipo/calendar-list
鉴权/权限：X-api-key。限流/窗口约束：未声明；status 必填单值。状态：可用。
参数: status(str,必填,subscribable|awaiting_listing)；详情用 issue_code(str,必填,≤32字符) 调 GET /api/hk-share/ipo/issue-detail
字段: issue_code=发行记录标识（保留 HK 前缀）；thscode **未确定时为 null**；issue_price 仅定稿时有值，只给区间时为 null（区间在 issue_price_text 如 "3.92-5.07"）；currency=HKD；entry_fee=入场费 HKD（**不要用价格×每手股数自行推算**）；subscription_end_date=公共招股截止日，不是各券商时点。详情返回 issue_price_range.lower/upper（可 null）、lot_size 股、entry_fee；详情**不代表当前可认购**。
FFF 可用性: 没有代码就不能进自选/行情链路；区间价与单一发行价要分两栏展示。

## 市场成交额预测 | GET /api/a-share/special-data/turnover-prediction-snapshot
鉴权/权限：X-api-key（但页面标注"该能力暂未开放外部接入"）。限流/窗口约束：未声明；无业务参数。状态：**客户端专用**（同花顺 AI 客户端内数据契约，端外不可调用）。
参数: 无
字段: predict_turnover=预测全天成交额元；previous_turnover=昨日全天成交额元；predict_turnover_change=预测增减额元，**任一输入为 null 则本字段 null**；source_updated_at=业务图表更新时间毫秒，可 null。
FFF 可用性: 需要客户端身份；桌面 App 只能自建估算，不能当公开 REST 依赖。

## 筹码形态可选日期 | GET /api/a-share/special-data/chip-shape-dates
鉴权/权限：X-api-key（页面标注暂未开放外部接入）。限流/窗口约束：无业务参数。状态：**客户端专用**。
参数: 无
字段: latest_date=最新可选日；dates[]=真实可选日期集合（选股日期必须以本集合为界）。
FFF 可用性: 端外不可用；无日期则 chip-shape-stocks 无从校验入参。
## 筹码形态股票筛选 | GET /api/a-share/special-data/chip-shape-stocks
鉴权/权限：X-api-key（页面标注暂未开放外部接入）。限流/窗口约束：page 从 1；size 1–20，默认 20；date 须属于可选日期集合。状态：**客户端专用**。
参数: shape(str,必填,double_peak|high_position_dense|low_position_dense|low_position_locked) date(str,否,YYYY-MM-DD) page(int,否,1) size(int,否,1–20,默认20)
字段: item[] 仅 thscode/name（无形态强度、无价格），保持筛选结果顺序；pagination.total 可为 null。
FFF 可用性: 只有代码+名称，要出卡片必须再打行情；端外不可用。

## 同花顺新增概念 | GET /api/a-share-index/baseinfo/new-concepts
鉴权/权限：X-api-key（页面标注暂未开放外部接入）。限流/窗口约束：page 从 1；size 1–15，默认 15。状态：**客户端专用**。
参数: page(int,否,1) size(int,否,1–15,默认15)
字段: record_id=概念新增事件标识（同一概念多次事件会有多行）；concept_code=概念业务代码；thscode=可映射的标准指数，**未登记时为 null**；created_at=新增时间毫秒。
FFF 可用性: 端外不可用；thscode 为 null 时无法直接拉成分股。

## 宽基ETF申购净流入 | GET /api/fund/etf-flow/net-inflow-historical
鉴权/权限：X-api-key（页面标注暂未开放外部接入）。限流/窗口约束：无业务参数，返回窗口由服务端决定；按 T+1 次日更新。状态：**客户端专用**。
参数: 无
字段: available_start_date/available_end_date=本次返回序列边界（**end_date 当天金额可能未就绪**）；item[].date_ms=日期零点毫秒；net_inflow=日净流入元，保留负值与 null。
FFF 可用性: 端外不可用；即便可用，最后一日也要按 null 处理。

## 快讯列表 | GET /api/news/flash/list
鉴权/权限：X-api-key。限流/窗口约束：单次数量与翻页边界由数据提供方决定（未声明具体值）。状态：可用。
参数: tag_id(int,必填,栏目ID) seq(str,必填,不透明序号,首屏传字符串"0")
字段: items[].id/seq 为**十进制字符串**（保留超长整数精度，不要转 number）；tags[].id 为 integer 与前者类型不同；create_time_ms/update_time_ms=上游秒值×1000；encoded_url=密文详情地址，非空；summary/pic_url 可 null；type=快讯类型原值。
FFF 可用性: tag_id 无枚举清单，需自行探测；seq 当游标原样回传。
## 快讯刷新 | GET /api/news/flash/refresh
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: tag_id(int,必填) seq(str,必填,已知最新序号) create_time_ms(int,必填,**必须能整除 1000**)
字段: 同快讯列表；服务端可能返回重复记录，**调用方自行去重**（按 id/seq）。
FFF 可用性: create_time_ms 传秒级会直接失败；轮询要自己做 id 去重。
## 资讯详情 | GET /api/news/article/detail
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: client_type(str,必填,WEB|WEB_ENCRYPTED|PC|PC_LIST,大小写不敏感) encoded_seq(str,必填,密文标识)
字段: 不返回明文 seq；content 为 **HTML**（需按内容安全策略渲染）；publish_time_ms=上游秒值×1000；author/summary/source/is_kuaixun 缺失显式 null；仅返回可对外提供的资讯，不可提供时返回业务错误。
FFF 可用性: encoded_seq 只能从列表的 encoded_url 里取，不能自造；正文必须清洗后展示。
## 公告详情与解读 | GET /api/news/notice/detail
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: seq(str,必填,公告序号)
字段: report_period 仅财报类公告有值，否则 null；summary 可 null（含 notice_type + items[].title/content）；monthly_report_interpretation 可 null（notice_type/has_findings/findings[].blocks[].content_html/summary_html）；guid 可 null。内容均为 HTML 片段。
FFF 可用性: 两个解读块都可为 null，UI 要有"无解读"分支。
## 日期范围异动解读 | GET /api/news/anomaly/analysis
鉴权/权限：X-api-key。限流/窗口约束：**指定 thscode 最多 365 天，全量最多 30 天**；超范围由数据方按结束日截取。状态：可用。
参数: begin_date(str,必填,yyyy-MM-dd) end_date(str,必填,yyyy-MM-dd) thscode(str,否,上游标的编码,**格式待核实**)
字段: items[].analysis_id 可作幂等键；analysis_content 为 HTML；key_word_list 数组或 null；create_time/last_anomaly_time/first_publish_time/tag_code_update_time 四个时间字段**单位未核实**（勿按毫秒解析）；was_truncated=true 表示被裁。
FFF 可用性: 时间字段单位不明是本接口最大坑；**空列表也可能表示服务降级**，不能据此断言期间无异动。
## 热门深度专题 | GET /api/news/topic/hot-list
鉴权/权限：X-api-key。限流/窗口约束：默认且最多 10 条（limit 1–10）；游标分页。状态：可用。
参数: tab_id(int,必填,栏目ID) cursor(str,否,原样回传) limit(int,否,1–10,默认10) important_only(bool,否,默认false)
字段: items[].id 为十进制字符串；url 非空；cover/type/seo_key/propagation_chain/pin_label 可 null；important_flag/pinned_flag 为整数标识原值；source_created_at/source_updated_at 为**原始字符串时间**（非毫秒）；next_cursor 可 null，配合 has_more。
FFF 可用性: 时间字段是字符串不是时间戳，且格式未统一。
## 资讯事件库 | GET /api/news/events/search
鉴权/权限：X-api-key 但仅客户端内可用；**单实例每秒 5 次，超限 code=4001**。限流/窗口约束：size 1–100，默认 20；query ≤200 字符。状态：**客户端专用**。
参数: query(str,否,≤200字符) search_param(enum,否,event_name|event_summary,默认event_name) standard_start_time/standard_end_time(str,否,yyyy-MM-dd) event_grading_score(str,否,逗号分隔如A,B) related_industry_code(str,否) related_concept_code(str,否) size(int,否,1–100,默认20)
字段: total=命中总数（可大于本页）；items[] 含 event_id/event_name/event_summary/standard_time、event_grading{score,score_reason,score_num}、related_industry[]/related_concept[]（code,name,score,score_num,to_stock,influence,correlation,source）、event_subject[]、related_stock[]、same_events[]/related_events[]、news_source、raw_semantic_score；event_time/create_time/publish_time 为**数据源原始字符串**；无分页参数，只返回首页 size 条。
FFF 可用性: 端外不可用；即便接入也无翻页，total 只能看不能取。

## 股票基础信息 | GET /（未提供路径）
鉴权/权限：—。限流/窗口约束：—。状态：**敬请期待**（文档原文：接口正在规划中，将提供基本资料、上市状态、行业归属、市值）。
参数: 无（未定义）
字段: 未定义
FFF 可用性: 不可调用；股票名称需用 /api/meta/tickers/search 或 list 反查，市值需从 prices/snapshot 的 float_market_cap 类字段另取。
## 股票所属同花顺指数查询 | GET /（未提供路径）
鉴权/权限：—。限流/窗口约束：—。状态：**敬请期待**（规划中，将按 thscode 反查所属行业/概念指数集合）。
参数: 无（未定义）
字段: 未定义
FFF 可用性: 不可调用；当前只能"指数→成分股"单向查（a-share-index/constituents/ths-stock-list），无法"个股→板块"。
## 指数概况（基本信息/成分股/权重）| GET /（未提供路径）
鉴权/权限：—。限流/窗口约束：—。状态：**敬请期待**（模块规划中）。
参数: 无（未定义）
字段: 未定义
FFF 可用性: 不可调用；现有替代=a-share-index 的 catalog/ths-index-list + constituents/ths-stock-list + prices/*，但无权重、无历史时点成分。

## 全市场数据导出 | GET /api/dump/market-dumps/<kind>/download-url
鉴权/权限：`/api/dump/**` 用 X-api-key；页面下载按钮走 `/dump/**` 登录态 Cookie（两个入口）。限流/窗口约束：返回 **S3 预签名链接，通常 5 分钟过期**，不可持久化/缓存，每次下载前重新获取。状态：可用。
参数: kind 为路径段：daily-k（10年全量）/ daily-k-10d（最近10交易日）/ adjustment-factors（全量事件）；无查询参数。
字段: 三个 dump 按 dump_id 区分：`a_share_daily_k_1d_none_10y`(daily_k/FULL/years=10)、`a_share_daily_k_1d_none_10d`(daily_k/RECENT_TRADING_DAYS/trading_days=10)、`a_share_adjustment_factors_event_none_all`(FULL)。日K 主键 `(thscode, date_ms)`，列：thscode/currency(CNY)/interval(1d)/adjusted(**none 未复权**)/date_ms/open_price/high_price/low_price/close_price/volume(**股**)/turnover(原币)。复权因子主键 `(thscode, ex_date_ms)`，列：ticker/ex_date_ms/dividend_per_share/per_share_bonus/**allotment_ratio**/**allotment_price**/currency。
FFF 可用性: 两个坑——(1) 日 K 明确是**未复权**，要复权得自己按因子算；(2) dump 的复权因子比 REST 端点**多配股两列**，REST 拿不到配股比例/价格。

## 基金净值 + 区间收益 | GET /api/fund/performance/nav
鉴权/权限：X-api-key。限流/窗口约束：不传 range 时**只返回最新一条**；传了按 nav_date 升序返回区间。状态：可用。
参数: thscode(str,必填,含后缀) range(str,否,week|month|tmonth|hyear|year|twoyear|tyear|fyear) nav_type(str,否,unit|adj|unit,adj,默认unit,adj)
字段: nav_date 毫秒；unit_nav=单位净值，adj_nav=**复权净值，不等同累计净值**；未请求的类型不输出该键。区间收益（GET /api/fund/performance/returns，仅 thscode）返回 return_week/month/tmonth/hyear/year/twoyear/tyear/fyear/nowyear/now，全部**百分数原值**；另有 peer_average_* 同类平均、rank_*/rank_total_* 同类排名与总数（integer）。
FFF 可用性: 两个端点互补但参数模型不同（一个要 range，一个不要）；nav_type 决定字段是否出现，解析不能假设键存在。
## 基金历史业绩指标 | GET /api/fund/performance/indicators-historical
鉴权/权限：X-api-key。限流/窗口约束：**start 与 end 均为必填**（长毫秒戳），此前可选，已改必填。状态：可用。
参数: thscode(str,必填) start(long,必填,毫秒) end(long,必填,毫秒)
字段: item[] 仅 date_ms/rsi_pct(净值波动RSI)/donchian_channel(唐奇安通道)/track_index_pe_ttm_five_year_percentile(跟踪指数PE TTM五年分位)；指标周期固定 DAY_1，不返回顶层 thscode/interval。
FFF 可用性: 缺 start/end 直接 1001；三个指标是不同量纲（RSI 数值、通道 0–1、分位 0–100），不能同轴画。
## 基金最大回撤 | GET /api/fund/performance/drawdowns
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: thscode(str,必填,含后缀)
字段: item[0] 含 thscode/ticker 与 week/month/tmonth/hyear/year/twoyear/tyear/fyear/nowyear/now，均为**百分数原值且为负值**（如 -12.5 表示 -12.5%），不是小数比例。
FFF 可用性: 负号是契约的一部分，取绝对值会掩盖方向；缺周期时该键可能不出现。
## 基金经理投资风格 | GET /api/fund/managers/investment-style
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: manager_id(str,必填,从 fund/profile/detail 的 manager_info 取)
字段: representative_fund_thscode/ticker/name（可 null）；investment_idea 可 null；total_fund_scale 元可 null；industry_preferences 为 **array|object|null 保留上游结构**（已验证样例为年度数组：report_tag + percent[7] + total_fund_scale），**不要在客户端写死成固定长度数组**。
FFF 可用性: industry_preferences 的 percent 数组长度与行业顺序由上游决定，需随包下发映射。
## 基金经理业绩 | GET /api/fund/managers/performance
鉴权/权限：X-api-key。限流/窗口约束：range 必填，无默认。状态：可用。
参数: manager_id(str,必填) range(enum,必填,month|tmonth|year|nowyear|now)
字段: item[] 按日期；date_ms 毫秒；manager_return_pct/peer_return_pct/benchmark_return_pct 均**百分数原值**；benchmark 可能为极大值（样例 4474.72），属里程碑累计口径，不要与同期收益画同一坐标轴。
FFF 可用性: range 缺省即报错；benchmark 与 manager/peer 量纲差异极大，需分轴或归一。
## 基金诊断详情 | GET /api/fund/diagnostics/detail
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: thscode(str,必填,含后缀)
字段: item[0] 含 thscode/ticker/fund_type/peer_code；dimensions/peer_dimensions/probabilities/ranges/resilience/peer_resilience **全部为 object，保留上游结构，字段名未在文档展开**（空对象 `{}` 是合法返回）。
FFF 可用性: 契约未定义内部字段，属"结构不稳定"接口，需要防御式解析与版本探测。
## 基金公司详情 | GET /api/fund/companies/detail
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: company_id(str,必填,从 fund/profile/detail 取,**不能用公司名代替**)
字段: company_id/company_name/company_type；established_date_ms 毫秒；fund_count 家；scale 元（规模）。
FFF 可用性: 只有 ID 入口，无"按名称搜公司"，需先有 profile。
## 基金财务数据（指标/利润表/资产负债表）| GET /api/fund/financials/indicators
鉴权/权限：X-api-key。限流/窗口约束：未声明；三个子端点均为单 thscode。状态：可用。
参数: thscode(str,必填,含后缀)；利润表 /income-statements、资产负债表 /balance-sheets 参数相同
字段: indicators 返回 start_date_ms/end_date_ms/publish_date_ms、distribution_profit(可分配利润)/current_profit(本期利润)/current_income(本期收入)、distribution_share_profit、average_nav_profit_margin、average_share_current_profit、share_nav(单位净值)/sum_share_nav(累计单位净值)、asset_nav(资产净值)、sum_nav_rate/nav_rate（增长率，**百分数原值**）。未披露字段保持 null，不补零。
FFF 可用性: publish_date_ms 与 end_date_ms 不同（披露滞后），做时间序列必须用报告期而非披露日。
## 基金持有人结构 | GET /api/fund/holders/detail
鉴权/权限：X-api-key。限流/窗口约束：merge_scope=all 时最多返回 2 条（merged/separate 各自最新），单一口径最多 1 条；所选口径无数据返回 code=3002。状态：可用。
参数: thscode(str,必填) merge_scope(enum,否,all|merged|separate,默认all)
字段: item[] 每条带 merge_scope 实际口径；report_date_ms 毫秒；ins_position=机构占比/psnl_rate=个人占比/mgmt_staff_hold_rate=员工持有比例，均**百分数原值**（8.88=8.88%）；holder_amount=持有人户数(int)；avg_holder_share=户均份额。
FFF 可用性: 同一基金的两条记录**报告日可能不同**（样例一个 2020、一个 2026），不能并排当同一期比较；3002 要当"暂无披露"而非错误。
## 基金资产配置 + 行业配置 | GET /api/fund/portfolio/asset-allocation
鉴权/权限：X-api-key。限流/窗口约束：未声明。状态：可用。
参数: thscode(str,必填,含后缀)；行业配置 /industry-allocation 参数相同
字段: 资产配置 item[] 含 report_date_ms、stock_ratio_pct/bond_ratio_pct/deposit_ratio_pct/other_ratio_pct，**百分数原值**（82.3=82.3%）。行业配置 item[] 含 report_period(字符串如 "2026Q2")、industry_name、ratio_pct(百分数原值)。
FFF 可用性: 资产配置用毫秒日期、行业配置用 "2026Q2" 字符串，两套时间键无法直接 join。
## QDII 额度 | GET /api/fund/quota/summary
鉴权/权限：X-api-key。限流/窗口约束：未声明；`tab` 必须 URL 编码的 JSON 数组字符串。状态：可用。
参数: tab(str,必填,如 `["nazhi100"]` 编码后 `%5B%22nazhi100%22%5D`)；列表 /list 另加 buy(bool,否,可购过滤,省略不注入默认值)
字段: **data 直接是数组，不套 data.item**；summary 元素 name/unlimited/total_limit/total/buy **全部为字符串**，不做单位换算；list 结构 name→sub_tab[]→fund_list[](thscode 含后缀/fund_name/quota(**null=无限额**)/year(**近一年收益率字符串**)/classify(字符串数组,可 null))。
FFF 可用性: 数值全是字符串、外层不是 item 数组，两处与其它端点不同；未知分类返回空结果而非报错。

## 期货（快照/K线/持仓/仓单/基差/主力合约）
鉴权/权限：X-api-key，与 A 股同一 Key。限流/窗口约束：分时端外**仅当前交易日**（trade_date 仅允许 "0"）；K 线端外**仅日 K**（time_period 仅 day_1）；主力/品种/合约目录多端点无参。状态：可用（F10 宏观指标除外）。
参数: 分时 `GET /api/futures/prices/intraday`:thscode(必填) session(否,pre_market|intraday|post_market,默认intraday) trade_date(否,端外仅"0")；K线 `GET /api/futures/prices/daily`:thscode(必填) start/end(long,否,成对,省略=最近100根) time_period(否,端外仅day_1)；持仓 `GET /api/futures/positions/variety-daily`(date 必填 yyyy-MM-dd)、`/company-variety-daily`(date+varieties 1–5个大写品种)、`/contract-daily`(thscode+variety+date)、`/contract-historical`(thscode+variety+company+start_date,**start_date 须在调用日前一年内，结束日固定调用日**)；仓单 `/warehouse-receipts/historical`(thscode+start_date+end_date)；基差 `/basis/main-continuous-latest`(无参)、`/basis/historical`(thscode+spot_indicator_id 否)；主力 `/contracts/main-continuous-list`、`/main-list`、`/secondary-main-list`、`/commodity-index-list`(均无参)；目录 `/contracts/list`(limit 1–1000 默认100 + offset)、`/contracts/detail`、`/varieties/list`、`/variety-plates/list`、`/calendar/trading-schedule`、`/calendar/session-timeline`。
字段: 分时点 timestamp/price/volume/turnover 均可 null；日 K OHLC+volume+turnover，interval 端外恒 day_1；品种日持仓含 volume/long_position/short_position/net_position 及各自 change、main_close_price/index_close_price/main_settle_price、main_change_ratio(**小数**)；仓单 date/amount/amount_change/equivalent_lots；基差 spot_price/converted_spot_price/close_price/settle_price/close_basis/settle_basis/close_basis_rate/settle_basis_rate（rate 为**小数**）；主力合约含 margin_rate(**小数**)/last_trade_date/last_delivery_date；主连含 minute_visit_count/kline_visit_count。**没有 futures/snapshot 端点**，最新价只能取日 K 末根或分时末点。
FFF 可用性: 对 A 股股票 App 价值低（跨市场、无板块联动字段），**不需要额外权限但需额外的期货合约目录+主力识别链路**；若只做"期货看板"，日 K 端点够用。别按 A 股习惯找 snapshot，不存在。

## 期权（快照/K线/持仓/仓单/基差/主力合约）
鉴权/权限：X-api-key。限流/窗口约束：与期货一致，分时端外仅当前交易日、K 线端外仅 day_1。状态：可用。
参数: `GET /api/options/prices/intraday`(thscode 必填 + session 否 + trade_date 端外仅"0")；`GET /api/options/prices/daily`(thscode 必填 + start/end 成对,省略=最近100根 + time_period 端外仅 day_1)；目录 `GET /api/options/contracts/list`(limit 1–1000 默认100 + offset)、`/contracts/detail`(thscode)、`/varieties/list`(无参)、`/calendar/session-timeline`(thscode)。
字段: 分时 timestamp/price/volume/turnover 可 null；日 K OHLC+volume+turnover；合约目录含 thscode/ticker/name/exchange_code/挂牌与到期日；时间轴含 trade_date/timezone/trade_stages[].trade_period+trade_ranges[].begin_time|end_time(毫秒)、exchange_sessions[].trade_phase+phase_range[]。**没有期权持仓、仓单、基差、主力合约端点**，也没有 snapshot。
FFF 可用性: 对 A 股股票 App 价值最低（期权链与希腊字母均不提供，只有行情的 OHLC 契约），且需自行维护合约→标的映射；无额外权限要求，但**结构性缺口大**（无 IV、无 Greeks、无持仓）。

## 估值数据（计算口径与错误约束）| GET /api/a-share/valuations/snapshot
鉴权/权限：X-api-key。限流/窗口约束：thscodes 单次默认最多 100 个原始 token，**服务端配置，调用方不能覆盖**；无分页、无指标选择、无高低估结论、不提供历史估值。状态：可用。
参数: thscodes(str,必填,逗号分隔,**大小写不敏感,服务端 trim+大写+去重并保留首次出现顺序**,每项须为六位数字+.SH|.SZ|.BJ)
字段: 固定 5 个指标，永不缺键：pe_ttm/pe_mrq/pb_mrq/ps_ttm/pcf_ttm（**均为倍数，非百分数**）；上游空值返回 null、**不补零**；负值与高精度原样返回，服务端不计算、不聚合、不取绝对值、不四舍五入；未返回的股票不生成占位项，全无匹配则 code=0/total=0/item=[]；data.timestamp=上游指标元数据中的**最大有效时间**，非全指标同步时间，无有效时间为 null。
口径: TTM=最近连续 12 个月（约等于最近四个季度）；MRQ=最近一个已披露报告期。两者财务周期不同，同一股票两口径可明显偏离；净利/净资产/经营现金流为负时指标可为负或 null，不可按"越低越便宜"排序。
错误: 1001 缺 thscodes；1002 空 token 或格式非法；1003 超 100 token；3001 不在 A 股代码表；5002/5003 数据源超时/不可用。
FFF 可用性: 无额外权限；但单次 100 只上限不可覆盖，全市场估值得按 100 分批（约 55 次），且 5 个指标全是倍数、不是百分数，展示别加 %；无历史估值，做趋势只能自建落库。

## 跨端点共性坑
1. **涨跌幅百分数 vs 小数混用**：百分数=auction/snapshot 的 auction_pct、limit-up/down-pool 的 price_change_ratio_pct、基金 returns/drawdowns、基金配置 *_pct、prices/snapshot 的 price_change_ratio_pct；小数=dragon-tiger-list 的 change/net_rate、dragon-tiger-stock-institution 的 org_net_rate、department-history 的 change_ratio、auction-stock-opportunities 的 bid_change_ratio、limit-up-statistics 的 seal_rate/promotion_rate、期货基差 *_basis_rate、期货持仓 main_change_ratio。字段名带 `_pct` 才是百分数（唯一例外：limit-up-statistics 的 seal_rate/promotion_rate 不带后缀但已是小数）。
2. **成交量/额单位不统一**：dump 与 prices 的 volume 明示"股"、turnover 为原币；集合竞价 auction_volume 实测为**手**（文档未写），auction_unmatched 单位仍未声明；limit-break-pool 的 turnover 未标单位；基金 snapshot 的 volume/turnover 未标单位。金额类（net_value/seal_money/org_buy_value/net_inflow/scale/quota）多为"元"，但 QDII 额度为字符串。
3. **日期参数三种格式**：`yyyy-MM-dd`（dragon-tiger-*、limit-up-statistics、auction-*、news、futures 持仓/仓单/日历、hk-share）；`yyyyMMdd`（calendar 的 date 字段、futures intraday 的 trade_date、limit-up-ladder 的 date/date_list）；**毫秒戳**（limit-up/down/break-pool 的 date_ms、fund/index/futures K 线 start/end、fund indicators start/end）。混用会直接 1002/1003。
4. **一年窗口限制**：dragon-tiger-list（date 超一年=1003）、dragon-tiger-stock-institution（查询范围一年）、limit-up-statistics（一年）、hot-list 历史榜与排名走势（一年）、futures contract-historical（start_date 在调用日前一年内，结束固定调用日）、calendar/trading-days（固定 [今日-1年,今日]）。**例外**：指数 K 线与基金历史日线为**5 年**窗口，collect 时要分别校验。
5. **分页方式四种**：page/size（均 1-based：auction-opportunities ≤20、department-history ≤30、abnormal-monitor ≤30、limit-*-pool ≤200）；offset/limit（futures/options contracts/list limit ≤1000）；游标（news topic 的 next_cursor+has_more、fund news 的 offset 原样回传、flash 的 seq）；**无分页/固定全量**（dragon-tiger-list 固定全量、limit-up-ladder 固定 30 日×4 只、calendar 固定一年）。total 可为 null，统一用 has_next/has_more 翻页。
6. **重复行不是脏数据**：dragon-tiger-list 的 count>stock_count（同股当日榜+3日榜各一行）；dragon-tiger-stock-institution 的 item 可含 range_days=1 与 3 两条；department-history 同股多次上榜分别保留；hk application-list 保留同公司重复递表；new-concepts 同概念多次新增事件多行；dragon-tiger 席位数组内 department_id 可重复（THS59 机构专用）。所有"按 thscode 聚合"都要先定分组键。
7. **榜单/统计滞后一个交易日**：dragon-tiger-list 省略 date 时取**上一交易日**（今天是交易日也不含当天）；ETF 净流入按 **T+1 次日更新**且 end_date 当天金额可能未就绪；集合竞价需先看 date 是否在 auction-opportunity-dates 集合内、再看 data.mode=real_time|history。
8. **缺省回退语义不同**：limit-*-pool 的 date_ms 省略回退"当前自然日"（非交易日易空）；auction/short-term-benchmark 显式传非交易日**不回退**；dragon-tiger-list 显式传非交易日**直接 1002**；fund/performance/nav 不传 range 只回 1 条。写代码前必须逐端点确认"省略=默认"还是"省略=不限制"。
9. **null 语义分级**：abnormal-monitor 的 end_date_ms=null 表示**仍在监控**（不是缺失）；hk calendar 的 thscode=null 表示**代码未确定**，issue_price=null 表示**只有区间**；valuations 的 null 表示上游无值且不补零；limit-up-ladder 的 seal_nextday=null 表示**无次日参考**（≠false）；turnover-prediction 的 change=null 是输入缺失传播。空数组 `[]` 与 null 不可互换。
10. **同一数据两套契约**：REST 复权因子端点**不含** allotment_ratio/allotment_price，而 market-dumps 的复权因子 Parquet **含**配股两列——推算复权因子必须走 dump 或自行补配股；dump 日 K 是 `adjusted=none`（未复权），不要当复权价入库。
11. **子结构未定义**：fund diagnostics 的 dimensions/peer_dimensions/probabilities/ranges/resilience 与 manager investment-style 的 industry_preferences 均为"保留上游结构"的半开放契约，文档不给字段名，客户端必须做防御式解析与降级。
12. **量纲不可同轴**：基金经理业绩的 benchmark_return_pct（样例 4474.72）与 manager/peer 收益不同量纲；基金 indicators 的 rsi_pct/唐奇安通道(0–1)/PE 五年分位(0–100) 三者不可共用 Y 轴。
