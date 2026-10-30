import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Reown pulls in coinbase_wallet_sdk, which ships with compileSdk 31 and without
// the consumer-rules.pro/proguard-rules.pro its build.gradle names, so a clean
// pub cache (CI) fails release builds. Create placeholders before tasks run.
subprojects {
    afterEvaluate {
        extensions.findByType(LibraryExtension::class.java)?.apply {
            compileSdk = 36
        }
        if (name == "coinbase_wallet_sdk") {
            for (rules in listOf("consumer-rules.pro", "proguard-rules.pro")) {
                val file = file(rules)
                if (!file.exists()) {
                    file.writeText("# placeholder — coinbase_wallet_sdk omits this file\n")
                }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
