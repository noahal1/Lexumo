/// The first-run gate: sign in to sync, or keep everything on this device.
///
/// ## Shape
///
/// The app is a two-material thing — a stone frame and a paper page — and this
/// screen is the one place that can show both at once, because it is the only
/// screen that is not inside the shell. Left is stone with the mark and the
/// name; right is paper with the actual question. Under 860dp the stone panel
/// collapses to a band across the top rather than disappearing: the mark is the
/// first thing a new install shows, and a screen that opens with a bare form
/// reads like a login wall rather than like the app.
///
/// ## Why the local path is a card, not a link
///
/// "Use it without an account" is half the product's promise, so it gets a
/// titled block and a real button. A quiet text link at the bottom would make
/// signing in the only path and this screen a nag; people close nags.
///
/// ## Why the server field is folded away
///
/// Almost everybody syncs to the one address baked into `kDefaultServer`. The
/// handful who self-host need to change it, and they are also the people
/// willing to open a disclosure. Showing it to everyone would make the first
/// screen look like a configuration file.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/scope.dart';
import '../../../../data/models/sync_config.dart' show kDefaultServer;
import '../../../../data/repositories/onboarding_store.dart';
import '../../../../data/repositories/sync_engine.dart';
import '../../../../data/services/sync_transport.dart' show SyncError;
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/lex_icon.dart';
import '../view_models/onboarding_view_model.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.engine,
    required this.onboarding,
    required this.onConfigured,
  });

  final SyncEngine engine;
  final OnboardingStore onboarding;

  /// Called once the answer is recorded. The app swaps this screen for the
  /// shell; this page does not navigate, because there is no shell to navigate
  /// inside yet.
  final VoidCallback onConfigured;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late final OnboardingViewModel _vm;
  late final TextEditingController _email;
  late final TextEditingController _password;
  late final TextEditingController _server;
  late final TextEditingController _key;

  /// The server disclosure starts open only when the saved address is not the
  /// built-in one, which means this user has configured a server before.
  late bool _showAdvanced;

  @override
  void initState() {
    super.initState();
    _vm = OnboardingViewModel(
      feedback: ContextFeedback(context),
      onboarding: widget.onboarding,
      engine: widget.engine,
      onConfigured: widget.onConfigured,
    );
    _vm.addListener(_onVmChanged);
    _email = TextEditingController(text: _vm.email);
    _password = TextEditingController(text: _vm.password);
    _server = TextEditingController(text: _vm.server);
    _key = TextEditingController(text: _vm.anonKey);
    _showAdvanced = _vm.server != kDefaultServer;
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmChanged);
    _vm.dispose();
    _email.dispose();
    _password.dispose();
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  void _submit(Future<void> Function() action) {
    // Drop the keyboard before the round trip: on a phone the keyboard covers
    // the error line that is about to appear underneath the form.
    FocusScope.of(context).unfocus();
    unawaited(action());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 5, child: _Frame(p: p)),
                  Expanded(flex: 6, child: _Paper(child: _body(p, true))),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Frame(p: p, band: true),
                Expanded(child: _Paper(child: _body(p, false))),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(Palette p, bool wide) {
    final inner = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: FadeRise(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              context.t('onboarding.title'),
              style: TextStyle(
                fontFamily: Fonts.display,
                fontSize: Fs.x2xl,
                height: Lh.title,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.01,
                color: p.ink,
              ),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              context.t('onboarding.lead'),
              style: TextStyle(
                fontSize: Fs.base,
                height: Lh.body,
                color: p.ink3,
              ),
            ),
            const SizedBox(height: Sp.x8),
            _form(p),
            const SizedBox(height: Sp.x7),
            _orRule(p),
            const SizedBox(height: Sp.x7),
            _localCard(p),
          ],
        ),
      ),
    );

    // Wide: the column is centred in the paper panel. Narrow: the band already
    // took the top, so the column starts right under it and scrolls.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        Sp.x6,
        wide ? Sp.x12 : Sp.x6,
        Sp.x6,
        Sp.x8,
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: wide ? Sp.x8 : 0),
          child: inner,
        ),
      ),
    );
  }

  Widget _form(Palette p) {
    final busy = _vm.busy;
    final error = _vm.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          context.t('onboarding.signInTitle'),
          style: TextStyle(
            fontSize: Fs.sm,
            fontWeight: FontWeight.w500,
            color: p.ink2,
          ),
        ),
        const SizedBox(height: Sp.x4),
        LexField(
          label: context.t('settings.syncEmail'),
          child: LexInput(
            controller: _email,
            placeholder: 'you@example.com',
            onChanged: _vm.setEmail,
            onSubmitted: (_) => _submit(_vm.signIn),
          ),
        ),
        const SizedBox(height: Sp.x4),
        LexField(
          label: context.t('settings.syncPassword'),
          hint: context.t('settings.syncPasswordHint'),
          child: LexInput(
            controller: _password,
            obscure: true,
            onChanged: _vm.setPassword,
            onSubmitted: (_) => _submit(_vm.signIn),
          ),
        ),
        const SizedBox(height: Sp.x3),
        _advanced(p),
        if (error != null) ...<Widget>[
          const SizedBox(height: Sp.x4),
          _errorNotice(p, error),
        ],
        const SizedBox(height: Sp.x5),
        LexButton(
          label: context.t(
            busy ? 'onboarding.signingIn' : 'settings.syncSignIn',
          ),
          kind: BtnKind.primary,
          block: true,
          onPressed: busy ? null : () => _submit(_vm.signIn),
        ),
        const SizedBox(height: Sp.x2),
        LexButton(
          label: context.t(
            busy ? 'onboarding.signingUp' : 'settings.syncSignUp',
          ),
          kind: BtnKind.quiet,
          block: true,
          onPressed: busy ? null : () => _submit(_vm.signUp),
        ),
      ],
    );
  }

  Widget _advanced(Palette p) {
    final label = Text(
      context.t('onboarding.advanced'),
      style: TextStyle(fontSize: Fs.xs, color: p.ink3),
    );
    final chevron = AnimatedRotation(
      turns: _showAdvanced ? 0.5 : 0,
      duration: Motion.dur2,
      curve: Motion.easeOut,
      child: LexIcon(Ic.chevronDown, size: 14, color: p.ink3),
    );
    // Not [TapTarget]: that wraps its child in a 44×44 box, which is right for
    // an icon-only button and wrong for a text row — the label would be
    // squeezed to 44dp and overflow. A minimum height gives the same finger
    // target without constraining the width.
    final minHeight = context.isTouch ? Layout.tap : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  label,
                  const SizedBox(width: Sp.x1),
                  chevron,
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: Motion.dur2,
          curve: Motion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: _showAdvanced
              ? Padding(
                  padding: const EdgeInsets.only(top: Sp.x3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      LexField(
                        label: context.t('settings.syncServer'),
                        hint: context.t('settings.syncServerHint'),
                        child: LexInput(
                          controller: _server,
                          placeholder: kDefaultServer,
                          onChanged: _vm.setServer,
                        ),
                      ),
                      if (_vm.isSupabase) ...<Widget>[
                        const SizedBox(height: Sp.x4),
                        LexField(
                          label: context.t('settings.syncKey'),
                          hint: context.t('settings.syncKeyHint'),
                          child: LexInput(
                            controller: _key,
                            onChanged: _vm.setAnonKey,
                          ),
                        ),
                      ],
                      const SizedBox(height: Sp.x3),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: LexButton(
                          label: context.t('settings.syncTest'),
                          kind: BtnKind.ghost,
                          size: BtnSize.sm,
                          onPressed: _vm.busy ? null : _vm.testConnection,
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }

  /// One line under the form saying what the server said.
  ///
  /// Same recipe as the settings page's inline error block — `dangerSoft`
  /// behind `danger` ink — rather than `onDanger`, which is the near-white that
  /// sits on a *filled* danger button and would be invisible here.
  Widget _errorNotice(Palette p, SyncError error) {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: p.dangerSoft,
        borderRadius: R.borderSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LexIcon(Ic.alert, size: 16, color: p.danger),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              _vm.errorLabel(error),
              style: TextStyle(
                fontSize: Fs.sm,
                height: Lh.body,
                color: p.ink2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _orRule(Palette p) {
    final line = Container(height: 1, color: p.line);
    return Row(
      children: <Widget>[
        Expanded(child: line),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
          child: Text(
            context.t('onboarding.or'),
            style: TextStyle(fontSize: Fs.xs, color: p.ink4),
          ),
        ),
        Expanded(child: line),
      ],
    );
  }

  Widget _localCard(Palette p) {
    return Container(
      padding: const EdgeInsets.all(Sp.x5),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            context.t('onboarding.localTitle'),
            style: TextStyle(
              fontSize: Fs.md,
              fontWeight: FontWeight.w600,
              height: Lh.tight,
              color: p.ink,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
            context.t('onboarding.localBody'),
            style: TextStyle(
              fontSize: Fs.sm,
              height: Lh.body,
              color: p.ink3,
            ),
          ),
          const SizedBox(height: Sp.x4),
          LexButton(
            label: context.t('onboarding.localAction'),
            kind: BtnKind.normal,
            block: true,
            onPressed: _vm.busy ? null : _vm.useLocal,
          ),
        ],
      ),
    );
  }
}

/// The stone panel: the mark, the name, and the one line that describes what
/// the app is for.
class _Frame extends StatelessWidget {
  const _Frame({required this.p, this.band = false});

  final Palette p;

  /// True on narrow screens, where this is a band across the top instead of a
  /// full-height panel.
  final bool band;

  @override
  Widget build(BuildContext context) {
    final name = Text(
      context.t('common.appName'),
      style: TextStyle(
        fontFamily: Fonts.display,
        fontSize: band ? Fs.lg : Fs.xl,
        height: Lh.tight,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.01,
        color: p.frameInk,
      ),
    );
    final tagline = Text(
      context.t('common.appTagline'),
      style: TextStyle(
        fontSize: Fs.sm,
        height: Lh.snug,
        color: p.frameInk3,
      ),
    );

    if (band) {
      return Container(
        color: p.frame,
        padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x6, Sp.x4),
        child: Row(
          children: <Widget>[
            const LexMark(size: 26),
            const SizedBox(width: Sp.x3),
            Expanded(child: name),
          ],
        ),
      );
    }

    return Container(
      color: p.frame,
      padding: const EdgeInsets.all(Sp.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const LexMark(size: 44),
          const SizedBox(height: Sp.x6),
          name,
          const SizedBox(height: Sp.x3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: tagline,
          ),
        ],
      ),
    );
  }
}

/// The paper panel. Same treatment as the shell's page surface: flat fill, no
/// border, because the stone beside it is what defines the edge.
class _Paper extends StatelessWidget {
  const _Paper({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ColoredBox(color: p.bg, child: child);
  }
}
