# Lexumo · 词砚 — Flutter 移植说明

这份文档记录 `flutter/` 这一份实现：它从 `src/`（Tauri 2 + React 19）逐层移植而来，
**不是** 一次重新设计。视觉决策仍以 `docs/design.md` 为准；本文只说明那些决策在
Flutter 里如何落地、哪些地方因为平台差异不得不换一种写法、以及哪些东西是已知缺口。

工程规模：`lib/` 与 `test/` 共 44,436 行 Dart，827 个测试通过（另有 6 条需要真 Postgres
桥接的 E2E 默认 skip），`flutter analyze` 零问题。

---

## 1. 为什么是 Flutter，以及它换来了什么

原来的技术栈是 Tauri 2 + React 19 + TypeScript：WebView 渲染界面，Rust 侧做文件读写。
问题出在 WebView 这一层——不同 Windows 机器上 WebView2 的版本、字体回退、输入法
行为、拖拽区域各不相同，一些组件（自绘窗口条、拖拽区域、滚动条）在部分机器上直接
失效。而这些恰好是桌面背单词应用最依赖的部分。

Flutter 换成自绘引擎：不再有 WebView，字体随包走，绘制结果在 Windows / Android / macOS
上是同一份代码。代价是包体（Windows release 约 20 MB 起步）和「所有控件都要自己写」——
React 里靠 CSS 一行搞定的东西，在 Flutter 里是一个 Widget。

这次移植的结论：**值得**。两端都能跑，`flutter analyze` 零问题，827 个测试覆盖纯逻辑与
共享控件，Android 上真机验证过完整流程。但工作量比预期大——页面层占了全部代码的 40%。

---

## 2. 目录结构与职责

```
flutter/lib/                        67 个文件，28,593 行（test/ 另有 45 个文件 15,843 行）
  main.dart            入口：Store 初始化 → UpdateService → 作用域树 → MaterialApp
  app/                 组合根：谁在什么时候构造谁
    scope.dart         InheritedWidget 层：StoreNotifier / StoreScope / I18nScope / ToastScope / NavScope
    update_scope.dart  更新服务的 InheritedNotifier：UpdateNotifier / UpdateScope
  data/                数据层：外部世界与持久化
    models/
      journal.dart     变更日志：pending / tombstones 记账（217 行）
      wire.dart        协议编解码：encode/decodeChangeSet、encodeAppData（539 行）
      sync_merge.dart  合并：collectChanges / applyRemote / applyRound（316 行）
      sync_config.dart 凭证与 rev 持久化到 sync.json（195 行）
    repositories/      仓库：唯一写入口 + 缓存/重试/合并策略
      store.dart       全部写操作的唯一入口，不可变提交（561 行）
      sync_engine.dart 会话、轮次、轮询、状态广播（486 行）
      update_service.dart 升级状态机：检查/下载/校验/安装（788 行）
    services/          服务：无状态地包住一项外部能力
      snapshot_store.dart Persistence 接口 + 文件实现 + MemoryStore（测试用）
      app_dir.dart     数据目录解析，含 updateDir（APK 暂存目录）
      transfer.dart    导出 JSON / CSV / Anki 与导入解析（394 行）
      sync_transport.dart SyncTransport 接口 + IoTransport（自建协议）+ CredentialAware（167 行）
      supabase_transport.dart  GoTrue 登录刷新 + PostgREST 调 RPC（320 行）
      backend_transport.dart   按 URL 形状在两个后端间分派（162 行）
      tts.dart         朗读服务：TtsEngine 接缝 + Speech + 语速/音色换算（500 行）
      speech.dart      speakWord / speakTerm：朗读 + 计数，页面唯一入口
      translate.dart   查词客户端：三个适配器 + 磁盘缓存 + 429 冷却（1145 行）
      file_dialogs.dart 文件选择/保存接缝：Android 走平台通道，桌面走 file_selector（167 行）
      app_installer.dart 安装接缝：通道 dev.lexumo.lexumo/app + FakeAppInstaller（341 行）
  domain/              纯逻辑，无 Flutter 依赖
    models/
      types.dart       AppData / Word / WordList / ReviewLog / Settings / Tombstones / PendingChanges
      srs.dart         间隔重复：applyGrade / statusForInterval / previewGrades
      session.dart     会话状态机：current / record / skip / undo / reset
      quiz.dart        出题：buildQuiz / quizShortfall / quizEligibleWords
      seed.dart        示例词库
      languages.dart   70 种语言选项
      utils.dart       uid / startOfDay / dayKeyOfTs / normalizeTerm / jsRound …
      version.dart     SemVer + ReleaseVersion：解析与比较（229 行）
      update_manifest.dart ReleaseManifest / ApkArtifact / UpdateCheck（266 行）
    use_cases/         用例：跨模型的一段业务，值得单独测
      word_query.dart  索引与查询：buildWordIndex / queryWords / summarize（317 行）
      day_stats.dart   今日复习数、连续天数（49 行）
  ui/                  界面层：按功能分包，每个功能有 view_models 与 views
    core/
      view_model.dart  MVVM 契约：ViewModel 基类 + Feedback 端口 + ToastKind
      context_feedback.dart Feedback 的 BuildContext 实现（唯一的适配器）
      system_ui.dart   系统栏：edgeToEdge + shellOverlayStyle（深色/浅色自适应图标）
      theme.dart       ThemeData 构建，把 Palette 塞进 ThemeExtension
      tokens.dart      全部设计令牌（Palette / Sp / R / Fs / Lh / Fonts / Motion / Layout / Shadows）
      i18n/
        i18n.dart      I18n 运行时：dict / t(key, vars) / has(key)
        zh_cn.dart     411 条键
        en.dart        同键英文（键集由 i18n_test 强制一致）
      widgets/
        widgets.dart   PageShell / Segmented / EmptyState / ProgressBar / Ring / StatusChip / StatTile / ShortcutRow / Kbd / Card
        controls.dart  LexButton / LexInput / LexTextArea / LexSelect / showLexModal / confirmLex / ContentCenter / LexField
        density.dart   触控密度：isTouchPlatform / TouchDensity extension / TapTarget
        lex_icon.dart  图标系统：Ic 常量 + LexIcon
        icon_paths.dart SVG path 数据
        keyboard_hints.dart showKeyboardHints()：按平台判断是否显示键帽（32 行）
        toast.dart     轻提示：堆叠、悬停暂停、入场/退场（367 行）
        entrance.dart   入场原语 FadeRise：一个控制器，延迟走 Interval（126 行）
    features/
      home/
        view_models/home_view_model.dart           首页聚合：今日目标 / 连续天数 / 近七天（306 行）
        views/home_page.dart                       只画（982 行）
      words/
        view_models/words_view_model.dart          列表 + 筛选 + 批量操作（477 行）
        view_models/word_editor_view_model.dart    新建/编辑词的草稿与查词（486 行）
        views/words_page.dart                     只画，不含判断（2031 行）
        views/word_editor.dart                    只画（767 行）
      flashcards/
        view_models/flashcards_view_model.dart     会话 / 翻面 / 评分 / 撤销（582 行）
        views/flashcards_page.dart                 只画（1387 行）
        views/session_result.dart                  会话结果卡（两个学习页共用）
      quiz/
        view_models/quiz_view_model.dart           一轮测验 / 答案 / 错题（364 行）
        views/quiz_page.dart                       只画（1018 行）
      stats/
        view_models/stats_view_model.dart          图表数据推导（276 行）
        views/stats_page.dart                      只画（899 行）
      settings/
        view_models/settings_view_model.dart       设置项、词典缓存、同步表单
        views/settings_page.dart                   只画
      update/
        view_models/update_view_model.dart         升级卡状态（393 行）
        views/update_sheet.dart                    只画（384 行）
      shell/
        view_models/shell_view_model.dart          三档布局 + 六页切换（198 行）
        views/app_shell.dart                       只画（870 行）
  third_party/
    flutter_tts/       flutter_tts 4.2.5 的原样拷贝，只改 Windows 的 C++（见 7.2）
```

**分层纪律**：`domain/` 不 import Flutter，因此可以脱离 widget 树测试；`data/` 只依赖
`domain/`；`ui/features/*/views/` 只读 `view_models/` 暴露的 getter 与回调，自己不做业务
判断；`view_models/` 只 import `package:flutter/foundation.dart`——不碰 `material`/`widgets`，
所以能脱离 widget 树测试；`app/` 是唯一知道「谁在什么时候构造谁」的地方。

MVVM 的那条线由两个文件钉住：`ui/core/view_model.dart` 定义 `ViewModel` 基类（`update()`
在已 dispose 时静默丢弃，避免写操作落在已弹出的页面上时抛 `A ChangeNotifier was used
after being disposed`）和 `Feedback` 端口（`t` / `toast` / `confirm` / `goTo`——页面需要的
四件外部事情）；`ui/core/context_feedback.dart` 是它唯一的 `BuildContext` 实现，用
`getInheritedWidgetOfExactType` 而不是 `dependOnInheritedWidgetOfExactType`，这样 view
model 不会注册一个会重建自己所在 widget 的依赖。

`platform/` 这个目录已经不存在了：朗读、查词、文件选择、安装本来就是「包住一项外部能力
的无状态服务」，现在都在 `data/services/` 里；数据目录也在那里，因为它是持久化的一部分。
这几件事在 Web 版里分别是 Web Speech API、一次 `fetch`、`<input type="file">`、
localStorage——都是浏览器白送的，这里都要自己写。

---

## 3. 设计令牌如何落到 Flutter

`src/styles/tokens.css` 的每一个值都在 `lib/ui/core/tokens.dart` 里有对应常量，
命名按语义而非数值：

| CSS 变量 | Dart | 说明 |
| --- | --- | --- |
| `--bg` `--surface` `--surface-2` … | `Palette.of(context).bg` / `.surface` / `.surface2` | `Palette` 是 `ThemeExtension`，随亮暗主题切换 |
| `--sp-1` … `--sp-16` | `Sp.x1` … `Sp.x16` | 4 / 8 / 12 / 16 / 20 / 24 / 28 / 32 / 40 / 48 / 64 |
| `--r-2xs` … `--r-full` | `R.x2xs` … `R.full` + `R.borderXs/sm/md/lg/xl` | 后一组是 `BorderRadius` 现成对象 |
| `--fs-xs` … `--fs-3xl` | `Fs.xs` … `Fs.x3xl` | 12 / 13 / 15 / 16 / 19 / 24 / 30 / 38 |
| `--lh-*` | `Lh.none/display/title/tight/snug/body/loose` | 1 / 1.05 / 1.15 / 1.2 / 1.4 / 1.6 / 1.7 |
| `--font-display/ui/mono` | `Fonts.display/ui/mono` | IBM Plex Serif / Sans / Mono |
| `--ease-*` `--dur-*` | `Motion.ease/easeOut/easeIn/easeTurn` + `Motion.dur1..dur5` | 120 / 180 / 260 / 420 / 620 ms |
| `--sidebar-w` `--content-max` … | `Layout.sidebarW` `Layout.contentMax` … | 232 / 1180 / 36 / 44 / 1000 / 720 |

关键点：**颜色只能从 `Palette.of(context)` 取**。没有全局颜色常量，也没有硬编码 `Color(0xFF…)`
散落在页面里——亮暗主题切换时，每个 `Palette` 字段自动换值，页面代码一行不用改。

字体：IBM Plex 三个家族共 8 个 TTF（约 1.4 MB）打包在 `assets/fonts/`，
`pubspec.yaml` 按 weight 400/500/600 注册。**CJK 故意不打包**——Plex 没有中文字形，
靠系统的 PingFang SC / Microsoft YaHei，`Fonts.cjkFallback` 列了 7 个候选。

这 8 个 TTF 不是手下的：`scripts/fetch-plex-ttf.cjs` 向 Google Fonts 要 css2 时
**故意不带 User-Agent**，这样返回的 `src` 是 `.ttf` 而不是 `.woff2`（Flutter 只吃前者），
然后把二进制直接写到 `flutter/assets/fonts/`。Web 版用的是 woff2（`src/styles/fonts.css`），
所以这是一份独立的取字流程，不是复用。

---

## 4. 状态管理与不可变提交

