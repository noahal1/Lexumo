# Lexumo · 词砚

Lexumo（词砚）是一个安静的背单词工作室：把生词研进词砚，用间隔重复一点点记住它们。

用 **Flutter** 构建，编译到 **Windows** 与 **Android**，界面以中文为主，视觉基调是暖纸色背景与石青点缀；数据默认全部保存在本机，不注册、不联网即可使用，需要多设备时可选接入同步。

> 这个仓库早先有一份 Tauri 2 + React 19 的实现（`src/`、`src-tauri/`），已于 2026-11 移除。现在 `flutter/` 是唯一的实现，本文描述的就是它；被移除那一版的记录作为历史留在
> [`docs/usability-round.md`](docs/usability-round.md)、[`docs/supabase-sync-plan.md`](docs/supabase-sync-plan.md) 与 [`docs/sync-protocol.md`](docs/sync-protocol.md) 里。
> 分层、与旧版每一处有意的差异、以及构建过程踩过的坑记在 [`docs/flutter-design.md`](docs/flutter-design.md)；
> 视觉决策的权威文档是 [`docs/design.md`](docs/design.md)。

## 功能

- **词库管理**：多词库、增删改查、搜索、状态筛选、排序、收藏。顶部是当前词库的下拉胶囊，其余词库在右边一条永不分行的横滚标签带上。每条词条包含释义、词性、补充释义、例句与例句译文、笔记、音标（词性与释义分开存：释义里不会出现 `n.` 这类前缀，列表和闪卡上词性以小字显示在释义之前）。支持批量操作（全选 / 收藏 / 删除所选）；删除词条后可在提示条上「撤销」，词条与它的复习记录一起回来。
- **手动查词翻译**：新建或编辑词条时，填好单词后点「翻译」按钮才会查词典，一次填入释义、词性、补充释义、例句与例句译文、音标；再点一次即强制覆盖。反过来也支持：先写释义，点「由释义查词」把词语补上——日语这类你真记得意思、不确定写法的词库按这个顺序更顺手。**任何输入框失焦、切换字段都不会触发查询，只有按钮会。** 查词链是 有道词典 → 有道网页翻译 → MyMemory → Google，结果缓存 30 天，命中限流时自动冷却换源，查不到不阻塞手动填写。
- **间隔重复**：SM-2 变体调度，评分分为 `easy / good / hard`；ease 限制在 `[1.3, 2.5]`，间隔限制在 `[1, 3650]` 天；卡片状态由已获得的间隔推导：`new → reviewing → learning → mastered`。
- **闪卡复习**：四种组卡方式（到期卡片 / 新卡片 / 全部词语 / 收藏词语，各自显示数量）、到期队列 + 新卡队列（受每日新卡上限约束）、翻面后仍保留词形、评分按钮上直接预览「下次间隔」、可随时「撤销上一次」评分或跳过、中途可「先到这里」、键盘快捷键、滑动评分、自动/手动朗读。
- **测验**：看词选义 / 看义选词双向模式，4 选 1，即时对错反馈，结束页给出错题列表；测验不写入 SRS。
- **统计**：总词数、已掌握、今日复习、连续天数、每日目标环、状态分布、学习活动柱状图（7 / 30 / 90 天可切换）、评分分布、记忆留存率、逾期词数。
- **我的**：头像与账号（未登录时只显示本机），今日复习 / 连续天数 / 词语总数三个数字，从 Excel 导入、设置两个平铺入口，以及一页关于与版本信息。**设置不再占一个标签**，它从「我的」里推开，是一个整屏页面。
- **设置**：主题（浅色 / 深色 / 跟随系统）、界面语言（简体中文 / English）、每日复习目标、每日新卡上限、复习顺序、朗读音色与语速、听力模式、翻译缓存管理、导入导出、账号与同步、关于与升级。每个控件改完即写入，没有保存按钮。
- **导入 / 导出**：JSON 快照、CSV 表格、Anki TXT 三种格式。
- **多端同步（可选）**：注册账号后可在多台设备间增量同步词库、词条、复习日志与设置。本地优先：不登录、不联网也能完整使用，登录后离线改动会在恢复网络时自动补推。冲突按 `updatedAt` 后写胜出（LWW），删除以墓碑传播，日志按 id 并集去重。设置页实时显示同步状态与待同步条数，可关闭自动同步。
- **应用内升级**：启动后定期检查更新，下载、校验摘要、交给系统安装器，装完回来 build 号变了才算成功。
- **本地优先**：单个版本化 JSON 快照，原子落盘（`.tmp` → flush → rename）加一份 `.bak`，坏文件只报错不抛异常；默认无账号、无遥测，同步是可选的。
- **设计系统**：两套材质，一个外壳。侧栏、连续打卡、手机底部标签栏是「石」——两种主题下都是深色，因为它是放东西的桌面，不是你阅读的表面；每个工作界面是「纸」——浅色主题米白，深色主题深青灰。单一强调色石青只用在三处：你在哪、选中了什么、一次复习走了多远；朱砂只留给不可恢复的删除，所以屏幕上出现红色就意味着要小心。字体按含义分工：IBM Plex Serif 是词条与页标题，IBM Plex Sans 是界面，IBM Plex Mono 是键帽与数字；三款字体的 latin 子集随包自托管，中文故意不打进去——一套 CJK 字体有几 MB，而应用必须能离线用，中文回落到系统的苹方 / 微软雅黑。令牌与每条决策的理由记在 [`docs/design.md`](docs/design.md)。
- **界面与可用性**：石与纸双材质、深浅双主题（跟随系统），侧栏可折叠为图标栏，词条行悬停才显示操作区，搜索命中高亮；全局快捷键与「?」快捷键帮助；弹窗带焦点陷阱，正文对比度满足 WCAG AA。错误用 `role="alert"` 播报。
- **动效**：翻页淡入、列表逐行落位、闪卡两段式翻面、测验对错反馈、按下缩放、提示条进出。全部走系统「减少动态」设置——开启后动画时长归零，闪卡直接出答案，不靠定时器。

