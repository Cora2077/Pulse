# 回家接力：历史复盘入口验收（2026-10-16）

## 同步与范围

- `main` 从 `fe2459f` 安全快进到 `c1f91ba`，同步前工作区干净；没有 reset、自动提交或推送。
- 按 [接力说明](<../development/HOME-HANDOFF.md>) 先补历史复盘闭环，不重新设计 Mac 的业务口径。
- [今日页](<../../PulseIOS/Sources/Views/TodayView.swift>) 的“补齐历史复盘”使用 [根导航](<../../PulseIOS/Sources/Views/WorkbenchFoundation.swift>) 的类型化账户分区动作：清理账户页旧导航路径，再切到复盘分区。
- [账户页与复盘编辑器](<../../PulseIOS/Sources/Views/AccountView.swift>) 为输入框提供明确的无障碍名称和稳定测试身份；把原有保存合并逻辑提取为可测试函数，保留未展示的下次检查点。只更新复盘，不改变成交事实或计划。
- 实际深色大字截图暴露了当前账户卡片在横向选择器中被裁掉的问题。选择器现根据当前账户定位视口，给当前卡片提供 selected 无障碍状态；滚动位置与真实账户选择分开，横向滚动不会切换账本。UI 回归同时检查当前账户整张卡片位于屏幕内。
- [应用单测](<../../PulseIOSUnitTests/WorkbenchStateTests.swift>) 覆盖检查点保留、显式清空、过期草稿拒绝不变、备注/空白复盘不算完成及校准排除。
- [UI 测试](<../../PulseIOSUITests/WorkbenchUITests.swift>) 覆盖已访问过流水页后的跳转、同一成交的真实保存和积压消失，以及深色大字下取消草稿不写入。

## 本机验证

共享回归全部通过：PulseCore **1033**、PulseMobile **85**、PulseSync **52**、PulseActivity **101**、PulseUI **49**、Node 推送桥 **152** 项。这里按实际本机输出记数，不照抄较早交接文档。

Mac 使用已有稳定签名编译通过；隔离的 workflow、review-boundary（61 个检查）和 trade-history（19 个合成渲染）自测通过。trade-history 首次调用因缺少其必需的 `--trade-history-demo` 参数被拒绝，带齐隔离参数后通过，不是源码回归。

已更新[日用应用](</Users/cora/Applications/FFF.app>)：替换前核对 bundle ID 和完整 designated requirement 相同，保留旧应用包备份；替换后验证深层签名、从已安装路径运行隔离 workflow 自测通过，并确认正常进程来自该安装路径。没有切换证书、ad-hoc 覆盖或手动修改真实账本。

iPhone 原生验收：

- iPhone 18 Pro：20 项应用单元测试 + 9 项 UI 测试通过（账户视口修复前的完整回归）；视口修复后，再跑 2 项历史复盘/深色大字 UI 测试通过，含当前账户选中状态及卡片完整可见的断言。
- 小屏 iPhone 17e：最终源码的 20 项应用单元测试 + 9 项 UI 测试全部通过，包含原有空成交价、部分执行、新建计划搜索取消保存、排序面板、系统 ActivityKit 和深色大字验收。
- 已目检真实模拟器导出的[保存结果](<home-review-20261016/history-review-saved.png>)与[小屏深色大字当前账户](<home-review-20261016/dark-large-current-account.png>)：复盘归类与内容正确，当前账户卡片完整显示，编辑器取消/保存可操作。所有图片均为合成数据。
- 最终本机结果包：[小屏完整回归](</tmp/pulse-home-ios-small-final.xcresult>)、[较大屏针对性复验](</tmp/pulse-home-ios-review-final.xcresult>)；测试未访问真实 iCloud 或 APNs。

`git diff --check` 通过；没有运行中的测试或工人任务，修改保留在本地工作区，尚未提交。

### 首轮发现与修复

首轮原生测试 20 项单元测试、7 项既有 UI 测试通过，新增 2 项 UI 测试失败。导出的真实无障碍层级表明：给复盘 `VStack` 添加的容器 identifier 向下传播，覆盖了成交行各自的 identifier。已去掉多余容器 identifier，保留每条成交的独立身份；没有改用模糊文案查询来掩盖失败。

图形入口更正：本机 Xcode 27 的模拟器窗口由 Device Hub 提供，旧的 Simulator 应用包路径不存在，并不等于缺少图形界面。随后已实际打开并确认 iPhone 17e 窗口可见，运行最新版合成演示；此前命令行 XCTest 和原生截图验收有效，未用网页替代。打开入口：

```bash
open /Applications/Xcode.app/Contents/Applications/DeviceHub.app
```

## 工人与边界

- 按当前分工尝试 Step-5-Preview 测试工人；它反复扫描同一组 API、没有写入测试，被终止并收齐输出。主代理自行完成实现和验证，没有静默改用其他模型。
- 自动验收始终使用隔离合成数据，没有导入办公室或真实账户记录。
- iCloud 双设备、APNs 真机链路、Watch 镜像、物理 iPhone 安装仍未验收。其余 Mac 独立页面尚未完整移植，不能把本项复盘闭环当成所有 Mac 功能对齐完成。
