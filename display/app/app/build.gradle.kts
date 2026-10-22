plugins {
    id("com.android.application")
}

android {
    namespace = "io.github.dylanneve1.avfdisplay"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "io.github.dylanneve1.avfdisplay"
        minSdk = 34
        // Keep <= 36: apps targeting 37+ may not open the ashmem device that
        // SharedMemory uses, and crosvm can only map ashmem (not an app memfd).
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        externalNativeBuild { cmake { arguments += "-DANDROID_STL=none" } }
        ndk { abiFilters += "arm64-v8a" }
    }

    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