## 键盘操作

界面内所有操作都可以用键盘完成，按 <kbd>?</kbd> 随时打开快捷键帮助。

| 按键 | 作用 |
| --- | --- |
| <kbd>Ctrl</kbd>/<kbd>⌘</kbd>+<kbd>1</kbd> … <kbd>5</kbd> | 切换首页 / 词库 / 练习 / 统计 / 我的 |
| <kbd>?</kbd> | 打开或关闭快捷键帮助 |
| <kbd>/</kbd> | 聚焦搜索框（词库页） |
| <kbd>n</kbd> | 新建词条（词库页） |
| <kbd>Ctrl</kbd>+<kbd>A</kbd> | 全选词条（词库页，焦点不在输入框时） |
| <kbd>Space</kbd> | 翻开 / 盖上闪卡 |
| <kbd>1</kbd> <kbd>2</kbd> <kbd>3</kbd> | 闪卡评分（困难 / 记得 / 简单） |
| <kbd>Ctrl</kbd>+<kbd>Z</kbd> | 撤销上一次闪卡评分或跳过 |
| <kbd>←</kbd> <kbd>→</kbd> | 跳过当前卡片 |
| <kbd>A</kbd>–<kbd>D</kbd> 或 <kbd>1</kbd>–<kbd>4</kbd> | 选择测验选项 |
| <kbd>Enter</kbd> | 测验下一题 |
| <kbd>Esc</kbd> | 关闭弹窗 / 清空搜索 |

> 快捷键只有一个来源：`flutter/lib/ui/features/shell/views/app_shell.dart` 里的 `kShortcutHelp` 声明表，帮助面板按它生成，因此不会出现「帮助里写着、实际按了没反应」。`Ctrl`/`⌘`+数字这一组由 `PageId.values` 的顺序生成，加一个顶级页面就要同时加一个数字键。

> 在输入框内输入时，单键快捷键会自动让位，不会误触发；用中文输入法打拼音时（组字过程中）同样不会触发——按 <kbd>n</kbd> 不会在选字途中打开新建词条，<kbd>Space</kbd> 也不会在选字途中翻卡。

## 手机与触屏

界面按窗口宽度自适应，不区分平台——手机、平板、桌面窗口都走同一套布局。

| 宽度 | 布局 |
| --- | --- |
| ≥ 1000px | 完整侧栏 + 多列列表 |
| 720–1000px | 侧栏收成图标轨道（rail） |
| < 720px | 侧栏隐藏，底部五标签栏导航；弹窗变成底部抽屉 |

触屏适配的几处细节：

- 底部标签栏常驻五个顶级页面，练习标签带到期数量徽标；切换页面时滚动位置自动回到顶部。
- 词库行在手机上收成「词形 + 释义（两行截断）+ 状态」三块，行内只保留发音按钮；收藏、编辑、删除移入编辑器。
- 触控目标地板 44dp（`Layout.tap`），带文字的按钮整体长大，纯图标按钮只长大命中盒（`TapTarget`），绘制形状不变。
- 触屏不依赖 hover：行操作在手机上始终可见，桌面端仍是悬停显示。
- 平台差异按平台判断，不按宽度判断：窄化的桌面窗口仍然由键盘和鼠标驱动，横屏平板很宽却只有手指——宽度会把这两种情况都答错。快捷键提示（`ui/core/widgets/keyboard_hints.dart`）与触控密度（`ui/core/widgets/density.dart`）都取 `defaultTargetPlatform`，测试可以显式传入钉住答案。

## 技术栈

