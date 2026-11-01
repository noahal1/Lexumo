# Lexumo · 词砚 — Flutter 实现

同一套功能、同一套设计令牌，用 Flutter 重写的版本，编译到 **Windows** 与 **Android**。
`../src/` 是原本的 Tauri 2 + React 19 版；这一份不是它的替代，而是并行的另一份。

- 视觉决策的权威文档是 [`../docs/design.md`](../docs/design.md)（石与纸、单一石青强调、
  朱砂只留给不可恢复的删除）。
- 这一份如何落地、与 Web 版有意的差异、以及构建过程踩过的坑，记在
  [`../docs/flutter-design.md`](../docs/flutter-design.md)。

## 跑起来

**不要直接调 `flutter`。** 这台机器上 flutter 工具启动即写
`%APPDATA%\.flutter_tool_state`，而沙箱对 dart 进程写该路径返回 `PathAccessException`。
工作区里的 wrapper 把 `HOME` / `APPDATA` / `TMP` 钉到仓库内的 `.flutter-home/`：

```bash
cd flutter

../.flutter-sdk/flutterc analyze     # No issues found!
../.flutter-sdk/flutterc test        # 611 passed, 6 skipped

./tool/build_apk.sh                  # release APK → dist/lexumo-android-release.apk
./tool/release.sh                    # 签名 APK + dist/update.json（发布用）
./tool/reinstall.sh                  # 装到模拟器并校验
```

`flutter build apk` / `flutter run` 在本机会失败于一个**与代码无关**的原因：
它们交给 Gradle 的环境只有 `JAVA_HOME` 和 `PATH`，`gradlew.bat` 于是找不到
`~/.gradle`，算出错误的 dists 路径后试图重新下载，撞上
`gradle-9.3.1-all.zip.lck (Access denied)`——看起来像权限问题，其实不是。
`tool/build_apk.sh` 钉住环境变量后直接调 Gradle；`tool/repro_lck.sh` 可以复现这个
判断（同一行命令在裸 shell 里失败，钉住变量后成功）。完整分析见
`../docs/flutter-design.md` 的 7.4。

包名是 **`dev.lexumo.lexumo`**（`android/app/build.gradle.kts`）。注意不是
`com.lexumo.app`——那是 Tauri 版的 identifier。写错会让 `pm path` 永远返回空，
很容易把「已经装上了」误判成「没装上」。

## 目录

```
lib/
  main.dart          入口：Store 初始化 → UpdateService → 作用域树 → MaterialApp
  app/               scope（InheritedWidget 层）/ shell（三档布局 + 快捷键）/ toast
                     / update_scope.dart（升级服务的 InheritedNotifier）
  design/            tokens.dart（全部令牌）/ theme.dart（ThemeData 构建）
  domain/            纯逻辑，无 Flutter 依赖：srs / session / quiz / word_index / seed …
                     / version.dart（SemVer 比较）/ update_manifest.dart（清单解析）
  data/              store（全部写操作的唯一入口）/ snapshot_store / 同步四件套 / transfer
                     / update_service.dart（升级状态机）
  pages/             words / word_editor / flashcards / quiz / session_result / stats
                     / settings / update_sheet（升级弹窗）
  platform/          文件选择（Android 走平台通道）/ TTS / 发音 / 翻译 / 安装
  ui/                controls（LexButton/LexInput/LexSelect…）/ widgets（PageShell 等）
                     / density.dart / keyboard_hints.dart / lex_icon.dart
```

两条贯穿全局的规矩，改代码前先看它们：

1. **写操作只有一个入口。** 所有提交走 `data/store.dart`，不可变快照，UI 只读
   `context.data`。加一个写操作意味着同时加一条 journal 记账。
2. **平台差异按平台判断，不按宽度判断。** 快捷键提示（`ui/keyboard_hints.dart`）
   与触控密度（`ui/density.dart`）都是这么做的：窄化的桌面窗口仍然由键盘和鼠标驱动，
   横屏平板很宽却只有手指——宽度会把这两种情况都答错。参数的默认值取
   `defaultTargetPlatform`，测试可以显式传入钉住答案。

## 手机布局

令牌里的控件高度 36 / 32 是鼠标量出来的。手机上的规则是：

- **触控目标地板 44dp**（`Layout.tap`，经 `ui/density.dart` 的 `context.controlH` 取到），
  带文字的按钮整体长大，纯图标按钮只长大命中盒（`TapTarget`），绘制形状不变。
