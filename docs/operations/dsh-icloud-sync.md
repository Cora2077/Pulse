# DSH iCloud Sync 插件设计(v1)

> 目标:两台 Mac 上的 DeepSeek Harness(DSH)**插件清单 + 配置层**通过 iCloud Drive 自动双向同步,
> 任一台改动,另一台在下一次心跳内自动采纳并热生效;冲突可恢复、永不静默丢数据。
> 机密(凭据/会话/账号池)**明确不同步**。

---

## 1. 现状盘点(本机实勘结论)

| 事实 | 位置 | 说明 |
|---|---|---|
| 插件=bundle 声明 | `~/.dsh/profiles/desktop/package.json` → `dsh.profile.bundles` | 安装了哪些插件、什么版本(pnpm 依赖) |
| 全部用户配置 | `~/.dsh/profiles/desktop/cordis.patch.yml` | 模型路由、UI 偏好、MCP 服务器、每个插件的 config 覆盖 |
| 版本排除钉子 | `~/.dsh/profiles/desktop/pnpm-workspace.yaml` | `minimumReleaseAgeExclude` 等安装策略 |
| 精确锁版本 | `~/.dsh/profiles/desktop/pnpm-lock.yaml` | 决定两台机器装到完全相同的版本 |
| reload 机制 | DSH `pluginManager` 服务 | "Manage profile files and apply their declared reload lifecycle" —— **改文件即热重载,插件只需正确落盘** |
| iCloud | `~/Library/Mobile Documents/com~apple~CloudDocs/` | 本机实测可写 |

**判定:同步"清单+配置层"四个文件 ≈ 同步了整个插件/配置状态。** 不需要碰 node_modules(各机自行 `pnpm install`)。

### 明确排除(allowlist 之外一律不碰)
- `~/.dsh/.credentials.yaml`、`.workbuddy-pool*.json` — 密钥/账号,绝不入 iCloud
- `~/.dsh/sessions|storages|attachments|pet.json` — 会话与机器本地状态
- profile 内 `.dsh-market/`(region/discovery 缓存)、`.plugin-manager/logs/`
- `cordis.yml`(生成的基础层,两机同源,无需同步)

---

## 2. iCloud 同步区布局

```
~/Library/Mobile Documents/com~apple~CloudDocs/DSHSync/
├── manifest.json                    # 单一真源: {rev, deviceId, updatedAt, files:{<relpath>:{sha256,size}}}
├── devices.json                     # 设备登记 {hostname: {model, lastSeen}}
├── profiles/desktop/                # 每个要同步的 profile 一个目录
│   ├── package.json
│   ├── cordis.patch.yml
│   ├── pnpm-workspace.yaml
│   └── pnpm-lock.yaml               # 可选(配置项 syncLockfile,默认开)
├── plugin/dsh-icloud-sync-<ver>.tgz # 插件自身打包,供第二台 Mac 引导安装
├── install.sh                       # 第二台 Mac 的一键引导脚本
└── conflicts/                       # 冲突/被覆盖侧的完整备份,永不自动删
    └── desktop-cordis.patch.yml-<epoch>-<device>.yml
```

## 3. 同步算法(每 profile 独立状态机)

本地状态存 `~/.dsh/icloud-sync/state.json`(**不在**同步区内):`lastAppliedRev`、`lastPublishedHashes`、`deviceId`。

触发:`fs.watch` 两侧目录(2s 防抖)+ 每 30s 心跳兜底 + 启动即跑一轮。
(iCloud 经 fileproviderd 更新,Node 的 watch 偶尔不触发事件 → 心跳轮询是正确性兜底,watch 只是降延迟。)

一轮的决策表(先读远端 manifest,再算本地四文件 sha256):

| 远端 rev vs 本地 | 本地内容 vs 远端内容 | 动作 |
|---|---|---|
| 相同 | 相同 | 无事 |
| 远端更新 | 相同 | 仅采纳 `lastAppliedRev = rev` |
| 远端更新 | 本地即远端已发布版本的旧貌(无新本地改动) | **远端赢**:本地先备份到 conflicts/(保留最近 5 代滚动),原子写远端内容,触发 reload |
| 远端未动 | 本地自上次发布后有新改动 | **本地赢**:原子发布到 iCloud,`rev+1` |
| 双方都动过(真冲突) | — | **合并优先**:package.json 按 dep 求并集+取高版本、bundles 列表并集;YAML 无可靠合并 → 远端版落地生效,本地版整份存入 conflicts/ + 系统通知;`rev+1` |

