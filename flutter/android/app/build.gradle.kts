import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
// ---------------------------------------------------------------------------
//
// The keystore is NOT in this repository and must never be. `android/key.properties`
// (git-ignored, see `android/.gitignore`) names it and carries its passwords:
//
//     storeFile=upload-keystore.jks
//     storePassword=…
//     keyAlias=upload
//     keyPassword=…
//
// `storeFile` is resolved against `android/`, so the relative form above means
// `flutter/android/upload-keystore.jks`; an absolute path works too. Use forward
// slashes even on Windows — a `.properties` file treats `\` as an escape
// character, so `C:\Users\…` silently loses its separators when parsed.
//
// Why this matters beyond tidiness: an APK signed with the debug key is signed
// with a key that is generated per machine (and per CI run, when `~/.android`
// is not cached). Android refuses to install an update whose signature differs
// from the installed one — `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — so a release
// built on a developer's laptop and a release built on CI are two different
// apps that can never upgrade each other, and a user who installed one can only
// move to another by uninstalling and losing their data. A stable, backed-up
// release key is therefore a hard requirement for in-app self-update to work at
// all, not a "professional polish" item.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.isFile
val keystoreProperties = Properties().apply {
    if (hasKeystoreProperties) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "dev.lexumo.lexumo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.lexumo.lexumo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                // A present-but-incomplete `key.properties` is an error, not a
                // reason to fall back: the file's existence says someone meant to
                // publish, and quietly signing with the debug key would produce a
                // release artifact that passes every local check and still cannot
                // update a single installed user. Failing here — at configuration
                // time, on any task — surfaces the mistake the first time someone
                // builds, instead of at upload time.
                val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
                    .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
                if (missing.isNotEmpty()) {
                    throw GradleException(
                        "android/key.properties exists but is missing: ${missing.joinToString()}. " +
                            "Fill in all four keys, or delete the file to build with the debug key.",
                    )
                }

                // `rootProject` here is `flutter/android/`, so a relative
                // `storeFile` resolves next to `key.properties` — the arrangement
                // the instructions describe. `rootProject.file` also accepts an
                // absolute path unchanged, which is what CI needs when the
                // keystore is mounted from a secret store rather than copied into
                // the workspace.
                //
                // `orEmpty()` rather than `!!`: the check above already proved the
                // value is present, but a `!!` here would turn a future edit to
                // that check into an opaque NullPointerException instead of the
                // "keystore not found" message below.
                val keystoreFile = rootProject.file(
                    keystoreProperties.getProperty("storeFile").orEmpty().trim(),
                )
                if (!keystoreFile.isFile) {
                    throw GradleException(
                        "Release keystore not found: ${keystoreFile.path} " +
                            "(resolved from android/key.properties `storeFile`). " +
                            "Note that a .properties value treats `\\` as an escape; use forward slashes.",
                    )
                }

                storeFile = keystoreFile
                // Passwords are taken verbatim: a trailing space can be part of a
                // password, and the failure mode of trimming it would be an
                // obscure "keystore was tampered with, or password was incorrect".
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias").orEmpty().trim()
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Warn, not fail. Without `key.properties` there is no key this
                // build could use, and refusing to compile would break the two
                // things that must keep working on a machine with no publishing
                // credentials: `flutter run --release` (used to check release-only
                // behaviour such as tree shaking) and a clean `flutter build apk`
                // for anyone just cloning the repository. The default Flutter
                // template makes the same call, and a hard error here would push
                // people to weaken the check instead of reading it.
                //
                // The consequence is stated precisely, because it is the part
                // that gets forgotten: this artifact is signed by a machine-local
                // debug key. It installs fine, but a later build made on another
                // machine (or CI) has a different key, so it cannot be installed
                // over this one — and every existing user would have to uninstall
                // first. It must never reach a store or a user download.
                logger.warn(
                    """
                    |
                    |============================================================
                    |  RELEASE BUILD IS USING THE DEBUG SIGNING KEY
                    |------------------------------------------------------------
                    |  android/key.properties was not found, so this APK cannot
                    |  be published or distributed:
                    |    · The debug key differs between machines and CI runs.
                    |    · Android rejects an update with a different signature,
                    |      so anyone who installs this build can never upgrade
                    |      to a properly signed one without uninstalling and
                    |      losing their app data.
                    |
                    |  For local checks and `flutter run --release` this is fine.
                    |  To produce a publishable build, generate a keystore and
                    |  create android/key.properties (storeFile, storePassword,
                    |  keyAlias, keyPassword) — the file is git-ignored.
                    |============================================================
                    """.trimMargin(),
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