- `TapTarget` 必须放在 `GestureDetector` **内部**，且外层 detector 要
  `HitTestBehavior.opaque`，否则命中区没动、或者环是死的。
- 查询带在手机上是两行（搜索+排序+收藏 / 状态+批量选择），不是三行。

这些不靠看截图确认，`test/mobile_layout_test.dart` 用三条预算断言管住：
六个界面在 411dp 下不抛布局异常、五个页面每个 `GestureDetector` 两维 ≥ 44dp、
首屏预算（顶栏 ≤ 84dp、第一行单词 ≤ 320dp、查询带 ≤ 120dp）。
数字取「设计能容忍的最大值」而不是某一次量到的值，所以字体度量浮动半个像素不会
让测试变成绊线。理由与修之前的数字见 `../docs/flutter-design.md`。

## 发布与升级

两条命令，都从 `flutter/` 下跑：

```bash
./tool/build_apk.sh     # 未签名配置下的 release 包（本地自用）
./tool/release.sh       # 签名包 + dist/update.json，发布用
```

第一次发布前还要跑一次 `./tool/setup_signing.sh`：它把 keystore 复制进 `android/`、
用 `read -s` 收密码（不进 shell 历史）、**先拿 keytool 验一遍再写**
`android/key.properties`。密码错或 alias 错时它不写文件——写下去的错配置要等五分钟
构建才失败，而现象看起来像签名坏了。

`release.sh` 读 `pubspec.yaml` 的 `version:` 作为唯一版本来源，写进
`android/local.properties`（Gradle 从那里读）并同时经 `-Pdart-defines` 注入应用，
然后从磁盘上真实的 APK 算 `sha256` 与大小写进清单。它**不发网络请求**，发布那一步是
它打印出来的 `gh release create`。没有 `android/key.properties` 时它直接失败，
不回落 debug 签名——debug 密钥随机器变，装过 debug 包的人就再也无法覆盖升级。

打 `v*` 标签会触发 `.github/workflows/release.yml`：analyze + 全量测试 → 校验标签与
`pubspec.yaml` 一致 → 用四个 secret 解出 keystore → 构建 → `apksigner verify` 且拒绝
debug 证书 → 生成清单 → 发布 release 资产。需要的 secret：
`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、
`ANDROID_KEY_PASSWORD`。

更新说明可选：在 `flutter/notes.json` 里写 `{"zh": "…", "en": "…"}`，或者直接写一段
中文正文（整段归到 zh）。这个文件存在时 `release.sh` 自动读它（`--notes-file` 只是覆盖），
CI 读同一个文件。没有这个文件时清单里就没有 `notes`，应用会把「更新内容」整段省掉，
而不是画一个空的标题。

应用内升级的链路、三条判断（进度信字节不信安装器、唯一成功证据是 build 变了、
取消不是失败）记在 `../docs/flutter-design.md` 的 7.6 节。

## 测试

```bash
../.flutter-sdk/flutterc test                                # 全部
../.flutter-sdk/flutterc test test/mobile_layout_test.dart   # 手机布局三条预算
```

574 个通过、6 个跳过（那 6 条要真 Postgres 桥接，见
`../docs/supabase-sync-plan.md`）。四层验证各自抓不到什么，记在
`../docs/flutter-design.md` 末节：

| 层 | 命令 | 抓不到 |
| --- | --- | --- |
| 单元/widget | `flutterc test` | 真实 HTTP 形状、SQL |
| SQL | `../supabase/tests/run.sh` | 客户端是否说对协议 |
| 端到端 | `LEXUMO_SUPABASE_E2E=… flutterc test test/supabase_e2e_test.dart` | 真实 GoTrue 的 JWT |
| 差分 | `node ../supabase/tests/differential.cjs` | 两者是否**都对** |

## 已知缺口

按优先级列在 `../docs/flutter-design.md` 第 8 节。最实在的四条：签名密钥与第一次发布
还没做（在那之前装上的都是 debug 签名包，互相不能覆盖升级）；真 Supabase 项目上没跑过；
没有自绘标题栏（走系统原生的）；没有拖拽导入。另外查词翻译的**引擎**已经移植完并测试
到位（`lib/platform/translate.dart`），只是编辑器里那两个按钮还没接上，仍是禁用占位。
