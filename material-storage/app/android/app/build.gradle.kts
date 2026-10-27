import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── release 签名 ──────────────────────────────────────────────────────────
// 证书:scripts/env/huanhuashijie-release.jks(2026-10-27 生成,RSA 2048,有效期至 2054-03-14)
// 口令:scripts/env/keystore.properties(scripts/.gitignore 的 env/ 规则已忽略,不入库)
// 指纹与备份要求:scripts/env/huanhuashijie-release-keystore.md
// ⚠ 该证书是 App 的长期身份:分发出去后就不能更换(换证书 = 存量用户必须卸载重装,
//   且 App 备案登记的公钥/证书 MD5 失效,须做备案变更)。务必离线备份两份。
// 文件缺失时只告警并回退 debug 签名,保证未持有密钥的机器仍能出 debug/测试包;
// 正式发布由 tool/release.mjs 的签名闸(比对证书 MD5)兜底拦截。
val keystorePropertiesFile = rootProject.file("../../../scripts/env/keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

if (!hasReleaseKeystore) {
    logger.warn(
        "⚠ 未找到 scripts/env/keystore.properties:release 构建将回退 debug 签名," +
            "产物不可分发(与 App 备案登记的公钥/证书 MD5 不一致)。"
    )
}

android {
    // 包名 = 公司域名倒写 + 产品名;与 App 备案登记的应用包名必须一致,改动即等于换一个 App
    namespace = "com.taoxiplan.huanhuashijie"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // P8 flutter_local_notifications:插件要求开启 core library desugaring
        // (java.time 等在低 API 设备上的脱糖;依赖见下方 dependencies)
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.taoxiplan.huanhuashijie"
        // 显式收口 API 29(Android 10):media_store_plus 写 Downloads 依赖
        // scoped storage,仅 API 29+ 免权限(方案 §6.2);内网工具最低支持
        // Android 10 已定稿,API<29 不再回退 WRITE_EXTERNAL_STORAGE 老路。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

dependencies {
    // P8 flutter_local_notifications:配套 desugaring 库(与上方
    // isCoreLibraryDesugaringEnabled 成对;插件官方要求)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
