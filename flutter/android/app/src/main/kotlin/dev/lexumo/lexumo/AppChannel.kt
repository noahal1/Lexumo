package dev.lexumo.lexumo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The update channel: everything in-app self-upgrading needs from Android.
 *
 * A second channel rather than more methods on `dev.lexumo.lexumo/file`: that
 * one is about writing a user-visible backup file and carries its own pending
 * `Result` across an Activity-result boundary, while this one is stateless
 * question-answer calls. Merging them would put two unrelated lifetimes in one
 * handler and make either one harder to read.
 *
 * Four of the five methods exist because Android answers questions Flutter
 * cannot ask by itself — what version is installed, whether this app may install
 * packages at all, whether a downloaded APK is even signed by the same key as
 * the running app (see [verifySignature]), and where to send the user to grant
 * that permission ([openInstallSettings], which opens a settings screen and
 * comes back with nothing). Only [installApk] hands control to another app with
 * an outcome the user acts on.
 *
 * The Dart side lives in `lib/platform/app_installer.dart`; the flow there is:
 * download the APK, `verifySignature`, then `canInstall` /
 * `openInstallSettings` if needed, then `installApk`. The download lands in the
 * app's persistent directory, not this provider's exposed
 * `<cacheDir>/updates/`, so [installApk] stages a copy there itself.
 */
class AppChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> {
                try {
                    result.success(appInfo())
                } catch (e: Exception) {
                    // NameNotFoundException on our own package would mean the
                    // process cannot read the manifest it was launched from, but
                    // an error here must not look like an empty answer.
                    result.error("info_failed", e.message, null)
                }
            }
            "canInstall" -> result.success(canInstall())
            "openInstallSettings" -> result.success(openInstallSettings())
            "installApk" -> installApk(call, result)
            "verifySignature" -> verifySignature(call, result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- info ---

    /**
     * `{versionName, versionCode, buildNumber, packageName, isDebug, installer}`
     * for this very app.
     *
     * The version is read from the package manager rather than from a value
     * baked into the Dart code or `pubspec.yaml`: the updater has to compare
     * "what is running" with "what the server offers", and only the package
     * manager knows what the artifact actually says. A `--split-per-abi` build
     * also adds 1000 × ABI to the version code, so anything cached at compile
     * time would be wrong for split APKs.
     *
     * `installer` is the package name of whatever installed this app (Play
     * Store, `adb`, a file manager). It is informational — it tells the update
     * UI whether a store will deliver updates anyway — so a platform that
     * cannot answer is `null`, not an error.
     */
    private fun appInfo(): Map<String, Any?> {
        val packageManager = activity.packageManager
        val packageName = activity.packageName
        val info = packageManager.getPackageInfo(packageName, 0)

        // `versionCode` is a 32-bit int field on API < 28 and is deprecated from
        // 28 on in favour of `longVersionCode` (the old field clamps to
        // Integer.MAX_VALUE for codes above it). minSdk here is 24, so both
        // branches are reachable; the channel contract is an Int, so the long is
        // narrowed once, deliberately.
        @Suppress("DEPRECATION")
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode.toInt()
        } else {
            info.versionCode
        }

        // The key set is deliberately wider than the three the Dart side reads
        // today, because two different names for the same number is the one
        // place a channel contract realistically drifts:
        //
        //   · `versionCode` — the documented name (Android's own term).
        //   · `buildNumber` — the same value under Dart's `AppBuildInfo` field
        //     name. Both are sent so neither side has to rename the other's
        //     concept, and so an older Dart build reading `versionCode` keeps
        //     working. If only one were sent and the other side fell back to its
        //     `--dart-define` default, the build number would read 0 and the
        //     updater would offer the currently installed release forever.
        //   · `packageName` / `isDebug` — the update UI explains a refused
        //     install with them: a debug build cannot be installed over a
        //     release build (different certificates), and "this package is a
        //     debug build" is a sentence the user can act on, unlike a bare
        //     `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
        //   · `installer` — lets the UI say a store is already delivering
        //     updates, so the in-app prompt would be redundant.
        //
        // Extra map keys are safe over a MethodChannel: Dart picks the keys it
        // knows and ignores the rest, so this stays compatible in both
        // directions.
        return hashMapOf<String, Any?>(
            "versionName" to info.versionName,
            "versionCode" to versionCode,
            "buildNumber" to versionCode,
            "packageName" to packageName,
            "isDebug" to isDebuggable(),
            "installer" to installerPackage(packageManager, packageName),
        )
    }

    /**
     * Whether this process was built debuggable.
     *
     * `debuggable` is what the app can read about itself, and in every normal
     * build setup it is exactly what correlates with "signed by the debug key":
     * a debug build over a release build fails to install because their
     * certificates differ, and the update UI can only say that up front if it
     * knows which side it is on. Comparing certificates with ourselves would
     * always answer `true` and explain nothing.
     *
     * Read from `activity.applicationInfo` rather than through
     * `packageManager.getApplicationInfo(...)`: `Context.applicationInfo`
     * returns the same `ApplicationInfo` for the running process with no flags
     * argument and no deprecated overload, so there is nothing to suppress and
     * nothing that can throw.
     */
    private fun isDebuggable(): Boolean =
        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * The installer's package name, or `null` where Android will not say.
     *
     * `getInstallInfo` does not exist; API 30 replaced `getInstallerPackageName`
     * with `getInstallSourceInfo`, which also exposes the "initiating" package
     * and whether the install was initiated by the installer (Play, adb, a
     * sideload via a file manager). We take the plain installer name because it
     * is the one value both APIs agree on.
     */
    private fun installerPackage(packageManager: PackageManager, packageName: String): String? =
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                packageManager.getInstallSourceInfo(packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstallerPackageName(packageName)
            }
        } catch (e: Exception) {
            // NameNotFoundException / IllegalArgumentException: the platform
            // cannot attribute this install. That is an answer, not a failure.
            null
        }

    // --------------------------------------------------------- permission ---

    /**
     * Whether this app may open the package installer right now.
     *
     * API 26 introduced "install unknown apps" as a per-app permission that the
     * user grants in Settings; before that, sideloading was covered by the
     * global "Unknown sources" switch, so there was nothing to ask. Returning
     * `false` on API < 26 would send the caller to a settings page that does not
     * exist on that platform.
     */
    private fun canInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /**
     * Open the system page where the user allows this app to install packages.
     *
     * `ACTION_MANAGE_UNKNOWN_APP_SOURCES` with a `package:` data Uri opens the
     * per-app toggle directly. Without the Uri it opens the app list, which is
     * one more decision for the user and one more place to get lost.
     *
     * `false` means "there is nothing to open here", which the caller should
     * treat as a dead end it can explain, never as a crash.
     *
     * `resolveActivity` is trusted only below API 30. From Android 11 on,
     * package-visibility filtering can hide a Settings activity from a plain
     * implicit query, so a `null` there is not proof that nothing handles the
     * intent — acting on it would report "no such screen" on a device that has
     * it. From 30 on the `ActivityNotFoundException` catch is the authoritative
     * test, and it is a real test: it means the start was actually attempted.
     */
    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false

        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${activity.packageName}"),
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R &&
            intent.resolveActivity(activity.packageManager) == null
        ) {
            return false
        }

        return try {
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            // SecurityException: an OEM ROM that exports the activity but guards
            // it. Same answer as "no handler" — there is nothing to show.
            false
        }
    }

    // ------------------------------------------------------------ install ---

    /**
     * Hand a downloaded APK to the package installer.
     *
     * Returns one of three strings instead of `Boolean` + a separate
     * "needsPermission" query. The three outcomes are not independent facts —
     * they are the three things the caller can do next (say "opened", send the
     * user to settings, or say "this device cannot install it"), and a caller
     * that has to test two booleans to find out which of three it got is a
     * caller that will get the order wrong. One string also makes an unexpected
     * value visible as `null` on the Dart side rather than as a silent `false`.
     *
     * There is no result to await: a successful install kills this process, so
     * `"launched"` only means the installer UI is up. Anything else the caller
     * wants to know (did it work?) is answered by the next app start reading
     * `info`.
     *
     * The APK must travel as a `content://` Uri from our [FileProvider]. Passing
     * a `file://` path was the pre-API-24 approach and throws
     * `FileUriExposedException` from 24 on; there is no flag or manifest entry
     * that makes it legal again, and making the cache directory world-readable
     * is not possible either.
     */
    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        // `mimeType` is optional and defaults to the package-archive type: it is
        // the only type this method can ever usefully launch, so requiring the
        // caller to repeat it adds a failure mode (a missing argument answered
        // with `result.error`, which the Dart side reports as "installer
        // unavailable") in exchange for no flexibility. A caller that knows
        // better — an OEM installer wanting a vendor type — can still pass one.
        val mimeType = call.argument<String>("mimeType") ?: MIME_TYPE_APK
        if (path == null) {
            result.error("bad_args", "installApk requires 'path'.", null)
            return
        }

        // Checked before the file is touched: without the permission the
        // installer would open and then refuse, which reads to the user as a
        // broken APK rather than a missing permission.
        if (!canInstall()) {
            result.success(RESULT_NEEDS_PERMISSION)
            return
        }

        val apk = File(path)
        if (!apk.isFile) {
            result.success(RESULT_NO_HANDLER)
            return
        }

        // The common case: the caller already staged the download under
        // `<cacheDir>/updates/`, which is the one directory `file_paths.xml`
        // exposes, so the Uri can be minted for the file in place.
        val directUri = providerUriOrNull(apk)
        if (directUri != null) {
            launchInstaller(directUri, mimeType, result)
            return
        }

        // The file lives somewhere the provider may not lend out. Historically
        // that could only be a caller mistake, but the Dart side stages its
        // download in the app's *persistent* directory (`AppDir` derives it from
        // `TMPDIR` by dropping the `/cache` segment), so this is the normal path
        // today and not an error.
        //
        // The alternative — adding `<files-path>` to `file_paths.xml` — was
        // rejected: it would expose the whole data directory that holds
        // `lexumo.json` and the sync database to anything holding a grant, and
        // the brief for this file says the exposed surface must stay at
        // `<cacheDir>/updates/`. Copying the APK into that one directory keeps
        // the provider's surface exactly as declared and still installs, at the
        // cost of one temporary duplicate (~50 MB) that the sweep below clears.
        //
        // Off the platform thread: this handler runs on the main thread, and a
        // multi-megabyte copy there is a frozen UI right before the installer
        // takes over the screen — on a slow device, long enough to look like an
        // ANR. `runOnUiThread` posts the answer back, which a
        // `MethodChannel.Result` requires: answering from a worker thread is
        // undefined behaviour in the embedding, not just untidy.
        Thread {
            val staged = stageInCache(apk)
            activity.runOnUiThread {
                val stagedUri = staged?.let { providerUriOrNull(it) }
                if (stagedUri == null) {
                    // Copy failed, or the directory it landed in is somehow not
                    // the exposed one. Nothing was launched, which is exactly
                    // what `noHandler` promises.
                    result.success(RESULT_NO_HANDLER)
                } else {
                    launchInstaller(stagedUri, mimeType, result)
                }
            }
        }.start()
    }

    /** The `content://` Uri for [file], or null when no declared root covers it. */
    private fun providerUriOrNull(file: File): Uri? =
        try {
            FileProvider.getUriForFile(activity, FILE_PROVIDER_AUTHORITY, file)
        } catch (e: IllegalArgumentException) {
            // `getUriForFile` refuses paths outside the roots in
            // `res/xml/file_paths.xml` — correct behaviour, answered by the
            // caller deciding whether to stage a copy.
            null
        }

    /**
     * Build the install intent and start the installer.
     *
     * Only ever called on the platform thread, from either the fast path or the
     * post-back after staging.
     */
    private fun launchInstaller(uri: Uri, mimeType: String, result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            // The installer runs in another process and has no business reading
            // our private cache; without this flag it gets a SecurityException
            // on open and reports a corrupt package instead.
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // Harmless from an Activity and required if anything ever calls this
            // from a non-Activity context.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            activity.startActivity(intent)
            result.success(RESULT_LAUNCHED)
        } catch (e: ActivityNotFoundException) {
            // e.g. a form factor with no package installer, or a device whose
            // installer was disabled. No `resolveActivity` pre-check here: on
            // API 30+ it can return null for a handler that exists (package
            // visibility), and this catch already answers the same question
            // without that false negative.
            result.success(RESULT_NO_HANDLER)
        } catch (e: Exception) {
            // SecurityException from an OEM-guarded installer: still "nothing
            // was launched", which is what `noHandler` promises.
            result.success(RESULT_NO_HANDLER)
        }
    }

    /**
     * Copy [apk] into `<cacheDir>/updates/` — the directory the provider is
     * allowed to lend out — and return the copy.
     *
     * Runs on a worker thread; returns null on any failure rather than a
     * half-written file, because a truncated APK reaches the installer as
     * "package appears to be corrupt", a message that sends the user to the
     * wrong conclusion entirely.
     *
     * A copy already sitting in that directory is reused only when it is at
     * least as new as the source and has the same length: tapping "install"
     * twice should not move the file twice, but a re-downloaded release that
     * happens to keep the same byte count must not be silently replaced by the
     * stale copy (or vice versa) — the installer would then verify the wrong
     * file's signature.
     */
    private fun stageInCache(apk: File): File? {
        val directory = File(activity.cacheDir, PROVIDER_CACHE_SUBDIR)
        if (!directory.isDirectory && !directory.mkdirs()) return null
        sweepStaleStagedApks(directory)

        val target = File(directory, apk.name)
        if (target.isFile &&
            target.length() == apk.length() &&
            target.lastModified() >= apk.lastModified()
        ) {
            return target
        }

        return try {
            apk.copyTo(target, overwrite = true)
            target
        } catch (e: Exception) {
            // IOException / SecurityException: no space, or a read the platform
            // refuses. Leave nothing behind that could look installable.
            target.delete()
            null
        }
    }

    /**
     * Delete staged APKs left by earlier attempts.
     *
     * Only files older than [STAGED_APK_TTL_MS] are touched. Deleting
     * everything except the file just copied would be simpler, but two taps in
     * quick succession would then race: the second sweep would unlink the file
     * the first install intent is already handing to the installer, and the
     * install would fail as a corrupt package. A generous age cutoff has no such
     * race and still keeps the cache bounded — this directory only ever holds
     * what the updater itself put there.
     */
    private fun sweepStaleStagedApks(directory: File) {
        val cutoff = System.currentTimeMillis() - STAGED_APK_TTL_MS
        directory.listFiles()?.forEach { file ->
            if (file.isFile && file.lastModified() < cutoff) file.delete()
        }
    }

    // ----------------------------------------------------------- signature ---

    /**
     * Whether the APK whose path arrives as `path` is signed by exactly the
     * certificate set this running app is signed with.
     *
     * This has to happen *before* the installer is opened, because the installer
     * gives the user nothing to act on: a mismatched signature fails as
     * `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the only thing on screen is a
     * system sentence about an incompatible update. The user cannot tell whether
     * to uninstall and lose their data, wait for a different build, or give up.
     * Asking first turns that into an explanation — "this build was signed by a
     * different key" — while the app is still alive to explain it.
     *
     * The comparison is order-sensitive and length-first: `getPackageArchiveInfo`
     * on a v2/v3-signed APK can report more than one signer (a multi-signer APK,
     * or an APK whose v3 block additionally carries the rotation proof), and
     * `apkContentsSigners` is what the package installer itself compares. Set
     * equality would accept a different set that happens to have the same size;
     * pairwise comparison is the same rule the installer applies, so this
     * predicts its verdict instead of approximating it.
     *
     * A missing file, an unparsable APK, or a null `signingInfo` all answer
     * `false`: the caller must not open the installer on the strength of a
     * "could not tell".
     */
    private fun verifySignature(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "verifySignature requires 'path'.", null)
            return
        }
        result.success(archiveSignedWithOwnKey(path))
    }

    private fun archiveSignedWithOwnKey(apkPath: String): Boolean {
        if (!File(apkPath).isFile) return false
        val packageManager = activity.packageManager
        return try {
            val archive = archiveCertificateDigests(packageManager, apkPath) ?: return false
            val installed = installedCertificateDigests(packageManager) ?: return false
            if (archive.size != installed.size) return false
            archive.indices.all { archive[it] == installed[it] }
        } catch (e: Exception) {
            // NameNotFoundException, or a parsing failure surfaced as a runtime
            // exception by an OEM package manager.
            false
        }
    }

    /**
     * The signer digests of an APK file, in the order the package manager
     * reports them.
     *
     * API 28 replaced `GET_SIGNATURES` with `GET_SIGNING_CERTIFICATES`: the old
     * flag only exposes the v1 (JAR) signatures, so a modern APK signed with the
     * v2/v3 scheme only reads back as "no signatures" through it. Both branches
     * must exist because minSdk is 24.
     */
    @Suppress("DEPRECATION")
    private fun archiveCertificateDigests(
        packageManager: PackageManager,
        apkPath: String,
    ): List<String>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageArchiveInfo(
                apkPath,
                PackageManager.GET_SIGNING_CERTIFICATES,
            ) ?: return null
            return info.signingInfo?.apkContentsSigners?.map { it.toCharsString() }
        }
        val info = packageManager.getPackageArchiveInfo(
            apkPath,
            PackageManager.GET_SIGNATURES,
        ) ?: return null
        return info.signatures?.map { it.toCharsString() }
    }

    /** The same, for the app that is currently running. */
    @Suppress("DEPRECATION")
    private fun installedCertificateDigests(
        packageManager: PackageManager,
    ): List<String>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageInfo(
                activity.packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
            return info.signingInfo?.apkContentsSigners?.map { it.toCharsString() }
        }
        val info = packageManager.getPackageInfo(
            activity.packageName,
            PackageManager.GET_SIGNATURES,
        )
        return info.signatures?.map { it.toCharsString() }
    }

    companion object {
        const val CHANNEL = "dev.lexumo.lexumo/app"

        /**
         * Must match `android:authorities` in the manifest and nothing else in
         * the project may reuse it: two providers with one authority make the
         * second app fail to install.
         */
        private const val FILE_PROVIDER_AUTHORITY = "dev.lexumo.lexumo.fileprovider"

        private const val RESULT_LAUNCHED = "launched"
        private const val RESULT_NEEDS_PERMISSION = "needsPermission"
        private const val RESULT_NO_HANDLER = "noHandler"

        /** The type Android's own package installer registers for APK files. */
        private const val MIME_TYPE_APK = "application/vnd.android.package-archive"

        /** Must match the `<cache-path path="updates/">` entry in `file_paths.xml`. */
        private const val PROVIDER_CACHE_SUBDIR = "updates"

        /**
         * How long a staged copy of an APK is kept before the next install
         * sweeps it. Long enough that two instalments of the same update cannot
         * delete each other's file mid-install, short enough that an abandoned
         * update does not sit in the cache forever.
         */
        private const val STAGED_APK_TTL_MS = 10 * 60 * 1000L
    }
}