| 层次 | 选型 |
| --- | --- |
| 应用框架 | Flutter（Dart 3.13+，Flutter 3.47+），一个代码库出 Windows 与 Android |
| 状态 | 每个功能一对 `view_models/`（`ChangeNotifier`）+ `views/`；view model 不 import `material`，靠 `Feedback` 端口做 toast / 确认 / 跳页 |
| 持久化 | 单个版本化 JSON 快照（`flutter/lib/data/services/snapshot_store.dart`），原子写 + `.bak` 回退 |
| 发音 | `flutter_tts`（vendored 在 `flutter/third_party/flutter_tts`），走系统语音引擎 |
| 查词 / 翻译 | `dart:io` 直连有道词典 JSON API → 有道网页翻译 → MyMemory → Google，多源降级 + 30 天缓存 |
| 同步后端 | 两条路：默认连自带的 Supabase 项目；也可自建零依赖 Node 后端（`server/`） |
| 同步协议 | 增量 `rev`、LWW、墓碑删除、日志并集，见 [`docs/sync-protocol.md`](docs/sync-protocol.md) |
| 样式 | 自带设计令牌（`flutter/lib/ui/core/tokens.dart`）+ `ThemeExtension`，无第三方 UI 框架 |
| 图标 | `flutter/tool/generate_icons.py` 用 Pillow 生成：石框 + 纸页 + 石青书脊，几何与理由见 [`docs/icon/README.md`](docs/icon/README.md) |
| 测试 | `flutter_test`（单元 / widget / 布局预算），另有 SQL、端到端、差分三层后端验证 |

## 目录结构

```text
.
├── LICENSE.txt                 # GNU AGPL-3.0 全文
├── NOTICE                      # 版权与许可声明
├── THIRD-PARTY-LICENSES.md     # 第三方组件许可
├── docs/
│   ├── design.md               # 设计系统的权威文档：石与纸、令牌、每条决策的理由
│   ├── flutter-design.md       # Flutter 版如何落地、与旧版的差异、踩过的坑与四层测试
│   ├── sync-protocol.md        # 同步接口契约（后端与客户端共同的唯一规范）
│   ├── supabase-sync-plan.md   # 在真实 Supabase 项目上跑同步的计划与验证
│   ├── usability-round.md      # 一轮可用性审计的记录（旧网页版，历史存档）
│   ├── app-ui.png              # 界面截图（旧网页版，历史存档）
│   └── icon/                   # 应用图标的几何、调色与生成方式
├── flutter/                    # 应用本体
│   ├── pubspec.yaml            # 版本号（唯一来源）、依赖、字体注册
│   ├── notes.json              # 每个版本的更新说明（zh / en），发布清单读它
│   ├── lib/
│   │   ├── main.dart           # 入口：Store 初始化 → UpdateService → 作用域树 → MaterialApp
│   │   ├── app/                # 组合根：scope.dart（InheritedWidget 层 + DI）、update_scope.dart
│   │   ├── data/               # 数据层
│   │   │   ├── models/         # journal（写操作记账）/ wire / sync_config / sync_merge
│   │   │   ├── repositories/   # store.dart（写操作的唯一入口）/ sync_engine / update_service
│   │   │   └── services/       # 无状态外部适配：snapshot_store / transfer / 三种 transport
│   │   │                       #   / translate / tts / speech / app_dir / app_installer / file_dialogs
│   │   ├── domain/             # 纯逻辑，无 Flutter 依赖
│   │   │   ├── models/         # types / srs / session / quiz / languages / seed / utils / version
│   │   │   └── use_cases/      # day_stats / word_query（索引、筛选、汇总）
│   │   └── ui/                 # 表现层
│   │       ├── core/           # theme / tokens / i18n（en, zh_cn）/ widgets / system_ui
│   │       └── features/       # home / words / practice / flashcards / quiz / stats /
│   │                           #   profile / settings / onboarding / update / shell
│   ├── test/                   # 48 个测试文件 + support/（假 Feedback、假查词、假 TTS）
│   ├── android/                # 包名 dev.lexumo.lexumo；key.properties + upload-keystore.jks
│   ├── windows/                # runner 与 app_icon.ico
│   ├── assets/fonts/           # IBM Plex Sans / Serif / Mono 的 TTF 子集
│   ├── third_party/flutter_tts # vendored 的 TTS 插件
│   ├── tool/                   # build_apk.sh / release.sh / verify_apk.sh / reinstall.sh
│   │                           #   / setup_signing.sh / generate_icons.py / 若干静态检查脚本
│   └── dist/                   # 发布产物（gitignored）：APK + update.json
├── server/                     # 自建同步后端（零依赖 Node）
│   ├── package.json            # npm start / npm test
│   ├── README.md               # 部署、环境变量、端点说明
│   ├── src/                    # index.js（路由/CORS/body 限制）/ auth.js（scrypt + 令牌）/ store.js
│   ├── test/                   # node:test 用例（auth / cors / sync）
│   └── test-utils/             # 临时服务与 curl 冒烟脚本
├── supabase/                   # Supabase 侧的迁移与验证
│   ├── migrations/0001_sync.sql
│   └── tests/                  # run.sh（真 Postgres）/ differential.cjs / rpc_bridge.cjs
├── scripts/
│   └── fetch-plex-ttf.cjs      # 从 IBM Plex 官方仓库取 TTF 到 flutter/assets/fonts/
└── .github/workflows/release.yml  # 打 v* 标签：analyze → 测试 → 签名 APK → 发布 + 清单
```