React 那边是 `useSyncExternalStore` + 不可变快照。Flutter 这边同样：

- `Store` 持有唯一的 `AppData`。所有写操作（`addWord` / `gradeWord` / `updateSettings` …）
  **返回一个新的 `AppData`**，而不是就地修改。`_commit` 用 `identical(next, _data)`
  判断「没有任何变化」并跳过通知，所以空操作不会触发重建。
- `StoreNotifier extends ChangeNotifier` 桥接 `InheritedWidget`。`context.data` 读快照
  并订阅变更；`context.store` 只拿操作入口，不订阅——避免「只想写却被动重建」。
- 保存是防抖的（`saveDelayMs` 默认 220ms），窗口关闭时 `flush()` 兜底。
- `Persistence` 是三方法接口（`load` / `save` / `clear`）。测试用 `MemoryStore`，
  生产用 `SnapshotStore`（写入临时文件再原子改名，保留 `.bak`）。

一个和 TypeScript 版不同的地方：TS 用 immer 式 draft 再 mutate，Dart 版**每个操作显式
构造新对象**。好处是没有隐藏的状态共享，坏处是 `copyWith` 调用很多——`domain/types.dart`
里的 `Word.copyWith` 因此支持 `clearSrs` 这样的显式清除标记。

### 页面状态搬进 view model

页面原来自己 `setState` 管一切，结果每一页都是一个两千行的 `State`，业务判断和
`Column` 挤在同一个 `build()` 里。现在每个功能多一个 `view_models/` 目录，页面只剩
「读 getter、发意图、摆 widget」：

```dart
class _WordsPageState extends State<WordsPage> {
  late final WordsViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = WordsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      speak: (Word word) => speakWord(context, word),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _vm,
        builder: (BuildContext context, Widget? _) => ...,
      );
}
```

三条约束把这条线钉住，缺一条就会退化回原来那种写法：

1. **view model 只 import `package:flutter/foundation.dart`**。不碰 `material`、不碰
   `widgets`、拿不到 `BuildContext`、`MediaQuery`、`Navigator`。它要往外说话只有
   `Feedback` 这一个端口（`t` / `toast` / `confirm` / `goTo`），生产实现是
   `ContextFeedback`，测试实现是 `FakeFeedback`。副作用是每个功能现在都能在**没有
   widget 树**的情况下测——`view_model_test.dart`、`word_editor_view_model_test.dart`
   等六个文件就是这么来的。
2. **写操作还是只有一个入口**。view model 不碰文件、不碰 `Persistence`，它拿到的是
   `Store`，所以「所有写操作都走 `store.dart`，新增写操作等于新增一条 journal」这条
   纪律没有被 MVVM 削弱。
3. **`update()` 在已 dispose 时静默丢弃**。一次保存是 220ms 防抖的，用户完全可能按下
   保存后立刻退出这一页；`ChangeNotifier` 在 dispose 之后再 `notifyListeners()` 会抛
   `A ChangeNotifier was used after being disposed`，而这个异常会落在一次无关的
   异步回调里，堆栈指向持久化层，很难查。基类直接把它吞掉。

文本框和焦点节点**留在 view 里**，不进 view model：搜索框的 buffer 带着光标、选区、
输入法组词状态，它必须在「一次不由它引起的重建」中存活；放进 view model 就得每次
`notifyListeners()` 后重新对齐光标。词编辑页因此多了一个 `_EditorBuffers`，它订阅
view model 并把草稿推回 7 个 `TextEditingController`——**必须在构造函数末尾订阅，
不能在 `build()` 里同步**，否则 `controller.text = ...` 会在帧中途标记
`AnimatedBuilder` 需要重建，直接抛
`setState() or markNeedsBuild() called during build`。

---

## 5. 页面实现要点

### 首页（`home_page.dart`，982 行 + `home_view_model.dart` 306 行）
打开应用落在的那一页，回答的是「现在该做什么」，不是「一共有多少数据」——统计页
已经在答后一个问题了，两页若都铺数字，就没有哪一页是入口。

一页读完的四件事：一句问候带上还剩几张卡（`home.dueHeadline`，过完了换成
`home.dueClear`）、今日目标环、连续天数与已掌握两个块、以及一个**唯一**的实心按钮
「开始复习 · 7」。这一页**不做任何写操作**，四个入口全是跳页（复习→闪卡、测验→测验、
添加→词库、查看→统计），所以它没有「做到一半失败」的状态，也不需要撤销。

几个刻意的取舍：

- **问候语不装卡片。** 卡片是一组「东西」的分组，而问候是页面在说话；把它放进框里，
  它就从「现在该做什么」的答案退化成了又一个控件。
- **一屏只有一个实心按钮。** 复习是主行动，其余三个是次级（描边/文字）。两个实心按钮
  并排等于没有主行动。
- **目标环只放一个环，不放统计页那三行说明。** 手机上这张卡内宽 232dp，120dp 的环
  留给文字约 100dp——够一句短的，不够统计页的三行。首页陈述事实，解释留在统计页。
- **七个界面的顺序**：`_screens`（`responsive_layout_test.dart`）与 `kScreens`
  （`mobile_layout_test.dart`）里 `('home', …)` 排在最前，因为 `PageId` 的声明顺序
  就是标签栏顺序与 Ctrl/Cmd+1…6 的编号，测试列表若用别的顺序，那份顺序就成了假的。

首个把 `PageId` 从五页扩到六页的改动连带三处：`_digitKeys` 从五条扩到六条（它按
`PageId.values` 索引，少一条会在 Ctrl+6 上抛区间错误）、`kShortcutHelp` 与设置页
`_kShortcuts` 的 `Ctrl 1…5` 改成 `1…6`（设置页那是一份**故意镜像**的副本，反向
import 会成环）、`Ic.home` 加进 `icon_paths.dart` 与 `lex_icon.dart`。标签栏同时补了
两件事：`Shadows.tabbarFor(p.isDark)`（令牌写了却一直没接）、以及活动项的
`AnimatedContainer` + 4% 图标缩放——只动 transform 与 opacity，不越界回弹。

`_GoalAndTiles` 里有一处注释值得单独记：外面那个 `IntrinsicHeight(Row(...))` 让环和
两块等高，而**它的子树里不能出现 `LayoutBuilder`**（内禀尺寸算不出来，第 6 节第五类
缺陷就是这么来的），所以两块 `StatTile` 是直接构造的，没有各自的 `LayoutBuilder`。

宽度判断放在实际拿到的 `constraints.maxWidth` 上：环与两块并排的门槛是 640（按内容列
算，不是窗口），行动区竖排/横排是 480。手机上量到的数字：411dp 下
「今天还有 7 张卡片在等你」占 312dp，可用 363dp，不折行；320dp 下六个标签各占
25×14dp，最大的一行也没挤到相邻项。

### 词库页（`words_page.dart`，2031 行 + `words_view_model.dart` 477 行）
最复杂的一页：搜索框、五个状态筛选（全部/新词/复习中/学习中/已掌握）、排序、
收藏筛选、批量选择模式、行内收藏/朗读/删除、空状态。批量模式下底部浮出一条操作栏。

**行布局：词条在上、释义在下。** 这是相对 web 版的一处有意偏离。`WordsPage.tsx`
用的是四列网格（词语 1fr / 释义 1.6fr / 状态 136px / 操作 148px），在桌面上没问题，
但搬到手机上就成了「词容易展示不全」：一列英文词条和一列中文释义各自只能分到约一半
行宽，两边都只能截断。Flutter 版把词条与释义叠进**同一个自适应列**，状态与操作收成
固定宽度的侧栏：

- 宽度 ≥ 640：词条一行、释义在其下方（最多 2 行），右侧是 128px 状态列 + 140px 操作列。
- 宽度 < 640：整行折成三行——词条（2 行）／释义（3 行）／状态+朗读+删除。列头整块隐藏，
  因为两行式布局里它只是重复。
- 工具栏同理：窄屏下搜索框、状态条、工具按钮分三行，状态条横向可滚动，避免把筛选
  按钮裁掉一半。

`test/words_layout_test.dart` 用几何断言锁住这三点（释义在词条下方、释义列宽占行宽
一半以上、窄屏不溢出），因为截图只能证明「看起来对了」，不能证明「为什么对了」。

### 闪卡页（`flashcards_page.dart`，1387 行 + `flashcards_view_model.dart` 582 行）
会话状态机来自 `domain/models/session.dart`。卡片翻面是两段式 Y 轴旋转（`Matrix4.rotateY`），
键盘：空格翻面、1/2/3 评分、←/→ 跳过、Ctrl+Z 撤销。右侧面板显示快捷键与进度。
会话结束复用 `session_result.dart`。

### 测验页（`quiz_page.dart`，1018 行 + `quiz_view_model.dart` 364 行）
四个选项自适应排成 1/2/4 列（240px 最小宽度）。答完即时反馈：正确项描边 accent，
错选项描边 cinnabar，其余降到 55% 不透明度。键盘 A–D / 1–4 选择，Enter 下一题。

### 统计页（`stats_page.dart`，899 行 + `stats_view_model.dart` 276 行）
目标环 + 六个统计块 + 状态分布条 + 今日待复习列表。全部数值来自
`domain/use_cases/word_query.dart` 的 `summarize()`，页面本身不做计算。

### 设置页（`settings_page.dart`，1822 行 + `settings_view_model.dart` 627 行）
六块：外观（主题三选、界面语言二选）、学习（每日目标、新卡上限、复习顺序）、
音频（语速、自动发音、音色选择与试听）、词典（缓存条数与清空）、同步（登录态、
服务器地址、Supabase anon key、自动同步开关、立即同步、退出登录）、数据（计数、
导出 JSON / CSV、导入、清空）。
写操作全部经 `store.updateSettings`；导出/导入走 `data/services/transfer.dart` 与
`data/services/file_dialogs.dart`，同步走 `data/repositories/sync_engine.dart`。

词典那一块只有一行「N 条 / 清空」，看着单薄，但两个细节是有意的：条数在
view model 构造时读一次、清空后再读一次，而不是每次 build 都调 `cacheSize()`；缓存为 0
时按钮置灰——新装的机器上「无可清」是真实状态，一个看着能按却什么都不做的按钮比
一个看着不可用的更糟。

同步这一块有两种登录形态，靠 `detectBackend(server)` 判断当前是哪一种：自建协议只要
服务器地址 + 邮箱 + 密码，Supabase 还要一个 anon key——这个输入框**只在地址看起来像
Supabase 项目时才出现**，且每次 build 重算而不是存字段，否则改地址的瞬间会显示错状态。
`anonKey` 与 `refreshToken` 落在 `sync.json` 而不是 `AppData`，理由见第 6 节第 2 条。

---

## 6. 与 Web 版的已知差异

这些是**有意的**取舍，不是遗漏：

1. **没有自绘窗口条**。原版用 `decorations: false` 自己画 36px 窗口条（含最小化/最大化/关闭）。
   Flutter 桌面端这里走系统原生标题栏——自绘标题栏要接 `window_manager` 之类的插件，
   而窗口拖拽/缩放/贴边在 Windows 上交给系统更稳。代价是视觉上少了那条 stone 色的边。
2. **同步接了，而且两个后端都能打**。合并逻辑（`sync_merge.dart` 316 行）、
   会话与轮询（`sync_engine.dart` 486 行）、凭据存储（`sync_config.dart` 195 行）
   全部就位，设置页的登录 / 注册 / 立即同步 / 退出也都是真控件。传输层有两个实现，
   由 `backend_transport.dart` 按服务器 URL 分派，`SyncEngine` 不知道有两条路：

   - **自建参考服务**（`sync_transport.dart` 的 `IoTransport`）：说
     `docs/sync-protocol.md` 那套自建 JSON 协议（`POST /api/sync`），连仓库里的
     `server/`（653 行零依赖 Node）。
   - **Supabase**（`supabase_transport.dart` 320 行）：GoTrue 管登录与 token 刷新，
     同步走 PostgREST 调一个 `security definer` 的 Postgres 函数。服务端 SQL 在
     `supabase/migrations/0001_sync.sql`。

   分派的依据是 URL 形状（`.supabase.co` / `.supabase.in`），因为那是引擎唯一
   交出来的信息。**默认猜自建服务是安全的一侧**：Supabase 地址被误判成自建会得到
   一个清楚的连接错误，反过来会把 bearer token 发到一个不存在的路径上。

   Supabase 的会话比自建服务多两样东西，都只存在 `sync.json` 里、不进 `AppData`：
   项目的 `anonKey`（公开，每个 Supabase web bundle 都带），以及 `refreshToken`
   （只发往 token 端点，永不发往 sync 函数）。access token 有效期一小时，401 时
   传输层换一次 token 并重试——**只重试一次**，第二次 401 是真正的凭据问题。

   实现细节与四层验证见 `docs/supabase-sync-plan.md`。

