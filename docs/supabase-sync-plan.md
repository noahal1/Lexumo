# Supabase 同步后端：方案与实施路线

> 状态：三步全部落地。本文只记录**决策与依据**，实现细节以代码为准。
> 前置阅读：`docs/sync-protocol.md`（协议本身，187 行）、`docs/flutter-design.md` 第 6 节（当前缺口）。

## 1. 结论

**可行，而且现有协议几乎是为 Supabase 量身定做的。** 原因是它把「合并逻辑」和「传输层」分开了：

- 合并只吃 `ChangeSet` 吐 `ChangeSet`（`src/lib/syncMerge.ts` 262 行），不知道背后是 HTTP 还是 Postgres
- 传输是 `src/lib/sync.ts` 389 行，里面只有 `POST /api/sync` 一个业务端点

换后端 = **只换传输层**，合并逻辑一行不用重写。

## 2. 映射表：自建 Node 服务 → Supabase

| 自建（`server/`，653 行） | Supabase 对应 | 要不要写 |
| --- | --- | --- |
| `POST /api/auth/register`（scrypt + 16 字节 salt） | Supabase Auth | ❌ 不写 |
| `POST /api/auth/login` | Supabase Auth | ❌ 不写 |
| `POST /api/auth/logout` | Supabase Auth | ❌ 不写 |
| `GET /api/me` | `auth.getUser()` | ❌ 不写 |
| `tokens(token, user_id, expires_at)` 表，令牌 30 天 | GoTrue 的 refresh token | ❌ 不写 |
| `users(id, email, password_hash, salt, created_at)` | `auth.users` | ❌ 不写 |
| `POST /api/sync`（269 行 `server/src/index.js` + 323 行 `store.js`） | **一个 Postgres 函数** | ✅ 写 |
| `records` / `meta` 表 | 同构的 SQL 表 | ✅ 写 |

省掉的正是最容易写错的部分（密码哈希、令牌生命周期）。

## 3. 为什么用 RPC 而不是 PostgREST upsert

PostgREST 的 upsert 不支持条件更新：

```sql
-- 想要的是这个，PostgREST 的 on_conflict 给不了
on conflict (user_id, kind, id) do update
  set payload = excluded.payload
  where excluded.updated_at >= records.updated_at
```

绕法是写 BEFORE 触发器静默丢弃旧记录，但那样「写了但没生效」只能靠读日志发现——LWW 冲突是**正常路径**，不是异常，静默丢弃会让它变得不可观测。

改用一个 `security definer` 的函数，一个事务里完成「应用 + 返回增量」，与现有 `POST /api/sync` 的语义一一对应：

```sql
create function public.sync(since bigint, changes jsonb)
returns jsonb language plpgsql security definer set search_path = ''
```

**`security definer` 会绕过 RLS，所以函数体内每一处查询都必须显式带 `where user_id = auth.uid()`。** 漏一处就是越权读。

## 4. 三个已实测的坑

### 4.1 release APK 没有 INTERNET 权限（已修）

`android/app/src/{debug,profile}/AndroidManifest.xml` 有 `<uses-permission android:name="android.permission.INTERNET"/>`，但 `main/` 一个都没有。实测：

```
$ aapt2 dump permissions dist/lexumo-android-release.apk
package: dev.lexumo.lexumo
permission: dev.lexumo.lexumo.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
```

现在不联网所以无影响；接上同步后 **debug 能跑、release 静默失败**，是最难查的一类 bug。
已给 `main/` 补上，并**实测确认进了 APK**：

```
$ aapt2 dump permissions dist/lexumo-android-release.apk
package: dev.lexumo.lexumo
uses-permission: name='android.permission.INTERNET'
```

### 4.2 Windows 桌面端暂时验证不了

`supabase_flutter` 与 `supabase` 的 pub.dev 平台列表都含 Windows，但本机 Windows 构建卡在缺 VS 的 `Microsoft.VisualStudio.Component.VC.CMake.Project`（见 `docs/flutter-design.md` 7.2）。同步写完后只能在 Android 上验证。

### 4.3 选 `supabase` 而不是 `supabase_flutter`

| 包 | 原生插件 | 代价 |
| --- | --- | --- |
| `supabase_flutter` 2.18.3 | `app_links`、`shared_preferences`、`url_launcher`、`http`、`logging` | 5 个，其中 4 个带原生构建步骤 |
| `supabase` 2.16.5（纯 Dart） | 无 | session 持久化自己管 |

选纯 Dart 版。理由是项目本来就不用 `path_provider`（`app_dir.dart` 自己解析路径），`SnapshotStore` 的原子写可以直接复用来存 session。

## 5. token 不能进 `AppData`

