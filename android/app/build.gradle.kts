import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.personal.aibit.ai_bit"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.personal.aibit.ai_bit"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The launcher label carries the version ("AI BIT 2.17.0") so the
        // installed build is identifiable at a glance. In CI, versionName
        // comes from the tag via --build-name; a local build shows the
        // pubspec's placeholder 1.0.0, which is fine — locals are never
        // shipped.
        manifestPlaceholders["appName"] = "AI BIT " + flutter.versionName
    }

    // ONE permanent signing key for every release.
    //
    // Releases used to be signed with the CI runner's debug key, which is
    // generated fresh on every run — so each APK had a different signature
    // and Android refused to install any of them over the last ("App not
    // installed"). The only way through was uninstalling, which erased the
    // phone's history, playlists and downloads, and made the forced-update
    // screen a dead end. `android/key.properties` (gitignored) names the
    // keystore; CI writes it from repository secrets, and a machine without
    // it falls back to the debug key so it can still build for itself.
    // LOSING THIS KEY MEANS EVERY PHONE MUST UNINSTALL AGAIN. Copies: this
    // PC's ~/.android/aibit-release.jks, D:/AI BIT signing backup/, and the
    // ANDROID_KEYSTORE_B64 secret (write-only - it cannot be read back).
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    val hasReleaseKey = keyProps.getProperty("storeFile")?.let { file(it).exists() } == true
    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasReleaseKey) "release" else "debug",
            )

            // R8 off, deliberately.
            //
            // The release build crashed on launch on a real device with
            // "NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl
            // .<init>": R8 stripped the no-arg constructor that WorkManager —
            // pulled in by the vendored better_player_plus for its cache and
            // image workers — creates by reflection at startup. iOS was
            // unaffected because R8 is Android-only, which is why that platform
            // always worked while Android died before drawing a frame.
            //
            // Shrinking and obfuscation earn nothing on an app that is
            // sideloaded and never shipped to a store, and every plugin that
            // instantiates something by reflection is one keep-rule away from
            // the same crash. Turning R8 off removes the whole category.
            isMinifyEnabled = false
            isShrinkResources = false
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