3. **导出/导入已补上**。`lib/data/services/transfer.dart` 移植了原版 `src/lib/transfer.ts`
   （302 行）的全部三条导出与三条导入：JSON 备份、CSV 表格、Anki TXT。检测顺序
   与原版一致且**顺序即逻辑**——先试 JSON（首格是 `{word` 的 CSV 比损坏 JSON 更
   可能，所以解析失败会继续往下走）、再看首行有没有 `\t`（Anki 优先于逗号，因为
   英文释义里常有逗号）、再看逗号、最后全文找 `\t`。CSV 表头别名表也整份搬过来
   了（`term,word,词语,单词` 都认）。两个容易丢的细节：CSV 导出带 `\uFEFF` BOM +
   CRLF（否则 Excel 读中文是乱码），空字符串按「缺失」处理（否则空白单元格会变成
   `pos: ""` 的空标签）。
   
   文件选择走 `lib/data/services/file_dialogs.dart`，**Android 用平台通道直接调
   `ACTION_CREATE_DOCUMENT` / `ACTION_OPEN_DOCUMENT`，不是 `file_selector`**。
   原因是实测发现 `file_selector` 的 `getSaveLocation` 在 Android 上不可用，
   它只能选「已存在的文件」不能指定新文件的保存位置——而导出恰恰需要后者。
   桌面端仍走 `file_selector`。这条通道是唯一需要写原生代码的地方
   （`android/app/src/main/kotlin/.../MainActivity.kt`），其余全是纯 Dart。
   
   设置页「数据」区段现在是四行：导出 JSON、导出 CSV、导入、清空。导入会先弹
   预览（显示识别出的格式、词语数、前几个词条），确认后才写入——**直接写会让
   一次误选无法撤销**。已存在的词语按 `normalizeTerm` 比对后跳过并计数，因为
   宽容的解析器意味着「文件与现有词库有重叠」是常态而不是异常。
4. **拖拽导入仍然没有**。原版可以把 `.json` 拖到窗口导入，Flutter 桌面端要
   `desktop_drop` 插件。导入解析器和文件选择都已就位，缺的只是这一个拖放接收器；
   在桌面上补它是十几行的事。Windows 构建现在已通（见 7.2），所以这一项是可
   验证的。
5. **没有浏览器版本**。原版 `isDesktopShell()` 让窗口条在浏览器里不渲染。Flutter 这份
   只有 Windows / Android 两个 target。
6. **移动端不显示快捷键**。原版所有键帽提示在手机上都还在——手机没有键盘，那些
   `Ctrl` / `Enter` / `空格` 既按不到，又白占横向空间。`lib/ui/core/widgets/keyboard_hints.dart` 的
   `showKeyboardHints()` 按**平台**判断（`TargetPlatform.windows/macOS/linux` 为真，
   android/iOS/fuchsia 为假），不是按窗口宽度：窄化的桌面窗口仍然由键盘驱动，
   而横屏平板很宽却没有键盘——宽度会把这两种情况都答错。页面里统一走
   `context.showsKeyHints`，共 14 处调用点（`app_shell.dart:401`、`flashcards_page.dart`
   6 处、`quiz_page.dart` 4 处、`settings_page.dart:1635`、`words_page.dart:1717`、
   `word_editor.dart:265`）。`test/keyboard_hints_test.dart` 的 11 条测试在桌面与
   Android 两个分支上分别 pump 页面，断言键帽出现/消失。

### 手机布局：一套桌面度量在三处失灵

这套设计令牌是为 1280 宽的窗口量的。搬到 411dp 宽的手机上，有三处不是「变小了」
而是**直接不成立**，而且三处都会被桌面测试全部放过。

**一、控制高度 36/32 是鼠标量的，指尖不认。** 审计在 411×866 下量出词库一页
**54 个** `GestureDetector` 小于 44dp，其中 44 个是 32×32 的图标按钮
（`_RowAction`、`_QbarIconButton`、`_ListTab` 的加号）。`Layout.tap = 44.0` 这个令牌
一直存在，**但全项目只有 `lib/ui/core/widgets/widgets.dart:64` 的底部留白用过它一次**——
定义了却没接线，等于没有。

修法是新增 `lib/ui/core/widgets/density.dart`，按**平台**而不是宽度判断（与
`keyboard_hints.dart` 同一个理由：窄化的桌面窗口仍是鼠标，横屏平板仍是手指）：

```dart
bool isTouchPlatform({TargetPlatform? platform}) => switch (p) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
  TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => false,
};
```

`context.controlH` / `context.controlHSm` / `context.iconTarget` 三个取值器取代直接
引用 `Layout.controlH`，`LexButton` / `LexInput` / `LexSelect` / `_TopBar` 的
`Segmented` 全部改走它们。**两条配方刻意不同**：

- **带文字的按钮整体长大。** 边框和填充就是可供性，44dp 的按钮就是正常手机按钮。
- **纯图标按钮只长大命中盒，绘制盒不变。** 44dp 的描边方块放进表格行里像一个洞，
  不像一个控件。这就是 `docs/design.md` 给 Web 版记的「extend the target, not the
  shape」，Flutter 版的实现是 `TapTarget`：只在触控平台把 child 包进
  `SizedBox(44) + Center`。

`TapTarget` 有两条接线约束，**放错任何一处都量不出来**：

1. **必须在 `GestureDetector` 内部。** 识别器只在自己盒内收事件，套在外面只是把
   像素挪了，命中区没动。
2. **外层 detector 必须带 `HitTestBehavior.opaque`。** 裸 `SizedBox` 自身不可命中，
   不写这一条，icon 周围那 6dp 的环是死的。

`test/density_test.dart` 因此不看渲染盒，而是**点距中心 19dp 的位置**
（32 的一半是 16，44 的一半是 22）：第一版把 `TapTarget` 放错层时，量渲染盒永远
发现不了——两个尺寸都「对」，只有点击落在环上才暴露。

**二、查询带在手机上是三行，占了首屏 164dp。** 搜索、状态筛选、工具行各占一行，
401dp 宽里第一行单词被推到 y=358，805dp 的可见体已经用掉四成。压法不是隐藏信息
而是**让两行共用**：

| | 行一 | 行二 |
| --- | --- | --- |
| 桌面 | 搜索 3 : 状态 4 + 排序 + 收藏 + 批量选择（全在一行） |
| 手机 | 搜索 + 排序 + 收藏 | 状态（横向滚动）+ 批量选择 |

查询带 164 → 108dp，第一行单词提到 y=306，**两行都放得下三个和两个控件，
没有一行只剩一个全宽控件**——那正是「折叠」变成「换成标签」的分界线。

同时修掉三个连带问题：

- **`_actionsColW` 常量 140 删成函数** `math.max(140.0, 4 * context.iconTarget)`。
  桌面 140 是给四个 32dp 按钮量的，触控下四个 44 需要 176，硬编码 140 让整行
  **溢出 36px**。
- **`Segmented` 的边框从 `decoration` 改成 `foregroundDecoration`。** 真实 border
  会吃掉 1dp 布局空间：44dp 轨道里最高只能放 42dp 的 chip，而 chip 正是要满足
  44 的那个盒子。画在前景上，chip 拿到完整的 44。
- **`_DefinitionLine` 的词性胶囊 10px → `Fs.xs`（12）。** 10 不在 `Fs` 刻度里，
  是全 app 唯一小于 `Fs.xs` 的字号；在手机上它不是「说明文字」，是读不出的字。

**三、设置页横向溢出 40px——这是真 bug，不是观感问题。** `_Row` 在
`constraints.maxWidth < 520` 时**已经**改成上下堆叠了，但堆叠之后 `widget.control`
仍是一个 `Row(mainAxisSize: MainAxisSize.min)`，里面有一个 `SizedBox(width: 260)`
的语音选择器：260 + 8 + 「测试发音」按钮 ≈ 337 > 297 的可用宽。`260` 和 `200`
（倍速滑杆）都是**桌面宽度，不是下限**，各套一层 `Flexible` 即可。

这一处值得单独记，因为它是唯一一个 `RenderFlex overflowed` 会**直接抛异常**的
问题——其余两处只是不达标，测试从来不响。

### 用测试代替截图

手机上的几何在这套环境里没法靠眼睛验：`adb` daemon 随 bash 进程树死亡、dev server
的 origin 不在 capability 作用域内、模拟器截图重复拍出同一个文件（两个 md5 相同）。
所以这一轮的判据是 `test/mobile_layout_test.dart`，**五条预算，不是五条快照**：

| 断言 | 预算 | 修之前 |
| --- | --- | --- |
| 六个界面在 411dp 下不抛异常 | `takeException()` 为 null | 设置页溢出 40px |
| 五个页面每个 `GestureDetector` 两维 ≥ 44 | `Layout.tap` | 词库 54 个不达标 |
| 顶栏高 | ≤ 84dp | 87dp |
| 第一行单词 top | ≤ 320dp | 358dp |
| 查询带高 | ≤ 120dp | 164dp |

后来补的两组（`nothing is cut off` 12 条、`wrapping is a last resort` 6 条）管的是上表
看不见的那一类：不抛异常、不占首屏、够 44，却**画到了屏幕外或者断在荒唐的位置**。
它们的来历与三个真身见下一节。

再后来才发现更根本的一件事：**上面这些全部只在 411dp 竖屏下量过，而 411dp 只走到
`AppShell` 三套布局模式里的一套**。补的 `test/responsive_layout_test.dart` 扫五个视口
× 六个界面 × 两个字号，第一次跑就抓到三处溢出和一处内禀尺寸异常——见
「一套度量在另外两种布局模式下失灵」。

数字全部取「设计能容忍的最大值」而不是「这一次量到的值」，因为字体度量浮动半个
像素不该让断言变成绊线。`test/settings_layout_test.dart` 另有 4 条管住两个手绘控件
（`_LexSwitch`、`_RateSlider`）——它们不在 `LexButton` / `LexSelect` 里，所以
44dp 全扫看不见它们，而它们恰好是**没有任何确认步骤就能改设置**的两个控件。
`_RateSlider` 的做法是把 `SizedBox(height: 20)` 换成
`context.isTouch ? Layout.tap : 20`：滑杆是被拖的，只在拇指外面套一个环而不改拖拽面
等于没改；`_TrackPainter` 按 `size.height / 2` 居中，所以 6dp 轨道与 16dp 拇指的
观感分毫未变。

**「两端各存一份」只在本机存储这一层成立**——同步是显式的，要登录、要打开
`autoSync`，开箱即用的默认状态仍然是各存一份。

### 切掉的半截东西：手机上「显示不全」的三种真身

上面那五条预算管的是**版面预算**，它们全都通过之后，用户还是报「有些地方显示不全，
或者有分行，布局很奇怪」。原因是那一轮只在 411dp 下量了「有没有抛异常」「够不够 44」
「首屏还剩多少」——**一个既不抛异常、又够 44、也不占首屏的东西照样可以坏掉**。三种坏法：

**一、横向被裁。** `Segmented` 是 `Row(mainAxisSize: MainAxisSize.min)`，按内容宽排，
外面套横向滚动。五个状态筛选各带一个计数，量出来 396dp，容器只给 363dp，最后一个
chip 从卡片边缘切掉一半。**「切一半」与「这个 chip 不存在」在视觉上无法区分**，而
`overflow` 断言看不见它——被滚动容器接住的溢出不抛异常。

