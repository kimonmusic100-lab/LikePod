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
subprojects {
    project.evaluationDependsOn(":app")
}

// just_audio hides its ExoPlayer. Compile a kept hook into that plugin and
// call it when the player is created, so USB routing does not depend on
// obfuscated field names.
subprojects {
    if (name != "just_audio") return@subprojects
    val inject = tasks.register("injectUsbPreferredDevice") {
        doLast {
            val javaDir = file("src/main/java/com/ryanheise/just_audio")
            val audioPlayer = javaDir.resolve("AudioPlayer.java")
            if (!audioPlayer.isFile) {
                throw GradleException("just_audio AudioPlayer.java not found at $audioPlayer")
            }
            javaDir.mkdirs()
            val hooks = listOf(
                "UsbPreferredDevice.java",
                "UsbDirectSink.java",
                "UsbRenderersFactory.java",
            )
            for (hookName in hooks) {
                val file = rootProject.file("usb_hook/$hookName")
                if (!file.isFile) {
                    throw GradleException("Missing ${file.path}")
                }
                file.copyTo(javaDir.resolve(hookName), overwrite = true)
            }
            var source = audioPlayer.readText()
            val marker = "UsbPreferredDevice.onPlayerCreated(player);"
            if (!source.contains(marker)) {
                val needle = "player = builder.build();"
                if (!source.contains(needle)) {
                    throw GradleException("just_audio player build site changed; USB hook was not inserted")
                }
                source = source.replace(needle, "$needle\n            $marker")
            }
            val factory = "new UsbRenderersFactory(context)"
            if (!source.contains(factory)) {
                val needle = "new DefaultRenderersFactory(context)"
                if (!source.contains(needle)) {
                    throw GradleException("just_audio renderer factory site changed; USB sink was not inserted")
                }
                source = source.replace(needle, factory)
            }
            audioPlayer.writeText(source)
        }
    }
    tasks.configureEach {
        if (name == "preBuild" || (name.contains("compile") && name.contains("Java"))) {
            dependsOn(inject)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