TS 版把 `SyncConfig{server, email, token, rev, lastSyncAt}` 存 localStorage（`src/lib/sync.ts:62-89` 的 `readConfig`/`writeConfig`），与 AppData 分开。

Flutter 版必须同样分开，原因是 **`Settings` 会被 `collectChanges` 打包上传**。token 落进 `AppData.settings` 等于把自己的令牌同步给服务器。

约定：`flutter/lib/data/sync_config.dart` 存 `sync.json`，与 `lexumo.json` 并列，同样走原子写。

## 6. 三步路线（全部完成）

### 第一步：导出/导入（✅ 已完成）

纯 Dart 文件 I/O，无网络。移植 `src/lib/transfer.ts`（302 行）→ `flutter/lib/data/transfer.dart`
（394 行），`test/transfer_test.dart` 21 条测试对应 TS 的 21 个 `it`。

为什么先做这个：

1. **它是同步的兜底**——同步出问题时用户至少能把数据手工搬走
2. **它是同步的调试工具**——两端数据不一致时，能导出成 JSON 直接 diff
3. 不依赖任何外部服务，可以完整测试

**一个实测结论改了设计**：`file_selector` 的 `getSaveLocation` 在 Android 上不可用
——它只能选「已存在的文件」，不能指定新文件的保存位置，而导出恰恰需要后者。
所以 Android 侧走平台通道直调 `ACTION_CREATE_DOCUMENT` / `ACTION_OPEN_DOCUMENT`
（`flutter/lib/platform/file_dialogs.dart` + `MainActivity.kt`），桌面端仍用
`file_selector`。这是整个移植里唯一需要写原生代码的地方。

**已在 Android 真机（模拟器）验证**：导出 JSON 落盘 17,844 B，内容为
`version 3 / 14 words / 1 list / 45 logs`，且不含 `pending`、`tombstones`、`_rev`；
导入 CSV（3 行，其中 1 行与现有词重复）→ 预览显示 3 个词 → 确认后词库 14→16，
重复项被跳过。

设置页 UI 见 `settings_page.dart` 的「数据」区段（导出 JSON / 导出 CSV / 导入 / 清空），
`test/settings_transfer_test.dart` 9 条 widget 测试锁住「取消不能报成功」和
「重复不能新增」两条容易写错的语义。

### 第二步：合并逻辑（✅ 已完成）

- `flutter/lib/data/wire.dart`（539 行）← `src/lib/wire.ts`（311 行）：`decodeChangeSet` /
  `encodeChangeSet` / `encodeAppData`，17 条测试
- `flutter/lib/data/sync_merge.dart`（316 行）← `src/lib/syncMerge.ts`（262 行）：
  `collectChanges` / `hasChanges` / `applyRemote` / `applyRound`，36 条测试

合计 53 条测试，正好等于 TS 的 `it` 总数（wire 17 + syncMerge 23 + syncRound 13）。
零网络依赖，全部跑在 `MemoryStore` 上。

移植时做了三个形状上的改动，都不改行为：

1. **记录改成 sealed 类型**（`sealed WordRecord` → `WordEdit` / `WordTombstone`）。
   TS 里 `ChangeSet` 装的是 `Word | Tombstone` 的对象联合，合并靠字段判断；
   Dart 用模式匹配，**墓碑不可能被「编辑」规则误合并**——这个错误现在写不出来。
2. **`_rev` 是结构上不可能，不是被清洗掉**。TS 需要 `encodeAppData` 重建对象，
   因为 `AppData` 可以带任意键；Dart 的 `toJson` 逐字段枚举，没有地方能存 `_rev`。
   重建函数仍然保留，但作用变成归一化（`""` → 缺失的可选字段）。
3. **不可变**。TS 是 clone draft 再 mutate，Dart 每个操作返回新的 `AppData`。

**移植时发现两个 TS 侧的真 bug**（已记录、未修，因为要保证两端行为一致）：

1. `collectChanges` / `applyRemote` 用 `if (at)` 判断墓碑戳存在，而 `0` 是 falsy，
   所以戳为 `0` 的墓碑会被当成不存在。实际不可达（epoch ms），但规则本身是错的。
   Dart 版复现了这个行为（`at != null && at != 0`）并在三处注明。
2. `applyRemote` 的 settings 合并是 `{...data.settings, ...rest}`——**字段级**合并，
   与模块自己「settings 作为一个整体同步」的注释矛盾。现在看起来是整体覆盖，
   只因为 `cleanSettings` 总会填满每个字段。Dart 版直接取 `incoming.settings`，
   这是唯一一处有意的行为分歧，已用测试 `replaces the whole settings record` 钉住。

**已就绪的前置**：`flutter/lib/data/journal.dart`（217 行）已移植完成，含 `touch` /
`bury` / `touchSettings` / `purgeWords` / `settle` / `pendingTotal`。`Store.applyMerged`
（`store.dart:527`）也已就位。