**二、被兄弟挤窄到断行。** 这是最像「布局很奇怪」的一种：每一句都正确换行了，
但换的位置荒唐。测验页的方向选择器 237dp 站在 `_TopBar` 里，副标题只剩 109.5dp 而它
需要 145.8dp，于是「用主动回忆检验掌握程度」每次都在「用主动回忆检验」后面断开；统计页
`_HeadCard` 里 224dp 的窗口选择器把标题压到 85.3dp，「近 30 天复习」在「近」后断行。
**判据不是「换行了」，是「本可以一行却换行」**：`getMaxIntrinsicWidth(∞) <= 实际宽度`
还断成两行，就一定是被挤的。

**三、被固定宽度裁成两行。** 设置页语速读数是 `SizedBox(width: 52)` 包着
`'${rate.toStringAsFixed(2)}×'`——52 是旧 12dp 字号下的宽度，`Fs.sm` 下需要 66dp，于是
`×` 被挤到第二行单独成行，读起来像一个孤立的符号。

三处修法各不相同，因为三种坏法本来就不是一回事：

| 症状 | 病灶 | 修法 |
| --- | --- | --- |
| 状态筛选条右溢 21.8dp | `_SegButton` 侧向 padding 12dp × 5 | 触控平台收到 4dp，**并加 `minWidth: Layout.tap`** |
| 测验副标题断在「用主动回忆检验」后 | 选择器站在 `_TopBar` 里 | 触控平台把选择器移进卡片，方向 chip 随之删掉 |
| 统计卡标题断在「近」后 | `_HeadCard` 的 `Row[Expanded, trailing]` | `LayoutBuilder`，内宽 < 520 时上下堆叠（**只在这一头有 `trailing` 时才建**，理由见下一节） |
| `0.95×` 断成两行 | `SizedBox(width: 52)` | 去掉固定宽，`maxLines: 1, softWrap: false` |
| 搜索占位被省略号 | 一行里塞了搜索+排序+收藏 | 触控平台换短文案（129dp 装不下 149dp） |
| 词典段同一句话印两遍 | `_Section.note` 与 `_Row.hint` 同源 | 删掉 `note`，只留行内那句 |

**第一行那条修法里有个坑值得记**：padding 从 12 收到 4 之后，「全部」这种两字 chip
只剩 36.5dp 宽，`test/mobile_layout_test.dart` 的 44dp 全扫立刻抓到。所以「够宽能点」
与「够窄能放」必须同时成立，**光靠 padding 是调不出来的**，得给 `_SegButton` 加
`constraints: BoxConstraints(minWidth: Layout.tap)`。这条测试从「有 54 个不达标」变成
「有 2 个 36.5×44」再变成空，每一步都是它自己报的。

**探针要量绘制盒，不是布局盒。** 第一版回归测试把统计页判成「右溢 4dp」，追下去是
`FractionalTranslation`：图表最后一个日期标签在布局上停在轨道末端 415dp，靠
`FractionalTranslation(-1, 0)` 在绘制时左移到 366dp。**布局盒 415、实际画在 366**。
测试里因此要沿元素树累加 `FractionalTranslation` 的平移量，并把 `Positioned` /
`FractionalTranslation` 这类「自己不画任何东西」的包装层排除——否则会报出一个屏幕上
并不存在的缺陷。同理，输入框里的长 URL（`http://127.0.0.1:8787`，287dp 盒子装 325dp
字形）被判为裁剪是误报：`TextField` 是视口，内容可以横向滚，每个字符都还在。

**这三类各补了一组回归**（`test/mobile_layout_test.dart` 从 14 条增到 32 条）：
`nothing is cut off` 六屏各两条（绘制盒不越过 411dp；没有文本在有余量时被裁）、
`wrapping is a last resort` 六屏各一条（没有段落在 `intrinsic ≤ 实际宽` 的情况下换行）。
`test/widget_test.dart` 另补两条把 `Segmented` 的计数分支在 `windows` / `android`
两个平台各钉一次——`flutter test` 默认报 android，不钉的话桌面分支永远不执行。
**钉平台要用 `try/finally` 复位，不能用 `addTearDown`**：框架在 tear-down 之前就会断言
foundation 的 debug 变量已复位，用 `addTearDown` 会让测试因为「它本来想保护的那件事」
而失败。

### 一套度量在另外两种布局模式下失灵

上面三轮的视口全是 411dp 竖屏。但 `AppShell` 有三套布局模式，**411dp 只走到其中一套**：

| 宽度 | 模式 | 谁来画侧栏 |
| --- | --- | --- |
| ≤ 720（`Layout.mobileBreakpoint`） | mobile | 底栏 tab |
| 720 – 1000（`Layout.railBreakpoint`） | rail | 64dp 图标栏 |
| > 1000 | full | 248dp 完整侧栏 |

所以 411dp 的测试**在结构上不可能**发现 rail 里的事，无论加多少条断言。补的
`test/responsive_layout_test.dart` 把七个界面在五个视口（320×568、360×640、
横屏 866×411、平板 800×1280、桌面 1280×800）和两个字号（1.3×、2.0×）下各扫一遍，
判据仍然是 `takeException()` 为 null。**第一次跑就抓到三处 `RenderFlex overflowed`
和一处 `LayoutBuilder` 内禀尺寸异常，全部是线上真能碰到的组合。**

**一、rail 底部三个按钮挤在 47dp 里（右溢 85dp）。** 64dp 的 rail 减去
`EdgeInsets.symmetric(horizontal: Sp.x2)` 的两侧 8dp、再减 1dp 右边框，内宽正好
47dp；底部那排是三个 `_SidebarButton`，每个被 `TapTarget` 撑到 44dp（触控地板），
3×44 = 132，132 − 47 = **85**，与报错数字分毫不差。Web 版早就踩过并写下了结论
（`src/styles/global.css:397-404`：「The footer buttons cannot sit side by side in a
64px rail — stack them」，`.app.rail .sidebar-actions { flex-direction: column }`），
**Flutter 这边没把这条规则搬过来**。修法是 rail 分支改用
`Column(mainAxisSize: MainAxisSize.min)` 竖排，非 rail 分支保持横排——两套模式本来就
该有两种排法，硬用一套才是病根。

**二、平板是「宽 + 触控」，状态条挤爆（右溢 13dp）。** 词库查询带的宽屏分支给状态条
`Expanded(flex: 4)` 而不给滚动；同时平板 `isTouch` 为真，每个 chip 有
`minWidth: Layout.tap` 的 44dp 地板，缩不下去。**窄屏分支本来就有
`SingleChildScrollView`，宽屏分支没有**——因为写宽屏分支时默认「宽就够了」。修法是宽屏
分支也套横向滚动：宽不等于装得下，触控地板在宽屏同样生效。

**三、2.0× 字号下测验方向选择器挤爆（右溢 83dp）。** 两个标签在 2× 下量出约 388dp，
而 `Column` 加 `padding: EdgeInsets.all(Sp.x7)` 后只剩 305dp。**字号不是宽度也不是
平台**，前两轮的任何视口都碰不到它。修法同样是套横向滚动。

**四、`LayoutBuilder` 不能回答内禀高度（这一处不是溢出，是整套版面直接失败）。**
统计页在 1280dp 下抛
`LayoutBuilder does not support returning intrinsic dimensions`，后面跟着一串
`RenderBox was not laid out`——按 skill 的说法那串全是级联噪音，真正的第一句是它。
链路是：`_Split` 用 `IntrinsicHeight` 让并排两张卡等高 → 它向内层要内禀高度 →
`_HeadCard` 里恰好有个 `LayoutBuilder`（为「内宽 < 520 时把 trailing 挪到下一行」而建）
→ builder 答不出来。**报错点名的 widget 是 builder，病灶却在 `_Split`**，
这也是为什么必须顺着栈往上看。

修法不是拆 `IntrinsicHeight`（等高是设计意图），而是让 `_HeadCard` **在没有
`trailing` 时不建 builder**——没有要排的东西就没有要决策的布局，`_Split` 里那两张卡
正好都没有 trailing，builder 于是不在路径上。这条约束写进了 `_Split` 的文档注释：
**它的子树里不许出现 `LayoutBuilder`**。

**这四处都做了变异测试**：把修法逐个改回去，`responsive_layout_test.dart` 分别报出
2、1、1、1 条失败，改回来即全绿——所以每条断言都真的在管那件事，不是恰好通过。

第五组断言管的是「别用改坏别处的方式修好这里」：rail 必须**还是 64dp**。把宽度从
`Layout.sidebarRailW` 改成 `null`（让内容撑开）测试立刻红；改成 `100.0` 报出
`Expected: <64.0> Actual: <100.0>`。这条按 `kSidebarKey` 找 widget，不用
`find.byType(AnimatedContainer).first`——后者在树上一有改动就会默默开始量另一个东西，
是那种「一直绿着，但量的已经不是它」的测试。

顺带记一个测试写法：`tester.takeException()` 只给一句话，把
`FlutterErrorDetails` 的 widget 链（`error-causing widget` + `file:line` +
`constraints:` + `size:`）全丢了。要那串信息得自己接管
`FlutterError.onError` 并 `print(d.toString())`；且 `FlutterExceptionHandler` 这个类型
从 `package:flutter_test` 里**不可命名**，变量只能声明成
`final void Function(FlutterErrorDetails)? old = FlutterError.onError;`。

**五、不抛异常的挤压（这一处是用户报上来的，不是测试扫出来的）。**
「添加词语」弹窗里 `释义` 两个字竖着排成两行，整个头部行看着也不对。它不抛任何异常：
标签套在 `Expanded` 里，所以它只是被**挤**，不是被裁。实测（411dp 手机，弹窗 620 定宽、
左右各 24 内边距 → 内宽 331，两列各 159.5）：

| 宽度 | 标签拿到的盒子 | 行数 | 抛异常 |
| --- | --- | --- | --- |
| 411 | 0.0 × 42 | 2 | 是 |
| 520 | 0.0 × 42 | 2 | 是 |
| 540 | 4.8 × 42 | 2 | **否** |
| 560 | 14.8 × 42 | 2 | **否** |
| 580 | 24.8 × 42 | 2 | **否** |
| 600 | 34.8 × 21 | 1 | 否 |

**中间那三档是这类缺陷最危险的地方**：有异常时测试会红，而 540–580 三档只换行、
一句话都不说。头部行里语言对标签占 134.8dp、`翻译` 按钮约 64dp、间距 8dp，
合计 207dp 已经超过 159.5dp 的列宽，`Expanded` 只能把标签压到 0——而**宽度为 0 的
`Text` 仍然会换行**，于是它没有消失，而是竖着印了出来。

两处一起改才算修好，缺一处都还在：

1. **标签不再 `Expanded`**，改成占内禀宽度；把语言对标签套进 `Flexible` 并加
   `softWrap: false, overflow: TextOverflow.ellipsis`——该让路的是可选提示，不是字段名。
2. **两列在窄处堆叠**。Web 版的 `.field-row` 在 ≤ 820px 就是单列
   （`src/styles/global.css:2008`），移植时把这条规则丢了。弹窗本身封顶 560，
   所以判断写在**实际拿到的宽度**上（`constraints.maxWidth < 520`）而不是窗口宽度上。

这条的教训比修法重要：**「没抛异常」不等于「画对了」**。前四组溢出断言能抓到的只是
「有内容看不见」，而挤压是「内容看得见、但排错了」。所以断言要落到标签自己的盒子上：
内禀宽度、以及用 `getBoxesForSelection` 数出的**字形盒顶端有几个不同值**——那才是行数。
现在 `responsive_layout_test.dart` 在 411/540/560/580/620/900 六档都钉了这两条，
把两处修法都改回去时它报 6 条失败（含那三个静默档），只改回一处则互相兜住。

### 动效：一个原语，三处接线

Web 版有六个入场 keyframe（`fade-in`、`pop-in`、`rise`、`row-in`、`tile-in`、
`bar-rise`，`src/styles/global.css:1798-1885`），彼此只差「走多远」。移植过来合成
一个 `FadeRise`（`ui/core/widgets/entrance.dart`，126 行），于是「这块东西会不会
入场」变成一个 grep 就能回答的问题，而下面三条约束只需要在一处守住：

```dart
FadeRise(child: ..., offset: 10, delay: Motion.stagger * i, duration: Motion.dur3)
```

1. **只动 transform 和 opacity**。给 `Padding`/`SizedBox` 做补间会让内容在行还被
   测量的时候滑动，量出来的点击框和眼睛看到的那一行对不上。Web 版 `row-in` 的注释
   写的正是这件事。
