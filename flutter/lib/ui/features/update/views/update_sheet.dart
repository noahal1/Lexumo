/// The update sheet: what the new release is, and the four steps to it.
///
/// One modal for every phase, because the phases are one flow — a user who
/// pressed Download does not want a second dialog when the bytes land, and a
/// failure belongs where the retry button is. [UpdateService] owns the state;
/// [UpdateViewModel] owns the screen's share of it (the snapshot, the `working`
/// latch, the build this sheet asked to skip), and this file only draws.
///
/// Closing the sheet never cancels anything. The download runs in the service,
/// the settings row mirrors it, and a user who backgrounds the app for two
/// minutes comes back to a progress bar and not to a restarted download.
///
/// ## Two widgets, two view models
///
/// [showLexModal] takes `body` and `footer` as separate slots, so the sheet was
/// always two widgets — and it was two `AnimatedBuilder`s before the refactor.
/// Each builds its own [UpdateViewModel] over the same service, which is why
/// the `working` flag lives on the footer's one: that is the region whose
/// buttons it disables.
library;

import 'package:flutter/material.dart';

import '../../../../app/scope.dart';
import '../../../../app/update_scope.dart';
import '../../../../data/repositories/update_service.dart';
import '../../../core/tokens.dart';
import '../../../../domain/models/update_manifest.dart';
import '../../../core/context_feedback.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../view_models/update_view_model.dart';

/// Opens the sheet on [service], or on the one mounted in the tree.
Future<void> showUpdateSheet(BuildContext context, {UpdateService? service}) {
  final engine = service ?? UpdateScope.serviceOf(context);
  if (engine == null) return Future<void>.value();
  return showLexModal<void>(
    context: context,
    title: context.t('settings.update'),
    subtitle: context.t('settings.updateHint', {
      'version': engine.currentRelease.name.toString(),
      'build': '${engine.currentRelease.build}',
    }),
    body: _UpdateBody(service: engine),
    footer: _UpdateActions(service: engine),
  );
}

/* ------------------------------------------------------------------ */
/* Body                                                                */
/* ------------------------------------------------------------------ */

class _UpdateBody extends StatefulWidget {
  const _UpdateBody({required this.service});

  final UpdateService service;

  @override
  State<_UpdateBody> createState() => _UpdateBodyState();
}

