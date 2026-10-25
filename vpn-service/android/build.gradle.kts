import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "lfw.fly.vpn_service"
version = "1.0.0"

android {
    namespace = "lfw.fly.vpn_service"
    // Same as the Karing+ app (android/app/build.gradle.kts).
    compileSdk = 36

    defaultConfig {
        // Flutter 3.47 minimum; same as the Karing+ app.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // libbox.aar (sing-box v1.12.25, built in D:\dock\libbox-1.12-out) is packaged
    // by the app from android/app/libs. This plugin only needs it to compile:
    // put the same file in android/libs/ (not committed).
    compileOnly(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
}
