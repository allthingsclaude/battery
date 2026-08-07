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
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        compose = true
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

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)

    implementation(libs.glance.appwidget)
    implementation(libs.glance.material3)
    debugImplementation(libs.compose.ui.tooling)
}
