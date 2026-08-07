// Battery for Android — see ../tasks/plans/PLAN_01_android-app.md
//
// Two modules, mirroring the iOS split in ios/project.yml:
//   core  — the BatteryKit port. Pure Kotlin/JVM, no Android dependency, so the
//           regression and the forecast wording can be tested on the JVM against
//           the same golden fixtures the Swift tests use.
//   app   — everything Android: Compose UI, the Live Update, and (later) the
//           Glance widgets. Unlike iOS, widgets need no separate module: they're
//           a BroadcastReceiver in this same APK, not a codesigned .appex.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Battery"
include(":core")
include(":app")
