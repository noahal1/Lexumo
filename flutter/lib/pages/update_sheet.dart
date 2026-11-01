/// The update sheet: what the new release is, and the four steps to it.
///
/// One modal for every phase, because the phases are one flow — a user who
/// pressed Download does not want a second dialog when the bytes land, and a
/// failure belongs where the retry button is. [UpdateService] owns the state;
/// this file only draws it, and the two subscribe to the same
/// `ValueNotifier<UpdateState>` so a download that continues after the sheet is
/// closed still shows its progress when it is reopened.
///
/// Closing the sheet never cancels anything. The download runs in the service,
/// the settings row mirrors it, and a user who backgrounds the app for two
/// minutes comes back to a progress bar and not to a restarted download.
library;

import 'package:flutter/material.dart';

import '../app/scope.dart';
import '../app/update_scope.dart';
import '../data/update_service.dart';
import '../design/tokens.dart';
import '../domain/update_manifest.dart';
import '../platform/app_installer.dart';
import '../ui/controls.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart';

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

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({required this.service});

  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: service.state,
      builder: (context, _) {
        final state = service.state.value;
        final available = state.available;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (available != null) ...[
              _Headline(
                label: context.t('settings.updateAvailable', {
                  'version': available.manifest.version.name.toString(),
                }),
                detail: _sizeLine(context, available),
              ),
              if (state.phase == UpdatePhase.available ||
                  state.phase == UpdatePhase.downloading ||
                  state.phase == UpdatePhase.verifying) ...[
                const SizedBox(height: Sp.x4),
                ..._notes(context, available),
              ],
            ] else if (state.phase == UpdatePhase.upToDate) ...[
              _Headline(label: context.t('settings.updateUpToDate')),
            ] else if (state.phase == UpdatePhase.checking) ...[
              _Headline(label: context.t('settings.updateChecking')),
            ],
            if (state.isBusy) ...[
              const SizedBox(height: Sp.x4),
              _progress(context, state),
            ],
            if (state.phase == UpdatePhase.ready) ...[
              const SizedBox(height: Sp.x4),
              _Headline(
                label: context.t('settings.updateReady'),
                detail: state.file == null
                    ? null
                    : context.t('settings.updateDownloaded', {
                        'size': _formatBytes(state.totalBytes ?? 0),
                      }),
              ),
            ],
            if (state.phase == UpdatePhase.failed) ...[
              const SizedBox(height: Sp.x4),
              _problem(context, state),
            ],
            if (state.refusal == InstallRefusal.needsPermission) ...[
              const SizedBox(height: Sp.x3),
              _notice(context, context.t('settings.updatePermission'), p.warnSoft, p.warn),
            ],
            // Desktop cannot install an APK, and inventing a download button
            // that ends in "the installer said no" would be worse than saying
            // where the build lives. The URL is selectable so it can be copied
            // without adding a launcher plugin for one line of text.
            if (service.installer.support == InstallSupport.downloadOnly) ...[
              const SizedBox(height: Sp.x4),
              Text(
                context.t('settings.updateDesktop'),
                style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
              ),
              const SizedBox(height: Sp.x2),
              SelectableText(
                _releasesUrl(service.manifestUrl).toString(),
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

  String _sizeLine(BuildContext context, UpdateAvailable available) {
    final bytes = available.manifest.apk.bytes;
    if (available.required) return context.t('settings.updateRequired');
    if (bytes == null) return '';
    // Not `updateDownloaded`: the sheet is still offering the download, and
    // telling someone "19.5 MB downloaded" before they pressed anything is the
    // kind of small untruth that makes every other number here suspect.
    return context.t('settings.updateSize', {'size': _formatBytes(bytes)});
  }

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

  Widget _progress(BuildContext context, UpdateState state) {
    final p = Palette.of(context);
    final pct = (state.progress * 100).clamp(0, 100).round();
    final label = switch (state.phase) {
      UpdatePhase.verifying => context.t('settings.updateVerifying'),
      UpdatePhase.checking => context.t('settings.updateChecking'),
      _ => context.t('settings.updateDownloading', {'percent': '$pct'}),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProgressBar(value: state.progress, thick: true),
        const SizedBox(height: Sp.x2),
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
              ),
            ),
            if (state.totalBytes != null)
              Text(
                _formatBytes(state.receivedBytes),
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

  Widget _problem(BuildContext context, UpdateState state) {
    final p = Palette.of(context);
    return _notice(
      context,
      updateReasonText(context, state.reason),
      p.dangerSoft,
      p.danger,
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
  /// Set while a download or install call is awaiting, so a second press does
  /// not start a second one. The service guards too; this keeps the button from
  /// looking live while it is not.
  bool _working = false;

  Future<void> _download() async {
    if (_working) return;
    setState(() => _working = true);
    await widget.service.download();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _install() async {
    if (_working) return;
    setState(() => _working = true);
    final outcome = await widget.service.install();
    if (!mounted) return;
    setState(() => _working = false);
    if (!outcome.launched && outcome.refusal == InstallRefusal.needsPermission) {
      await widget.service.installer.openInstallSettings();
    }
  }

  Future<void> _retry() async {
    final state = widget.service.state.value;
    if (state.available == null) {
      await widget.service.check(force: true);
    } else {
      await _download();
    }
  }

  Future<void> _later() async {
    final available = widget.service.state.value.available;
    if (available != null) await widget.service.dismiss(available.manifest.version);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service.state,
      builder: (context, _) {
        final state = widget.service.state.value;
        final available = state.available;
        final required = available?.required ?? false;

        // A required release has no "not now": the build below the floor cannot
        // talk to the server, so dismissing it would only postpone a failure
        // the user cannot attribute. Everything else can be postponed.
        final laterButton = required
            ? null
            : LexButton(
                label: context.t('settings.updateLater'),
                kind: BtnKind.quiet,
                size: BtnSize.sm,
                onPressed: _later,
              );

        final actions = <Widget>[];
        switch (state.phase) {
          case UpdatePhase.idle:
          case UpdatePhase.upToDate:
            actions.add(LexButton(
              label: context.t('settings.updateCheck'),
              kind: BtnKind.normal,
              size: BtnSize.sm,
              icon: Ic.refresh,
              onPressed: () => widget.service.check(force: true),
            ));
          case UpdatePhase.checking:
            break;
          case UpdatePhase.available:
            if (laterButton != null) actions.add(laterButton);
            if (state.refusal == InstallRefusal.needsPermission) {
              actions.add(LexButton(
                label: context.t('settings.updateOpenSettings'),
                kind: BtnKind.primary,
                size: BtnSize.sm,
                icon: Ic.arrowRight,
                onPressed: () => widget.service.installer.openInstallSettings(),
              ));
            } else {
              actions.add(LexButton(
                label: context.t('settings.updateDownload'),
                kind: BtnKind.primary,
                size: BtnSize.sm,
                icon: Ic.download,
                onPressed: _working ? null : _download,
              ));
            }
          case UpdatePhase.downloading:
          case UpdatePhase.verifying:
            actions.add(LexButton(
              label: context.t('settings.updateCancel'),
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: widget.service.cancel,
            ));
          case UpdatePhase.ready:
            if (laterButton != null) actions.add(laterButton);
            if (state.refusal == InstallRefusal.needsPermission) {
              actions.add(LexButton(
                label: context.t('settings.updateOpenSettings'),
                kind: BtnKind.primary,
                size: BtnSize.sm,
                icon: Ic.arrowRight,
                onPressed: () => widget.service.installer.openInstallSettings(),
              ));
            } else {
              actions.add(LexButton(
                label: context.t('settings.updateInstall'),
                kind: BtnKind.primary,
                size: BtnSize.sm,
                icon: Ic.check,
                onPressed: _working ? null : _install,
              ));
            }
          case UpdatePhase.failed:
            actions.add(LexButton(
              label: context.t('settings.updateCancel'),
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: () => Navigator.of(context).maybePop(),
            ));
            actions.add(LexButton(
              label: context.t('settings.updateRetry'),
              kind: BtnKind.primary,
              size: BtnSize.sm,
              icon: Ic.refresh,
              onPressed: _working ? null : _retry,
            ));
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: Sp.x2),
              actions[i],
            ],
          ],
        );
      },
    );
  }
}

/// The sentence for a failure [reason] code.
///
/// One owner for the mapping, because it is read in two places that must agree:
/// the sheet, which offers a retry, and the settings row, which has no room for
/// a retry and therefore has to be right the first time. When this lived twice,
/// the row reported "no connection" for every failure — a bad digest and a
/// missing connection were indistinguishable from outside, and the only action
/// either suggests (check your network) was wrong half the time.
///
/// An unknown code falls back to the server sentence rather than inventing one:
/// a code the app does not recognise means a newer client wrote it, and
/// "something went wrong" is both true and useless.
String updateReasonText(BuildContext context, String? reason) => switch (reason) {
      'offline' => context.t('settings.updateReasonOffline'),
      'server' => context.t('settings.updateReasonServer'),
      'manifest' => context.t('settings.updateReasonManifest'),
      'digest' => context.t('settings.updateReasonDigest'),
      'signature' => context.t('settings.updateReasonSignature'),
      'space' => context.t('settings.updateReasonSpace'),
      'storage' => context.t('settings.updateReasonStorage'),
      'unsupported' => context.t('settings.updateReasonUnsupported'),
      'permission' => context.t('settings.updateReasonPermission'),
      _ => context.t('settings.updateReasonServer'),
    };

/// Where a desktop user should go instead: the manifest URL with its asset path
/// peeled off, which is the releases page that published it.
///
/// Derived rather than configured so a test build pointed at a local file
/// server still names a real page, and so there is one URL to change.
Uri _releasesUrl(Uri manifest) {
  final segments = [...manifest.pathSegments];
  final drop = segments.lastIndexOf('releases');
  if (drop >= 0) {
    return manifest.replace(pathSegments: segments.sublist(0, drop + 1), query: '');
  }
  return manifest.replace(query: '');
}

/// Bytes for humans: one decimal above a megabyte, whole numbers below.
String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}
