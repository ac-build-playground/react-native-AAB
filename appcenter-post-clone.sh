import groovy.xml.Namespace

apply plugin:AppCenterPlugin

class AppCenterPlugin implements Plugin<Gradle> {

    void apply(Gradle gradle) {
        gradle.addProjectEvaluationListener(new AppCenterProjectEvaluationListener())
    }
}

class AppCenterProjectEvaluationListener implements ProjectEvaluationListener {

    private static final GROUP = "AppCenter"

    @Override
    void beforeEvaluate(Project project) {

    }

    @Override
    void afterEvaluate(Project project, ProjectState state) {
        // support android.application and android.dynamic-feature modules
        if (!(project.plugins.hasPlugin("com.android.application") || project.plugins.hasPlugin("com.android.dynamic-feature")) || !(System.getProperty("MOBILECENTER_BUILD_VERSION") || System.getProperty("APPCENTER_BUILD_VERSION"))) {
            // No Android app or no build version set, don't run
            project.logger.warn("Project ${project.name} at ${project.path} is either no Android app project or build version has not been set to override. Skipping...")
            return
        }

        project.logger.info("Processing version code override for project ${project.name} at ${project.path}...")

        def newVersionCodeMobileCenter = System.getProperty("MOBILECENTER_BUILD_VERSION")
        def newVersionCodeAppCenter = System.getProperty("APPCENTER_BUILD_VERSION")

        if (newVersionCodeMobileCenter && newVersionCodeAppCenter && newVersionCodeMobileCenter != newVersionCodeAppCenter) {
            project.logger.warn("Conflict between new version codes for MOBILECENTER_BUILD_VERSION (${newVersionCodeMobileCenter}) and APPCENTER_BUILD_VERSION (${newVersionCodeAppCenter}), using the latter.")
        }

        def newVersionCode = Integer.parseInt(newVersionCodeAppCenter ?: newVersionCodeMobileCenter)

        project.logger.info("Preparing override of version code to ${newVersionCode}")
        project.logger.debug("Scanning for output manifest files which need to be modified")

        project.android.applicationVariants.all { variant ->
            project.logger.info("Analyzing variant ${variant.name}")
            def variantOutput = variant.outputs.first()

            def manifestFiles = []

            def processManifest = variantOutput.hasProperty('processManifestProvider') ? variantOutput.processManifestProvider.get() : variantOutput.processManifest

            if (processManifest.hasProperty('manifestOutputDirectory')) {
                // new behavior, need to read all the manifest files
                project.logger.debug("Variant output responds to 'manifestOutputDirectory'")

                File targetDirectory
                def outputDirectory = processManifest.manifestOutputDirectory
                if (outputDirectory instanceof File) {
                    targetDirectory = outputDirectory
                } else {
                    targetDirectory = outputDirectory.get().asFile
                }

                File testManifestFile = new File(targetDirectory.toString(), "AndroidManifest.xml")
                // we need to find the right manifest file - only the one for the built variant will exist
                project.logger.info("Intermediate AndroidManifest.xml to be stored at ${testManifestFile.absolutePath}")
                manifestFiles.add(testManifestFile)
            } else if (processManifest.hasProperty('manifestOutputFile')) {
                // old behavior, pre Android Gradle Plugin 3.0 - we could simply read the generated manifest and alter it
                project.logger.debug("Variant output responds to 'manifestOutputFile'")
                File manifestFile = processManifest.manifestOutputFile
                project.logger.info("Intermediate AndroidManifest.xml will be stored at ${manifestFile.absolutePath}")
                manifestFiles.add(manifestFile)
                
            } else if (variantOutput.metaClass.respondsTo(variantOutput, "setVersionCodeOverride")) {
                // Fallback behavior for Android Gradle Plugin versions from 3.0-beta.1 to 3.0-beta.5
                // behavior with Android Gradle Plugin 3.0+ - we check for the "setVersionCodeOverride" method and invoke it to override the version code
                // needs to be checked with reflection because Android Gradle Plugin classes are not on the class path
                // use -1 if the version code is not read from the properties correctly, -1 will cause the override to have no effect
                // TODO Improve this by using a full-fledged project
                project.logger.warn("Fallback: Not postprocessing AndroidManifest.xml file, using 'setVersionCodeOverride()'")
                variantOutput.setVersionCodeOverride(newVersionCode)
            }

            ['bundleManifestOutputDirectory', 'metadataFeatureManifestOutputDirectory', 'instantAppManifestOutputDirectory'].each { target ->
                if (processManifest.hasProperty(target)) {
                    project.logger.debug("Variant output responds to '${target}'")

                    File targetDirectory
                    def outputDirectory = processManifest[target]
                    if (outputDirectory instanceof File) {
                        targetDirectory = outputDirectory
                    } else {
                        targetDirectory = outputDirectory.get().asFile
                    }

                    File testManifestFile = new File(targetDirectory.toString(), "AndroidManifest.xml")
                    // we need to find the right manifest file - only the one for the built variant will exist
                    project.logger.warn("Intermediate AndroidManifest.xml to be stored at ${testManifestFile.absolutePath}")
                    manifestFiles.add(testManifestFile)
                }
            }

            project.logger.info("Manifest file paths to consider: ${manifestFiles}")

            manifestFiles.eachWithIndex { manifestFile, index ->
                def manifestPath = manifestFile.absolutePath
                def variantName = variant.name.capitalize()

                project.logger.info("Creating manifest processing task for variant ${variantName}")
                project.logger.debug("Manifest file path: ${manifestPath}")

                ProcessManifestTask manifestTask = project.tasks.create("processAppCenter${variantName}-${index}Manifest", ProcessManifestTask)
                manifestTask.group = GROUP
                manifestTask.manifestPath = manifestPath
                manifestTask.targetVersionCode = newVersionCode
                manifestTask.mustRunAfter processManifest

                def processResources = variantOutput.hasProperty('processResourcesProvider') ? variantOutput.processResourcesProvider.get() : variantOutput.processResources

                processResources.dependsOn manifestTask

                // for AAB we need to update manifests before "bundle<Variant>Resources" task
                def bundleResources = project.tasks.find { it.name.contains("bundle${variantName}Resources") }
                if (bundleResources) {
                    bundleResources.dependsOn manifestTask
                }

                project.logger.debug("Installed processing task for variant ${variant.name}")
            }
        }
    }
}

class ProcessManifestTask extends DefaultTask {
    String manifestPath
    Integer targetVersionCode

    @TaskAction
    def updateManifest() {
        File manifestFile = new File(manifestPath)
        if (!manifestFile.exists()) {
            project.logger.info("Manifest file at ${manifestFile.absolutePath} does not exist, skipping")
            return
        }
        project.logger.info("Updating AndroidManifest.xml at ${manifestPath}")
        def ns = new Namespace("http://schemas.android.com/apk/res/android", "android")
        def xml = new XmlParser().parse(manifestPath)

        if (xml) {
            def versionCode = xml.attributes()[ns.versionCode]
            xml.attributes()[ns.versionCode] = targetVersionCode
            def writer = new FileWriter(manifestPath)
            def printer = new XmlNodePrinter(new PrintWriter(writer))
            printer.preserveWhitespace = true
            printer.print(xml)
            writer.close()
        } else {
            project.logger.error("Manifest file does not seem to contain valid XML or does not exist")
        }
        project.logger.debug("Finished updating AndroidManifest.xml at ${manifestPath}")
    }
}