2. **延迟是 `Interval`，不是 `Timer`**。一个 `Duration delay` 由一个
   `AnimationController` 用 `Interval(delay / total, 1, curve:)` 消化掉。用 `Timer`
   的话 `pumpAndSettle()` 会提前返回，然后 teardown 报「Timer is still pending」——
   而 `entrance_test.dart` 里那条「a delayed block uses no timer, so settle
   terminates」就是钉这个的。
3. **尊重 `disableAnimations`**：在 `didChangeDependencies` 里读一次
   `MediaQuery.maybeOf(context)?.disableAnimations`，为真就直接把控制器置到末态。

接线的地方各自选了不同的位移，理由各不相同：

| 位置 | offset | 理由 |
| --- | --- | --- |
| `PageShell` 的正文 | **0** | 只渐显。页面容器一旦有 transform 就会成为页内定位元素的包含块，粘性表头会跟着错位——Web 版 `.page-inner` 的注释是这个意思 |
| 首页的四块 | 8 | 仪表盘是唯一「按顺序抵达」的页面：问候 → 数字 → 出口。超过四块不再加延迟，否则读起来像卡了 |
| 词库的行 / 统计的格子 | 6 / 9 | 行和格子随下标递增，各自封顶 8 / 4 项（Web 版 `Math.min(index, 8) * 16ms`）。不封顶的话第 400 行要等六秒 |

另外三件事顺带补上：`LexButton` 有了按下反馈（`AnimatedScale` 缩到 0.985，走的正是
Web 的 `.btn:active`，用 `onTapDown`/`onTapCancel` 而不是 `onTap`，因为触摸屏没有
hover，按下必须当场看得见）；侧栏底部三个图标按钮的悬浮底色改成淡入而不是直接跳变；
收起/展开的箭头从「换一个图标」改成「同一个图标转 180°」，于是它**摆**过去而不是被
替换。

**一处真 bug 是这轮测试挖出来的**：`ToastHost` 原来把整个栈包在 `IgnorePointer` 里
（为了「让点击穿透到页面」），结果连「撤销」按钮也一起穿过去了——点了没反应，而
toast 照样消失，看起来像撤销成功了。Web 版的做法是栈 `pointer-events: none`、
每张卡 `auto`（`global.css:1452-1463`），移植时把这条弄反了。修法是把
`IgnorePointer` 整个去掉：`Column` 本身不吃点击，空白处照样穿透，只有卡片收下。
`test/toast_test.dart`（9 条）从此覆盖这条路——之前所有测试都是拿假 `ToastScope`
替掉真实 host，所以这条路径一次都没被跑过。

判据也得改：`tester.takeException()` 抓不到一个「点不动」的按钮，因为不抛异常。
那条断言只能落在**副作用**上——点完之后 `onAction` 到底有没有被调用。

顺带补上 toast 自己的入场/退场（同一个控制器：进 170ms 从下往上 10dp，退反向走完
再让宿主摘掉卡片），以及深色主题下石框/纸面之间那道亮边——`Palette.edge` 这个 token
在 Dart 和 CSS 里都有，但移植后**从没被画过**，所以深色桌面上的分界线只剩一档
几乎看不出的亮度差。现在由 `_Paper` 画：深色且非手机布局时，纸面左侧一道 2dp 的
`p.edge` 内描边。

### 0.2.4 上线的那个「卡在首页」：一个控件放错了层

用户报的原话是「现在我的应用就在主页了 点啥都没有反应」。0.2.4+5 装上去之后，
首页画得出来（那是上一帧留下的画面），但任何点击都没有响应，也不报错。

根因在 `main.dart` 的一层嵌套，不在任何页面里：`ToastHost` 被包在 `MaterialApp`
**外面**，而它 `build` 出来的是一个裸 `Stack`。`Stack` 的默认 `alignment` 是
`AlignmentDirectional.topStart`，要解析它得有祖先 `Directionality`——而
`Directionality` 正是 `MaterialApp` 装上去的。放在它上面就等于没有：

```
Null check operator used on a null value
#0 AlignmentDirectional.resolve (painting/alignment.dart:651)
#2 RenderStack.performLayout (rendering/stack.dart:684)
#8 RendererBinding.drawFrame
```

首帧布局直接抛异常，于是**什么都没画**，窗口停在上一次的内容上。表现就是
「画面还在，点不动」。

这条错误比这次发布早得多：`887deef`、`5337cd5`、`cca6f19` 的嵌套一模一样，
0.2.2/0.2.3 的 `toast.dart` 里也是同一个裸 `Stack`。**它一直在那儿，只是没人整屏点过。**

修法是把 `ToastHost` 挪进 `MaterialApp.builder`：

```dart
builder: (BuildContext context, Widget? child) => ToastHost(
  key: _toastKey,
  child: child ?? const SizedBox.shrink(),
),
```

`builder` 跑在 `MaterialApp` **内部**（`Directionality`、`MediaQuery`、`Theme` 都齐了），
但**在 `Navigator` 之上**——所以 toast 依旧浮在所有页面和所有对话框上面，这正是当初
把它提到外面想要的效果。放在外面不是"更外层所以更靠上"，而是"没有 Directionality
所以首帧就死"。

#### 为什么所有测试都没抓到

这是这一轮最值得记的一点。事后的探针 `test/zz_probe_tap_test.dart` 用真的
`AppShell` + 真的 Store/Scope/`MaterialApp`，在 411×866 上点 tab、点「开始复习」，
**全部通过**——因为它把 `ToastHost` 放在了 `MaterialApp` **里面**，正好绕开了这个 bug。
同理 `ToastHost(child: MaterialApp(...))` 那种写法也是对的（`MaterialApp` 在里面）。
换句话说：**凡是手工重新拼过一遍树形的测试，都看不见 `main.dart` 自己那一层的嵌套错误。**

所以补的回归测试 `test/app_mount_test.dart` 不拼树，它 pump 的就是 `LexumoApp`
本身——那个 `build` 里装着嵌套关系的 widget。四条断言分两类：

- 结构类：`ToastHost` 必须是 `MaterialApp` 的**后代**，永远不能是祖先（这条能直接指出
  放错的方向，而不仅仅是"挂了"）；
- 行为类：首帧不抛异常、首页真的画出来了、点 tab 真的换了页。

这两类都需要。「没抛异常」单独不够——首帧失败只抛一次，之后只是安静地什么都不画，
`takeException()` 拿到一次之后就再没有信号了；反过来只断言点击通过也不够，因为
树里少一个页面时点击也可能"成功"地点在空气上。反向验证过：把嵌套改回去，四条全红。

#### 教训

`showModalBottomSheet`、`ToastHost`、主题注入、任何需要在**整个 app 之上**画东西的
壳，都必须走 `MaterialApp.builder`（或 `materialApp` 之内的 `Overlay`），而不是包在
`MaterialApp` 外面。包在外面的写法能编译、能过单测、甚至在桌面跑起来"看起来正常"
（因为 `Focus`/路由都没坏），但缺 `Directionality`、`MediaQuery`、`Theme`、`Navigator`
这一整套由 `MaterialApp` 提供的环境。

另外记一条工作方法：这次是 `flutterc run -d windows --release` 在真窗口里跑，
才拿到首帧那个 `Null check operator`。之前所有基于 `flutterc test` 的诊断都是不可信的，
因为它们和出问题的树形不是同一个。**用户说不用测试、让我直接看真实应用，是对的。**

### 两端的数据是怎么走的

同一份 Dart 代码编出两个 target，**默认**各存一份：

| | 存哪 | 怎么读 |
| --- | --- | --- |
| Android | `/data/user/0/dev.lexumo.lexumo/files/Lexumo/lexumo.json` | 应用私有目录 |
| Windows | `%APPDATA%\Lexumo\lexumo.json` | 用户漫游目录 |

`lib/data/services/app_dir.dart` 的 `_resolve()` 按 `Platform.isWindows` / `Platform.isAndroid`
分派，各自落在本机文件系统上。`lib/data/services/snapshot_store.dart` 只做原子写
（`lexumo.json.tmp` → flush → rename）、`.bak` 回退和容错读取——三个文件，全在本机。

**但这不是终态**：登录之后两端会通过同步服务合并。所以准确的表述是「本机存储这一层
是独立的，跨设备需要显式登录」——`pubspec.yaml` 的依赖仍然只有 `flutter`、
`flutter_localizations`、`flutter_tts`，网络走 `dart:io` 的 `HttpClient`，
没有第三方 HTTP 包；不发请求的默认状态下，两端的词库确实互不可见。

