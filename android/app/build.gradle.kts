import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties, which is NOT in git (see
// .gitignore). If it is absent the release build falls back to the debug key so
// the project still builds, but such an APK must never be distributed: Android
// refuses to install an update signed with a different key, and switching keys
// later forces an uninstall, losing the configured accounts.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasSigningConfig = keystorePropertiesFile.exists()
if (hasSigningConfig) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.rdvir.mailtree"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Both devices are arm64, and the APK is built for arm64 alone. The ML
    // Kit libraries bring x86 and 32-bit copies of their native code as
    // well, eight megabytes for nothing. Left out as the APK is packed:
    // abiFilters did not do it, Flutter's own build setting them again.
    packaging {
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications, which uses java.time on API
        // levels that predate it. Without this the release build fails at
        // checkReleaseAarMetadata rather than at compile time, so the error
        // does not say which dependency wants it.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Deliberately still says mailtree, after the app was renamed to
        // MyEmail. Android identifies an app by this string: changing it makes
        // a different app, which means an uninstall, the accounts lost again,
        // and an in-app updater that cannot bridge the gap. It is never shown
        // to anyone. The name people see is android:label in the manifest.
        applicationId = "com.rdvir.mailtree"
        // Android 8.0 at least: ML Kit's on-device AI (the summary, proofread
        // and rewrite) needs it. Both of Ron's devices are far past it.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasSigningConfig) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasSigningConfig) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "MailTree: android/key.properties not found. Signing release with the " +
                        "DEBUG key. This APK must not be distributed.",
                )
                signingConfigs.getByName("debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // The phone's own AI; see AiBridge. The GenAI ones run Gemini Nano
    // through AICore where the phone has it, and are thin; Smart Reply
    // brings its own small model.
    implementation("com.google.mlkit:genai-summarization:1.0.0-beta1")
    implementation("com.google.mlkit:genai-proofreading:1.0.0-beta1")
    implementation("com.google.mlkit:genai-rewriting:1.0.0-beta1")
    implementation("com.google.mlkit:smart-reply:17.0.4")
    // Dates and times in text: a meeting typed in a line, and the dates in a
    // message (EntityBridge). Its English model is fetched on first use.
    implementation("com.google.mlkit:entity-extraction:16.0.0-beta6")
}
