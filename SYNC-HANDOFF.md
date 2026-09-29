# Pulse 交接文档

最后更新：2026-09-29 18:00（WorkBuddy 收尾）

## 先读这个（2026-09-29 下午续记）

**工作区状态**：改动全部已 commit + push，`main` 与 `origin/main` 同步，工作区干净。今天共 **4 个 commit**：

| commit | 内容 |
|---|---|
| `ce3286e` | Mac 间同步功能（iCloud 占位符、缓存 UUID 一致性） |
| `a045c86` | 钉住窗口加宽 340 → 520pt |
| `910ff9a` | 交易手续费 + 成本口径切换（加权/摊薄）+ 总盈亏 |
| `08513a5` | 投资逻辑（thesis）字段 |

**完整开发记录在 `.workbuddy/memory/2026-09-29.md`**（很长，含全部踩坑过程与代码细节）；长期项目笔记在 `.workbuddy/memory/MEMORY.md`。**接手前先读这两份。**

### 今天新踩的坑（memory 里有详细版）

1. **本地化条目必须整行匹配** —— 用 Edit 加 `.strings` 条目时，若 `old_string` 只取 key 而不含 `= "value";`，行尾会残留成 `"..."; = "持仓";`，**一行两个 `=` 会让整个表从该行起失效，界面全变成原始 key**。且 **`plutil -lint` 报 OK，抓不到这个问题**。
2. **`.sheet` 在 accessory 应用里会关掉整个窗口** —— App 是 `LSUIElement`（无 Dock 图标），sheet 是独立窗口，点输入框抢焦点失败 → 窗口被系统关闭。**改用页内内联编辑。**
3. **`Menu` 会同时压缩 label 的宽和高** —— 放 `stat`（依赖 `maxWidth: .infinity`）会宽度塌陷，放两行 VStack 会裁掉第二行。**改用 `Button` + `.buttonStyle(.plain)`。**
4. **`.app` 目录的 mtime 不更新** —— Xcode 增量构建只重写 `Contents/MacOS/` 里的二进制；判断版本要看**二进制**的时间。
5. **macmini 上的 `rsync` 是 openrsync**，不认 `--delete`，报 `server receiver mode requires two argument`。**用 `scp -r`。**
6. **新字段要接 5 条链路**（`WatchItem` 手写 Codable 的 4 处 + `normalizedItems` 去重合并 + `mergeItem` 三方合并 + 归档导入导出 + MCP）—— 少接一条就**静默丢数据**，尤其同步那条。

### 待办

- **iCloud 双机实测**（唯一没做的）：macmini 打开 `~/Applications/Pulse Dev.app` → 选 `iCloud Drive/PulseSyncTest` → 与本机双向同步。**本机已配置好并写出了同步文件，iCloud 链路已验证通**（macmini 已收到同一文件）。
- macmini 的**屏幕共享仍连不上**：需在它的「系统设置 → 通用 → 共享」里关掉「远程管理」、打开「屏幕共享」（两者互斥）。
- macmini **只有 CommandLineTools、没有完整 Xcode** → 不能构建。跑新版要在本机构建后 `scp` `.app` 过去。

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

没有执行网站更新日志、版本发布、提交或推送；不应把原项目的下一版本号直接当作这个 fork 的发布计划。
