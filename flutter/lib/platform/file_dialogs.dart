/// Saving and picking files, behind one interface the UI can fake.
///
/// Three platform paths, and the reason each is shaped the way it is:
///
///   · **Android — saving needs its own channel.** `file_selector` opens files
///     there but cannot choose a save location (its README's feature table says
///     so outright), and scoped storage offers no filesystem path to write to.
///     `MainActivity.kt` implements `ACTION_CREATE_DOCUMENT` for exactly this.
///
///   · **Android — opening needs no permission.** `file_selector` goes through
///     the Storage Access Framework, so the picked file's bytes are readable
///     without `READ_EXTERNAL_STORAGE`. That is why no storage permission
///     appears in the manifest.
///
///   · **Desktop — plain paths.** `getSaveLocation` returns a real path and
///     `dart:io` writes it. No channel needed.
///
/// Everything here returns `null`/`false` when the user cancels. A cancel is
/// not an error and must never surface as a toast.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// File types the import button accepts.
///
/// Declared as a group rather than per-platform lists because `XTypeGroup`
/// picks whichever of extensions/mimeTypes the platform understands: Windows
/// and Linux use extensions, Android needs the mime types.
const XTypeGroup _importableFiles = XTypeGroup(
  label: 'Lexumo backup, CSV or Anki TXT',
  extensions: ['json', 'csv', 'txt'],
  mimeTypes: ['application/json', 'text/csv', 'text/plain'],
);

/// What an import picked. [name] is only for display — the preview dialog
/// shows it under the title.
class PickedFile {
  const PickedFile({required this.name, required this.text});

  final String name;
  final String text;
}

/// The instance the UI talks to.
///
/// A mutable top-level rather than an injected scope because there is exactly
/// one implementation in production and widget tests replace it wholesale;
/// threading a scope through five pages for a settings-only concern would be
/// more machinery than the problem deserves. Tests set it in `setUp` and
/// restore it in `tearDown`.
FileDialogs fileDialogs = const PlatformFileDialogs();

/// The operations the settings page needs. Abstract so widget tests can run
/// without touching a real dialog.
abstract class FileDialogs {
  /// Open a file picker. `null` means the user cancelled.
  Future<PickedFile?> pickTextFile();

  /// Save [content] under [suggestedName]. Returns `false` when the user
  /// cancelled, `true` once the bytes are on disk.
  Future<bool> saveTextFile({
    required String suggestedName,
    required String content,
    required String mimeType,
  });
}

/// The real implementation, dispatching to whichever path the platform has.
class PlatformFileDialogs implements FileDialogs {
  const PlatformFileDialogs();

  static const MethodChannel _androidChannel =
      MethodChannel('dev.lexumo.lexumo/file');

  @override
  Future<PickedFile?> pickTextFile() async {
    final XFile? file = await openFile(acceptedTypeGroups: [_importableFiles]);
    if (file == null) return null;
    return PickedFile(name: file.name, text: await file.readAsString());
  }

  @override
  Future<bool> saveTextFile({
    required String suggestedName,
    required String content,
    required String mimeType,
  }) async {
    if (Platform.isAndroid) {
      // The channel writes the bytes itself: on Android the destination is a
      // content Uri, and `dart:io` cannot open one.
      final bool? saved = await _androidChannel.invokeMethod<bool>(
        'saveTextFile',
        <String, String>{
          'fileName': suggestedName,
          'mimeType': mimeType,
          'content': content,
        },
      );
      return saved ?? false;
    }

    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(label: suggestedName, extensions: [_extensionOf(suggestedName)]),
      ],
    );
    if (location == null) return false;

    // Write through the file system, not `XFile.saveTo`: the latter is not
    // implemented on every desktop platform this app targets.
    await File(location.path).writeAsString(content);
    return true;
  }

  /// The extension of [name] without the dot, for the save dialog's filter.
  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? 'txt' : name.substring(dot + 1);
  }
}

/// Stands in for the dialogs in widget tests.
///
/// [onPick] and [onSave] are what the test supplies; both default to
/// "cancelled", which is also what a user who closes the dialog produces.
class FakeFileDialogs implements FileDialogs {
  FakeFileDialogs({this.onPick, this.onSave});

  final Future<PickedFile?> Function()? onPick;
  final Future<bool> Function(String suggestedName, String content)? onSave;

  /// Everything [saveTextFile] was asked to write, in order — a test asserts
  /// on the content without a filesystem.
  final List<SavedFile> saved = <SavedFile>[];

  @override
  Future<PickedFile?> pickTextFile() async => onPick == null ? null : onPick!();

  @override
  Future<bool> saveTextFile({
    required String suggestedName,
    required String content,
    required String mimeType,
  }) async {
    saved.add(SavedFile(name: suggestedName, content: content, mimeType: mimeType));
    return onSave == null ? true : onSave!(suggestedName, content);
  }
}

/// One write a [FakeFileDialogs] observed.
@immutable
class SavedFile {
  const SavedFile({
    required this.name,
    required this.content,
    required this.mimeType,
  });

  final String name;
  final String content;
  final String mimeType;
}
