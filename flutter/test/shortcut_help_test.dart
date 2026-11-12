// Wave 1.5 — the `?` sheet used to lie, and its own advertised Esc key did
// not work.
//
// The old table listed `/` and `n` as app-wide (they are bound only in the
// word library), labelled `←/→` as "skip" (`←/→/↑` grade a flashcard; `↓`
// skips it), and omitted the quiz's keys entirely. It was also a bare
// `showDialog` with a non-scrolling Column: no Esc binding, so the one key it
// did document for closing a modal was the one key that failed on itself.
//
// These tests pin:
//   · every row names a real i18n key and the scope it truly belongs to;
//   · the sheet renders the group headings and the truthful key rows;
//   · the dialog is scrollable and closes on Esc.

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/app/scope.dart';
import 'package:lexumo/ui/core/i18n/i18n.dart';
import 'package:lexumo/domain/models/types.dart' show UiLang;
import 'package:lexumo/ui/core/theme.dart';
import 'package:lexumo/ui/core/tokens.dart';
import 'package:lexumo/ui/core/widgets/widgets.dart' show ShortcutRow;
import 'package:lexumo/ui/features/shell/views/app_shell.dart';

/// Pumps [child] inside the scopes `context.t` needs, at a desktop width.
Future<void> pumpScoped(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    I18nScope(
      i18n: const I18n(UiLang.zhCN),
      child: MaterialApp(
        theme: buildTheme(Palette.light),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('kShortcutHelp', () {
    test('every row resolves to a real label', () {
      final I18n i18n = const I18n(UiLang.zhCN);
      for (final ShortcutHelp row in kShortcutHelp) {
        expect(
          i18n.dict.containsKey(row.labelKey) ||
              I18n.fallback.containsKey(row.labelKey),
          isTrue,
          reason: 'missing i18n key: ${row.labelKey}',
        );
      }
    });

    test('page-scoped keys are not app-wide', () {
      bool isAppWide(List<String> keys) => kShortcutHelp.any(
            (ShortcutHelp r) => r.scopeKey == null && _sameKeys(r.keys, keys),
          );
      // `/` and `n` live in WordsPage, not the shell.
      expect(isAppWide(const <String>['/']), isFalse);
      expect(isAppWide(const <String>['n']), isFalse);
      // The shell genuinely owns these three.
      expect(isAppWide(const <String>['?']), isTrue);
      expect(isAppWide(const <String>['Esc']), isTrue);
      expect(isAppWide(const <String>['Ctrl', '1…5']), isTrue);
    });

    test('arrows grade, down-arrow skips', () {
      String scopeOf(List<String> keys, String labelKey) {
        final ShortcutHelp row = kShortcutHelp.firstWhere(
          (ShortcutHelp r) => _sameKeys(r.keys, keys) && r.labelKey == labelKey,
        );
        return row.scopeKey ?? '';
      }
      // The old lie: `['←','→']` → shortcuts.skip, app-wide.
      expect(
        kShortcutHelp.where((ShortcutHelp r) => r.labelKey == 'shortcuts.skip'),
        isEmpty,
        reason: 'no row may still call ←/→ skip',
      );
      expect(scopeOf(const <String>['←'], 'flashcards.gradeHard'), 'flashcards');
      expect(scopeOf(const <String>['→'], 'flashcards.gradeGood'), 'flashcards');
      expect(scopeOf(const <String>['↑'], 'flashcards.gradeEasy'), 'flashcards');
      expect(scopeOf(const <String>['↓'], 'quiz.skip'), 'flashcards');
    });

    test('the quiz keys are present and scoped to the quiz', () {
      for (final String label in <String>[
        'quiz.chooseAnswer',
        'quiz.chooseAnswerNum',
        'quiz.next',
      ]) {
        expect(
          kShortcutHelp.where(
            (ShortcutHelp r) => r.labelKey == label && r.scopeKey == 'quiz',
          ),
          hasLength(1),
          reason: 'missing quiz row: $label',
        );
      }
    });

    test('the three groups are the ones the app has', () {
      final Set<String?> scopes =
          kShortcutHelp.map((ShortcutHelp r) => r.scopeKey).toSet();
      expect(scopes, <String?>{null, 'words', 'flashcards', 'quiz'});
    });
  });

  group('ShortcutSheet', () {
    testWidgets('renders group headings and the truthful rows', (tester) async {
      // In the app the sheet is the (scrollable) body of showLexModal. Pumped
      // bare it would overflow a small viewport, so give it the same scroll
      // wrapper here and assert what the reader actually sees.
      await pumpScoped(
        tester,
        const SingleChildScrollView(child: ShortcutSheet()),
      );
      expect(find.text('词库'), findsOneWidget);
      expect(find.text('练习 · 卡片'), findsOneWidget);
      expect(find.text('练习 · 测验'), findsOneWidget);
      expect(find.text('困难'), findsOneWidget);
      expect(find.text('记得'), findsOneWidget);
      expect(find.text('简单'), findsOneWidget);
      // The single `↓ 跳过` row, not a `←/→` pair.
      expect(find.text('跳过'), findsOneWidget);
      expect(find.byType(ShortcutRow), findsNWidgets(kShortcutHelp.length));
    });
  });

  group('showShortcutSheet', () {
    testWidgets('the body scrolls and Esc closes the dialog', (tester) async {
      // A small viewport forces the grouped table taller than the dialog's
      // maxHeight, so a non-scrolling body would overflow and the sheet would
      // be unreadable. showLexModal wraps the body in a SingleChildScrollView.
      tester.view.physicalSize = const Size(800, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpScoped(
        tester,
        Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => showShortcutSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(find.text('快捷键'), findsOneWidget);

      // The old bare showDialog had no Esc binding and stayed open.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('快捷键'), findsNothing);
    });
  });
}

bool _sameKeys(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
