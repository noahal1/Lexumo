/// Last-resort surfaces: what the user sees when the app cannot start.
///
/// ## What was wrong
///
/// `main()` awaits five things before `runApp` — the system chrome, the
/// snapshot, the sync engine, the update state, the onboarding sidecar — and
/// nothing caught a failure. The whole of `lib/` had no `runZonedGuarded`, no
/// `ErrorWidget.builder`, no `PlatformDispatcher.onError`.
///
/// So a throw in any of those five ended `main` *before a single widget was
/// built*, and the window kept showing the launch window. On a light-theme
/// device that launch window is white: `drawable-v21/launch_background.xml` is
/// `?android:colorBackground` and `values/styles.xml` launches on
/// `Theme.Light.NoTitleBar`. (On a dark-theme device the identical failure is a
/// black screen, which is why "it goes white" is a description of the theme,
/// not of the bug.)
///
/// A screen that says nothing is unactionable — reported from a phone that is
/// not on this machine, there is nothing to work with. That is the whole reason
/// this file exists.
///
/// ## Two ways `main` can fail, and one way a *running* app can look blank
///
///   1. **It throws.** [BootFailureApp] names the step that broke and prints
///      the exception.
///   2. **It never finishes.** A platform channel that never answers looks
///      identical from the outside, so the caller arms a watchdog for
///      [kBootDeadline] and paints the same page.
///   3. **A widget throws while building.** A release build's default
///      `ErrorWidget` paints an empty box — one bad page reads as a blank
///      screen with no clue. [installErrorHandlers] replaces it with
///      [BrokenWidget], which shows the message.
///
/// Nothing here swallows an error: what was invisible becomes visible, and the
/// app still refuses to pretend it is fine.
library;

import 'package:flutter/material.dart';

import '../ui/core/theme.dart';
import '../ui/core/tokens.dart';

/// How long `main` may spend before the app is allowed to say something is
/// wrong.
///
/// Generous on purpose. Boot is file IO plus one platform round trip — a cold
/// start on a slow phone with a large snapshot is under two seconds — so twenty
/// is far past "slow" and comfortably short of "the user has given up". A boot
/// that finishes after the deadline still takes over the screen; this is a
/// status report, not a kill switch.
const Duration kBootDeadline = Duration(seconds: 20);

/// Installs [BrokenWidget] as the face of a widget that throws during build.
///
/// Only `ErrorWidget.builder` is replaced. `FlutterError.onError` and
/// `PlatformDispatcher.onError` are deliberately left at their defaults: both
/// already write the exception to the console (and therefore to logcat), which
/// is exactly what a crash reporter would replace them with. What neither of
/// them does is put anything on screen, and that is the gap being closed here.
void installErrorHandlers() {
  ErrorWidget.builder = (FlutterErrorDetails details) =>
      BrokenWidget(details: details);
}

/// What the app draws when `main` itself failed.
///
/// Deliberately not using the store, the i18n scope or the theme of the moment:
/// every one of those is loaded by the very sequence that failed. The two
/// hardest facts — which step, which exception — are written in both languages
/// because the language setting is part of what could not be read.
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({
    super.key,
    required this.step,
    required this.error,
    required this.stack,
    this.hint,
  });

  /// The step `main` was in when the failure happened, in the user's language:
  /// "读取词库", "读取同步会话", and so on.
  final String step;

  final Object error;
  final StackTrace stack;

  /// An extra line for the watchdog case, where there is no exception to show.
  final String? hint;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Palette.light),
        darkTheme: buildTheme(Palette.dark),
        home: _FailurePage(step: step, error: error, stack: stack, hint: hint),
      );
}

class _FailurePage extends StatelessWidget {
  const _FailurePage({
    required this.step,
    required this.error,
    required this.stack,
    this.hint,
  });

  final String step;
  final Object error;
  final StackTrace stack;
  final String? hint;

  /// Enough of the stack to find the frame that threw, not so much that the
  /// interesting part is scrolled off a phone screen. The top frames are the
  /// ones that matter, so it is a head, not a tail.
  String get _detail {
    final head = stack.toString().split('\n').take(8).join('\n');
    return '${error.runtimeType}: $error\n\n$head';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(Sp.x6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '词砚没能启动',
                    style: TextStyle(
                      fontFamily: Fonts.display,
                      fontSize: Fs.xl,
                      height: Lh.title,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                      fontFamilyFallback: Fonts.cjkFallback,
                    ),
                  ),
                  SizedBox(height: Sp.x1),
                  Text(
                    'Lexumo could not start',
                    style: TextStyle(
                      fontSize: Fs.sm,
                      height: Lh.snug,
                      color: p.ink3,
                      fontFamilyFallback: Fonts.cjkFallback,
                    ),
                  ),
                  SizedBox(height: Sp.x5),
                  Text(
                    '停在「$step」这一步。',
                    style: TextStyle(
                      fontSize: Fs.base,
                      height: Lh.body,
                      color: p.ink2,
                      fontFamilyFallback: Fonts.cjkFallback,
                    ),
                  ),
                  if (hint != null) ...<Widget>[
                    SizedBox(height: Sp.x2),
                    Text(
                      hint!,
                      style: TextStyle(
                        fontSize: Fs.sm,
                        height: Lh.body,
                        color: p.ink3,
                        fontFamilyFallback: Fonts.cjkFallback,
                      ),
                    ),
                  ],
                  SizedBox(height: Sp.x4),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(Sp.x3),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: R.borderMd,
                      border: Border.all(color: p.line),
                    ),
                    child: SelectableText(
                      _detail,
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.body,
                        color: p.ink2,
                      ),
                    ),
                  ),
                  SizedBox(height: Sp.x4),
                  Text(
                    '把这一屏截图发给开发者就能定位问题；'
                    '这个页面只在本机出现，不影响已保存的单词。',
                    style: TextStyle(
                      fontSize: Fs.sm,
                      height: Lh.body,
                      color: p.ink3,
                      fontFamilyFallback: Fonts.cjkFallback,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The face of a widget that threw while building.
///
/// Sized and coloured by hand rather than by `Theme.of(context)`: this widget is
/// inserted *where the failure was*, which may be above `MaterialApp` or inside
/// a subtree whose `Theme` is the thing that threw. A `DefaultTextStyle` and a
/// `Directionality` are cheap; depending on the ambient theme is not safe here.
class BrokenWidget extends StatelessWidget {
  const BrokenWidget({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final message = details.exceptionAsString().split('\n').first;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Paper.bg,
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: Fs.sm,
            height: Lh.snug,
            color: Paper.ink2,
            fontFamilyFallback: Fonts.cjkFallback,
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(Sp.x4),
              child: Text(
                '这一块没能画出来 · This part failed to build\n$message',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
