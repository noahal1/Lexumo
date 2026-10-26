# Lexumo 同步后端

Lexumo（Tauri + React 词汇学习应用）的自建账号与多端同步服务。**零第三方依赖**，只用 Node 24 内置模块（`node:http`、`node:crypto`、`node:fs`），数据落盘为每个用户一个 JSON 文件。

唯一的接口契约是仓库根目录的 [`docs/sync-protocol.md`](../docs/sync-protocol.md)，本服务逐字实现该文件。

## 启动

```bash
cd server
npm start
```

默认监听 `http://127.0.0.1:8787`，数据目录为 `server/data/`（已被根 `.gitignore` 排除）。

环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8787` | 监听端口 |
| `HOST` | `127.0.0.1` | 绑定地址（局域网访问可设 `0.0.0.0`） |
| `DATA_DIR` | `<server>/data` | 数据目录；相对路径按进程 cwd 解析 |

冒烟测试：

```bash
curl -s http://127.0.0.1:8787/api/health
# {"ok":true,"version":1}
```

运行测试：

```bash
cd server
npm test
```

测试用 `node:test` + `node:assert`，每个用例独立临时 `DATA_DIR` 与随机端口（`listen(0)`），可并发执行，跑完自动清理。

另有一个手工冒烟脚本，会起服务并用 curl 走一遍注册/登录/推送/拉取/CORS：

```bash
cd server
bash test-utils/verify.sh
```

## 端点一览

所有响应均为 JSON（`204` 除外），错误统一为 `{ "error": "<snake_case_code>" }`。

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/health` | — | `{ "ok": true, "version": 1 }` |
| POST | `/api/auth/register` | — | 注册，成功 `200 { token, email, rev: 0 }`；`409 email_taken`；`400 invalid_email` / `weak_password` |
| POST | `/api/auth/login` | — | 登录，成功 `200 { token, email, rev }`；失败 `401 bad_credentials` |
| POST | `/api/auth/logout` | Bearer | 作废当前令牌，`204` |
| GET | `/api/me` | Bearer | `200 { email, rev }`；令牌无效 `401 unauthorized` |
| POST | `/api/sync` | Bearer | 推送变更 + 拉取 `rev > since` 的记录 |

### `POST /api/sync` 要点

- 请求：`{ "since": 12, "changes": { "lists": [], "words": [], "logs": [], "settings": null } }`
- **先应用后返回**：先在服务端应用本次 `changes`，再返回 `since` 之后的所有记录（含本次刚写入的，带 `_rev` 便于调试）。
- `words` / `lists`：按 `updatedAt` 做 last-write-wins（`incoming.updatedAt >= stored.updatedAt` 才覆盖），墓碑（`deleted: true`）参与同样的比较。
- `logs`：按 `id` 幂等插入，已存在则忽略；支持日志墓碑（`{ "id", "at", "deleted": true }`，用于「撤销上一次评分」），删除会分配新 `rev` 以便传播，拉取时墓碑同样按 `rev > since` 返回。
- `settings`：单条记录，同样按 `updatedAt` LWW；未变化时响应里为 `null`。
- 每个被接受的记录分配 `rev = ++userRev`，`rev` 全局单调递增。
- 请求体上限 8 MB；`changes` 单次超过 5000 条 → `400 { "error": "too_many_changes" }`。
- CORS：`Access-Control-Allow-Origin: *`，允许 `GET, POST, OPTIONS` 与 `content-type, authorization` 头，`OPTIONS` 返回 `204`；不使用 Cookie。

### 契约未明确处的实现选择

| 情况 | 实现 |
| --- | --- |
| 未知路由 | `404 { "error": "not_found" }` |
| 已知路由但方法不对 | `405 { "error": "method_not_allowed" }` |
| 请求体超过 8 MB | `413 { "error": "payload_too_large" }` |
| 非法 JSON / body 不是对象 / 记录缺 `id`、`updatedAt` | `400 { "error": "bad_request" }` |
| `since` 缺失或非法 | 按 `0`（全量拉取）处理 |
| 服务端内部异常 | `500 { "error": "internal_error" }` |

## 数据目录

```
server/data/
├── users.json            # 邮箱 → { id, email, salt, passwordHash, createdAt }
├── tokens.json           # token → { userId, expiresAt }（30 天有效）
└── records/<userId>.json # 该用户的 rev、lists/words/logs 记录与 settings
```

- 密码用 `node:crypto` 的 `scryptSync` + 每个用户随机 16 字节 salt 派生，只存 salt 与 hash，**绝不存明文**。
- 令牌是 `randomBytes(32).toString("hex")`（64 字符 opaque token），有效期 30 天。
- 所有写盘都是「写临时文件 → `rename`」的原子替换，避免进程中断留下半个 JSON。
- 单进程内同步读写 + 内存缓存，一次 `/api/sync` 的「读-改-写」不会被其它请求交错。

## 生产化建议

当前实现适合个人/小团队自建（单进程、JSON 文件、无 TLS）。对外提供服务前建议：

1. **换数据库**：JSON 文件在并发写、数据量增长和备份上会吃力，换 Postgres（或 SQLite + WAL）并把 `rev` 分配放进事务；本项目的存储层接口（`createUser` / `createToken` / `applySync`）可以原样替换。
2. **加限流**：至少对 `/api/auth/*` 按 IP 限流防撞库（如 5 次/分钟），对 `/api/sync` 按用户限流；可加登录失败退避与验证码。
3. **上 HTTPS**：用 Caddy / Nginx 反向代理终止 TLS，只暴露 443；服务本身保持绑定 `127.0.0.1`。桌面客户端配置服务器地址时必须用 `https://`。
4. **令牌与会话**：建议只存令牌的 SHA-256 哈希，支持按设备吊销；可加刷新令牌与过期回收任务。
5. **备份与监控**：定期备份数据目录/数据库；加请求日志、错误率与延迟指标；`/api/health` 接入探活。
6. **多实例**：若要水平扩容，`rev` 分配需改为数据库序列/事务，并保证同一用户请求落到同一写节点（或使用行锁）。

## 目录结构

```
server/
├── package.json          # 只有元信息与 scripts，无 dependencies
├── README.md
├── src/
│   ├── index.js          # HTTP 服务、路由、CORS、鉴权中间逻辑
│   ├── store.js          # 用户 / 令牌 / 记录存储与 LWW、日志去重
│   └── auth.js           # scrypt 密码哈希、邮箱校验、令牌生成
├── test/
│   ├── auth.test.js      # 注册/登录/me/令牌/错误码
│   ├── sync.test.js      # 推送/增量/LWW/日志幂等与墓碑/词条墓碑/settings
│   └── cors.test.js      # CORS 预检与响应头
└── test-utils/
    └── server.js         # 测试用的独立实例（临时 DATA_DIR + 随机端口）
```