## 开发命令

前置要求：

- Flutter 3.47+ 与 Dart 3.13+
- Windows 需要 Visual Studio 的 C++ 桌面工具链（`flutter build windows` 要建符号链接，需开启开发者模式）
- Android 需要 Android SDK + JDK 17

```bash
cd flutter

../.flutter-sdk/flutterc analyze     # 静态检查
../.flutter-sdk/flutterc test        # 全量测试

./tool/build_apk.sh                  # release APK → dist/lexumo-android-release.apk
./tool/release.sh                    # 签名 APK + dist/update.json（发布用）
./tool/reinstall.sh                  # 装到模拟器并校验
```

> **不要直接调 `flutter`。** 这台机器上 flutter 工具启动即写
> `%APPDATA%\.flutter_tool_state`，而沙箱对 dart 进程写该路径返回 `PathAccessException`。
> 工作区里的 wrapper（`.flutter-sdk/flutterc`）把 `HOME` / `APPDATA` / `TMP` 钉到仓库内的
> `.flutter-home/`；每一处调用都要带 `--no-pub`，否则它会先跑一次 `pub get` 撞上符号链接。

`flutter build apk` / `flutter run` 在本机会失败于一个**与代码无关**的原因：它们交给 Gradle 的环境只有 `JAVA_HOME` 和 `PATH`，`gradlew.bat` 于是找不到 `~/.gradle`，算出错误的 dists 路径后试图重新下载，撞上 `gradle-9.3.1-all.zip.lck (Access denied)`——看起来像权限问题，其实不是。`tool/build_apk.sh` 钉住环境变量后直接调 Gradle；`tool/repro_lck.sh` 可以复现这个判断。完整分析见 [`docs/flutter-design.md`](docs/flutter-design.md) 的 7.4。

包名是 **`dev.lexumo.lexumo`**（`flutter/android/app/build.gradle.kts`）。写错会让 `pm path` 永远返回空，很容易把「已经装上了」误判成「没装上」。

重新生成应用图标（需要 Pillow）：

```bash
python flutter/tool/generate_icons.py           # 写入 .ico 与五档 mipmap PNG
python flutter/tool/generate_icons.py --check   # 只打印几何表，不写文件
```

`.ico` 会逐字节复原；Android 的 PNG 像素一致但字节不同（Pillow 的编码器换过），**所以校验图标要比像素，不要比哈希**。

## 测试

```bash
cd flutter
../.flutter-sdk/flutterc test                                # 全部
../.flutter-sdk/flutterc test test/mobile_layout_test.dart   # 手机布局三条预算
../.flutter-sdk/flutterc test test/responsive_layout_test.dart # 五个视口 × 七个界面
../.flutter-sdk/flutterc test test/app_mount_test.dart       # 真实 main.dart 的嵌套能挂载、能点
```

**930 个通过、6 个跳过**（跳过的是需要真 Postgres 桥接的用例，见下面第四层）。按关注点分组：

