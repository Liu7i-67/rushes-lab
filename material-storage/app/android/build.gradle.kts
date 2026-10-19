import com.android.build.api.dsl.CommonExtension

allprojects {
    repositories {
        google()
        mavenCentral()
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
