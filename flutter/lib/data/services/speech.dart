/// One call that both says a word and counts the listen.
///
/// Every page that offers a 发音 control wants the same three things: speak the
/// term in the word's own language, at the user's rate and voice, and record
/// that it was played. The web build repeated that pair inline in
/// `WordsPage.tsx:222` and `FlashcardsPage.tsx:253`; here it is one function so
/// the two cannot drift, and so a page never has to reach for the settings.
///
/// It lives outside the pages because the settings lookup is the only thing
/// that makes it a page concern — everything else is the speech service plus
/// one store write.
library;

import 'package:flutter/widgets.dart';

import '../../app/scope.dart';
import '../../domain/models/types.dart';
import 'tts.dart';

/// Speaks [word] and bumps its listen count.
///
/// Returns a future that settles when the utterance ends (or immediately when
/// speech is unavailable), which the flashcard auto-play uses to avoid
/// overlapping two clips.
Future<void> speakWord(
  BuildContext context,
  Word word, {
  VoidCallback? onEnd,
}) {
  final Settings settings = context.data.settings;
  // Counted even when the engine is silent: the user pressed 发音, and the
  // count is a usage tally rather than an audio diagnostic. The web build
  // bumped unconditionally for the same reason.
  context.store.bumpListen(word.id);
  return appSpeech.speak(
    word.term,
    lang: word.sourceLang,
    rate: settings.ttsRate,
    voiceURI: settings.ttsVoiceURI,
    onEnd: onEnd,
  );
}

/// Speaks [word] without touching the listen count.
///
/// Auto-play uses this: the web build's reveal effect called `speak` directly
/// and left `listenCount` alone, so a card that speaks itself does not inflate
/// the tally the user sees on the row. Only an explicit 发音 press counts.
Future<void> speakTerm(
  BuildContext context,
  Word word, {
  VoidCallback? onEnd,
}) {
  final Settings settings = context.data.settings;
  return appSpeech.speak(
    word.term,
    lang: word.sourceLang,
    rate: settings.ttsRate,
    voiceURI: settings.ttsVoiceURI,
    onEnd: onEnd,
  );
}

/// Whether a 发音 control should render at all.
///
/// A page asks this rather than reading [Speech.supported] so a test can swap
/// the singleton without every page knowing about [appSpeech].
bool get speechAvailable => appSpeech.supported;
