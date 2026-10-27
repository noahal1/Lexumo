# Lexumo · 词砚

Lexumo（词砚）是一个安静的桌面背单词工作室：把生词研进词砚，用间隔重复一点点记住它们。

项目参考开源桌面词汇应用 **[Lingueez](https://lingueez.app)**（Python + PySide6，作者 Yurii Lysak）的功能理念，用 **Tauri 2 + React 19 + TypeScript + Vite 7** 重新实现。界面以中文为主，视觉基调是暖纸色背景与玉绿色点缀；数据默认全部保存在本机，不注册、不联网即可使用，需要多设备时可选接入自带的同步后端。

![Lexumo 界面](docs/app-ui.png)

> 界面截图。桌面窗口在 150% 缩放的测试机上会被系统二次缩放，为避免排版失真，此图直接取应用前端在 Chromium / WebView2 中渲染后的结果。

## 功能

- **词库管理**：多词库、增删改查、搜索、状态筛选、标签筛选、排序、收藏；每条词条包含主释义、补充释义、例句、笔记、标签。
- **添加时自动翻译**：新建词条时输入单词并失焦，自动查词典填入释义、补充释义、例句与音标；可一键「重新翻译」强制覆盖。桌面版通过 Rust 代理查有道词典（音标 + 词性 + 双语例句），网页版降级到有道 / MyMemory / Google 机器翻译链；结果缓存 30 天，命中限流时自动冷却换源，查不到不阻塞手动填写，设置里可整体关闭。
- **间隔重复**：SM-2 变体调度，评分分为 `easy / good / hard`；ease 限制在 `[1.3, 2.5]`，间隔限制在 `[1, 3650]` 天；卡片状态由已获得的间隔推导：`new → reviewing → learning → mastered`。
- **闪卡复习**：四种组卡方式（到期卡片 / 新卡片 / 全部词语 / 收藏词语，各自显示数量）、到期队列 + 新卡队列（受每日新卡上限约束）、翻面后仍保留词形、评分按钮上直接预览「下次间隔」、可随时「撤销上一次」评分或跳过、中途可「结束本轮」、键盘快捷键、自动/手动 TTS 发音。
- **测验**：看词选义 / 看义选词双向模式，4 选 1，即时对错反馈，结束页给出错题列表；测验不写入 SRS。
- **统计**：总词数、已掌握、今日复习、连续天数、每日目标环、状态分布、学习活动柱状图（7 / 30 / 90 天可切换）、评分分布、记忆留存率、逾期词数。
- **设置**：主题（浅色 / 深色 / 跟随系统）、界面语言（简体中文 / English）、每日目标、每日新卡上限、复习顺序、TTS 语速与音色、听力模式、自动翻译开关与翻译缓存管理、账号与同步（服务器地址 / 登录注册 / 自动同步开关 / 立即同步）。
- **导入 / 导出**：JSON 快照、CSV 表格、Anki TXT 三种格式。
- **多端同步（可选）**：仓库自带一个零依赖的 Node 同步后端（`server/`），注册账号后可在多台设备间增量同步词库、词条、复习日志与设置。本地优先：不登录、不联网也能完整使用，登录后离线改动会在恢复网络时自动补推。冲突按 `updatedAt` 后写胜出（LWW），删除以墓碑传播，日志按 id 并集去重。侧栏与设置页实时显示同步状态与待同步条数，可关闭自动同步。
- **本地优先**：IndexedDB 单快照持久化，localStorage 兜底；默认无账号、无遥测，同步是可选的。
- **界面与可用性**：暖纸色 / 深色双主题（跟随系统），侧栏可折叠为图标栏，启动骨架屏，词条行悬停才显示操作区，搜索命中高亮；全局快捷键与「?」快捷键帮助；弹窗带焦点陷阱，正文对比度满足 WCAG AA。

## 键盘操作

界面内所有操作都可以用键盘完成，按 <kbd>?</kbd> 随时打开快捷键帮助。

| 按键 | 作用 |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>1</kbd> … <kbd>5</kbd> | 切换词库 / 闪卡 / 测验 / 统计 / 设置 |
| <kbd>?</kbd> | 打开或关闭快捷键帮助 |
| <kbd>/</kbd> | 聚焦搜索框（词库页） |
| <kbd>n</kbd> | 新建词条（词库页） |
| <kbd>Space</kbd> | 翻开 / 盖上闪卡 |
| <kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> | 闪卡评分（困难 / 良好 / 简单） |
| <kbd>Ctrl</kbd>+<kbd>Z</kbd> | 撤销上一次闪卡评分或跳过 |
| <kbd>←</kbd> <kbd>→</kbd> | 跳过当前卡片 |
| <kbd>A</kbd>–<kbd>D</kbd> 或 <kbd>1</kbd>–<kbd>4</kbd> | 选择测验选项 |
| <kbd>Enter</kbd> | 测验下一题 |
| <kbd>Esc</kbd> | 关闭弹窗 / 清空搜索 |

> 在输入框内输入时，单键快捷键会自动让位，不会误触发。

## 手机与触屏

界面按窗口宽度自适应，不区分平台——手机浏览器、平板、桌面窗口都走同一套布局。

| 宽度 | 布局 |
| --- | --- |
| ≥ 1000px | 完整侧栏 + 多列列表 |
| 720–1000px | 侧栏收成图标轨道（rail） |
| < 720px | 侧栏隐藏，底部五标签栏导航；弹窗变成底部抽屉 |

触屏适配的几处细节：

- 底部标签栏常驻五个顶级页面，闪卡标签带到期数量徽标；切换页面时滚动位置自动回到顶部。
- 词库行在手机上收成「词形 + 释义（两行截断）+ 状态」三块，行内只保留发音按钮；收藏、编辑、删除移入编辑器。
- 弹窗以底部抽屉呈现，高度不超过视口，操作按钮留在拇指区。
- 表单控件字号固定 16px，避免 iOS 聚焦时强制放大。
- 按钮、开关、滑块、标签的最小触控尺寸按 38–44px 排布，并适配 `safe-area-inset-*`（刘海与手势条）。
- 触屏不依赖 hover：行操作在手机上始终可见，桌面端仍是悬停显示。

## 技术栈

| 层次 | 选型 |
| --- | --- |
| 桌面壳 | Tauri 2（Rust，系统 WebView2 / WebKitGTK / WKWebView） |
| 前端框架 | React 19 |
| 语言 | TypeScript 5.8（`strict` + `noUnusedLocals` + `noUnusedParameters`） |
| 构建 | Vite 7（固定端口 1420，`strictPort`） |
| 测试 | Vitest 3（纯函数用 Node 环境，整应用冒烟测试用 jsdom） |
| 持久化 | IndexedDB（`lexumo` 库，单键快照）+ localStorage 回退 |
| 发音 | Web Speech API（`speechSynthesis`） |
| 查词 / 翻译 | Rust 侧 `reqwest` 代理有道词典 JSON API（桌面）；浏览器降级到有道 `trans` → MyMemory → Google |
| 同步后端 | Node 24（`node:http` + `node:fs`，零第三方依赖），每用户一个 JSON 文件 |
| 同步协议 | 自建 JSON API，见 [`docs/sync-protocol.md`](docs/sync-protocol.md)：增量 `rev`、LWW、墓碑删除、日志并集 |
| 样式 | 原生 CSS（设计令牌 + 全局样式），无 UI 框架 |
| 图标 | Pillow 脚本生成，衬线体「L」字形 |

## 目录结构

```text
.
├── index.html                  # 单页入口，标题「Lexumo · 词砚」
├── package.json                # 脚本：dev / build / preview / test / tauri:*
├── vite.config.ts              # @ → ./src，端口 1420，outDir dist
├── vitest.config.ts            # 测试配置：environment node，@ 别名，包含 .ts/.tsx
├── tsconfig.json               # 前端 TS 配置（strict，include: src）
├── tsconfig.node.json          # vite/vitest 配置文件的 TS 配置
├── LICENSE.txt                 # GNU AGPL-3.0 全文
├── NOTICE                      # 上游署名与 AGPL-3.0 §7(b) 附加条款
├── THIRD-PARTY-LICENSES.md     # 第三方组件许可
├── docs/
│   ├── app-ui.png              # README 界面截图
│   └── sync-protocol.md        # 同步接口契约（后端与客户端共同的唯一规范）
├── server/                     # 自建同步后端（零依赖 Node）
│   ├── package.json            # npm start / npm test
│   ├── README.md               # 部署、环境变量、端点说明
│   ├── src/
│   │   ├── index.js            # HTTP 路由、CORS、body 限制
│   │   ├── auth.js             # 注册/登录/登出、scrypt 口令、令牌
│   │   └── store.js            # 每用户 JSON 落盘与 LWW 合并
│   ├── test/                   # node:test 用例（auth / cors / sync）
│   └── test-utils/             # 临时服务与 curl 冒烟脚本
├── src/
│   ├── main.tsx                # React 挂载 + Provider 组装
│   ├── App.tsx                 # 应用外壳：侧边栏、主题、页面切换
│   ├── app/router.tsx          # 极简 hash 路由
│   ├── components/
│   │   ├── Icon.tsx            # 内联 SVG 图标集
│   │   ├── SessionResult.tsx   # 闪卡/测验共用的结算页（正确率只在这里格式化）
│   │   └── ui.tsx              # 通用 UI：PageShell / Modal / Toast / ProgressBar 等
│   ├── i18n/
│   │   ├── index.tsx           # 翻译函数与 Provider
│   │   └── locales/            # zh-CN.ts / en.ts（结构同构，en 受 Dictionary 约束）
│   ├── lib/
│   │   ├── db.ts               # IndexedDB + localStorage 持久化
│   │   ├── store.ts            # createStore 工厂、可观察快照与全部数据变更
│   │   ├── journal.ts          # 变更日志：pending / tombstones 的唯一写者
│   │   ├── srs.ts              # 间隔重复：调度算术 + 「评分后是什么状态」的唯一决策点
│   │   ├── session.ts          # 学习会话状态机（纯函数，闪卡与测验共用）
│   │   ├── wordIndex.ts        # 词库索引：每库分桶、状态计数、标签池、筛选排序、统计头条
│   │   ├── dayStats.ts         # 今日复习数 / 连续学习天数（纯函数）
│   │   ├── quiz.ts             # 出题（纯函数）
│   │   ├── transfer.ts         # 导入导出：JSON / CSV / Anki TXT
│   │   ├── utils.ts            # id / 日期 / 文本等小工具
│   │   ├── types.ts            # 领域类型与默认设置
│   │   ├── seed.ts             # 首次启动的演示词库与复习历史
│   │   ├── languages.ts        # 语言元数据
│   │   ├── translate.ts        # 查词/翻译：有道解析、多源降级、缓存
│   │   ├── sync.ts             # 同步客户端：会话、增量推送/拉取、自动同步循环
│   │   ├── syncMerge.ts        # 纯函数：收集待推改动、合并远端改动（LWW/墓碑）、一轮同步的结算与合并
│   │   ├── localChanges.ts     # 无依赖的本地变更事件总线（避免 store ↔ sync 循环）
│   │   └── tts.ts              # 语音合成封装
│   ├── __tests__/
│   │   └── app.smoke.test.tsx  # jsdom 整应用挂载冒烟测试
│   ├── pages/
│   │   ├── words/              # WordsPage.tsx / WordEditor.tsx
│   │   ├── study/              # FlashcardsPage.tsx / QuizPage.tsx
│   │   ├── stats/              # StatsPage.tsx
│   │   └── settings/           # SettingsPage.tsx / SyncSection.tsx / parts.tsx
│   └── styles/                 # tokens.css（设计令牌）+ global.css + 页面级 study.css / insights.css
└── src-tauri/
    ├── Cargo.toml              # tauri 2 / tauri-build 2 / reqwest（查词代理）
    ├── build.rs
    ├── tauri.conf.json         # 窗口、构建命令、bundle 图标
    ├── capabilities/default.json  # Tauri 2 权限能力
    ├── icons/                  # 应用图标 + 生成脚本
    │   ├── icon.png            # 512×512
    │   ├── 32x32.png
    │   ├── 128x128.png
    │   ├── 128x128@2x.png      # 256×256
    │   ├── icon.ico            # 16/32/48/64/128/256 多尺寸
    │   └── generate-icons.py   # 用 Pillow 重新生成上述图标
    └── src/
        ├── main.rs             # 桌面可执行入口
        └── lib.rs              # Tauri Builder、窗口宿主、lookup_word / translate_text 命令
```

## 开发命令

前置要求：

- Node.js 20+（项目使用 ESM 与 `import.meta.url`）
- Rust 1.77.2+ 与对应平台工具链（仅 `tauri:dev` / `tauri:build` 需要）
- Windows 需要 WebView2 运行时；Linux 需要 `webkit2gtk` 等系统依赖

```bash
# 安装依赖
npm install

# 仅浏览器开发：http://localhost:1420
npm run dev

# 类型检查 + 生产构建，产物在 dist/
npm run build

# 桌面窗口开发（Tauri 会先执行 npm run dev，再打开原生窗口）
npm run tauri:dev

# 打包安装包（会执行 npm run build 并编译 Rust）
npm run tauri:build

# 测试 / 单独类型检查
npm test          # 等价于 npx vitest run
npx tsc --noEmit
```

重新生成应用图标（需要 Pillow）：

```bash
python src-tauri/icons/generate-icons.py
```

> `npm run build` 内部已经包含 `tsc --noEmit`，因此类型错误会阻断构建。Vite 端口固定为 `1420` 且 `strictPort: true`，与 `tauri.conf.json` 的 `devUrl` 保持一致；`src-tauri/**` 已从 Vite 的监听范围中排除。

如果只想得到可执行文件、跳过安装包打包（打包需要联网下载 WiX/NSIS）：

```bash
npx tauri build --no-bundle
# 产物：src-tauri/target/release/lexumo.exe
```


## 测试

```bash
npm test
```

| 文件 | 用例数 | 覆盖内容 |
| --- | --- | --- |
| `src/lib/srs.test.ts` | 66 | 三档评分调度、ease 上下限、间隔上限、状态边界、间隔文案、不可变性；`reviewCard` 的「永不降级」、复习日志字段、`undoGrade` 是评分的精确逆、`previewGrades` 与实际评分一致 |
| `src/lib/utils.test.ts` | 20 | 文本归一化、clamp、shuffle、日期差值、dayKey、cx、uid、相对时间 |
| `src/lib/translate.test.ts` | 24 | 有道词典 / 机器翻译 / MyMemory / Google 各源解析、释义格式化、缓存命中、429 降级与冷却 |
| `src/lib/syncMerge.test.ts` | 23 | 待推改动收集、LWW 合并、墓碑删除、日志并集去重 |
| `src/lib/syncRound.test.ts` | 13 | 一轮同步的结算与合并：发送后结算、在途编辑仍留 pending、远端合并但不算本地编辑、墓碑删除、旧记录 LWW 落败、回声不重复 |
| `src/lib/journal.test.ts` | 22 | 用真实 store 实例验证：每次本地编辑都进 pending、删除必留墓碑、删词库级联词与日志、快照不可变、`applyRound` 真的结算、远端改动不算本地编辑 |
| `src/lib/session.test.ts` | 19 | 学习会话状态机：全程进度、hard 算复习但不算答对、skip 语义、undo 双向精确还原、空列表、正确率不为 NaN |
| `src/lib/wordIndex.test.ts` | 22 | 每库分桶与状态计数、标签池排序（含同次数 localeCompare 兜底）、到期判定、四种筛选与四种排序、统计头条各数字 |
| `src/lib/dayStats.test.ts` | 9 | 今日复习数只算本地午夜之后、连续天数（今天空着不断档、缺一天即停、同一天多次只算一天、跨月不串） |
| `src/__tests__/app.smoke.test.tsx` | 5 | 在 jsdom 中真实挂载整个应用：五个页面渲染、主题切换、弹窗开关、搜索过滤 |

共 **223** 个用例。后端另有 `server/` 下的 `node:test` 用例（`cd server && npm test`）。

冒烟测试通过 `// @vitest-environment jsdom` 单独指定环境，其余用例仍跑在 Node 环境。

## 数据存储

- **主存储**：IndexedDB 数据库 `lexumo`，对象仓库 `kv`，键 `app`，保存**单个版本化快照** `AppData`：

  ```ts
  interface AppData {
    version: number;            // 当前 DATA_VERSION = 2
    lists: WordList[];
    words: Word[];
    logs: ReviewLog[];          // 每次评分的复习日志
    settings: Settings;
    settingsUpdatedAt: number;  // 设置项参与同步时的 LWW 时间戳
    tombstones: Tombstones;     // 已删除的词/词库/日志 id → 删除时间
    pending: PendingChanges;    // 尚未推送到服务器的改动（id 列表）
  }
  ```

- **写入策略**：所有变更走 `store.ts` 的 `commit()`，先通知订阅者，再以 220ms 防抖写入快照。`commit` 只浅拷数组，因此记录一律**替换**而非就地修改（`patchWord` / `patchList`），旧快照不会被后续编辑污染。
- **同步记账**：`pending`（待推改动）与 `tombstones`（删除墓碑）只由 `src/lib/journal.ts` 写入，业务操作不再各自手写 `mark*Dirty`。这样「本地改动必须被推送」「本地删除必须留墓碑」两条不变量由模块保证，新增操作不会漏记账；删词、批量删词、删词库共用同一套级联（`journal.purgeWords`），不会留下孤儿复习日志。
- **一轮同步的顺序**：推送成功后的「先结算已发送、再合并远端」不再写在 `sync.ts` 的调用点，而是由纯函数 `applyRound(data, { sent, received })` 一次完成，store 只暴露单个 `applyRound`。顺序之所以重要，是因为结算带版本守卫——只有当本地记录仍是推送出去的那个版本时才清 `pending`；请求在途期间用户又编辑过，这条记录就保持 pending 进入下一轮。合并属于「服务器在说话」，因此不触发本地变更事件，避免每次推送后再空跑一轮同步。
- **学习会话**：闪卡页与测验页共用 `src/lib/session.ts` 的状态机（当前卡片、进度、正确率、撤销栈），「hard 算复习但不算答对」这条规则与正确率格式化各只有一处实现，两个页面只负责渲染、键盘与调用 `gradeWord` / `undoReview`。
- **复习决策**：`src/lib/srs.ts` 不只算间隔，也拥有「评完这一档之后这张卡是什么状态」的完整决策——`reviewCard(card, grade, now, ids)` 返回 `{ srs, status, log }`，其中状态按「永不降级」规则提升、复习日志在模块内部铸造；`undoGrade(prev, log)` 是它的精确逆（**故意不重算**，否则一张刚失手的已掌握卡片会被降级回去），`previewGrades` 让评分按钮预览的正是将要执行的那条规则。`store.ts` 里只剩持久化与同步记账，因此这条不变量不会再因为出现第二个调用者而被绕开。
- **词库派生**：状态计数、标签池、到期桶、筛选排序与统计头条全部由 `src/lib/wordIndex.ts` 一次遍历产出（`buildWordIndex` / `queryWords` / `summarize`），页面不再各自手写一份。今日复习数与连续天数归 `src/lib/dayStats.ts` 所有，侧栏与统计页读同一份实现。此前词库页表头的到期数是全局的、标签下拉却作用于单个词库，会出现「选了标签却是空列表」这类前后不一致；现在表头、标签下拉与列表都描述同一个词库，侧栏徽标仍保持全局。
- **回退链**：IndexedDB 不可用或读写失败 → localStorage 键 `lexumo:data`（JSON 字符串）→ 再失败则仅保存在内存（刷新即丢失）。
- **版本迁移**：启动时若快照 `version` 低于 `DATA_VERSION`，会就地补齐新字段（`updatedAt` / `tombstones` / `pending` / `settingsUpdatedAt`）并保留原有数据；只有 `version` 高于当前版本（降级运行）才会重新播种。
- **隐私**：数据默认只在本机。只有在「设置 → 账号与同步」中显式登录后，词库、复习日志与设置才会推送到你填写的服务器地址；不登录则没有任何网络上传。

## 导入 / 导出格式

三种格式均为 **UTF-8 文本**。

### JSON（完整快照）

导出整个 `AppData` 对象（含 `version`、词库、词条、复习日志、设置），用于无损备份。

导入时支持两种输入：完整快照对象（读取其 `words` 数组）或直接的词条数组。**导入只恢复词条**，不会覆盖已有的复习日志与设置；缺少 `term` 的行会被跳过。

### CSV（表格）

导出首行为表头，列顺序固定：

```csv
term,definition,definition2,example,note,tags,status
serendipity,意外发现美好事物的能力,,a serendipitous meeting,来自阅读,抽象;名词,reviewing
```

- `tags` 用分号 `;`（也接受全角 `；`）分隔；
- 含逗号、双引号或换行的字段按 RFC 4180 用双引号包裹，内部双引号写两遍；
- 导出带 UTF-8 BOM 与 CRLF，便于 Excel 直接打开；
- 导入时表头可用中英文别名（`term`/`word`/`单词`/`词语`、`definition`/`meaning`/`释义`/`意思` 等）；无表头时首列作 `term`。

### Anki TXT

Tab 分隔，第一列是词形，其余列合并为释义，HTML 标签会被剥离：

```text
serendipity	意外发现美好事物的能力	a serendipitous meeting
```

### 导入行为

- 所有导入的词条都会写入**第一个词库**；
- 与目标词库中已有词条重复（按归一化后的词形比较）的行会被跳过，并在结果中提示跳过数量；
- 导入前会显示预览（识别出的格式、条数、跳过数、前 8 个词条），确认后才写入。

## 多端同步

同步是**可选的**：不登录时应用与单机版完全一致。需要多设备共享时，自己跑一个后端即可——不需要任何云服务商。

### 1. 启动后端

```bash
cd server
npm start
# 默认 http://127.0.0.1:8787，数据写在 server/data/
```

零第三方依赖，只需要 Node 20+。`PORT` / `HOST` / `DATA_DIR` 三个环境变量可调；想让手机和电脑都连上，把 `HOST` 设为 `0.0.0.0` 并用局域网 IP 访问。详见 [`server/README.md`](server/README.md)。

### 2. 在应用里登录

打开「设置 → 账号与同步」：

1. 服务器地址填后端地址（例如 `http://192.168.1.10:8787`），可先点「测试连接」；
2. 填邮箱与密码，首次点「创建账号」，之后在别的设备上点「登录」；
3. 登录成功后会自动推一次本地改动并拉取服务器上的数据。

登录后侧栏底部会出现同步状态（已同步 / 同步中 / 同步失败 / 待同步条数），点它可直接跳到设置页。默认开启自动同步：本地编辑后 2.5 秒防抖推送、每 15 秒轮询一次未推送的改动、窗口重新获得焦点或网络恢复时立即同步。也可以手动点「立即同步」。

### 3. 冲突与删除的处理

- **词条与词库**：整条记录同步，按 `updatedAt` 后写胜出（LWW）。本地有未推送的改动且比服务器上的更新时，保留本地版本并在下一轮推送。
- **复习日志**：只追加，按 `id` 去重做并集，不会互相覆盖；撤销评分时会写入日志墓碑，让删除也能传播。
- **删除**：写墓碑（`{ id, updatedAt, deleted: true }`）而不是直接抹掉，否则离线设备下次同步会把删掉的词再推回来。
- **设置**：整体按 `settingsUpdatedAt` 做 LWW。
- **首次登录**：本地已有的词库（包括首次启动的示例词库）会整批上传，所以新设备登录后能看到全部内容。

接口契约见 [`docs/sync-protocol.md`](docs/sync-protocol.md)，客户端 `src/lib/sync.ts` 与后端 `server/` 都以它为准。

## 已知限制

- **平台**：以 Windows 为主进行开发；macOS / Linux 打包未验证。macOS 打包还需要 `icon.icns`（当前仅生成 PNG 与 ICO）。
- **安装包**：`cargo check` 与 `cargo build --release` 均已在 Windows 上通过，产物 `src-tauri/target/release/lexumo.exe`（约 12.7 MB）可正常启动并显示窗口。但 `npm run tauri:build` 的**打包步骤**未能在本环境完成：Tauri 需要从 GitHub Releases 下载 WiX（MSI）或 NSIS（EXE 安装器），该域名在开发环境中超时。二进制本身没有问题，在能访问 GitHub 的机器上重跑即可产出安装包；或先用 `npx tauri build --no-bundle` 只产出可执行文件。
- **自动翻译**：依赖有道词典 / MyMemory 等公开接口，需联网；接口可能限流或变更，届时查词会降级或提示失败，不影响手动录入。缓存 30 天，设置里可清除。
- **视觉验证**：功能层有 jsdom 冒烟测试覆盖；界面另用 headless Edge + DevTools 协议做了实测——五个页面均渲染、无控制台异常与失败请求、无横向溢出，并核对了设计令牌的实际取值、深色主题配色反转、860px 窄窗口下侧栏折叠、以及词条行「悬停显形操作区」的透明度变化。学习流程另外用真实键盘/鼠标事件跑过完整一轮：闪卡翻面、三档评分、撤销回到同一张卡、结算页「答对 / 已复习」与百分比互相吻合，测验四选一、即时反馈、Enter 推进到结算页。未做跨平台像素级视觉回归。
- **TTS**：依赖系统语音合成引擎，可用音色与语言随平台而异；部分语言可能没有可用语音，此时听音功能静默降级。
- **同步**：自带的后端是单进程、每用户一个 JSON 文件的实现，适合个人或小规模自建；不支持集群、无数据库、无备份策略。传输默认是明文 HTTP（本机或局域网内使用没问题，暴露到公网请自行在前面加 HTTPS 反向代理）。令牌存在 localStorage，有效期 30 天。改名前的旧本地数据不会自动迁移（存储键已随应用改名更换）。
- **规模**：采用「全量快照 + 防抖写盘」，词条量很大（约 2 万以上）时每次写入会有可感知延迟。同步也是整条记录增量传输，单次最多 5000 条改动。
- **导入编码**：仅支持 UTF-8，GBK 等编码需先转码；Anki 的 `.apkg` 包不在支持范围内。
- **搜索**：前端内存过滤，无分词与模糊匹配，也不支持正则。

## 致谢与许可

- **功能与交互理念**参考 **[Lingueez](https://lingueez.app)**（作者 Yurii Lysak，AGPL-3.0）。Lexumo 是独立重写，但保留了「词条状态阶梯 + 间隔重复 + 听音记忆」这一核心思路。
- **许可**：本项目以 **GNU AGPL-3.0** 授权，是 Lingueez 的衍生重写，许可证全文见 [`LICENSE.txt`](LICENSE.txt)。
- **署名（AGPL-3.0 §7(b) 附加条款）**：按上游 [`NOTICE`](NOTICE) 的要求，必须在用户可见的法律声明中保留 **“Lingueez — created by Yurii Lysak”** 这一署名。该署名已展示在应用「设置 → 关于」中，请勿移除。
- **第三方组件**：React、Vite、Tauri 等依赖的许可见 [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)。
- **图标**：由 `src-tauri/icons/generate-icons.py` 使用 Pillow 生成；「L」字形取自本机 Georgia 衬线字体，字体文件不随应用分发。
