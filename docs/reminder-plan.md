# 复习提醒：方案

日期 2026-11-26，基线 `bbe8976`（0.2.22+23）。范围：`flutter/`。前置阅读：
`docs/design.md`（视觉决策权威）、`flutter/lib/data/repositories/update_service.dart`
（sidecar 与 seam 的先例）。

## 1. 决策

### 提醒设置是设备本地的，不进 Settings

`Settings` 是**整份同步**的：一条 `SettingsRecord`，按 `updatedAt` last-write-wins。
把「每天 20:00 提醒我」放进去，意味着手机上关掉的提醒会同步到 Windows——而
Windows 构建根本没有通知能力，这个开关在那里是一句谎话。同步还会把 A 设备的
时间覆盖 B 设备的时间，两个设备无法各自选不同的提醒时刻。

这与 `UpdateStateStore` 不进 `Settings` 是同一条理由（"a release the user
dismissed is a fact about this device's attention"）：提醒也是**这台设备**的
注意力安排。所以提醒偏好放本地 sidecar `reminder.json`，与 `lexumo.json`
同目录，write-then-rename 原子写，损坏时回落默认值——损失最多是重新开关一次。

### 到期数不进通知文本之外的状态

每次调度时用 `deck_plan.dart` 的 `dueWords(words, now)` 现算。不缓存"上次
算出的 N"：缓存必然过期（用户半夜加了一批词），而现算的成本是遍历一次内存
列表，微不足道。

### 通知文本

`今天有 N 张卡片到期`（i18n：`reminderBody`，en: `N cards due today`）。
N 为 0 时**不发**——一条"你今天没有到期卡片"的通知是对打扰预算的挥霍。

### 与本地优先原则的关系

调度完全在本地，不产生任何同步记录、不改 `AppData`。关掉提醒、卸载应用，
账户数据零影响。

## 2. 结构

```
lib/data/services/notifications.dart    # seam：NotificationPort + 插件实现
lib/data/repositories/reminder_service.dart  # 调度决策 + sidecar 偏好
lib/ui/features/settings/…              # 设置页新增一组控件
```

### NotificationPort（seam，形状照 `AppInstaller`）

```dart
abstract class NotificationPort {
  Future<bool> requestPermission();     // Android 13+ 运行时权限；桌面恒 true
  Future<void> scheduleDaily(int id, String title, String body, ReminderTime time);
  Future<void> cancel(int id);
  bool get supported;                   // Windows 构建为 false
}
```

`PluginNotifications` 包 `flutter_local_notifications`；测试用
`FakeNotifications` 记录调用。`supported == false` 时设置页不渲染这组控件，
与 `speechSupported` 的处理完全一致。

### ReminderService

```dart
class ReminderService {
  ReminderService({required NotificationPort notifications,
                   required Store store, required ReminderPrefsStore prefs});
  Future<void> init();        // 读偏好，开且到期则调度
  Future<void> setEnabled(bool);
  Future<void> setTime(ReminderTime);
}
```

调度发生在：`init`（开机）、开关切换、时间变更、以及**每次同步轮结束**
（到期数可能变了——但只更新已调度通知的正文，不新增调度点）。旧通知先
`cancel` 再排新的，幂等。

### ReminderTime

`{hour, minute}`，默认 20:00。存 sidecar：`{"enabled": false, "hour": 20,
"minute": 0}`。

## 3. 平台

| 平台 | 能力 |
| --- | --- |
| Android 13+ | 需运行时 `POST_NOTIFICATIONS`（Manifest 已声明 normal 权限之外的运行时申请在插件内完成）；精确闹钟不申请——日历型通知不需要 |
| Android <13 | 安装时授予，无提示 |
| Windows | 插件支持 Windows 通知，但 0.2.x 只发布 APK + Windows 安装包且 Windows 端未验证通知行为——首版 `supported = false`，留待验证后打开 |

## 4. 测试

`test/reminder_service_test.dart`：fake 时钟 + `MemoryStore` + fake 通知口，
覆盖——开关打开即调度当天/次日正确时刻；N=0 不发；重排先 cancel；sidecar
损坏回落默认；不支持时不调度。
