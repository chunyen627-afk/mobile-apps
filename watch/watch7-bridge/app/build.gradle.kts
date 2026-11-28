plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.chunyen627afk.watch7bridge"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.chunyen627afk.watch7bridge"
        testInstrumentationRunner = "io.github.chunyen627afk.watch7bridge.TripSmoke"
        minSdk = 33
        targetSdk = 36
        versionCode = 3
        versionName = "0.3.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    testImplementation("junit:junit:4.13.2")
}
