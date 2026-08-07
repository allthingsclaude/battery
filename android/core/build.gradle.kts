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
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
