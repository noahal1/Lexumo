# Lexumo UI/UX 优化计划

日期 2026-11-09，基线 `024b0f2`（0.2.20+21）。范围：`flutter/` 五个界面 + 引导 + 外壳。

## 0. 关于 uizze-ui 的 image-first 工作流

`uizze-ui` 要求「先出 UI 图，再 1:1 实现」。这条链路在本机**走不通**，如实说明：

- 没有图像生成工具：网关（`127.0.0.1:8326`）105 个模型里没有任何 image 生成端点（只有 chat/vision）。
- 没有 Uizze MCP 连接：`mcp_connector_status` = 0 条；Uizze 的资源需要付费连接。

所以按 skill 的 `## If image generation is unavailable` 分支走：**不伪造图，不声称 1:1 匹配**，改为「以现有实机截图为基线 → 改 → 同尺寸再截图 → 视觉模型逐项比对」。这条替代链路的证据强度低于真图，但每一步都可复核（截图 + 源码位置都在仓库里）。

## 1. 证据来源（三路，互相校验）

| 来源 | 内容 |
| --- | --- |
| 实机截图 | 1600×1000 与 620×1100 两种宽度，六屏 + onboarding，共 13 张（`.hallmark/shots/ux-*.png`） |
| 视觉审计 | `deepseek-official/deepseek-flash` 逐屏读图，指出层级/重复/裁切 |
| 静态审计 | 只读代码审计：状态完整性、危险操作、键盘焦点、无障碍、文案一致性 |

下面每条都带 `文件:行号`，可核对。

## 2. 四波计划

按「会不会真的伤到人」排序，不按「好不好看」排。每波独立可验证、可单独发布。

---

### Wave 1 · P0：五个真 bug（不改视觉）

**1.1 搜索框里打 `n` 会弹出新建词页**

- 位置：`flutter/lib/ui/features/words/views/words_page.dart:186-193`
- 现状：`CallbackShortcuts` 绑了裸 `n`（新建词）和 `/`（聚焦搜索），没有判断搜索框是否已聚焦。`CallbackShortcuts` 在输入框的祖先链上，普通字母不会被输入框消费，所以边打字边触发。
- 改法：两个回调前加 `if (_searchFocus.hasFocus) return;`，并把 `_searchFocus` 之外的可编辑区域（词库重命名框）也纳入守卫。
- 验证：先写一条**会失败**的 widget 测试（聚焦搜索框 → `tester.sendKeyEvent(keyN)` → 断言没有打开编辑器），再修到绿。这条现在是测不出来的：现有测试用 `enterText` 绕开了按键。

**1.2 Windows 窗口收窄到手机宽度时，底部导航栏盖住内容**

- 位置：`flutter/lib/ui/core/widgets/widgets.dart:92`、`:136`
- 现状：布局模式按**宽度**判断（`app_shell.dart:252` `width <= Layout.mobileBreakpoint`，720dp），但安全留白按**平台**判断（`widgets.dart:92` `context.isTouch ? Layout.tap : 0`，`isTouchPlatform()` 在 Windows 上恒为 false）。两个判断不一致 → 620 宽的 Windows 窗口用手机布局（有底栏）却拿不到底栏留白，最后一行被盖住。
- 改法：新增一个由 `app_shell` 提供的 `InheritedWidget`（`ShellChrome`，暴露 `hasBottomBar` 与 `bottomBarHeight`），`PageShell` 与 FAB 的底部留白改读它，读不到时退回现在的行为（widget 测试不受影响）。这同时修掉 FAB 的同一个坑。
- 验证：620×1100 实机截图，OCR/视觉确认最后一行完整可见、FAB 不被底栏压住；并补一条 620 宽（Windows 平台）的布局测试。

**1.3 Windows 构建永远显示版本 `0.0.0`**

