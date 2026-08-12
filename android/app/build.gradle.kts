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
    }

    buildTypes {
        release {
            // Signed with the debug key: this is a personal, sideloaded /
            // TestFlight app that is never published, so there is no upload key.
            signingConfig = signingConfigs.getByName("debug")

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
