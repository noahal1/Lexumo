/// The profile screen's state.
///
/// Ports the 「我的」 destination of the reference design: the three figures at
/// the top, the two bulk actions under them, and the version at the foot.
///
/// Everything the screen reads is a getter here, so the view derives nothing.
/// Pure of the widget layer — `foundation` only, no `material` — for the same
/// reason the other view models are: the arithmetic can be unit-tested without
/// pumping a tree, and the four things a view model cannot do itself
/// (translate, toast, confirm, navigate) arrive through [Feedback].
///
/// The import flow deliberately mirrors `SettingsViewModel.pickImport`: the
/// profile screen offers it as a first-class row instead of hiding it one level
/// down in settings, and the part that actually carries risk — parsing a
/// stranger's file and deciding what counts as a duplicate — is already shared
/// through `transfer.parseImport` and `findDuplicate`. What differs between the
/// two screens is only the preview sheet's chrome, which is a view concern.
library;

import 'package:flutter/foundation.dart';

import '../../../../data/repositories/store.dart';
import '../../../../data/services/file_dialogs.dart';
import '../../../../data/services/transfer.dart' as transfer;
import '../../../../domain/models/types.dart';
import '../../../../domain/use_cases/word_query.dart';
import '../../../core/view_model.dart';

/// Asks the user to confirm an import. The view shows the sheet; a test can
/// answer without one.
typedef ProfileImportPrompt = Future<bool> Function(ProfileImportRequest request);

/// What the preview sheet is asked to show.
@immutable
class ProfileImportRequest {
  const ProfileImportRequest({
    required this.fileName,
    required this.formatLabel,
    required this.result,
  });

  final String fileName;
  final String formatLabel;
  final transfer.ImportResult result;
}

/// State for the profile destination.
class ProfileViewModel extends ViewModel {
  ProfileViewModel({
    required this._store,
    required this._feedback,
    this._importPrompt,
    FileDialogs? dialogs,
    int Function()? clock,
  })  : _dialogs = dialogs ?? fileDialogs,
        _clock = clock ?? _systemClock {
    _derive();
    _detach = _store.addListener(_onStore);
    refresh();
  }

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  final Store _store;
  final Feedback _feedback;
  final ProfileImportPrompt? _importPrompt;
  final FileDialogs _dialogs;
  final int Function() _clock;
  late final void Function() _detach;

  late StatsSummary _summary;

  /* ---------------------------------------------------------------- */
  /* State the view reads                                             */
  /* ---------------------------------------------------------------- */

  /// The headline figures for the identity block: reviewed today, the streak
  /// and the size of the library.
  StatsSummary get summary => _summary;

  /// Words reviewed today.
  int get today => _summary.today;

  /// Consecutive days with at least one review.
  int get streak => _summary.streak;

  /// Words in the library.
  int get total => _summary.total;

  /// Declared wordbooks, for the library line's sub-caption.
  int get listCount => _store.data.lists.length;

  /// The library, for the parts of the screen that read it directly.
  AppData get data => _store.data;

  /// Whether a page can be opened by wire id — false in a bare test pump.
  bool get canNavigate => _feedback.canNavigate;

  /* ---------------------------------------------------------------- */
  /* Actions                                                          */
  /* ---------------------------------------------------------------- */

  /// Picks a file, parses it, asks for confirmation, then adds the words.
  ///
  /// The preview is not a nicety: importing can touch hundreds of words at
  /// once and the parsers are forgiving by design, so the user should see the
  /// result of that forgiveness before it lands in their library.
  Future<void> pickImport() async {
    final picked = await _dialogs.pickTextFile();
    if (isDisposed || picked == null) return;

    final data = this.data;
    final listId = data.lists.isNotEmpty ? data.lists.first.id : DEFAULT_LIST_ID;
    final result = transfer.parseImport(picked.text, listId);
    if (result.format == transfer.ImportFormat.unknown || result.words.isEmpty) {
      _feedback.toast(
        _feedback.t('settings.importFailed', {
          'msg': _feedback.t('settings.importUnrecognised'),
        }),
        kind: ToastKind.err,
      );
      return;
    }

    final prompt = _importPrompt;
    if (prompt == null) return;
    final confirmed = await prompt(
      ProfileImportRequest(
        fileName: picked.name,
        formatLabel: formatLabel(result.format),
        result: result,
      ),
    );
    if (!confirmed || isDisposed) return;

    commitImport(result);
  }

  /// Adds the parsed words, skipping terms already in the library.
  ///
  /// Duplicates are matched with [findDuplicate], the same function the word
  /// editor uses to warn about them — so "duplicate" means the same thing
  /// whether the word arrived from a form or a file.
  void commitImport(transfer.ImportResult result) {
    final data = this.data;
    final listId = data.lists.isNotEmpty ? data.lists.first.id : DEFAULT_LIST_ID;

    var added = 0;
    var duplicated = 0;
    for (final word in result.words) {
      if (findDuplicate(_store.data, word.term, listId) != null) {
        duplicated += 1;
        continue;
      }
      _store.addWord(word);
      added += 1;
    }

    if (added > 0) {
      _feedback.toast(
        _feedback.t('settings.importSuccess', {'n': added}),
        kind: ToastKind.ok,
      );
    }
    if (duplicated > 0) {
      _feedback.toast(
        _feedback.t('settings.importSkippedDuplicates', {'n': duplicated}),
        kind: ToastKind.info,
      );
    }
    if (added == 0 && duplicated == 0) {
      _feedback.toast(
        _feedback.t('settings.importFailed', {
          'msg': _feedback.t('settings.importNothing'),
        }),
        kind: ToastKind.err,
      );
    }
  }

  /// How a recognised format is named in the preview's subtitle.
  String formatLabel(transfer.ImportFormat format) => switch (format) {
        transfer.ImportFormat.json => _feedback.t('settings.formatJson'),
        transfer.ImportFormat.csv => 'CSV',
        transfer.ImportFormat.anki => 'Anki TXT',
        transfer.ImportFormat.unknown => _feedback.t('settings.formatUnknown'),
      };

  /* ---------------------------------------------------------------- */
  /* Wiring                                                           */
  /* ---------------------------------------------------------------- */

  void _onStore() {
    _derive();
    refresh();
  }

  void _derive() {
    // One clock read per derive: `summarize` must not be handed two different
    // "now"s inside one pass, or a review logged at midnight can be counted
    // as today by one figure and yesterday by the next.
    _summary = summarize(_store.data, _clock());
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