| 文件 | 用例数 | 覆盖内容 |
| --- | --- | --- |
| `test/domain_test.dart` | 137 | 领域纯逻辑：SRS 调度算术、状态永不降级、会话状态机的撤销、出题、日期统计、迁移与线格式 |
| `test/translate_test.dart` | 61 | 各查词源的解析、词性与义项拆分、缓存命中、限流降级与冷却、注入的适配器与时钟 |
| `test/sync_engine_test.dart` | 47 | 同步循环：防抖推送、轮询、在途编辑仍留 pending、令牌过期重登、一轮同步的结算顺序 |
| `test/sync_merge_test.dart` | 36 | 待推改动收集、LWW 合并、墓碑删除、日志并集去重 |
| `test/tts_test.dart` | 30 | 朗读封装：语言映射、语速、音色缺失时的静默降级 |
| `test/onboarding_test.dart` | 27 | 首次启动的本地/同步两条路、连不上时的退路 |
| `test/update_service_test.dart` | 25 | 升级四步：检查 → 下载（边下边算摘要）→ 校验 → 交给安装器；取消不是失败 |
| `test/stats_view_model_test.dart` | 23 | 统计页每个数字的来源、7/30/90 天窗口、空库状态 |
| `test/words_layout_test.dart` | 21 | 词库页布局：查询带、当前词库下拉、横滚标签带、行操作 |
| `test/transfer_test.dart` | 21 | 三种格式进出口：CSV 表头顺序与 RFC 4180 引号、BOM 与 CRLF、JSON 只恢复词条、Anki 多列合并与 HTML 剥离 |
| `test/home_view_model_test.dart` | 21 | 首页头条、目标环、近七天柱、快捷入口 |
| `test/flashcards_view_model_test.dart` | 21 | 组卡方式与数量、评分预览、撤销、新卡上限 |
| `test/supabase_transport_test.dart` | 20 | Supabase 侧 auth/rest 的请求形状与错误分类 |
| `test/word_editor_view_model_test.dart` | 18 | 编辑器的字段、校验、查词与反查、有未保存改动时的拦截 |
| `test/tokens_test.dart` | 18 | 设计令牌自检：字号阶梯比例、行高、对比度门槛 |
| `test/wire_test.dart` | 17 | 同步线格式：逐字段重建让服务器盖的 `_rev` 无法回写/回推/进备份、畸形记录被丢弃、可选文本字段往返不丢 |
| `test/quiz_view_model_test.dart` | 17 | 出题：选项不重复且必含答案、同词不重复、词表不足四个时不崩 |
| `test/view_model_test.dart` | 16 | `ViewModel` 基类契约：dispose 后不再 notify |
| `test/version_test.dart` | 15 | SemVer 解析与比较，决定「这是不是一次升级」 |
| `test/profile_layout_test.dart` | 14 | 我的页：身份块、三个数字、平铺行、推开的设置页能回来、411dp 无溢出 |
| `test/kana_deck_test.dart` | 14 | 五十音推荐词库的内容与顺序 |
| `test/widget_test.dart` | 13 | 通用 widget：Card / HairlineRow / SectionTitle / EmptyState |
| `test/update_manifest_test.dart` | 13 | 清单解析：版本、摘要、大小、渠道，坏清单被拒绝 |
| `test/mobile_layout_test.dart` | 13 | 手机布局三条预算：411dp 不抛异常、每个 GestureDetector 两维 ≥ 44dp、首屏预算 |
| `test/settings_update_test.dart` | 12 | 设置页的升级区块与四种失败原因文案 |
| `test/editor_lookup_test.dart` | 12 | 查词按钮的四种结果落地：填字段、查不到、离线、限流 |
| `test/system_ui_test.dart` | 11 | 系统栏：edgeToEdge、图标明暗跟随主题 |
| `test/sync_e2e_test.dart` | 11 | 对着自建后端跑真实 HTTP（跳过时需先起 `server/`） |
| `test/keyboard_hints_test.dart` | 11 | 快捷键提示按平台给（`Ctrl` vs `⌘`），不按宽度给 |
| `test/i18n_test.dart` | 10 | 字典自检：中英键集完全一致、无空串、占位符一致、键名必须带命名空间 |
| `test/entrance_test.dart` | 10 | 入场动画与「减少动态」归零 |
| `test/backend_transport_test.dart` | 10 | 按地址路由：`.supabase.co` 走 Supabase，其它走自建后端 |
| `test/toast_test.dart` | 9 | 提示条队列：悬停暂停、可手动关闭、撤销入口 |
| `test/settings_transfer_test.dart` | 9 | 导入预览弹窗与去重统计 |
| `test/flashcards_swipe_test.dart` | 9 | 滑动评分的方向语义与阈值 |
| `test/settings_sync_test.dart` | 7 | 同步区块的状态显示与错误文案 |
| `test/settings_layout_test.dart` | 7 | 设置页在小宽度下不溢出 |
| `test/responsive_layout_test.dart` | 7 | 七个界面 × 五个视口 × 两个字号，断言不抛布局异常 |
| `test/practice_layout_test.dart` | 6 | 练习页：横条在滚动区之外、组卡信息一句话只说一次、620dp 居中 |
| `test/density_test.dart` | 6 | 触控密度：44dp 地板与命中盒 |
| `test/supabase_e2e_test.dart` | 5 | 对着真 Supabase 项目跑（需 `LEXUMO_SUPABASE_E2E=…`） |
| `test/study_split_test.dart` | 5 | 宽屏两栏的拆分点与左栏宽度 |
| `test/settings_supabase_test.dart` | 5 | 设置页指向 Supabase 时的字段与文案 |
| `test/editor_test.dart` | 4 | 编辑器弹窗的挂载与保存 |
| `test/app_mount_test.dart` | 4 | 真实 `main.dart` 的嵌套能挂载、首帧不抛、点 tab 真换页 |
| `test/store_undo_test.dart` | 3 | 删除与撤销：词条连同它的复习记录一起回来 |
| `test/release_artifacts_test.dart` | 3 | 发布清单与磁盘产物一致（版本、大小、sha256） |
| `test/sync_token_rebase_test.dart` | 1 | 令牌刷新与在途请求的重新对齐 |

四层验证各自抓不到什么，记在 [`docs/flutter-design.md`](docs/flutter-design.md) 末节：

| 层 | 命令 | 抓不到 |
| --- | --- | --- |
| 单元/widget | `flutterc test` | 真实 HTTP 形状、SQL |
| SQL | `supabase/tests/run.sh` | 客户端是否说对协议 |
| 端到端 | `LEXUMO_SUPABASE_E2E=… flutterc test test/supabase_e2e_test.dart` | 真实 GoTrue 的 JWT |
| 差分 | `node supabase/tests/differential.cjs` | 两者是否**都对** |