关键实现细节:

1. **全部原子写**:先写 `.tmp` 再 `rename`,manifest 用 rename 实现单写者 CAS;rename 失败即让位重读(防两台 Mac 同时在线互踢)。
2. **写入前先校验**:YAML/JSON parse 不通过的远端内容**绝不落盘**到 profile(防坏数据打挂另一台 DSH), parked 到 conflicts/ + 通知。
3. **Dataless 文件**:iCloud"优化存储"下文件可能未下载,读超时(5s)后走 `brctl download <path>` 兜底再重试一次。
4. **每次 apply 前**把本地现状滚动备份(5 代),`conflicts/` 永不清理 —— 静默丢数据为零容忍。

## 4. 生效路径(不重造 reload)

- **仅 patch/配置变化**(最常见:改模型、改 UI、改 MCP):pluginManager 本就监听 profile 文件,写完即热重载。插件不调用任何私有 API。
- **bundle 清单变化**(装/卸/升级插件):插件对 profile 目录执行 `pnpm install`(nodeLinker 已是 hoisted),lockfile 同步保证两机版本一致;DSH 自身的 reload 生命周期接管;若该 bundle 需要 host 级重启,发系统通知提示"重启 DSH 生效"(诚实边界:跨进程组合无法全部热插)。

## 5. 插件形态(host 侧单半边,v1 不做 Web UI)

```
@cora/dsh-icloud-sync          # npm 包,bundle 形态
├── package.json               # dsh.bundle.patch → cordis.patch.yml: insert {id: icloud-sync, name: 本包}
├── cordis.patch.yml
└── lib/index.js               # Service 注册
```

- **Service `icloudSync`**:`status()`、`syncNow(profile?)`、`adoptRemote()`、`publishLocal()` —— 全部可从会话里直接驱动。
- **Config(schemastery)**:
  ```yaml
  icloud-sync:
    enabled: true
    folder: DSHSync              # CloudDocs 下的目录名
    profiles: [desktop]          # 未来可加 headless
    syncLockfile: true
    pollIntervalSec: 30
    applyMode: auto              # auto | notify(只通知不自动改)
    deviceId: auto               # 默认 scutil --get ComputerName
  ```
- **Command `/sync`**:手动立即同步 + 打印两机状态表。
- 状态心跳顺带刷新 `devices.json`,GUI/会话里能看见"另一台上次在线时间"。
- (可选彩蛋,v1.1)冲突/生效事件转发给 dsh-pet 的 `pet.announce` 气泡。

## 6. 第二台 Mac 引导(解决先有鸡还是先有蛋)

`install.sh` 存在 iCloud 同步区内,第二台 Mac 只需:
```
bash "/Users/<name>/Library/Mobile Documents/com~apple~CloudDocs/DSHSync/install.sh"
```
脚本职责:① 检测/创建 `~/.dsh/profiles/desktop`;② 现有 package.json / patch 先备份;
③ 从 `plugin/*.tgz` 安装本插件进 profile(bundle 行 + 依赖);④ 首启由插件自动采纳 iCloud 现状。

## 7. 安全与红线

- **allowlist 硬编码**四个文件,任何配置都加不进凭据/会话类路径;路径一律先 resolve 再前缀校验。
- iCloud 属用户私有 Apple ID,但仍按"半可信"对待:parse 校验 + 备份 + conflicts 兜底。
- v2 预留:同步内容用 age 加密、密钥入 login Keychain。

## 8. 里程碑与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 | 插件骨架 + status/syncNow/手动发布-采纳 | 单机跑通,`/sync` 输出正确哈希表 |
| M2 | watch + 心跳 + 决策表 + 原子写/备份 | 本机改 patch → iCloud 目录 30s 内出现新 rev |
| M3 | pnpm install 联动 + 引导脚本 | (模拟第二目录)全新 profile 从 iCloud 拉齐并热生效 |
| M4 | 真机两台联调:单边改/双边冲突/离线重连 | 三场景各演练一次,conflicts/ 备份齐全,零丢数据 |

**已知取舍**:lockfile 冲突时 last-writer-wins(版本短暂漂移到下次发布,可接受);双机同时在线的写竞争由 rename-CAS 化解;`settings` 服务存储的运行时设置(非 patch 层)v1 不覆盖。
