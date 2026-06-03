import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, environmentName: String): String? =
    (keystoreProperties[propertyName] as String?) ?: System.getenv(environmentName)

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_FILE")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val releaseStorePassword = signingValue("storePassword", "ANDROID_STORE_PASSWORD")

if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
    val missingSigningValues = listOfNotNull(
        "storeFile/ANDROID_KEYSTORE_FILE".takeIf { releaseStoreFile.isNullOrBlank() },
        "keyAlias/ANDROID_KEY_ALIAS".takeIf { releaseKeyAlias.isNullOrBlank() },
        "keyPassword/ANDROID_KEY_PASSWORD".takeIf { releaseKeyPassword.isNullOrBlank() },
        "storePassword/ANDROID_STORE_PASSWORD".takeIf { releaseStorePassword.isNullOrBlank() },
    )
    if (missingSigningValues.isNotEmpty()) {
        throw GradleException(
            "Release signing is not configured. Missing: ${missingSigningValues.joinToString()}. " +
                "Create android/key.properties from android/key.properties.example or set the matching environment variables."
        )
    }
}

android {
    namespace = "com.yang.epubtranslator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    buildToolsVersion = "36.1.0"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yang.epubtranslator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
            storeFile = releaseStoreFile?.let { file(it) }
            storePassword = releaseStorePassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