- 位置：`flutter/tool/build_windows.sh`（没有传 `--dart-define`）；`flutter/lib/data/services/app_installer.dart:172-175,214`
- 现状：Windows 上 method channel 不存在 → 回落到 `--dart-define` → 两个值都是空/0 → `AppBuildInfo.unknown`（`versionName: '0.0.0'`）。`tool/release.sh:163` 只给 APK 传了这些 define，Windows 脚本漏了。
- 改法：`build_windows.sh` 从 `pubspec.yaml` 解析 `version:` 拆成 name/build，追加 `--dart-define=LEXUMO_VERSION=… --dart-define=LEXUMO_BUILD=…`。
- 验证：重建后「我的 → 关于」读到真实版本号（视觉确认，不是 `0.0.0`）。

**1.4 切 tab 会销毁页面状态**

- 位置：`flutter/lib/ui/features/shell/views/app_shell.dart:236-248`
- 现状：`_navigate` 主动 `controller.jumpTo(0)`，且五个页面在 `switch` 里互斥构建，没有 keep-alive。后果：滚动位置丢失；练习页正在进行的一轮复习（`practice_page.dart:59` 的 `_running`）静默消失；词库页的列表重命名态、`_busy` 一起丢。同文件 `:146-150` 的注释还写着「切回来像返回而不是重启」，与实现矛盾。
- 改法：分两步，先做便宜且无争议的——
  - 删掉 `jumpTo(0)`，每个 `PageShell` 的 controller 配 `PageStorageKey`，滚动位置由框架恢复；
  - 练习轮的 `_running` 提到 shell 之上的 `PracticeSessionScope`（形状照 `SyncScope`/`UpdateScope`），切走再回来仍是同一轮；确实要离开一轮时弹确认。
- 验证：切走切回，滚动位置与进行中的复习轮都还在；补测试。

**1.5 快捷键帮助表在说谎，而且自己关不掉**

- 位置：`flutter/lib/ui/features/shell/views/app_shell.dart:110-120`（表）vs `:266-279`（真实绑定）、`:1311-1345`（弹窗）
- 现状：
  - 表里列 `/`、`n` 为全局键，实际只在词库页绑；
  - 表里 `←/→` 写作「跳过当前卡片」，闪卡里 `←/→/↑` 是**评分**、`↓` 才是跳过（`flashcards_page.dart:224-245`）；
  - 弹窗是裸 `showDialog`，没有 Esc、内容不可滚（矮窗口或 2.0× 字号直接溢出）。
- 改法：表改成按页分组的真实绑定（或把 `/`、`n` 提升为全局并在各页实现）；弹窗换成 `showLexModal`（自带 Esc 与滚动）。
- 验证：逐条按键实测，表与实际一致；矮窗口（1000×560）下弹窗可滚、Esc 可关。

---

### Wave 2 · 信息架构：一个数字只出现一次

这一波是用户说的「更美观现代」里真正有内容的部分：**删**比**加**更能提升观感。

**2.1 统计页同一进度说三遍**

- 位置：`flutter/lib/ui/features/stats/views/stats_page.dart:110-140`
- 现状：`今日复习 0`（StatTile）+ `每日目标 0/20`（`_HeadCard` 副标题）+ `还差 20 次复习`（同一张卡内）三处同源；`词语总数 14` 与 `状态分布 · 共 14 个词语` 两处。
- 改法：`今日复习` 这个 StatTile 只留数字与「达标/未达标」一个词，把「还差 N 次」交给每日目标卡独占；`状态分布` 的副标题去掉（它上面就是 `词语总数`）。

**2.2 首页数字 7 出现四次**

- 位置：`flutter/lib/ui/features/home/views/home_page.dart:254-365`（`_Hero`）、侧栏徽标、底部词库胶囊
- 现状：标题「还有 7 张卡片在等你」、按钮「开始复习 · 7」、侧栏 `练习` 徽标 7、底部「示例词库·英语 7」。
- 改法：标题保留数字（它是这句话的主语），按钮去掉计数（动作不需要再复述数量），徽标保留（它是跨页的持久提示），底部胶囊的词数改成「词库名」之外的弱信息或去掉。

**2.3 侧栏底部：诗句 + 三个无标签图标**

