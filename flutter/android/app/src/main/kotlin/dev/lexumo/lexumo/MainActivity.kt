package dev.lexumo.lexumo

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app's Activity. It owns two MethodChannels, one per concern:
 *
 *   · `dev.lexumo.lexumo/file` ([CHANNEL]) — the save dialog described below.
 *   · `dev.lexumo.lexumo/app` ([AppChannel.CHANNEL]) — in-app self-update:
 *     the installed version, the "install unknown apps" permission, and
 *     handing a downloaded APK to the package installer.
 *
 * They are separate channels with separate handlers because their lifetimes do
 * not match: the save flow holds a `Result` open across an Activity-result
 * boundary, while every update call is a request/response pair that keeps
 * nothing. One handler for both would make the stateless half carry the
 * busy/state machine the stateful half needs — and it would put two unrelated
 * reasons for a dropped `Result` in one place.
 *
 * ## `dev.lexumo.lexumo/file` — the one file operation `file_selector` cannot do
 *
 * `file_selector` opens files on Android, but its own feature table lists
 * "Choose a save location" as unsupported there — and on Android there is no
 * filesystem path to ask for anyway: scoped storage means the app writes
 * through a content `Uri`. `ACTION_CREATE_DOCUMENT` is the platform's answer
 * and needs a few lines of Activity code.
 *
 * The alternatives were worse:
 *   · `share_plus` — 37 transitive dependencies and a sharing UI in place of a
 *     save dialog;
 *   · `path_provider` — writes into app-private storage, producing a file the
 *     user cannot find with a file manager, which defeats the purpose of a
 *     backup.
 *
 * The content is passed in with the request rather than written afterwards, so
 * no payload has to survive across the Activity-result boundary.
 *
 * The Dart side lives in `lib/platform/file_dialogs.dart` (save) and
 * `lib/platform/app_installer.dart` (the update channel).
 */
class MainActivity : FlutterActivity() {
    private var pendingSave: MethodChannel.Result? = null
    private var pendingContent: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Stateless update channel. `this` is passed as the Activity so the
        // install intent starts from a real Activity context and the settings
        // intent carries our package name.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AppChannel.CHANNEL)
            .setMethodCallHandler(AppChannel(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveTextFile" -> {
                        if (pendingSave != null) {
                            // A double tap must not orphan the first Result.
                            result.error("busy", "A save dialog is already open.", null)
                            return@setMethodCallHandler
                        }
                        val name = call.argument<String>("fileName") ?: "export.json"
                        val mime = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        pendingContent = call.argument<String>("content") ?: ""
                        pendingSave = result
                        startCreateDocument(name, mime)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startCreateDocument(fileName: String, mimeType: String) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_SAVE)
        } catch (e: Exception) {
            failPending("no_picker", e.message)
        }
    }

    @Deprecated("The embedding v2 Activity still routes results through here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE) return

        val pending = pendingSave ?: return
        val content = pendingContent ?: ""
        pendingSave = null
        pendingContent = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // Cancelling is a normal outcome, not an error.
            pending.success(false)
            return
        }

        try {
            contentResolver.openOutputStream(uri, "wt")?.use { stream ->
                stream.write(content.toByteArray(Charsets.UTF_8))
                stream.flush()
            } ?: run {
                pending.success(false)
                return
            }
            pending.success(true)
        } catch (e: Exception) {
            pending.error("write_failed", e.message, null)
        }
    }

    private fun failPending(code: String, message: String?) {
        val pending = pendingSave
        pendingSave = null
        pendingContent = null
        pending?.error(code, message, null)
    }

    companion object {
        private const val CHANNEL = "dev.lexumo.lexumo/file"
        private const val REQUEST_SAVE = 0x4C58
    }
}
