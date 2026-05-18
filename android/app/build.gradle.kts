plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tcw3.icamera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"  // installed NDK version

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.tcw3.icamera"
        minSdk = 26  // tflite_flutter requires API 26+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                // C++17, fast-math, unroll loops for the image pipeline
                cppFlags("-std=c++17", "-O3", "-ffast-math", "-funroll-loops")
                // Build for all Android ABIs
                abiFilters("arm64-v8a", "armeabi-v7a", "x86_64")
            }
        }
    }

    externalNativeBuild {
        cmake {
            // Path relative to android/app/build.gradle.kts
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Camera2 interop for direct ISO / shutter speed control
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    // ListenableFuture — return type of Camera2CameraControl.setCaptureRequestOptions()
    implementation("com.google.guava:guava:31.1-android")
}
