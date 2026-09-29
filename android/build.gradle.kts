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
// Tüm modüllerde (app + pluginler) Java/Kotlin hedefini eşitle.
// Bazı pluginler (örn. tflite_flutter) farklı varsayılanlarla gelir ve
// yeni Kotlin sürümlerinde "Inconsistent JVM Target" hatası verir.
// Eski pluginler (compileSdk 33 ve altı) AGP 9 ile derlenemez,
// SDK'da kurulu olan 35'e eşitliyoruz.
// NOT: Bu blok evaluationDependsOn'dan ÖNCE olmalı, yoksa
// "project is already evaluated" hatası verir.
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.let {
            it.compileSdk = 36
            it.compileOptions.apply {
                sourceCompatibility = org.gradle.api.JavaVersion.VERSION_17
                targetCompatibility = org.gradle.api.JavaVersion.VERSION_17
            }
        }
        extensions.findByType<com.android.build.api.dsl.ApplicationExtension>()?.let {
            it.compileSdk = 36
            it.compileOptions.apply {
                sourceCompatibility = org.gradle.api.JavaVersion.VERSION_17
                targetCompatibility = org.gradle.api.JavaVersion.VERSION_17
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
