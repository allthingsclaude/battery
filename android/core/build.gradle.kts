plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Deliberately a plain JVM module, not an Android library. Nothing in the port of
// BatteryKit's *logic* — the regression, the forecast, the level thresholds —
// needs the Android framework, and keeping it out means these run as ordinary
// JVM tests in milliseconds against the same golden fixtures the Swift suite uses
// (see Tests/BatteryTests/). The moment this module needs `android.*`, the shared
// fixture story is over, so that's the line to defend.

// Target 17 bytecode rather than requesting a 17 *toolchain*: this machine has
// only JDK 26, and pinning a toolchain would make the build depend on a JDK
// nobody has installed. Any JDK 17+ can produce 17 bytecode.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    // Used via the runtime `parseToJsonElement` API only — no @Serializable
    // types, so no compiler plugin. The API surface is one GET and one POST;
    // four fields do not justify code generation.
    implementation(libs.kotlinx.serialization.json)

    testImplementation(kotlin("test"))
    // Test-only, and only for reading the shared fixtures. No @Serializable types
    // and therefore no compiler plugin: Json.parseToJsonElement is a pure runtime
    // API. Keeping it out of `implementation` is deliberate — `core` shipping a
    // serialization framework to read three JSON files would be backwards.
    testImplementation(libs.kotlinx.serialization.json)
}

tasks.test {
    useJUnitPlatform()
    // The golden fixtures are shared with the Swift suite, so they live at the
    // repository root rather than inside this module's resources. `rootProject`
    // here is `android/`, so its parent is the repo root.
    systemProperty(
        "battery.fixtures",
        rootProject.projectDir.parentFile.resolve("fixtures").absolutePath,
    )
    testLogging {
        events("failed")
        showStandardStreams = false
    }
}
