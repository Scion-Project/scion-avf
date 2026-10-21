plugins {
    id("com.android.application")
}

android {
    namespace = "io.github.dylanneve1.avfprobe"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.dylanneve1.avfprobe"
        // The AVF Java API (android.system.virtualmachine) is Android 14+.
        minSdk = 34
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
