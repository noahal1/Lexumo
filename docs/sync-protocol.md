# 同步协议 v1

Lexumo 的账号与多端同步协议。客户端（Tauri/浏览器）与自建后端都按本文实现，改动必须同步更新两端与本文件。

## 设计要点

- **本地优先**：所有数据先写本地，同步是后台增益。断网、未登录、服务端故障时应用完全可用。
- **整条记录同步**：以 `Word` / `WordList` / `ReviewLog` / `Settings` 为同步单元，不做字段级 diff。
- **冲突策略**：词条、词库、设置按 `updatedAt` **last-write-wins（LWW）**；复习日志**只追加、按 `id` 去重取并集**（日志不可变，天然幂等）。
- **删除用墓碑**：删除不传播记录本身，而是上传 `{id, deleted: true, updatedAt}`；客户端保留 `AppData.tombstones` 以便再次推送。
- **增量拉取**：服务端为每条记录维护一个单调递增的 `rev`，客户端保存 `lastRev`，只拉 `rev > lastRev` 的记录。

## 传输

- 纯 HTTP + JSON，UTF-8。
- 默认监听 `8787`（`PORT` 环境变量可改），可用 `HOST` 指定绑定地址。
- 鉴权用 `Authorization: Bearer <token>`（opaque token，非 JWT）。
- CORS：允许任意 `Origin`，允许 `GET, POST, OPTIONS`，允许 `content-type, authorization` 请求头，**不使用 Cookie**。
- 请求体上限 8 MB；`changes` 单次最多 5000 条记录。

## 数据结构

```ts
type WordStatus = "new" | "reviewing" | "learning" | "mastered";
type Grade = "hard" | "good" | "easy";

interface SrsState {
  ease: number;            // [1.3, 2.5]
  intervalDays: number;    // [1, 3650]
  dueAt: number;           // epoch ms
  reviewCount: number;
  correctCount: number;
  lastReviewedAt: number | null;
}

interface WordRecord {
  id: string;
  term: string;
  phonetic?: string;       // IPA, no slashes
  pos?: string;            // part of speech, space separated (`"n. v."`)
  definition: string;
  definition2: string;
  example: string;
  exampleZh?: string;      // translation of `example`
  note: string;
  status: WordStatus;
  favorite: boolean;
  listId: string;
  sourceLang: string;
  targetLang: string;
  listenCount: number;
  srs: SrsState | null;
  createdAt: number;
  updatedAt: number;
  deleted?: true;          // 墓碑：只需 id / updatedAt / deleted
}

interface ListRecord {
  id: string;
  name: string;
  sourceLang: string;
  targetLang: string;
  createdAt: number;
  updatedAt: number;
  deleted?: true;
}

interface LogRecord {
  id: string;
  wordId: string;
  grade: Grade;
  at: number;
  intervalBefore: number;
  intervalAfter: number;
}

interface SettingsRecord {
  theme: "light" | "dark" | "system";
  uiLang: "zh-CN" | "en";
  dailyGoal: number;
  ttsRate: number;
  ttsVoiceURI: string;
  autoPlayAudio: boolean;
  audioFirst: boolean;
  newCardsPerDay: number;
  reviewOrder: "due" | "random";
  updatedAt: number;
}

interface ChangeSet {
  lists: ListRecord[];
  words: WordRecord[];
  logs: LogRecord[];
  settings: SettingsRecord | null;
}
```

服务端在响应记录上额外附带 `_rev: number`（客户端可忽略，仅用于调试）。

## 端点

### `GET /api/health`

```json
{ "ok": true, "version": 1 }
```

### `POST /api/auth/register`

请求 `{ "email": "a@b.com", "password": "至少 8 位" }`

- `200 { "token": "...", "email": "a@b.com", "rev": 0 }`
- `409 { "error": "email_taken" }`
- `400 { "error": "invalid_email" }` / `{ "error": "weak_password" }`（< 8 字符）

邮箱比较前统一 `trim().toLowerCase()`。密码用 `scrypt`（随机 16 字节 salt）加盐存储，**绝不存明文**。

### `POST /api/auth/login`

请求 `{ "email", "password" }` → `200 { "token", "email", "rev" }`，失败 `401 { "error": "bad_credentials" }`。

### `POST /api/auth/logout`

`Authorization: Bearer <token>` → `204`。令牌作废（服务端删除）。

### `GET /api/me`

`Authorization: Bearer <token>` → `200 { "email": "...", "rev": 0 }`，令牌无效 `401 { "error": "unauthorized" }`。

### `POST /api/sync`

`Authorization: Bearer <token>`

请求：

```json
{ "since": 12, "changes": { "lists": [], "words": [], "logs": [], "settings": null } }
```

处理顺序（**先应用后返回**）：

1. 校验令牌，取该用户的当前 `rev`。
2. 逐条应用 `changes`：
   - `words` / `lists`：若 `incoming.updatedAt >= stored.updatedAt` 则覆盖，否则丢弃；被接受的记录分配 `rev = ++userRev`。墓碑同样按 `updatedAt` 比较。
   - `logs`：按 `id` 插入，已存在则忽略；新插入的分配 `rev = ++userRev`。
   - `settings`：若 `incoming.updatedAt >= stored.updatedAt` 则覆盖并 `rev = ++userRev`。
3. 返回 `since` 之后的所有记录（含本次刚写入的，方便客户端对齐）：

```json
{
  "rev": 42,
  "serverTime": 1730000000000,
  "changes": { "lists": [], "words": [], "logs": [], "settings": null }
}
```

返回的 `changes` 只包含 `rev > since` 的记录；`settings` 为 `null` 表示该区间内未变。

### 日志墓碑

客户端支持「撤销上一次评分」，会删除一条复习日志。为了让删除也能传播，`LogRecord` 同样支持墓碑形态：

```json
{ "id": "r_abc", "at": 1730000000000, "deleted": true }
```

应用规则：

- `incoming.deleted === true`：删除该 `id` 的日志（不存在则忽略），并 `rev = ++userRev`，使删除能传播给其它客户端；
- 否则按 `id` 插入，已存在则忽略；
- 拉取时日志墓碑同样按 `rev > since` 返回。

## 客户端同步算法

1. 未登录 / 未配置服务器 → 跳过。
2. 组装 `changes`：本次待推送的记录（含墓碑）。
3. `POST /api/sync { since: lastRev, changes }`。
4. 应用返回的 `changes`：对每条记录，若本地同 id 记录**尚未推送**且 `local.updatedAt > remote.updatedAt`，保留本地（下一轮再推）；否则覆盖本地。
5. `lastRev = rev`，清空已推送的待办，记录 `lastSyncAt = serverTime`。
6. 失败（网络/401）时保留待办，下次重试；401 时提示重新登录。

## 存储（参考实现）

- `node:sqlite`（Node 24 内置，零依赖）或每用户一个 JSON 文件，二选一。
- 表/结构：`users(id, email, password_hash, salt, created_at)`、`tokens(token, user_id, expires_at)`、`records(user_id, kind, id, rev, updated_at, payload_json)`、`meta(user_id, rev, settings_payload, settings_rev)`。
- 令牌有效期 30 天。
- 数据目录默认 `server/data/`（`DATA_DIR` 可改），需在 `.gitignore` 中排除。
