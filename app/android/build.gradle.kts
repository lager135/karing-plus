allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Older pub plugins pin low compileSdk/ndk versions or still lack a namespace.
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.application") || plugins.hasPlugin("com.android.library")) {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let { androidExt ->
                androidExt.compileSdkVersion(36)
                androidExt.ndkVersion = "28.2.13676358"
                if (androidExt.namespace == null) {
                    androidExt.namespace = project.group.toString()
                }
            }
        }
    }
}

// Some pub plugins (sentry_flutter 8.14.x) still set Kotlin languageVersion 1.6, which
// Kotlin 2.2 rejects. Raise anything below 1.8 to 1.8; newer settings stay as they are.
subprojects {
    afterEvaluate {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            val minimum = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_1_8
            val lang = compilerOptions.languageVersion.orNull
            if (lang != null && lang < minimum) compilerOptions.languageVersion.set(minimum)
            val api = compilerOptions.apiVersion.orNull
            if (api != null && api < minimum) compilerOptions.apiVersion.set(minimum)
        }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects { project.evaluationDependsOn(":app") }

tasks.register<Delete>("clean") { delete(rootProject.layout.buildDirectory) }
