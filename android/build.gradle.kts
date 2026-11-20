allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Plugins that pin an old compileSdk are raised to 36 after their own build
// script has run. flutter_displaymode hardcodes 33, and the androidx libraries
// the app now pulls in (fragment 1.7, window 1.2) refuse to be compiled
// against anything below 34 — CI failed 2.33.0 on checkReleaseAarMetadata
// for exactly that. compileSdk only decides which APIs the plugin can see at
// build time; it does not change minSdk or targetSdk, so which phones can
// install the app and how it behaves on them are unaffected. Registered
// BEFORE the evaluationDependsOn block below, which evaluates projects and
// would make a later afterEvaluate registration throw.
subprojects {
    if (name != "app") {
        afterEvaluate {
            extensions.findByName("android")?.withGroovyBuilder {
                val current = getProperty("compileSdk") as? Int
                if (current == null || current < 34) {
                    setProperty("compileSdk", 36)
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
