// What the app shows when it cannot start, or when a widget throws.
//
// These surfaces exist because of a shipped bug: `main()` awaited five things
// before `runApp` with no handler anywhere, so a throw in any of them meant the
// window kept showing the launch drawable — white on a light theme. A phone
// reporting "it's just white" gave nothing to work with. See `boot_guard.dart`
// for the full account.
//
// The assertions are deliberately about *what is on screen*: names the step,
// prints the exception, and does so without help from the theme or the store,
// because those are part of what failed.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/boot_guard.dart';
import 'package:lexumo/data/services/app_dir.dart';

Widget _throwing() => Builder(
      builder: (BuildContext context) =>
          throw StateError('the page could not be built'),
    );

void main() {
  group('a boot that failed', () {
    testWidgets('names the step that broke', (WidgetTester tester) async {
      await tester.pumpWidget(BootFailureApp(
        step: '读取词库',
        error: StateError('disk said no'),
        stack: StackTrace.current,
      ));

      expect(find.text('停在「读取词库」这一步。'), findsOneWidget);
      expect(find.textContaining('Lexumo could not start'), findsOneWidget);
    });

    testWidgets('prints the exception and where it came from',
        (WidgetTester tester) async {
      await tester.pumpWidget(BootFailureApp(
        step: '读取同步会话',
        error: StateError('disk said no'),
        stack: StackTrace.current,
      ));

      expect(
        find.textContaining('StateError: Bad state: disk said no'),
        findsOneWidget,
      );
    });

    testWidgets('a watchdog failure explains itself in words',
        (WidgetTester tester) async {
      await tester.pumpWidget(BootFailureApp(
        step: '读取版本信息',
        error: TimeoutException('no answer', kBootDeadline),
        stack: StackTrace.current,
        hint: '关掉应用重开通常就好。',
      ));

      expect(find.textContaining('关掉应用重开通常就好'), findsOneWidget);
      expect(find.textContaining('TimeoutException'), findsOneWidget);
    });

    testWidgets('the deadline is long enough to be a real boot, short enough '
        'that a user waits', (WidgetTester tester) async {
      // A wide band on purpose: the point is that this is a *judgement* recorded
      // in one place, not a number to tune silently.
      expect(kBootDeadline.inSeconds, greaterThanOrEqualTo(10));
      expect(kBootDeadline.inSeconds, lessThanOrEqualTo(60));
    });
  });

  group('a widget that threw while building', () {
    testWidgets('says so instead of painting an empty box',
        (WidgetTester tester) async {
      // Release builds replace a failed subtree with an empty `ErrorWidget`,
      // which is indistinguishable from a blank page.
      //
      // Restored inside the body, not in a tear-down: the binding asserts the
      // builder is unset *before* tear-downs run, so an addTearDown restore is
      // already too late.
      final previous = ErrorWidget.builder;
      installErrorHandlers();
      try {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _Bad())));
        final error = tester.takeException();

        expect(error, isA<StateError>());
        expect(find.textContaining('这一块没能画出来'), findsOneWidget);
        expect(
            find.textContaining('the page could not be built'), findsOneWidget);
      } finally {
        ErrorWidget.builder = previous;
      }
    });

    testWidgets('needs no theme from the subtree that failed',
        (WidgetTester tester) async {
      // It is inserted exactly where the failure was, which may be above
      // `MaterialApp`. Anything that reads `Theme.of(context)` here would throw
      // a second time and lose the message.
      await tester.pumpWidget(BrokenWidget(
        details: FlutterErrorDetails(exception: StateError('no theme here')),
      ));

      expect(find.textContaining('no theme here'), findsOneWidget);
    });
  });

  group('the data directory', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('lexumo-appdir-'));
    tearDown(() => root.deleteSync(recursive: true));

    testWidgets('walks past a folder it cannot create, and uses the next',
        (WidgetTester tester) async {
      // A path whose parent is a *file* cannot be created, which is the shape of
      // the real failure: the platform hands over a folder this process may not
      // write to.
      final blocker = File('${root.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('not a folder');
      final good = '${root.path}${Platform.pathSeparator}good';

      final chosen = AppDir.debugPrepare(<String>[
        '${blocker.path}${Platform.pathSeparator}nested',
        good,
      ]);

      expect(chosen, good);
      expect(Directory(good).existsSync(), isTrue);
      expect(Directory('${blocker.path}${Platform.pathSeparator}nested')
          .existsSync(), isFalse);
    });

    testWidgets('answers with a path rather than throwing when nothing works',
        (WidgetTester tester) async {
      // The app must still start. A bad day for writes is not a reason to show
      // a launch window forever: the first real save will fail loudly with a
      // path in its message instead.
      final blocker = File('${root.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('not a folder');
      final impossible =
          '${blocker.path}${Platform.pathSeparator}still-not-a-folder';

      final chosen = AppDir.debugPrepare(<String>[impossible]);

      expect(chosen, impossible);
    });

    testWidgets('the first candidate wins when it is writable',
        (WidgetTester tester) async {
      final first = '${root.path}${Platform.pathSeparator}first';
      final second = '${root.path}${Platform.pathSeparator}second';

      expect(AppDir.debugPrepare(<String>[first, second]), first);
      expect(Directory(second).existsSync(), isFalse);
    });
  });
}

/// Throws while building, on purpose.
class _Bad extends StatelessWidget {
  const _Bad();

  @override
  Widget build(BuildContext context) => _throwing();
}