**连原来的 Tauri 版也不共享数据**。那一版把数据存在 WebView2 的 IndexedDB
（`%LOCALAPPDATA%\com.lexumo.app\EBWebView\Default\IndexedDB\`，实测 87 MB），
Flutter 版读的是 `%APPDATA%\Lexumo\lexumo.json`——两个完全不同的存储引擎。
想迁移就得解析 LevelDB，所以这是一次平行重写，不是升级。

这条路径在设置页文案上留下过两道疤，都值得记：

1. `settings.syncUnavailableBody` 曾经让用户「用下方的导出」把数据带走，但当时导出
   并不存在——**让用户去找一个不存在的按钮，比直接说做不到更糟**。那条文案先被
   改成如实说明「两端各存一份，且此版本还没有导出」；导出补上之后又改一次；等到
   同步真正接通，它已经没有必要存在，于是在死代码清理时删掉了。
2. `settings.wipeConfirmBody` 里的「建议先导出备份」经历了一个来回：导出不存在时
   删掉过，导出补上后又加了回来——现在那句话指向的按钮真的在那里。

**同一条文案的正确性取决于功能是否存在**，所以文案必须在功能落地时重新审一遍，
而不是一次写完就算完。这两处都是「功能变了、文案没跟上」的实例，而它们恰好都是
在用户可见的位置上。

### TTS 已经补上（不再是缺口）

`flutter_tts` 4.2.5 接进了 `lib/data/services/tts.dart`，四件事值得记：

1. **语速刻度**。Web Speech 里 `1.0` 是正常速度，`flutter_tts` 把 `0.5` 当正常
   （Android 侧 `rate * 2`，Windows 侧 `SpeakingRate(rate + 0.5)`）。`Settings.ttsRate`
   存的是 web 刻度（快照格式早于这次移植），所以换算只发生在 `Speech.speak` 内部，
   上层不知道这件事。
2. **音色句柄**。Web Speech 有稳定的 `voiceURI`，插件只给 `{name, locale}` 且没有 id。
   `VoiceInfo.uri` 因此是自描述的（`name` + `locale` 编码进去），这样持久化的
   `Settings.ttsVoiceURI` 在重启、且内存里没有任何映射表时仍然能还原。
3. **就绪时机**。Android 引擎初始化完成前 `getVoices` 返回空，插件是排队而非报错，
   所以 `Speech.refreshVoices` 轮询最多 10 次、每次间隔 300 ms，然后安静放弃。
4. **`supported` 的三态**。warm-up 之前答 `true`（否则按钮会闪一下才出现），
   warm-up 失败之后答 `false`（此时还承诺能朗读是更大的谎）。**平台差异**：Windows
   上判断「真的能用」要求语音列表非空，其它平台只要求通道通——因为 Windows 那份
   vendored 插件在引擎没激活时仍会应答每个方法，见 7.2。

调用点：`words_page.dart:92`（行内发音）、`flashcards_page.dart:104/106`（显式朗读 /
自动朗读，后者不计数）、`quiz_page.dart:95`（题干与复习行）、设置页音色下拉 + 试听。
三处都是把闭包注入 view model，因为真正的 `speakWord` 要 `BuildContext` 读设置。
`word.listenCount` 现在有触发点了——`speakWord` 每次调用都 `bumpListen`，
`speakTerm`（自动朗读）不计数，与原版一致。

---

## 7. 构建与验证

三条命令覆盖日常：

```bash
cd flutter
../.flutter-sdk/flutterc analyze           # No issues found!
../.flutter-sdk/flutterc test              # 827 passed, 6 skipped
./tool/build_apk.sh                        # 出 release APK 到 dist/
./tool/build_windows.sh                    # 出 Windows release 包
./tool/release.sh                          # 出签名 APK + dist/update.json
./tool/reinstall.sh                        # 装到模拟器并校验
```

**不要用 `flutterc build apk`**。这条路径在本机会失败于一个与代码无关的原因，
见 7.4；`tool/build_apk.sh` 是唯一能用的出包方式。

### 7.1 Android

工作区里有 SDK wrapper `../.flutter-sdk/flutterc`，它把 `HOME` / `APPDATA` /
`TMP` 钉到工作区内的 `.flutter-home`。不钉的话 flutter 工具会去碰
`C:\Users\noaha\AppData\Roaming\.flutter_tool_state` 并报「failed to delete file」。
**所有命令都走这个 wrapper**，直接调 `flutter` 会踩那个坑。

`flutterc devices` 默认超时下常常只报 Windows / Chrome / Edge，看不到模拟器。
加 `--device-timeout 30` 就能稳定看到：

```
sdk gphone16k x86 64 (mobile) • emulator-5554 • android-x64 • Android 17 (API 37)
```

两种调试方式，取舍不同：

| 方式 | 命令 | 代价 |
| --- | --- | --- |
| 热重载 | `flutterc run --device-timeout 30 -d emulator-5554` | 每次都要走 Gradle，会碰 7.4 的坑 |
| 现成包 | `flutterc run --use-application-binary=build/app/outputs/apk/release/app-release.apk` | 完全绕开 Gradle，但**没有热重载** |

包名是 **`dev.lexumo.lexumo`**（`android/app/build.gradle.kts:19`）。不是
`com.lexumo.app`——那是原 Tauri 版的 identifier。用错包名会让 `pm path` 永远返回空，
很容易把「已经装上了」误判成「没装上」，`tool/*.sh` 里全都写对了这个值。

#### 状态栏与手势条

改之前**一处系统栏调用都没有**：`grep -r 'SystemChrome|SystemUiOverlay' lib` 是空的。
于是 Android 画着默认的不透明状态栏，Flutter 视图从它下面开始，而 shell 的
`SafeArea(bottom: false)` 又把它让出一次——状态栏那一圈既是系统画的、又被让了两遍。
同时 `Theme.Light.NoTitleBar` 没声明刘海模式，带刘海的机器上刘海是直接切进信箱的。

沉浸是**两半**，两半必须一致，缺一个就是「透明了但图标看不见」或「图标亮了但栏还在」：

1. **`enableEdgeToEdge()`**（`lib/ui/core/system_ui.dart`）在 `main()` 里、
   `runApp` **之前** `await`：`SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`，
   然后先推一份临时样式。顺序要紧——不 await 就会与首帧抢平台通道，第一帧先带信箱
   再跳一下。
2. **`AnnotatedRegion<SystemUiOverlayStyle>`** 包住 shell 的 `Scaffold`，值来自
   `shellOverlayStyle(tabBar: mobile, isDark: _vm.isDark)`。

为什么用 `AnnotatedRegion` 而不是进程级的 `SystemChrome.setSystemUIOverlayStyle`：图标
明暗取决于**这一页顶部是什么颜色**，而那是布局模式决定的（手机上顶上是 stone 导航，
桌面上顶上也是 stone，只有底部手势条落在纸上）。把决定权放在画的那棵树上，跟着
路由走，页面弹窗时也不会串色。

两条边是**两个不同的判断**，这是这段最容易写错的地方：

| 边 | 底下是什么 | 图标 |
| --- | --- | --- |
| 状态栏（上） | 永远是 stone（深色，两种主题里都是） | 永远浅色 |
| 手势条（下） | 手机上是 stone 标签栏；桌面上是 paper（跟主题） | 有标签栏→浅色，否则跟主题 |

所以 `statusIcons` 是常量 `Brightness.light`，`navIcons` 才是三元表达式。两处写反都会
被 `test/system_ui_test.dart` 抓到：把 `navIcons` 写成常量 `Brightness.light` 挂 3 条，
让 `statusIcons` 跟着 `isDark` 挂 3 条。这个测试还断言了 `enableEdgeToEdge` 真的发出了
`SystemUiMode.edgeToEdge` 的通道调用——**注意 `SystemChrome` 把最近一次的样式缓存在静态
字段里，传相同样式就直接不发通道**，所以两条独立的「第一次」测试无法同时成立，只能合成
一条，并 `await pumpEventQueue()` 等微任务落下来。

`shellOverlayStyle` 里的 `systemStatusBarContrastEnforced: false` /
`systemNavigationBarContrastEnforced: false` 不是可选的：Android 10+ 会给透明栏自动加
一层半透明遮罩「保护可读性」，不去掉的话 `Colors.transparent` 并不真的透明。

Android 资源那一半（`android/app/src/main/res/`）：新建 `values/colors.xml`，其中
`frame`（`#252C28`）是**整个工程唯一一处 Android 重复写设计令牌**——启动窗口由系统在
Dart 起来之前绘制，只能读资源。`values/styles.xml` 与 `values-night/styles.xml` 的
`LaunchTheme`/`NormalTheme` 都补了 `windowLayoutInDisplayCutoutMode=shortEdges`、
`statusBarColor`/`navigationBarColor=@color/transparent`；`NormalTheme` 再加
`windowLightStatusBar=false`、`windowLightNavigationBar=false`、两条 `enforce*Contrast=false`，
并把 `windowBackground` 从 `?android:colorBackground` 换成 `@color/frame`——启动图和第一帧
Flutter 因此是同一块表面，不会闪一下。

**这一项没有在真机上验过**：本机 adb 起不来（`adb devices -l` 报
`CreateProcess failure, error 2`），所以上面全部是断言与单测的结论，不是眼睛看到的结论。
要在真机上确认，装包后看三件事：状态栏图标是浅色、内容画到状态栏下面而不是从它下面
开始、手势条区域是 stone（手机）或纸色（桌面）而不是黑色条。

### 7.2 Windows

构建与运行都已打通。**走过三道关，前两道是环境、第三道是插件 bug**。

#### 关一：VS 工具链

`flutterc build windows` 原本报 `Unable to find suitable Visual Studio toolchain`，
根因在 `flutter_tools/lib/src/windows/visual_studio.dart:287-317`：它要求两个
component 同时存在——

- `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` —— 原本就有
- `Microsoft.VisualStudio.Component.VC.CMake.Project` —— **原本缺失**

装上后者之后检测通过。注意即使 `VC.Tools` 在、`cl.exe` 也在，缺 CMake 组件时
flutter 一律判定工具链不可用，不会尝试。

#### 关二：符号链接与 nuget

两个都不能省，否则构建以**看似无关的信息**失败：

1. **符号链接**。`pub get` 报 `Building with plugins requires symlink support.
   Please enable Developer Mode`。本机 Developer Mode 注册表位是开的，但 bash
   的 `ln -s` 和 `cmd` 的 `mklink /D` 都能建链接、**Dart 的
   `Link(link).createSync()` 却抛 `OS Error 1314`**（进程令牌未声明
   `SeCreateSymbolicLinkPrivilege`，Dart 不申请）。所以由 `tool/prelink.cjs`
   调 `mklink /D` 补出 `windows/flutter/ephemeral/.plugin_symlinks/*`，再跑
   `cmd //c windows\flutter\ephemeral\_mklinks.bat`。
   `prelink.cjs` 会把 `p.path` 里的连续反斜杠折叠、去掉尾部反斜杠（`mklink`
   否则把它当名字的一部分）。
2. **nuget 在 PATH 上**。不在就报 `Unable to generate build files`，且 149ms 内
   就失败，看不到任何 CMake 信息。

#### 关三：`flutter_tts` 让 release 启动即崩

**症状**：debug 构建正常，release/profile 构建启动后 2–3 秒退出，从未画出窗口，
退出码 `0xC0000409`（`STATUS_STACK_BUFFER_OVERRUN`，MSVC 对未捕获 C++ 异常的
fail-fast）。

**定责过程**（每一步都用最小工程 `.winrun/probeapp` 交叉验证，不是猜）：

| 实验 | 结论 |
| --- | --- |
| 纯模板 release | 能跑 |
| 模板 + 只加 `file_selector` | 能跑 |
| 模板 + 只加 `flutter_tts` | **崩**，与 Lexumo 业务代码无关 |
| 2×2：runner 补 `RoInitialize` × 有无 `flutter_tts` | 补丁无关紧要，**有无插件决定生死** |
| 插件成员处插探针 | 日志只有 `before-synth`，**没有 `after-synth`** |

最后一行是决定性证据：**崩溃发生在 `SpeechSynthesizer synth;` 这个成员的默认
构造里，早于构造函数体执行**。所以任何写在构造函数体内的 `try/catch` 都抓不到
它——这也解释了为什么先前两次「加了 try/catch 就不崩」的结论是假的（那次测的是
上一次构建残留的 exe，见下面的教训）。

**根因**：本机 WinRT 语音栈没有可用语音。`New-Object
Windows.Media.SpeechSynthesis.SpeechSynthesizer` 能建实例但 `AllVoices.Count = 0`；
同时 **SAPI 有两个语音**（`Microsoft Huihui Desktop` zh-CN、`Microsoft Zira
Desktop` en-US），而这版插件的桌面分支走的是 WinRT 而非 SAPI。激活在零语音时
抛 `winrt::hresult_error`（`hr=0x800455A0`），抛在成员初始化器里 → fail-fast。

**修法**（`flutter/third_party/flutter_tts/`，见下节）：把激活从成员初始化器搬到
构造函数体内的一次显式 `activate()`，失败就记 `ready = false` 而不是终止进程，
再用 `ready` 守卫每个入口。修完 release 构建稳定运行、正常写出数据文件。

**验证**（`tool/probe_exit.ps1`，Windows 上唯一可信的启动测量方式）：

```
verdict : ALIVE after 15.1s (window=True)
```

同时写出 `.winrun/v3/Lexumo/lexumo.json`（version 3、1 个 list、14 个词、45 条 log）。

#### 为什么要把 `flutter_tts` 复制进仓库

`flutter/third_party/flutter_tts/` 是 **4.2.5 的原样拷贝**，只改 Windows 那份
`flutter_tts_plugin.cpp`。`pubspec.yaml` 用 `path:` 指向它。理由：改 pub cache 里的
文件是「用后必须还原」的临时手段，既不能随代码提交、也不能在另一台机器重现。
补丁本身也固化成脚本：`node tool/patch_tts_windows.cjs`（`--restore` 还原，备份为
`.lexpristine`），可重复执行且幂等。

改动的四处：

1. 成员改为不激活的空构造：`SpeechSynthesizer synth{ nullptr };`、
   `MediaPlayer mPlayer{ nullptr };`，新增 `bool ready = false;`
2. 新增 `bool activate()`，在 `try/catch` 里做激活并置 `ready`
3. 12 处入口加 `ready` 守卫：`pause/continuePlay/stop/getVoices/getLanguages` 直接
   return，`setVoice/setLanguage/speak/asyncSpeak` 回 `Success(0)`（Dart 侧得到回复
   而不是永久挂起），`setVolume/setPitch/setRate` 三个单行函数加 `if (!ready) return;`
4. 析构里仅在 `ready` 时 `try { mPlayer.Close(); } catch (...) {}`（对空 player 调
   `Close()` 会从析构函数抛出）

只改 `#if defined(WINAPI_FAMILY) && (WINAPI_FAMILY == WINAPI_FAMILY_DESKTOP_APP)`
那半到 `#else` 之间的桌面分支，UWP 半边保持上游原样。**注意**：按
`void FlutterTtsPlugin::getVoices(...)` 定位会命中两次（两个分支各一份），必须先按
`\n#else\n` 切开再在 head 里替换。

#### 由此暴露的一个诚实性问题（已修）

插件被守护后不再抛异常，但它**仍然会应答每一个方法**——`getVoices` 返回空列表、
`setLanguage` 返回 `0`。于是原先的 `init()`「通道答了就说明引擎能用」的判断在这台
机器上会答 `true`，界面画出 发音 按钮而点了没声音。

`FlutterTtsEngine.init()` 现在分平台判断：**Windows 上要求语音列表非空**才算可用；
其它平台仍然「通道通了就算可用」，因为 Android 的引擎在后台异步启动、插件会排队，
冷启动第一次拿到空列表是正常的，把它当失败会在每次启动时藏掉 发音 按钮。平台通过
构造参数注入（`FlutterTtsEngine(null, TargetPlatform.windows)`）以便测试。
`test/tts_test.dart` 的 `FlutterTtsEngine.init` 组用 mock method channel 覆盖了
四种情形：Windows 零语音 → 不可用、Windows 有语音 → 可用、Android 空列表 → 可用、
通道缺失 → 任何平台都不可用。

**顺带说明桌面语音的最终行为**：这台机器上 Windows 版会把 发音 按钮藏起来（WinRT
零语音），这是如实反映而不是故障。Android 端的语音正常——那边的引擎是
`TextToSpeech`，与 WinRT 无关。

#### 沙箱对运行的限制

本机沙箱禁止 **Dart/Flutter 进程**写工作区之外的路径（实测五个目标里只有工作区内
那个成功，其余全抛 `PathAccessException errno = 5`；bash 与 `cmd` 的
`echo >` 却能写同一目录，`icacls` 显示全权限、无 deny ACE），所以验证 Windows 版
必须把 `APPDATA` 指到工作区内：

```bash
powershell -NoProfile -ExecutionPolicy Bypass \
  -File flutter/tool/probe_exit.ps1 \
  -Exe flutter/build/windows/x64/runner/Release/lexumo.exe -Ms 15000 \
  -AppData .winrun/v3
```

不指的话应用启动后立刻因 `SnapshotStore.save` 的 `PathAccessException` 退出——那是
沙箱限制，不是代码问题。

#### 完整的 Windows 构建命令

```bash
./tool/build_windows.sh          # 环境变量、符号链接、清理、构建，一次做完
```

上面那三条关（nuget、符号链接、install 前缀）都不是「知道一次就记住」的东西，
所以它们被收进 `tool/build_windows.sh`。脚本做的事：把 `HOME`/`APPDATA`/`TMP`
钉到工作区、把 `/c/Users/noaha/Downloads` 加进 PATH、`taskkill` 掉可能在跑的实例、
跑 `prelink.cjs` 与 `_mklinks.bat`、**删掉 `build/windows`**、再调 flutterc。
参数原样透传。

删 `build/windows` 是其中最新加的一条，代价是每次多 47 秒，收益是躲开一个
很能骗人的错误：**`CMAKE_INSTALL_PREFIX` 会被缓存**。干净的 configure 把它写成
`$<TARGET_FILE_DIR:lexumo>`（于是 install 步骤把文件拷到 exe 旁边，正是想要的），
但某个更早的缓存里留着 `C:/Program Files/lexumo` 时，install 步骤会去那儿建目录、
失败于 `file cannot create directory: C:/Program Files/lexumo`，而 MSBuild 只把它
包成一句 `MSB3073: 命令 setlocal 已退出，代码为 1`——**报错里既不提 CMake 也不提
install**，只在中间某行出现过一次 `cmake_install.cmake`。真正的修复就是删缓存目录。

#### 产物

`flutter/build/windows/x64/runner/Release/` 约 40 MB：`lexumo.exe`（80,896 B）、
`flutter_windows.dll`、`flutter_tts_plugin.dll`、`file_selector_windows_plugin.dll`、
`data/`（`app.so` + `flutter_assets` + `icudtl.dat`）。字体已打进
`data/flutter_assets/assets/fonts/`。

#### 一条通用教训

这一整轮的多数弯路都不是「分析错了」，而是**测了上一次构建的残留二进制**：旧 exe
没删，`[ -f "$EXE" ]` 通过，于是「崩溃消失了」和「格子结果互相矛盾」同时出现。
任何「改代码 → 看行为」的实验，构建前必须删掉目标二进制、构建后必须确认它真的被
重写。这与死代码扫描器那次「工具报全干净」是同一类错误：**先验证测量手段有效，
再相信测量结果**。为此 `tool/probe_exit.ps1` 取代了更早的 `tool/run_windows.ps1`——
后者用 `Start-Process -PassThru`，对短命 GUI 子进程常常返回空 `ExitCode`，把
「崩溃 `0xC0000409`」和「正常退出 0」都印成 `code= (0x00000000)`。

### 7.3 测试与验证工具

`flutter/tool/` 下的脚本都是为「模拟器 adb 不稳定」这件事写的，都带重试：

| 脚本 | 用途 |
| --- | --- |
| `build_apk.sh` | 出 release APK（唯一的正确出包方式） |
| `reinstall.sh` | 重装并校验远端 APK 大小，确认装的是新包 |
| `adb.sh` | 带重试的 adb 包装（`tool/adb.sh shell "pm list packages"`） |
| `dump_ui.sh` | dump 当前界面无障碍树到 xml |
| `mobile_sweep.sh` | 依次切五个页面并 dump，用于回归 |
| `check_hints.cjs` | 检查 dump 出的 xml 里有没有残留键帽文本 |
| `shot.sh` | 截图（同样带 adb 重试） |
| `apk_state.sh` / `verify_apk.sh` / `diagnose_install.sh` | 安装问题排查 |
| `repro_lck.sh` | 复现 7.4 的 `.lck` 问题，用于确认环境变量假设 |
| `release.sh` | 出签名 APK + 生成 `dist/update.json`（见 7.6） |
| `setup_signing.sh` | 把 keystore 就位并写出 `android/key.properties`，密码不经历史、先验证再落盘 |
| `scan_i18n.cjs` / `scan_symbols.cjs` / `scan_public.cjs` / `scan_orphans.cjs` | 死代码扫描 |
| `ui_text.sh` | 只取界面文本标签（比整棵无障碍树好读） |
| `restart_and_dump.sh` | 重启应用并 dump，用于确认冷启动后的状态 |
| `shots_mobile.sh` / `shot_retry.sh` | 逐页截图 / 单张截图（都带 adb 重试） |
| `probe_exit.ps1` | Windows 启动测量：拿真实退出码 + 是否画出窗口（见 7.2） |
| `run_windows.ps1` | 旧版 Windows 启动测量，退出码不准，已被上一条取代 |
| `prelink.cjs` | 用 `mklink /D` 补插件符号链接（Dart 建不了，见 7.2） |
| `patch_tts_windows.cjs` | 给 vendored `flutter_tts` 打 Windows 崩溃补丁（`--restore` 还原） |
| `probe_lookup.dart` | 打真实网络的查词冒烟：三个 provider 各走一次，打印音标/释义/例句与缓存条数 |
| `build_windows.sh` | Windows release 出包：环境变量、符号链接、删 build/windows、构建（见 7.2） |

一次完整的移动端回归：

```bash
./tool/build_apk.sh && ./tool/reinstall.sh
./tool/mobile_sweep.sh .shots/verify
for f in .shots/verify/*.xml; do node tool/check_hints.cjs "$f" | grep verdict; done
# 每页都应输出 verdict: CLEAN (no keyboard hints)
```

### 7.4 为什么必须用脚本：`.lck` 报错的真相

`flutterc build apk` / `flutterc run` 会失败于：

```
java.io.FileNotFoundException:
C:\Users\noaha\.gradle\wrapper\dists\gradle-9.3.1-all\9ot9r568e8zfvvd4mn8rbu1j0\gradle-9.3.1-all.zip.lck (拒绝访问。)
```

这条报错把排查引向了三个错误方向，逐个排除之后才找到真因：

1. **不是权限**。`icacls` 显示 `NOAH\noaha:(I)(F)` 全权限；Java 单独
   `new RandomAccessFile(lck,"rw")` 也成功；把 `.lck` 删掉仍然报同样的错。
2. **不是磁盘满**。磁盘一度到 100%（剩 15 MB），清到 8 GB 后报错一字不变。
3. **不是 target 反斜杠**。`flutterc run -v` 显示它传给 Gradle 的是绝对路径
   `-Ptarget=C:\Users\noaha\prj\lingueez-web\flutter\lib\main.dart`，不是反斜杠的
   `lib\main.dart`。

**真因是环境变量**。flutter 只给 Gradle 子进程传 `JAVA_HOME` 和 `PATH`
（`flutter_tools/lib/src/android/java.dart:154-160` 的 `environment` getter），
而 `gradlew.bat` 要靠 `HOME` / `USERPROFILE` 定位 `~/.gradle`。继承完整的用户环境
（`tool/build_apk.sh` 做的就是这个）就能过。

`tool/repro_lck.sh` 是决定性的对照实验：同一个命令行，只改环境变量——

```
===== A: plain environment =====        BUILD FAILED in 20s
===== B: flutterc-pinned environment ===  BUILD SUCCESSFUL in 2m 19s
```

顺带记一个前置：`services.gradle.org` 直连超时，`gradle-9.3.1-all.zip` 是从
`https://mirrors.cloud.tencent.com/gradle/` 手工下到
`~/.gradle/wrapper/dists/gradle-9.3.1-all/9ot9r568e8zfvvd4mn8rbu1j0/` 的
（目录名 = md5(distributionUrl) 的 base36）。下好之后 `./gradlew --version` 自己会
解压出 `.ok`。这台机器上 Gradle 分发包不是自动拉的，装新机器时要重做一次。

### 7.5 磁盘空间

C: 长期在 99%。移植过程中清掉的：

- `.flutter-sdk/flutter.zip`（1.94 GB）——SDK 已解压，zip 不需要
- 误拷的 `.flutter-home/gradle-home`（需先 `taskkill //F //IM java.exe` 解锁）
- `flutter/build` 从 1.8 GB 清到 552 MB（删 `app/intermediates`、`app/tmp`、
  `.cxx`、`native_assets`）

之后稳定在 6.2 GB 空闲。`flutter/build` 会随每次构建回涨，空间紧张时重复上面第三步。

### 7.6 发布与应用内升级

一条命令出签名包加清单：

```bash
cd flutter
./tool/release.sh            # 读 pubspec 的 version，出签名 APK + dist/update.json
./tool/release.sh --no-build # 只重算清单（APK 已在 dist/）
```

`--allow-dirty` / `--notes-file <path>` / `--min-supported <n>` / `--tag <v…>` 可选。
脚本**不做网络动作**，发布那一步是它打印的 `gh release create`。

更新说明是同一个可选的输入：`flutter/notes.json` 写 `{"zh": "…", "en": "…"}`，或者一段
中文正文（整段归到 `zh`）。**这个文件存在时 `release.sh` 会自动读它**（`--notes-file`
只是覆盖它），CI 也读同一个文件——两条出包路径共用一个来源，否则本机切出来的包会没有
说明、而 runner 切出来的有。没有这个文件时
清单里没有 `notes` 字段，而 `update_sheet.dart` 的 `_notes()` 在字段缺失时返回空列表——
这是刻意的：一个空的「更新内容」标题比没有这一节更糟，它暗示有内容却没写。

三处单一来源，改版本时只改一处：

| 事实 | 唯一来源 | 谁读它 |
| --- | --- | --- |
| 版本号与 build | `pubspec.yaml` 的 `version:` | Gradle（经 `local.properties`）、`release.sh`、CI |
| 安装包指纹 | 磁盘上真实 APK 的 `sha256` 与大小 | `release.sh` 写进清单，`UpdateService` 下载后重算比对 |
| 下载地址 | 清单 URL 由 `--dart-define=LEXUMO_UPDATE_URL` 决定 | `updateManifestUrl()`，默认是仓库 releases 的 `latest/download/update.json` |

**为什么脚本自己写 `local.properties`**：Gradle 从 `android/local.properties` 的
`flutter.versionName` / `flutter.versionCode` 读版本，而那几行平时是 `flutter build`
写进去的——本机跑不了 `flutter build apk`（见 7.4），所以 `release.sh` 用
`write_local_props()` 自己写这三行，只碰这三行，`sdk.dir` / `flutter.sdk` 原样留着。
版本同时经 `-Pdart-defines=<base64>` 注入引擎，作为通道拿不到版本时的回落。

**签名的两种失败方式，脚本各管一种**：

- `android/key.properties` 缺失 → 打印 keytool 指引并 `exit 1`。不回落 debug，因为
  debug 密钥随机器变，装过 debug 包的人永远无法覆盖升级（Android 拒绝签名不一致的
  覆盖安装），而那是一个用户无法自救的状态。`--no-build` 时只警告，因为那条路只是
  重算清单。
- 签名对但清单对不上 → 由 `UpdateService` 在下载后拦（`verifySignature` 通道调
  Kotlin 侧比对证书）。这类错误必须在**安装之前**发现：装上之后系统只会给一句
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，用户不知道该怪谁。

`tool/setup_signing.sh` 管住第三种，也是实际最常发生的一种：`key.properties` 写错了。
它把 keystore 复制进 `android/`（`storeFile` 是相对 `android/` 解析的，文件放别处时
Gradle 的报错只会说"找不到某个文件"），用 `read -s` 收密码（不进 shell 历史、不进日志），
**先拿 `keytool -list` 验一遍再落盘**——密码错或 alias 错时不写文件，因为写下去的错
`key.properties` 比没有更糟：它要等五分钟构建才失败，而原因看起来像签名问题。
`umask 077` 收权限，`cp` 而不是 `mv`（原件可能是唯一备份）。

`.github/workflows/release.yml` 在打 `v*` 标签时跑：analyze + 全量测试 → 校验标签与
`pubspec.yaml` 一致 → 解 `ANDROID_KEYSTORE_BASE64` 四个 secret 成 keystore →
`flutter build apk --release --target-platform android-arm64` → **`apksigner verify`
并拒绝任何证书里带 "Android Debug" 的包** → 生成 `update.json` → `gh release create`
→ `curl --fail --head` 验证清单真的可达。

CI 里**刻意不用** `tool/build_apk.sh`：那脚本只是本机 `HOME` 丢失的绕法，Linux runner
上原生 `flutter build apk` 是对的，把它搬进 CI 会让 CI 对「干净机器能做什么」撒谎。

应用内升级的链路（`lib/data/repositories/update_service.dart` + `lib/ui/features/update/views/update_sheet.dart`）：

```
启动 ─→ load()（读真版本，首帧前）─→ check()（六小时内不重复）
                                     ├ upToDate   → 设置页第二行说一句
                                     ├ available  → 卡片转 primary → 弹窗
                                     └ failed     → 静默，卡片第二行留原因
available ─→ download()（写 cache/updates/，边写边算 sha256）
             └ 大小对 + digest 对 + 签名对 ─→ ready
ready ─→ install()（交文件给系统安装器）
         └ 回来后 resumed ─→ confirmInstalled()：**重读 buildNumber，变大才算装上**
```

三条判断值得记下：

- **进度不信安装器，信字节。** `download()` 自己数个数字节、自己算 SHA-256，装不上
  之前所有证据都在自己手里；把「下载好了」当作安装器的话，会让一次篡改的下载看起来
  像一次成功的升级。
- **唯一的成功证据是 build 变了**（`confirmInstalled()`）。安装器返回 `launched` 只
  说明「对话框弹了」，用户可能点了取消。
- **取消不是失败**。`cancel()` 之后回到 `available` 并把半截文件删掉，不做红字提示：
  那是用户自己的点击，不该被当错误回敬。

`reason` 是 wire 码不是句子（`offline` / `server` / `manifest` / `digest` /
`signature` / `space` / `storage` / `unsupported` / `permission`），翻译在 i18n 层，
所以一条 iOS 上永远到不了的码不会让字典长出无主文案。

**清单是真产物验过的，不是只验过解析器。** `test/release_artifacts_test.dart` 读
`dist/update.json`，用 app 自己那个 `ReleaseManifest.parse` 解一遍，再回头把磁盘上的
APK 重新算一遍大小与 SHA-256 对比，最后核对清单里的 build 与 `pubspec.yaml` 一致。
`dist/` 在 gitignore 里，所以干净克隆和 CI 上这三条会 `markTestSkipped`；本地跑一次
`./tool/release.sh` 之后它们就是活的。这一步的意义在接缝处：清单是 shell 脚本写的、
Dart 读的，两侧手写同一个格式，中间没有任何东西替它们对账——一个字段悄悄改名，要到
发版之后每台手机都说「已是最新」才会暴露。

### 本机环境实测

```
rustc 1.94.1     node v24.10.0     java 17.0.12 (Oracle)
Flutter 3.47.8   Dart 3.13.7       PostgreSQL 18.4 (docker, postgres:latest)
Android SDK 36.0.0  build-tools 36.0.0  platform android-37.0
模拟器 Medium_Phone (1080×2400)   VS2019 BuildTools 16.11.36602.28（缺 CMake 组件）
```

### 截图

`.shots/` 下有模拟器实拍：`01-words` `02-flashcards` `03-quiz` `04-stats` `05-settings`
`06-quiz-active` `07-flashcard-session` `08-settings-dark` `09-settings-en` `10-final-words`。

---

## 8. 如果要继续

按优先级：

1. **把密钥送上 GitHub，然后打第一个标签**。本机这一半已经做完了：
   `android/upload-keystore.jks` 已生成（`CN=lexumo, OU=Mobile, O=lexumo,
   L=Hangzhou`），`setup_signing.sh` 写出了 `android/key.properties`，
   `tool/release.sh` 出的包用 `apksigner verify --print-certs` 能验到这张证书而不是
   `CN=Android Debug`。剩下的两步都要凭据，脚本故意不做：用
   `flutter/tool/github_secrets.sh` 逐个把四个值送进剪贴板、粘进 GitHub 的 Settings →
   Secrets（它不打印任何值，也不上传），然后打第一个 `v*` 标签让 workflow 跑起来。
   **两个文件都已 gitignore**（`android/.gitignore` 的 `**/*.jks` 与 `key.properties`），
   而 keystore 一旦丢失，所有已安装的包就再也无法覆盖升级——它比仓库本身更该备份。
2. **在真 Supabase 项目上验证一次**。SQL 函数、13 条 Postgres 测试、差分测试都已
   就位，但那跑的是「真 Postgres + 手写 RPC 垫片」，GoTrue 是 `rpc_bridge.cjs` 模拟的。
   真实 GoTrue 发的是 JWT，`auth.uid()` 从 `request.jwt.claim.sub` 读——协议一致，
   但没在线上项目走过一遍。顺带补 `supabase/config.toml` 与 `db push` 的部署流程
   （本机无 supabase CLI）。
3. **自绘标题栏**。Windows 版现在能跑，但窗口用的是系统标题栏，而 Web 版是 36px
   石色自绘条（`--frame-bar-h`）。要补需要 `window_manager` 加窗口拖拽/最小化/
   最大化/关闭的原生接线，`Layout.frameBarH` 这个令牌是给它留的。
4. **拖拽导入**。`desktop_drop` 插件，接到设置页的导入逻辑上。解析器和文件选择都已
   就位，缺的只是这个拖放接收器；Windows 构建已通，现在加它是可验证的。
5. **Windows 桌面语音**。本机 WinRT 语音栈零 voice，桌面版会把 发音 按钮藏起来。
   要真正出声得把插件的桌面分支从 WinRT 换到 SAPI（`sapi.h`/`sphelper.h` 与
   `SAPI.Lib` 在 SDK 里齐全，SAPI 侧本机有两个可用语音），但那是几百行的改动，且
   `atlstr.h`（ATL）本机没装。现在的 vendor 补丁刻意没走这条路，只保证「不崩 +
   不用时安静降级」。

已知**不该再动**的部分：`third_party/flutter_tts` 的桌面分支只承担「不崩」和
「引擎不可用时安静降级」两个目标。若哪天上游修好了崩溃，删掉 vendor 目录、
`pubspec.yaml` 改回 `flutter_tts: ^4.2.5` 即可，`tool/patch_tts_windows.cjs` 同步失效。

### 查词翻译是怎么接上的

这一项原在缺口清单里，现已完成，但它的形状值得记一笔，因为**难点不在网络请求**。

`platform/translate.dart` 早就移植好了（三个适配器、30 天缓存、429 冷却、音标与双语
例句解析），编辑器里的两个按钮也一直在原位——只是 `onPressed` 是 null。接线本身很短：

- 词 → 释义：`_runLookup` 调 `lookupTerm(term, LookupOptions(from, to, force: true))`，
  把 `posTags` / `primaryMeaning` / `alternativeMeaning` / `examples.first` / `phonetic`
  分别写进对应字段。**只写非空项**，这样查不到音标时不会把用户手填的音标清掉。
- 释义 → 词：`_runReverse` 反向查，`prefer: [google, myMemory]`——有道把「苹果」译成
  「りんごです」，那是句子不是词条。
- **重试要抬掉冷却**。一个 429 会把所有 provider 关进 90 秒黑屋，而按钮这时正好变成
  「重新翻译」——不抬冷却的话，它在这 90 秒里只可能再失败一次，看起来就是个坏按钮。
  所以两个 `_run*` 都在 `phase == failed` 时先 `resetProviderCooldown()`。
  这不会让人真的刷爆 provider：仍在限流的那个会再答一个 429、重新上自己的锁；窗口
  只是省掉无谓请求，不是替 provider 执行限流。
- 缓存落在 `AppDir.dataDir/lookup-cache.json`，与 `lexumo.json` **分开**：快照是用户
  数据，要备份、同步、导出；词典缓存是抛弃型，混进去只会让每次备份臃肿。
  `FileLookupStorage` 惰性读一次后常驻内存，写盘失败就静默吞掉——内存副本仍是权威，
  代价只是下次多一次网络请求。

真正会出错的是**迟到的答案**。一次查询比启动它的那次按键活得久，所以结果落地前要
过两道守卫：请求没被更新的请求顶掉（`isCurrentForward(stamp)`），**并且那个字段现在
的内容还是当初查的词**（`model.term.text.trim() != query` 就丢弃）。只有第一道不够——
stamp 只在新请求或 dispose 时递增，用户改词并不触发它，于是「cat」的慢答案会覆盖掉
用户刚改过的释义。`editor_lookup_test.dart` 里「a late answer for a superseded word is
dropped」就是钉这一条的。

**真端点验过一遍。** `tool/probe_lookup.dart` 打的是真实网络而不是假 HTTP：`candid` 与
`zephyr` 都从有道拿到音标与多条释义（各 2 条例句），`苹果` 经 Google/MyMemory 反查
回 `Apple`。缓存文件也确认落盘（`.flutter-home/AppData/Roaming/Lexumo/lookup-cache.json`，
键 `lexumo.dict.v1`）——单测能证明解析和降级链，证明不了对端今天还这么答。

另一处容易漏的：`pumpAndSettle()` 在没有待调度帧时立刻返回，早于 fake 的
`Future.delayed` 触发，按钮还停在「翻译中…」。测试里必须先
`await tester.pump(const Duration(milliseconds: 300))` 显式推进虚拟时钟。

### 四层验证，以及它们各自抓不到什么

改同步代码时值得知道哪一层会替你看住什么，因为它们看的不是同一件事：

| 层 | 命令 | 能抓到 | 抓不到 |
| --- | --- | --- | --- |
| 单元/widget | `flutterc test` | 合并语义、会话文件、UI 状态 | 真实 HTTP 形状、SQL |
| SQL | `supabase/tests/run.sh` | 函数逻辑、LWW、并发锁、RLS | 客户端是否说对协议 |
| 端到端 | `LEXUMO_SUPABASE_E2E=… flutterc test test/supabase_e2e_test.dart` | Dart 客户端 ↔ 真 Postgres 的整条链 | 真实 GoTrue 的 JWT |
| 差分 | `node supabase/tests/differential.cjs` | 两个后端是否给出同一个答案 | 两者是否**都对**（共同的错不会被发现） |

第 3 层不是可选的。它抓到了一个单元测试抓不到的 bug：一轮同步在**请求之前**把
`config` 快照下来了，而 401 换 token 发生在请求**之中**，于是轮末保存会话时用旧快照
覆盖了刚拿到的新 refresh token——下一次启动会拿一个已被服务端作废的 token 去刷新。
这种「只在第二次启动时才出错」的 bug，假传输永远测不出来，因为假传输不会在请求中间
改自己的状态。修法与回归测试见 `test/sync_token_rebase_test.dart`。

第 4 层做过反向验证：把 words 的 LWW 从 `>=` 改成 `>`，差分立刻报 10/13 轮不同；
改回来回到 13/13 identical。**一个从不失败的测试不算测试。**