布局不靠看截图确认。`test/mobile_layout_test.dart` 用预算断言管住「够不够用」（411dp 不抛异常、触控目标两维 ≥ 44dp、首屏预算），`test/responsive_layout_test.dart` 管住「还有没有别的模式」（五个视口 × 两个字号）。数字取「设计能容忍的最大值」而不是某一次量到的值，所以字体度量浮动半个像素不会让测试变成绊线。

还有一类更隐蔽的：**树形装错了层**。0.2.4+5 上线后应用卡在首页、点什么都不响应，根因是 `main.dart` 把 `ToastHost` 包在 `MaterialApp` 外面，而它画的是裸 `Stack`，`Stack` 要从 `MaterialApp` 装的 `Directionality` 解析默认对齐——首帧布局就抛 `Null check operator used on a null value`，什么都没画出来。所有 widget 测试都在手工拼树（把 `ToastHost` 放在 `MaterialApp` 里面），因此永远看不见 `main.dart` 自己的嵌套。`test/app_mount_test.dart` 为此不再拼树：它 pump 的就是 `LexumoApp` 本身。

## 数据存储

- **主存储**：一个版本化 JSON 快照 `AppData`，Windows 在 `%APPDATA%\Lexumo\lexumo.json`，Android 在应用私有目录。

  ```dart
  class AppData {
    final int version;              // 当前 DATA_VERSION = 3
    final List<WordList> lists;
    final List<Word> words;
    final List<ReviewLog> logs;     // 每次评分的复习日志
    final Settings settings;
    final int settingsUpdatedAt;    // 设置项参与同步时的 LWW 时间戳
    final Map<String, int> tombstones;  // 已删除的词/词库/日志 id → 删除时间
    final Map<String, int> pending;     // 尚未推送到服务器的改动（id 列表）
  }
  ```
- **写入策略**：所有变更走 `data/repositories/store.dart`，不可变快照，先通知订阅者再落盘。记录一律**替换**而非就地修改，旧快照不会被后续编辑污染。加一个写操作意味着同时加一条 journal 记账。
- **原子落盘**：`snapshot_store.dart` 先写 `lexumo.json.tmp`，flush 后 rename 覆盖正式文件，并留一份 `lexumo.json.bak`。崩溃只会看到旧文件或新文件，不会看到半个文件；读不出来时上报错误并尝试 `.bak`，而不是抛异常炸掉启动。
- **同步记账**：`pending` 与 `tombstones` 只由 `data/models/journal.dart` 写入，业务操作不再各自手写 `mark*Dirty`。这样「本地改动必须被推送」「本地删除必须留墓碑」两条不变量由模块保证；删词、批量删词、删词库共用同一套级联，不会留下孤儿复习日志。
- **登录凭据单独存**：会话与 `rev` 放在同目录的 `sync.json` 里，同样的原子写纪律。**故意不放进 `AppData`**——`Settings` 是参与同步的，把 bearer token 放进去等于把它上传给认证它的那台服务器，还会跑进每一次备份。
- **线格式边界**：服务器给每条记录额外盖一个 `_rev`，它属于服务器的簿记，不属于词条。`data/models/wire.dart` 在边界上逐字段重建领域记录（剥掉 `_rev` 与任何未知键，形状不符的记录直接丢弃而不是抛错），因此 `_rev` 不会写进快照、不会被下次上传回推、也不会跑进用户的 JSON 备份。**逐字段重建意味着字段白名单必须完备**：`phonetic` 与 `exampleZh` 都曾在白名单之外，导致音标和例句译文在同步与 JSON 备份两侧被静默剥离——两者现在都在白名单里，且 `wire_test.dart` 有专门的回归用例。
- **版本迁移**：启动时若快照 `version` 低于 `DATA_VERSION`，会就地补齐新字段并保留原有数据；只有 `version` 高于当前版本（降级运行）才会重新播种。
- **清空数据的传播**：清空会为每个被删的词、词库、日志写墓碑（否则下次登录同步会把「已清空」的数据再拉回来）；唯独默认词库只更新时间戳而不写墓碑——它的 id 是固定值，新快照一定会重建它，写墓碑会让回声删除把刚建好的空词库也删掉。
- **隐私**：数据默认只在本机。只有在「设置 → 账号与同步」中显式登录后，词库、复习日志与设置才会推送到你填写的服务器地址；不登录则没有任何网络上传。

## 导入 / 导出格式

三种格式均为 **UTF-8 文本**。

### JSON（完整快照）

导出整个 `AppData` 对象（含 `version`、词库、词条、复习日志、设置），用于无损备份；`pending` / `tombstones` 这些同步簿记**不导出**，别把它们交给用户。

导入时支持两种输入：完整快照对象（读取其 `words` 数组）或直接的词条数组。**导入只恢复词条**，不会覆盖已有的复习日志与设置；缺少 `term` 的行会被跳过。

