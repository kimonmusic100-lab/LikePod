plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.likepod.likepod"
    compileSdk = 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.likepod.likepod"
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
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // Flutter's Gradle plugin also turns these on for release.
            // Kept here so a later plugin change cannot ship an unshrunk APK.
            isMinifyEnabled = true
            isShrinkResources = true
            isJniDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            ndk {
                debugSymbolLevel = "NONE"
            }
            vcsInfo {
                include = false
            }
        }
    }

    packaging {
        jniLibs {
            // Compress libflutter.so / libapp.so inside the APK. resources.arsc
            // stays stored (aapt default) so install does not reject the package.
            useLegacyPackaging = true
            // abiFilters does not cover Flutter plugin native assets.
            excludes += setOf(
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
            )
        }
        exclude("DebugProbesKt.bin")
        exclude("kotlin-tooling-metadata.json")
        exclude("META-INF/version-control-info.textproto")
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