- 位置：`flutter/lib/ui/features/shell/views/app_shell.dart:436-470`（按钮）、`:545-620`（布局）
- 现状：`_StreakCard`（火焰 0 天 / 今日复习 0）+ 三个纯图标按钮（快捷键、主题、折叠）+ 一句装饰诗。三个图标无文字、不可聚焦、读屏读不到；诗句占固定空间但与任何任务无关。
- 改法：三个图标加 tooltip 已有，但补 `Semantics(label:)` 与键盘焦点；诗句从侧栏底部移除（或缩成品牌区的一行小字，不占独立段落）。`_StreakCard` 与首页/统计页的连续学习重复，二选一。

**2.4 我的页：身份区没有登录入口，版本号说两遍**

- 位置：`flutter/lib/ui/features/profile/views/profile_page.dart:150-170`（身份 + `_AboutRow`）、`:714-739`
- 现状：未登录时只有「未登录」三个字，登录要去设置里找；`_AboutRow` 副标题是版本号，尾部又写一次「版本」；公告卡（`_DesktopCard`）插在「导入 / 设置」和「关于」之间，打断扫描。
- 改法：身份区在未登录时给一个主按钮「登录 / 同步」；`_AboutRow` 去掉尾部「版本」二字（副标题已经是它）；公告卡移到列表末尾。

---

### Wave 3 · 视觉：栅格与密度

**3.1 词库宽屏一行中间大片空白**

- 位置：`flutter/lib/ui/features/words/views/words_page.dart:1390-1510`（`_buildWide`）
- 现状：`_buildWide` 与 `_buildCompact` 结构完全相同，都是「词条+释义一列，操作图标贴右」。1600px 下词条在最左、图标在最右，中间 900px 空着。表头（`:1420` 附近）还把「词语/释义」上下堆叠，与行的两行文字错位约 8px。
- 改法：宽屏改真两列：词条列固定约 320dp、释义列 `Expanded`，表头改成同栅格的单行（词语 | 释义），彻底消掉那 8px 错位。
- 验证：1600 宽截图，表头与行左缘像素级对齐。
- **实机校准（已落地）**：阈值最初按 960dp 写，但那是 logical 内容宽度——Windows 桌面 DPI 144 = 1.5×，1600 物理像素窗口只有约 1067 logical，扣掉 232dp 侧栏与 paper padding 后词表仅约 787dp，960 阈值会让两列在那个窗口完全不生效（widget 测试全绿，因为测试泵在 `devicePixelRatio=1`）。实测 1600 物理像素仍是堆叠、1920 才并排，遂把阈值降到 **720dp**（= `Layout.mobileBreakpoint`），并补一条 `@787dp` 的回归测试钉住这个真实 DPI 场景。720dp 时词条 320 + 间距 16 + 两个 32dp 操作 = 416，释义仍得约 250dp，两行不 ellipsis；640–720 保持原堆叠。

**3.2 练习页主操作在首屏之外**

- 位置：`flutter/lib/ui/features/practice/views/practice_page.dart`（`_frontPage`）
- 现状：1600×1000 下纵向顺序是 标题 → 模式切换 → 大号数字「7/本轮」→ 范围切换 → 「选项」+ 4 行设置 → **「开始复习」按钮**，按钮需要滚动 600 才看得到。`ConstrainedBox(maxWidth: 560)` + `Align(topCenter)` 让上半区极空、下半区堆叠。
- 改法：主操作固定到可见区——桌面用两栏（左：数字 + 开始按钮；右：选项列表），手机把「开始复习」做成贴底常驻按钮（和 FAB 同一条安全边）。设置项在手机上收进可展开的「选项」区。
- 验证：两种宽度下首屏都能看到并点击主操作。

**3.3 引导页细节**

- 位置：`flutter/lib/ui/features/onboarding/views/onboarding_page.dart:296-305` 及左栏
- 现状：副标题出现孤字换行（最后一行只剩「上。」）；密码框没有占位符也没有显隐图标（邮箱框有 `you@example.com`）；窗口矮时「先不登录」被底边裁切；左侧 232dp 石框只有小图标 + 字标 + 一句诗，上下大片纯色空白像占位区。
- 改法：副标题加 `maxLines` 与更宽的约束避免孤字；密码框补占位符 + 显隐切换；主列改用可滚动容器，矮窗口不裁切；左栏补一点真实内容（如三行功能点）或压缩到不再像空块。