### CSV（表格）

导出首行为表头，列顺序固定：

```csv
term,pos,definition,definition2,example,exampleTranslation,note,status
serendipity,n.,意外发现美好事物的能力,,a serendipitous meeting,一次机缘巧合的相遇,来自阅读,reviewing
```

- `pos` 是词性，可留空；导入时也认 `part of speech`/`partOfSpeech`/`词性`。释义本身不含词性前缀，两者分开存；
- `exampleTranslation` 是例句的译文，可留空；导入时也认 `example_zh`/`examplezh`/`例句翻译`/`例句译文` 这几个列名；
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

## 例句

例句不是一个单独的字段，而是**一对**：`example`（原句）与 `exampleZh`（它的译文）。

- **点击才填**：按下「翻译」按钮时，把词典返回的第一组双语例句一起填进来。有道 `jsonapi` 会给 3 组，取第一组；降级到机器翻译那条链时拿不到例句，只填释义。字典给什么就填什么——按钮本身就是显式覆盖。
- **原句和译文成对写入**：两者要么一起换、要么都不动。译文只在写入它配套那句话的同一步里写；你自己手写的原句下面不会被贴上词典里另一句的译文，那比没有译文更糟。译文输入框也只在有原句时出现。
- **闪卡背面**：原句与译文分两行显示，原句斜体，译文字号小一档、颜色淡一档。空白译文不占位。
- **导入导出**：CSV 有 `exampleTranslation` 列，JSON 快照里是 `exampleZh`，两者都会随同步传播。

> 为什么不用 Tatoeba：它的官方 API 有 CORS 但**不返回配对的译文**（`trans` 系列参数一律 400，单条记录的 `/translations` 端点 404），中文句子覆盖也稀疏——常用词有 10 条，`resilient` / `ubiquitous` / `serendipity` 这类恰好是你要背的词却是 0 条。再加上单次查询 7–30 秒的延迟，它不适合做「点一下就填」这条同步路径。有道那 3 组中英对照是查词时本来就已经下载到本地的数据。

## 多端同步

同步是**可选的**：不登录时应用与单机版完全一致。需要多设备共享时有两条路：

- **默认连自带的 Supabase 项目**：地址与公开的 publishable key 已编译进 `flutter/lib/data/models/sync_config.dart` 的 `kDefaultServer` / `kDefaultAnonKey`，装好直接填邮箱密码即可。换成自己的 Supabase 项目只需在设置页改这两项，不用重新编译。
- **自建后端**：仓库自带一个零依赖的 Node 实现（`server/`），适合局域网或自己的服务器。客户端按地址自动路由：域名里带 `.supabase.co` / `.supabase.in` 走 Supabase 的 `auth/v1` + `rest/v1/rpc/sync`，其它地址走自建后端的 JSON API。

### 1. 启动自建后端（如果走这条路）

```bash
cd server
npm start
# 默认 http://127.0.0.1:8787，数据写在 server/data/
```

零第三方依赖，只需要 Node 20+。`PORT` / `HOST` / `DATA_DIR` 三个环境变量可调；想让手机和电脑都连上，把 `HOST` 设为 `0.0.0.0` 并用局域网 IP 访问。详见 [`server/README.md`](server/README.md)。

### 2. 在应用里登录

打开「我的 → 设置 → 账号与同步」：

1. 服务器地址保持默认（走 Supabase），或填自建后端地址（例如 `http://192.168.1.10:8787`），可先点「测试连接」；
2. 填邮箱与密码，首次点「创建账号」，之后在别的设备上点「登录」；
3. 登录成功后会自动推一次本地改动并拉取服务器上的数据。

默认开启自动同步：本地编辑后防抖推送、定期轮询未推送的改动、网络恢复时立即同步。也可以手动点「立即同步」。设置页实时显示「已同步 / 正在同步 / 这次没同步上 / 待同步条数」。

> 用自带的 Supabase 项目前，要先在该项目的 Dashboard 里把 **Authentication → Sign In / Providers → Email** 打开，否则注册与登录都会被 GoTrue 拒绝（`email_provider_disabled`）。应用会把这条错误翻成中文提示，而不是笼统的「服务器出错了」。

### 3. 冲突与删除的处理

- **词条与词库**：整条记录同步，按 `updatedAt` 后写胜出（LWW）。本地有未推送的改动且比服务器上的更新时，保留本地版本并在下一轮推送。
- **复习日志**：只追加，按 `id` 去重做并集，不会互相覆盖；撤销评分时会写入日志墓碑，让删除也能传播。
- **删除**：写墓碑（`{ id, updatedAt, deleted: true }`）而不是直接抹掉，否则离线设备下次同步会把删掉的词再推回来。
- **设置**：整体按 `settingsUpdatedAt` 做 LWW。
- **首次登录**：本地已有的词库（包括首次启动的示例词库）会整批上传，所以新设备登录后能看到全部内容。