### 第三步：接 Supabase（✅ 已完成）

客户端和服务端两侧都落地并验证过了。**不需要改 `SyncEngine`**——它只认 `SyncTransport`，
两个后端的差别被关在传输层里。

**客户端**

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `flutter/lib/data/sync_transport.dart` | 167 | `SyncTransport` 抽象 + `SyncError` 七种失败 + `CredentialAware` 可选接口 |
| `flutter/lib/data/backend_transport.dart` | 162 | 按服务器 URL 在两条传输之间路由，`SyncEngine` 不知道有两个实现 |
| `flutter/lib/data/supabase_transport.dart` | 320 | GoTrue（signup / password / refresh）+ PostgREST `rpc/sync`；401 时换一次 token 并重试 |
| `flutter/lib/data/sync_config.dart` | 195 | 会话持久化到 `sync.json`，含 `anonKey` / `refreshToken` |
| `flutter/lib/data/sync_engine.dart` | 486 | 登录/注册/退出、轮询、防抖、首轮；Supabase 的 token 刷新回调也在这里接线 |

**服务端**

| 文件 | 作用 |
| --- | --- |
| `supabase/migrations/0001_sync.sql` | 两张表（`sync_records`、`sync_meta`，都启用 RLS 且**不建 policy**）+ `sync(since, changes)` |
| `supabase/tests/sync.sql` | 13 条 SQL 测试，逐条对应参考实现的 12 个测试 + 匿名拒绝 |
| `supabase/tests/shim.sql` | 裸 Postgres 上补 `auth.users` / `auth.uid()` / `authenticated` 角色 |
| `supabase/tests/run.sh` | 一次性容器跑全套，`trap` 清理 |
| `supabase/tests/rpc_bridge.cjs` | PostgREST + GoTrue 的最小替身，让 Dart 客户端能打真 Postgres |
| `supabase/tests/differential.cjs` | 同一串 13 轮操作分别打到两个后端，逐字段 diff |

**四层验证，每层的失败方式都不同**

1. `flutter test` —— 单元 + widget，427 条。假传输，不碰网络。
2. `supabase/tests/run.sh` —— 13 条 SQL 测试，真 Postgres，假客户端。
3. `flutter test test/supabase_e2e_test.dart` —— 5 条，真 Dart 客户端打真 Postgres
   （经 `rpc_bridge.cjs`）。靠 `LEXUMO_SUPABASE_E2E` 开启，默认 skip。
4. `node supabase/tests/differential.cjs` —— 13 轮操作打两个后端，逐字段比对。

第 3 层抓到了一个单元测试抓不到的 bug：一轮同步在**请求之前**就把 `config` 快照下来了，
而 401 换 token 发生在请求**之中**，于是轮末保存会话时用旧快照覆盖了刚拿到的新 refresh
token——下一次启动会拿一个已被服务端作废的 token 去刷新。修法是轮末从 `_config` 重新取
当前值再 `copyWith`。回归测试在 `test/sync_token_rebase_test.dart`（不依赖 Docker）。

第 4 层也做过反向验证：把 words 的 LWW 从 `>=` 改成 `>`，差分立刻报 10/13 轮不同；
改回来回到 13/13 identical。**一个从不失败的测试不算测试。**

**还差什么**

- 真 Supabase 项目上的验证。目前跑的是「真 Postgres + 手写 RPC 垫片」，GoTrue 是
  `rpc_bridge.cjs` 模拟的。真实 GoTrue 的 token 是 JWT，`auth.uid()` 从
  `request.jwt.claim.sub` 读——协议一致，但没在线上项目验证过。
- `supabase/config.toml` 与 `supabase db push` 的部署流程没有走通（本机无 supabase CLI，
  用 Docker 直起 Postgres 替代）。


## 7. 参照实现别扔

`server/`（653 行 Node，零依赖）是 `sync()` 函数最好的参照。它的 `server/test/sync.test.js` 有 12 条测试，覆盖的行为应当照搬成 SQL 测试：

1. 推送后能增量拉回
2. LWW：旧记录被丢弃、较新的接受、**相等也接受**（`>=` 不是 `>`）
3. lists 同样 LWW
4. 日志按 id 幂等（重复推送不产生两条）
5. 日志墓碑按 rev 传播
6. 词条墓碑按 rev 传播
7. settings LWW，未变化时返回 null
8. 超 5000 条 → 400 `too_many_changes`，**且整体不写入**
9. 畸形 changes → 400 `bad_request`
10. 用户数据隔离
11. 重启后持久化
12. `_rev` 只出现在响应里，不出现在备份文件里

第 2 条的 `>=` 和第 8 条的「整体不写入」是最容易在 SQL 重写时丢掉的两条。
