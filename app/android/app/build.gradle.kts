import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // The Sentry Gradle plugin was removed: it only uploads mappings/symbols and needs
    // credentials. sentry_flutter itself still works without it.
}

// Release signing comes from android/key.properties when its keystore exists;
// otherwise every build type is signed with the local Android debug key.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseStoreFile = keyProps.getProperty("storeFile.release")
    ?.takeIf { it.isNotBlank() }
    ?.let { rootProject.file(it) }
    ?.takeIf { it.exists() }

android {
    namespace = "com.nebula.karing"
    compileSdk = 36
    ndkVersion = "28.2.13676358" // flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    sourceSets { getByName("main").java.srcDirs("src/main/kotlin") }

    defaultConfig {
        applicationId = "com.icefusion.karingplus"
        minSdk = 24 // Flutter 3.47 minimum
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = keyProps.getProperty("storePassword.release")
                keyAlias = keyProps.getProperty("keyAlias.release")
                keyPassword = keyProps.getProperty("keyPassword.release")
            }
        }
    }

    buildTypes {
        val releaseSigning = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        getByName("debug") {
            ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }
        }
        getByName("profile") {
            signingConfig = releaseSigning
            ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }
        }
        getByName("release") {
            signingConfig = releaseSigning
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            ndk {
                abiFilters.clear()
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
            }
        }
    }

    packaging {
        // libbox.so is large; keep it compressed in the APK (extracted at install).
        jniLibs {
            useLegacyPackaging = true
            // Only arm64-v8a/armeabi-v7a have libflutter.so and libbox.so; drop the
            // x86_64 leftovers of other plugins so x86_64 devices do not install a broken APK.
            excludes += listOf("lib/x86_64/**", "lib/x86/**")
        }
    }
}

flutter { source = "../.." }

dependencies {
    // sing-box core (libbox) v1.12.25, built in D:\dock\libbox-1.12-out
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