**3.4 手机宽度：左右缩进不统一**

- 位置：`words_page.dart` 各处 gutter（`_gutter`）、`widgets.dart` 的 `PinnedStrip` 与 `PageShell` 内边距
- 现状：620 宽下词库胶囊/搜索框左缩进 ~49、列表文字 ~64、筛选按钮贴边 14、加号右侧 44——四条不同的左边线。
- 改法：统一成一个 gutter 令牌，所有区块读同一个值。

---

### Wave 4 · 键盘与无障碍（系统性问题）

**4.1 全应用按钮不可键盘聚焦**

- 位置：`flutter/lib/ui/core/widgets/controls.dart:164-196`（`LexButton`）、`:407-505`（`LexSelect` 等）
- 现状：`GestureDetector` + `MouseRegion`，没有 `FocusableActionDetector`/`InkWell`，Tab 只能到文本框。桌面版「键盘驱动」名不副实。
- 改法：给 `LexButton`、`LexSelect`、`LexSwitch`、侧栏 `_NavItem`、底栏 `_TabItem` 换 `FocusableActionDetector`（Enter/Space 触发 + 焦点环），焦点环用现成的 accent 色。
- 说明：这是本计划里**改动面最大**的一项（牵动所有页面的按钮），建议单独一波、单独发布。

**4.2 危险操作三种待遇**

- 位置：`settings_view_model.dart:333`（退出登录无确认）、`:382-396`（清空数据一次确认、无 undo）、`words_view_model.dart:481-496`（删词库 toast 不点名词库、无 undo）、`words_page.dart:2200-2211`（批量删用 `quiet` 而非 `danger`）、`:2727`（删最后一个词库静默失败）
- 改法：统一成一条规则——不可撤销 → `danger` + 明确宾语 + 需要二次确认；可撤销 → 必须有 undo。

**4.3 异步动作没有「进行中」这一态**

- 位置：`profile_page.dart:107-112`（`_busy` 只写不读，导入无任何反馈）、`settings_view_model.dart:419-422`（取消保存对话框被当成失败）、`:348`（退出登录成功却 toast「同步完成」）、`controls.dart:154`（`LexButton` 无 busy 变体）
- 改法：`LexButton` 加 `busy` 变体（禁用 + 内联 spinner）；导入、导出、同步三个动作都接到它上面。

---

## 3. 明确不做的事

- **不动设计系统**：`core/tokens.dart` 的色板、字号梯、间距梯、圆角规则都不改。这轮只调布局与信息架构。
- **不动用户未提交的 11 个文件**（onboarding/settings 的密码校验与 `SyncError.emailDisabled` 那批在途工作），改到同一文件时先和这批改动对齐、不覆盖。
- **不重构 `words_page.dart`（2836 行）**：只做定位到的局部修改。
- **不引入新依赖**（不加 `desktop_drop`、不加状态管理库）；`IndexedStack`/`InheritedWidget` 都是框架自带的。
- **不做深色主题专项**：本计划所有结论在浅色下验证，深色（Slate）需要单独一轮逐项核对。

## 4. 需要你拍板

1. **从哪一波开始**？建议 Wave 1（五个真 bug），它不碰视觉、可单独发版、每项都能用测试或截图验收。
2. **Wave 4.1（全应用键盘焦点）要不要做**？它价值高但改动面最大，会碰到每一个页面的按钮。
3. **要不要每波结束发一个版本**（0.2.21 / 0.2.22 …），还是全部做完一次发？

## 5. 验收方式（每波通用）

- `flutter analyze --no-pub` 干净；
- 受影响的测试文件通过（**全量测试由你自己跑**，我不跑）；
- 真实 Windows release 二进制重建 → 1600×1000 与 620×1100 各截一次图 → 视觉模型逐项比对改动点；
- 每波一个 commit，commit message 写清「改了什么 / 为什么」。
