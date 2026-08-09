plugins {
    // No `kotlin-android` plugin: AGP 9.0+ ships built-in Kotlin support and
    // applying it is a hard error. See https://kotl.in/gradle/agp-built-in-kotlin
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.allthingsclaude.battery"
    // 37, not 36: current androidx (core 1.19, lifecycle 2.11, compose BOM
    // 2026.06) refuses to be consumed by anything compiled against less.
    // compileSdk only governs which APIs are *visible* — targetSdk below is what
    // opts into runtime behaviour, and that stays at 36 to match the device.
    // Compiling against 37 is also what will make MetricStyle reachable when
    // One UI 9 lands on the S24 Ultra.
    compileSdk = 37

    defaultConfig {
        // Suffixed to match the iOS convention (com.allthingsclaude.battery.ios).
        applicationId = "com.allthingsclaude.battery.android"
        // Live Updates need API 36; minSdk 31 keeps the app itself installable
        // further back and is also the Material You floor. The Now Bar card is
        // gated at runtime rather than by the manifest.
        minSdk = 31
        targetSdk = 36
        // Overridable from CI: versionName comes from the android-v* tag and
        // versionCode from the commit count, so there is no second place to
        // remember to bump. The literals are only the local-build defaults.
        versionCode = (findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = (findProperty("versionName") as String?) ?: "0.1.0"

        // Which repository this build checks for its own updates. The release
        // workflow passes `-PreleaseRepo=$GITHUB_REPOSITORY`, so an APK looks for
        // updates where it was published from — a fork's build finds the fork's
        // releases instead of polling upstream, comparing upstream's newest tag
        // against its own version and concluding it is up to date.
        //
        // Empty rather than a literal default: the canonical value is
        // ReleaseFeed.DEFAULT_REPO, and repeating it here would be a second place
        // for it to be wrong. Blank means "no override".
        buildConfigField(
            "String",
            "RELEASE_REPO",
            "\"${(findProperty("releaseRepo") as String?).orEmpty()}\"",
        )
    }

    signingConfigs {
        create("release") {
            // Present only in CI, where the workflow decodes the keystore into
            // the runner's temp dir and shreds it afterwards. Absent locally, in
            // which case the release build falls back to the debug key below —
            // which is what makes `assembleRelease` work on a dev machine
            // without anyone holding the real signing key.
            val path = System.getenv("BATTERY_KEYSTORE")
            if (path != null && file(path).exists()) {
                storeFile = file(path)
                storePassword = System.getenv("BATTERY_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("BATTERY_KEY_ALIAS")
                keyPassword = System.getenv("BATTERY_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // So a debug build installs beside a release-signed one instead of
            // being refused for a key mismatch. Without it, testing anything on a
            // device means uninstalling the real app and its Keystore-backed
            // credentials first. Sign-in still works here: the OAuth redirect is
            // loopback, not a scheme tied to the applicationId.
            applicationIdSuffix = ".debug"
        }
        release {
            // Left off deliberately for now: R8 would need keep rules for the
            // Glance/Compose runtime and for the reflective notification extras,
            // and a stripped release that silently stops promoting would be very
            // hard to diagnose against the Now Bar work still in flight.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release").takeIf {
                it.storeFile != null
            } ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
        // BuildConfig.DEBUG gates the diagnostics harness. AGP 9 no longer
        // generates BuildConfig unless asked.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.work.runtime.ktx)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.material3)
    implementation("androidx.compose.material:material-icons-core")
    implementation(libs.compose.ui.tooling.preview)

    implementation(libs.glance.appwidget)
    implementation(libs.glance.material3)
    debugImplementation(libs.compose.ui.tooling)
}
