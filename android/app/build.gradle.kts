plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val allAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val targetAbi = System.getenv("TOOLBOX_ABI")?.takeIf { it.isNotEmpty() } ?: "arm64-v8a"

android {
    namespace = "com.mustafa.toolbox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.mustafa.toolbox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: Ogg/Opus decoding (WhatsApp voice notes) and MediaStore downloads.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 64-bit phones only: keeps the APK small (Python, FFmpeg and whisper are native).
        // CI builds an x86_64 variant (TOOLBOX_ABI) to run the self-test on an emulator.
        ndk {
            abiFilters += listOf(targetAbi)
        }

        // Self-test entry point (see MainActivity.runSelfTest); only enabled in CI test builds.
        buildConfigField("boolean", "SELF_TEST", (System.getenv("TOOLBOX_SELFTEST") == "1").toString())
    }

    buildFeatures {
        buildConfig = true
    }

    // Fixed key so new builds install as updates over old ones. CI writes it from the
    // ANDROID_KEYSTORE_B64 secret; without it, builds fall back to the debug key.
    val releaseKeystore = file("release.keystore")
    signingConfigs {
        create("release") {
            if (releaseKeystore.exists()) {
                storeFile = releaseKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.takeIf { it.isNotEmpty() } ?: "toolbox"
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")?.takeIf { it.isNotEmpty() } ?: "toolbox"
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.takeIf { it.isNotEmpty() } ?: "toolbox"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    // youtubedl-android runs Python/FFmpeg binaries straight from the native lib folder.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Library AARs ship every ABI; we only build Flutter + whisper for arm64,
            // so drop the rest (saves ~130 MB and avoids half-working installs).
            excludes += allAbis.filter { it != targetAbi }.map { "lib/$it/**" }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore.exists()) "release" else "debug")
            // Flutter turns on R8 for release builds; keep the native-library glue intact.
            proguardFiles("proguard-rules.pro")
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
    implementation("androidx.core:core-ktx:1.13.1")
    // yt-dlp with embedded Python + QuickJS, and FFmpeg for HD merging / MP3.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    // On-device translation (offline after the language packs download once).
    implementation("com.google.mlkit:translate:17.0.3")
}