接口契约见 [`docs/sync-protocol.md`](docs/sync-protocol.md)，客户端 `data/services/` 下的 transport 与后端 `server/`、`supabase/` 都以它为准。

## 发布

从 `flutter/` 下跑，两条命令：

```bash
./tool/build_apk.sh     # 未签名配置下的 release 包（本地自用）
./tool/release.sh       # 签名包 + dist/update.json，发布用
```

第一次发布前还要跑一次 `./tool/setup_signing.sh`：它把 keystore 复制进 `android/`、用 `read -s` 收密码（不进 shell 历史）、**先拿 keytool 验一遍再写** `android/key.properties`。密码错或 alias 错时它不写文件——写下去的错配置要等五分钟构建才失败，而现象看起来像签名坏了。

`release.sh` 读 `pubspec.yaml` 的 `version:` 作为唯一版本来源，写进 `android/local.properties` 并同时经 `-Pdart-defines` 注入应用，然后从磁盘上真实的 APK 算 `sha256` 与大小写进清单。它**不发网络请求**，发布那一步是它打印出来的 `gh release create`。没有 `android/key.properties` 时它直接失败，不回落 debug 签名——debug 密钥随机器变，装过 debug 包的人就再也无法覆盖升级。

打 `v*` 标签会触发 `.github/workflows/release.yml`：analyze + 全量测试 → 校验标签与 `pubspec.yaml` 一致 → 用四个 secret 解出 keystore → 构建 → `apksigner verify` 且拒绝 debug 证书 → 生成清单 → 发布 release 资产。需要的 secret：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。

更新说明可选：在 `flutter/notes.json` 里写 `{"zh": "…", "en": "…"}`，或者直接写一段中文正文（整段归到 zh）。这个文件存在时 `release.sh` 自动读它，CI 读同一个文件。没有这个文件时清单里就没有 `notes`，应用会把「更新内容」整段省掉，而不是画一个空的标题。

应用内升级的链路、三条判断（进度信字节不信安装器、唯一成功证据是 build 变了、取消不是失败）记在 [`docs/flutter-design.md`](docs/flutter-design.md) 的 7.6 节。

## 已知限制

- **平台**：Windows 与 Android 是目标平台。Windows 构建在本机需要开启开发者模式（Flutter 插件要建符号链接），目前没有任何 Windows 安装包被发布过——所有 release 资产都只有 `.apk` 与 `update.json`。macOS / Linux 从未构建。
- **账号体系**：登录用邮箱密码，走 Supabase 的 GoTrue。自带的那个项目必须先在 Dashboard 打开 Email provider，且本机网络不能对该域名做 SNI 拦截（被拦时表现为连接超时，不是鉴权失败）。
- **在线查词**：依赖有道词典 / MyMemory / Google 等公开接口，需联网；接口可能限流或变更，届时查词会降级或提示失败，不影响手动录入。只有点按钮才会发起请求。缓存 30 天，设置里可清除。
- **代理**：`dart:io` 的 `HttpClient` 不读 Windows 的系统代理设置，也不读环境变量（`findProxy` 没有接）。需要走代理时用 TUN 模式的全局代理，否则同步与查词都会直连失败。
- **TTS**：依赖系统语音合成引擎，可用音色与语言随平台而异；部分语言可能没有可用语音，此时听音功能静默降级。Windows 上 `flutter_tts` 需要 `tool/patch_tts_windows.cjs` 处理一下，已经随仓提交。
- **同步**：自带的后端是单进程、每用户一个 JSON 文件的实现，适合个人或小规模自建；不支持集群、无数据库、无备份策略。自建后端默认是明文 HTTP（本机或局域网内使用没问题，暴露到公网请自行在前面加 HTTPS 反向代理）。Supabase 那条路是 HTTPS。
- **规模**：采用「全量快照 + 防抖写盘」，词条量很大（约 2 万以上）时每次写入会有可感知延迟。同步也是整条记录增量传输，单次最多 5000 条改动。
- **导入编码**：仅支持 UTF-8，GBK 等编码需先转码；Anki 的 `.apkg` 包不在支持范围内。
- **搜索**：内存过滤，无分词与模糊匹配，也不支持正则。
- **文档里的旧截图与旧审计**：`docs/app-ui.png` 与 `docs/usability-round.md` 只属于已移除的网页版，保留作历史记录，不代表当前界面。

## 许可

- **许可**：本项目以 **GNU AGPL-3.0** 授权，许可证全文见 [`LICENSE.txt`](LICENSE.txt)。
- **第三方组件**：Flutter、flutter_tts、file_selector 等依赖的许可见 [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)。
- **图标**：由 `flutter/tool/generate_icons.py` 使用 Pillow 生成，全部是几何图形（圆角矩形 + 圆点），不含任何字体字形或第三方素材，可自由随项目分发。
- **字体**：IBM Plex Sans / Serif / Mono 为 SIL Open Font License 1.1，来源与许可见 [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)。