class _UpdateBodyState extends State<_UpdateBody> {
  late final UpdateViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = UpdateViewModel(
      service: widget.service,
      feedback: ContextFeedback(context),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final available = _vm.available;
        final headline = _vm.availableHeadline;
        final status = _vm.statusHeadline;
        final ready = _vm.readyHeadline;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (available != null && headline != null) ...[
              _Headline(label: headline, detail: _vm.availableDetail),
              if (_vm.showNotes) ...[
                const SizedBox(height: Sp.x4),
                ..._notes(context, available),
              ],
            ] else if (status != null) ...[
              _Headline(label: status),
            ],
            if (_vm.showProgress) ...[
              const SizedBox(height: Sp.x4),
              _progress(context),
            ],
            if (ready != null) ...[
              const SizedBox(height: Sp.x4),
              _Headline(label: ready, detail: _vm.readyDetail),
            ],
            if (_vm.showProblem) ...[
              const SizedBox(height: Sp.x4),
              _notice(context, _vm.problemText, p.dangerSoft, p.danger),
            ],
            if (_vm.showPermissionNotice) ...[
              const SizedBox(height: Sp.x3),
              _notice(context, _vm.permissionText, p.warnSoft, p.warn),
            ],
            // Desktop cannot install an APK, and inventing a download button
            // that ends in "the installer said no" would be worse than saying
            // where the build lives. The URL is selectable so it can be copied
            // without adding a launcher plugin for one line of text.
            if (_vm.downloadOnly) ...[
              const SizedBox(height: Sp.x4),
              Text(
                _vm.desktopText,
                style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
              ),
              const SizedBox(height: Sp.x2),
              SelectableText(
                _vm.releasesUrlText,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: p.ink3,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The release notes, in the language the rest of the screen is speaking.
  ///
  /// Picking the note needs the active locale, which [Feedback] does not expose
  /// — it translates keys, it does not report which language it translated
  /// into. So the view picks the text and the view model only decides whether
  /// any notes are drawn at all ([UpdateViewModel.showNotes]).
  List<Widget> _notes(BuildContext context, UpdateAvailable available) {
    final p = Palette.of(context);
    final note = available.manifest.notesFor(context.i18n.lang.wire);
    if (note == null || note.trim().isEmpty) return const <Widget>[];
    return [
      Text(
        context.t('settings.updateNotes'),
        style: TextStyle(
          fontSize: Fs.sm,
          height: Lh.tight,
          fontWeight: FontWeight.w500,
          color: p.ink2,
        ),
      ),
      const SizedBox(height: Sp.x2),
      Text(
        note.trim(),
        style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink3),
      ),
    ];
  }

  Widget _progress(BuildContext context) {
    final p = Palette.of(context);
    final bytes = _vm.progressBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProgressBar(value: _vm.state.progress, thick: true),
        const SizedBox(height: Sp.x2),
        Row(
          children: [
            Expanded(
              child: Text(
                _vm.progressLabel,
                style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
              ),
            ),
            if (bytes != null)
              Text(
                bytes,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.tight,
                  color: p.ink4,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _notice(BuildContext context, String text, Color fill, Color ink) {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(color: fill, borderRadius: R.borderSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LexIcon(Ic.alert, size: 14, color: ink),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.label, this.detail});

  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: Fonts.display,
            fontSize: Fs.md,
            height: Lh.title,
            fontWeight: FontWeight.w600,
            color: p.ink,
          ),
        ),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            detail!,
            style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3),
          ),
        ],
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Footer actions                                                      */
/* ------------------------------------------------------------------ */

class _UpdateActions extends StatefulWidget {
  const _UpdateActions({required this.service});

  final UpdateService service;

  @override
  State<_UpdateActions> createState() => _UpdateActionsState();
}

class _UpdateActionsState extends State<_UpdateActions> {
  late final UpdateViewModel _vm;

  @override
  void initState() {
    super.initState();
    _vm = UpdateViewModel(
      service: widget.service,
      feedback: ContextFeedback(context),
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// Perform [action], then close the sheet when the action means "done here".
  ///
  /// The pop is the view's because a view model has no route: [UpdateViewModel]
  /// records the skip and this method dismisses the modal, which is the same
  /// order the sheet had before the refactor.
  Future<void> _onPressed(UpdateAction action) async {
    switch (action) {
      case UpdateAction.later:
        await _vm.run(action);
        if (mounted) Navigator.of(context).maybePop();
      case UpdateAction.close:
        Navigator.of(context).maybePop();
      default:
        await _vm.run(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final actions = _vm.actions;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: Sp.x2),
              LexButton(
                label: context.t(_labelKey(actions[i])),
                kind: _kindFor(actions[i]),
                size: BtnSize.sm,
                icon: _iconFor(actions[i]),
                onPressed: _vm.isEnabled(actions[i])
                    ? () => _onPressed(actions[i])
                    : null,
              ),
            ],
          ],
        );
      },
    );
  }

  /// The i18n key for a button. Presentational, so it stays in the view: the
  /// view model names the action, this table names the words.
  String _labelKey(UpdateAction action) => switch (action) {
        UpdateAction.check => 'settings.updateCheck',
        UpdateAction.download => 'settings.updateDownload',
        UpdateAction.install => 'settings.updateInstall',
        UpdateAction.retry => 'settings.updateRetry',
        UpdateAction.cancel => 'settings.updateCancel',
        UpdateAction.openSettings => 'settings.updateOpenSettings',
        UpdateAction.later => 'settings.updateLater',
        UpdateAction.close => 'settings.updateCancel',
      };

  /// The weight each action keeps from before the refactor: the suggested step
  /// is primary, the way out is quiet, and Check stays `normal` — it is the
  /// only button on an idle sheet, so a quieter one would leave the row looking
  /// disabled.
  BtnKind _kindFor(UpdateAction action) => switch (action) {
        UpdateAction.check => BtnKind.normal,
        UpdateAction.later || UpdateAction.cancel || UpdateAction.close =>
          BtnKind.quiet,
        UpdateAction.download ||
        UpdateAction.install ||
        UpdateAction.retry ||
        UpdateAction.openSettings =>
          BtnKind.primary,
      };

  String? _iconFor(UpdateAction action) => switch (action) {
        UpdateAction.check || UpdateAction.retry => Ic.refresh,
        UpdateAction.download => Ic.download,
        UpdateAction.install => Ic.check,
        UpdateAction.openSettings => Ic.arrowRight,
        UpdateAction.cancel || UpdateAction.later || UpdateAction.close => null,
      };
}

/// The sentence for a failure [reason] code.
///
/// The mapping itself lives in [updateReasonKey], which the settings row also
/// reads through this function. Kept here, taking a [BuildContext], because
/// that is the shape the settings row calls it in — and because the sheet and
/// the row must never disagree about what a failure code means.
String updateReasonText(BuildContext context, String? reason) =>
    context.t(updateReasonKey(reason));
