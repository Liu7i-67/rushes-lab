import com.android.build.api.dsl.CommonExtension

// 小米「动态照片 SDK」私有 maven 仓(docs/qdev/2026-11-16-xiaomi-motionphoto-sdk.md §4.1):
// 凭据只存机器级 ~/.gradle/gradle.properties(xgLivephotoUser/xgLivephotoPass),不入仓库。
val xgUser = providers.gradleProperty("xgLivephotoUser").getOrElse("")
val xgPass = providers.gradleProperty("xgLivephotoPass").getOrElse("")
if (xgUser.isEmpty() || xgPass.isEmpty()) {
    logger.warn("⚠ 缺少小米动态照片 SDK maven 凭据(~/.gradle/gradle.properties 的 " +
        "xgLivephotoUser/xgLivephotoPass 两属性),livephoto 依赖将无法解析," +
        "配置见 docs/qdev/2026-11-16-xiaomi-motionphoto-sdk.md §4.1")
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://repos.xiaomi.com/maven")
            content { includeGroup("com.xiaomi.camera") } // 只允许 livephoto 走此仓,防其他 group 元数据查询带凭据打小米仓
            credentials {
                username = xgUser
                password = xgPass
            }
        }
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

// 统一插件子工程 compileSdk:file_picker 等插件模板声明的 compileSdk(34/35)低于
// 传递依赖 flutter_plugin_android_lifecycle 的要求(36),在各自 build.gradle 跑完后
// 覆写为 36 —— 只影响编译期 API 面,不改 targetSdk/minSdk 行为。
// ⚠ 本块必须在下方 evaluationDependsOn 之前注册:Gradle 9 禁止对已评估工程挂
// afterEvaluate(evaluationDependsOn(":app") 会提前评估 :app)。
subprojects {
    afterEvaluate {
        extensions.findByType(CommonExtension::class.java)?.compileSdk = 36
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
