# Lexilo · 词屿

Lexilo（词屿）是一个安静的桌面背单词工作室：把生词收进词屿，用间隔重复一点点记住它们。

项目参考开源桌面词汇应用 **[Lingueez](https://lingueez.app)**（Python + PySide6，作者 Yurii Lysak）的功能理念，用 **Tauri 2 + React 19 + TypeScript + Vite 7** 重新实现。界面以中文为主，视觉基调是暖纸色背景与玉绿色点缀；数据全部保存在本机，不注册、不联网即可使用。

![Lexilo 界面](docs/app-ui.png)

> 界面截图。桌面窗口在 150% 缩放的测试机上会被系统二次缩放，为避免排版失真，此图直接取应用前端在 Chromium / WebView2 中渲染后的结果。

## 功能

- **词库管理**：多词库、增删改查、搜索、状态筛选、标签筛选、排序、收藏；每条词条包含主释义、补充释义、例句、笔记、标签。
- **添加时自动翻译**：新建词条时输入单词并失焦，自动查词典填入释义、补充释义、例句与音标；可一键「重新翻译」强制覆盖。桌面版通过 Rust 代理查有道词典（音标 + 词性 + 双语例句），网页版降级到有道 / MyMemory / Google 机器翻译链；结果缓存 30 天，命中限流时自动冷却换源，查不到不阻塞手动填写，设置里可整体关闭。
- **间隔重复**：SM-2 变体调度，评分分为 `easy / good / hard`；ease 限制在 `[1.3, 2.5]`，间隔限制在 `[1, 3650]` 天；卡片状态由已获得的间隔推导：`new → reviewing → learning → mastered`。
- **闪卡复习**：四种组卡方式（到期卡片 / 新卡片 / 全部词语 / 收藏词语，各自显示数量）、到期队列 + 新卡队列（受每日新卡上限约束）、翻面后仍保留词形、评分按钮上直接预览「下次间隔」、可随时「撤销上一次」评分或跳过、中途可「结束本轮」、键盘快捷键、自动/手动 TTS 发音。
- **测验**：看词选义 / 看义选词双向模式，4 选 1，即时对错反馈，结束页给出错题列表；测验不写入 SRS。
- **统计**：总词数、已掌握、今日复习、连续天数、每日目标环、状态分布、学习活动柱状图（7 / 30 / 90 天可切换）、评分分布、记忆留存率、逾期词数。
- **设置**：主题（浅色 / 深色 / 跟随系统）、界面语言（简体中文 / English）、每日目标、每日新卡上限、复习顺序、TTS 语速与音色、听力模式、自动翻译开关与翻译缓存管理。
- **导入 / 导出**：JSON 快照、CSV 表格、Anki TXT 三种格式。
- **本地优先**：IndexedDB 单快照持久化，localStorage 兜底；无账号体系，无遥测。
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

## 技术栈

| 层次 | 选型 |
| --- | --- |
| 桌面壳 | Tauri 2（Rust，系统 WebView2 / WebKitGTK / WKWebView） |
| 前端框架 | React 19 |
| 语言 | TypeScript 5.8（`strict` + `noUnusedLocals` + `noUnusedParameters`） |
| 构建 | Vite 7（固定端口 1420，`strictPort`） |
| 测试 | Vitest 3（纯函数用 Node 环境，整应用冒烟测试用 jsdom） |
| 持久化 | IndexedDB（`lexilo` 库，单键快照）+ localStorage 回退 |
| 发音 | Web Speech API（`speechSynthesis`） |
| 查词 / 翻译 | Rust 侧 `reqwest` 代理有道词典 JSON API（桌面）；浏览器降级到有道 `trans` → MyMemory → Google |
| 样式 | 原生 CSS（设计令牌 + 全局样式），无 UI 框架 |
| 图标 | Pillow 脚本生成，衬线体「L」字形 |

## 目录结构

```text
.
├── index.html                  # 单页入口，标题「Lexilo · 词屿」
├── package.json                # 脚本：dev / build / preview / test / tauri:*
├── vite.config.ts              # @ → ./src，端口 1420，outDir dist
├── vitest.config.ts            # 测试配置：environment node，@ 别名，包含 .ts/.tsx
├── tsconfig.json               # 前端 TS 配置（strict，include: src）
├── tsconfig.node.json          # vite/vitest 配置文件的 TS 配置
├── LICENSE.txt                 # GNU AGPL-3.0 全文
├── NOTICE                      # 上游署名与 AGPL-3.0 §7(b) 附加条款
├── THIRD-PARTY-LICENSES.md     # 第三方组件许可
├── src/
│   ├── main.tsx                # React 挂载 + Provider 组装
│   ├── App.tsx                 # 应用外壳：侧边栏、主题、页面切换
│   ├── app/router.tsx          # 极简 hash 路由
│   ├── components/
│   │   ├── Icon.tsx            # 内联 SVG 图标集
│   │   └── ui.tsx              # 通用 UI：PageShell / Modal / Toast / ProgressBar 等
│   ├── i18n/
│   │   ├── index.tsx           # 翻译函数与 Provider
│   │   └── locales/            # zh-CN.ts / en.ts（结构同构，en 受 Dictionary 约束）
│   ├── lib/
│   │   ├── db.ts               # IndexedDB + localStorage 持久化
│   │   ├── store.ts            # 可观察快照 store 与全部数据变更
│   │   ├── srs.ts              # 间隔重复调度（纯函数）
│   │   ├── quiz.ts             # 出题（纯函数）
│   │   ├── transfer.ts         # 导入导出：JSON / CSV / Anki TXT
│   │   ├── utils.ts            # id / 日期 / 文本等小工具
│   │   ├── types.ts            # 领域类型与默认设置
│   │   ├── seed.ts             # 首次启动的演示词库与复习历史
│   │   ├── languages.ts        # 语言元数据
│   │   ├── translate.ts        # 查词/翻译：有道解析、多源降级、缓存
│   │   └── tts.ts              # 语音合成封装
│   ├── __tests__/
│   │   └── app.smoke.test.tsx  # jsdom 整应用挂载冒烟测试
│   ├── pages/
│   │   ├── words/              # WordsPage.tsx / WordEditor.tsx
│   │   ├── study/              # FlashcardsPage.tsx / QuizPage.tsx
│   │   ├── stats/              # StatsPage.tsx
│   │   └── settings/           # SettingsPage.tsx
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
# 产物：src-tauri/target/release/lexilo.exe
```


## 测试

```bash
npm test
```

| 文件 | 用例数 | 覆盖内容 |
| --- | --- | --- |
| `src/lib/srs.test.ts` | 50 | 三档评分调度、ease 上下限、间隔上限、状态边界、间隔文案、不可变性 |
| `src/lib/utils.test.ts` | 20 | 文本归一化、clamp、shuffle、日期差值、dayKey、cx、uid、相对时间 |
| `src/lib/translate.test.ts` | 24 | 有道词典 / 机器翻译 / MyMemory / Google 各源解析、释义格式化、缓存命中、429 降级与冷却 |
| `src/__tests__/app.smoke.test.tsx` | 5 | 在 jsdom 中真实挂载整个应用：五个页面渲染、主题切换、弹窗开关、搜索过滤 |

共 **99** 个用例。

冒烟测试通过 `// @vitest-environment jsdom` 单独指定环境，其余用例仍跑在 Node 环境。

## 数据存储

- **主存储**：IndexedDB 数据库 `lexilo`，对象仓库 `kv`，键 `app`，保存**单个版本化快照** `AppData`：

  ```ts
  interface AppData {
    version: number;      // 当前 DATA_VERSION = 1
    lists: WordList[];
    words: Word[];
    logs: ReviewLog[];    // 每次评分的复习日志
    settings: Settings;
  }
  ```

- **写入策略**：所有变更走 `store.ts` 的 `commit()`，先通知订阅者，再以 220ms 防抖写入快照。
- **回退链**：IndexedDB 不可用或读写失败 → localStorage 键 `lexilo:data`（JSON 字符串）→ 再失败则仅保存在内存（刷新即丢失）。
- **版本迁移**：启动时若快照 `version` 与 `DATA_VERSION` 不一致，会丢弃旧快照并重新播种演示数据；`settings` 字段缺失时用默认值补齐。
- **隐私**：数据只在本机，不上传任何服务器；清除 WebView 数据或卸载应用会删除词库，建议定期导出 JSON 备份。

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

## 已知限制

- **平台**：以 Windows 为主进行开发；macOS / Linux 打包未验证。macOS 打包还需要 `icon.icns`（当前仅生成 PNG 与 ICO）。
- **安装包**：`cargo check` 与 `cargo build --release` 均已在 Windows 上通过，产物 `src-tauri/target/release/lexilo.exe`（约 12.7 MB）可正常启动并显示窗口。但 `npm run tauri:build` 的**打包步骤**未能在本环境完成：Tauri 需要从 GitHub Releases 下载 WiX（MSI）或 NSIS（EXE 安装器），该域名在开发环境中超时。二进制本身没有问题，在能访问 GitHub 的机器上重跑即可产出安装包；或先用 `npx tauri build --no-bundle` 只产出可执行文件。
- **自动翻译**：依赖有道词典 / MyMemory 等公开接口，需联网；接口可能限流或变更，届时查词会降级或提示失败，不影响手动录入。缓存 30 天，设置里可清除。
- **视觉验证**：功能层有 jsdom 冒烟测试覆盖；界面另用 headless Edge + DevTools 协议做了实测——五个页面均渲染、无控制台异常与失败请求、无横向溢出，并核对了设计令牌的实际取值、深色主题配色反转、860px 窄窗口下侧栏折叠、以及词条行「悬停显形操作区」的透明度变化。未做跨平台像素级视觉回归。
- **TTS**：依赖系统语音合成引擎，可用音色与语言随平台而异；部分语言可能没有可用语音，此时听音功能静默降级。
- **同步**：无多设备同步与云备份，数据仅存本机。
- **规模**：采用「全量快照 + 防抖写盘」，词条量很大（约 2 万以上）时每次写入会有可感知延迟。
- **导入编码**：仅支持 UTF-8，GBK 等编码需先转码；Anki 的 `.apkg` 包不在支持范围内。
- **搜索**：前端内存过滤，无分词与模糊匹配，也不支持正则。

## 致谢与许可

- **功能与交互理念**参考 **[Lingueez](https://lingueez.app)**（作者 Yurii Lysak，AGPL-3.0）。Lexilo 是独立重写，但保留了「词条状态阶梯 + 间隔重复 + 听音记忆」这一核心思路。
- **许可**：本项目以 **GNU AGPL-3.0** 授权，是 Lingueez 的衍生重写，许可证全文见 [`LICENSE.txt`](LICENSE.txt)。
- **署名（AGPL-3.0 §7(b) 附加条款）**：按上游 [`NOTICE`](NOTICE) 的要求，必须在用户可见的法律声明中保留 **“Lingueez — created by Yurii Lysak”** 这一署名。该署名已展示在应用「设置 → 关于」中，请勿移除。
- **第三方组件**：React、Vite、Tauri 等依赖的许可见 [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)。
- **图标**：由 `src-tauri/icons/generate-icons.py` 使用 Pillow 生成；「L」字形取自本机 Georgia 衬线字体，字体文件不随应用分发。
