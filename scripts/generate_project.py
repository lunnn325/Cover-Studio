#!/usr/bin/env python3
"""Generate the checked-in native Xcode project; Python 3 standard library only."""
from pathlib import Path
import argparse
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "MyCoverStudio.xcodeproj"


def uid(label):
    return hashlib.sha256(label.encode("utf-8")).hexdigest()[:24].upper()


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def generate():
    sources = sorted((ROOT / "App").rglob("*.swift"), key=lambda p: p.as_posix())
    if not sources:
        raise SystemExit("No App Swift source files found.")
    objects = []

    def obj(key, body):
        objects.append(f"\t\t{uid(key)} = {{ {body} }};")

    def refs(keys):
        return "(" + " ".join(uid(key) + "," for key in keys) + ")"

    source_keys = []
    for source in sources:
        path = source.relative_to(ROOT / "App").as_posix()
        key = "source:" + path
        source_keys.append(key)
        obj(key, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = \"<group>\";")
        obj("build:" + path, f"isa = PBXBuildFile; fileRef = {uid(key)};")

    resources = [("Assets.xcassets", "folder.assetcatalog"), ("PrivacyInfo.xcprivacy", "text.xml")]
    for name, kind in resources:
        obj("resource:" + name, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(name)}; sourceTree = \"<group>\";")
        obj("resource-build:" + name, f"isa = PBXBuildFile; fileRef = {uid('resource:' + name)};")
    obj("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
    obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MyCoverStudio.app; sourceTree = BUILT_PRODUCTS_DIR;')
    app_keys = source_keys + ["resource:" + name for name, _ in resources] + ["info"]
    obj("app-group", f'isa = PBXGroup; children = {refs(app_keys)}; path = App; sourceTree = "<group>";')
    obj("ui-source", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StartupRecoveryUITests.swift; sourceTree = "<group>";')
    obj("ui-source-build", f'isa = PBXBuildFile; fileRef = {uid("ui-source")};')
    obj("ui-group", f'isa = PBXGroup; children = {refs(["ui-source"])}; path = UITests; sourceTree = "<group>";')
    obj("ui-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = StartupUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj("products", f'isa = PBXGroup; children = {refs(["product", "ui-product"])}; name = Products; sourceTree = "<group>";')
    obj("main-group", f'isa = PBXGroup; children = {refs(["app-group", "ui-group", "products"])}; sourceTree = "<group>";')
    obj("package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
    obj("core-product", f'isa = XCSwiftPackageProductDependency; package = {uid("package")}; productName = CoverCore;')
    obj("core-build", f'isa = PBXBuildFile; productRef = {uid("core-product")};')
    obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(["core-build"])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:" + p.relative_to(ROOT / "App").as_posix() for p in sources])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["resource-build:" + name for name, _ in resources])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("ui-sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["ui-source-build"])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("ui-frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    obj("ui-proxy", f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("app-target")}; remoteInfo = MyCoverStudio;')
    obj("ui-dependency", f'isa = PBXTargetDependency; target = {uid("app-target")}; targetProxy = {uid("ui-proxy")};')

    for config in ["Debug", "Release"]:
        debug = config == "Debug"
        project_settings = {
            "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else '"dwarf-with-dsym"',
            "GCC_OPTIMIZATION_LEVEL": "0" if debug else "s",
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"' if debug else '"-O"',
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"' if debug else '"$(inherited)"',
            "ENABLE_TESTABILITY": "YES" if debug else "NO",
        }
        target_settings = {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
            "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "App/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
            "MARKETING_VERSION": "1.0", "PRODUCT_BUNDLE_IDENTIFIER": "studio.mycover.app",
            "PRODUCT_NAME": '"$(TARGET_NAME)"', "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
            "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "TARGETED_DEVICE_FAMILY": '"1,2"', "SWIFT_EMIT_LOC_STRINGS": "YES",
            "SWIFT_STRICT_CONCURRENCY": "targeted",
        }
        ui_settings = {
            "CODE_SIGN_STYLE": "Automatic", "GENERATE_INFOPLIST_FILE": "YES",
            "PRODUCT_BUNDLE_IDENTIFIER": "studio.mycover.app.StartupUITests", "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "TEST_TARGET_NAME": "MyCoverStudio", "TARGETED_DEVICE_FAMILY": '"1,2"', "SKIP_INSTALL": "YES",
            "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"', "SUPPORTS_MACCATALYST": "NO",
            "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"',
        }
        for level, settings in [("project", project_settings), ("target", target_settings), ("ui", ui_settings)]:
            body = " ".join(f"{key} = {value};" for key, value in settings.items())
            obj(level + config, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};')
    for level in ["project", "target", "ui"]:
        obj(level + "-configs", f'isa = XCConfigurationList; buildConfigurations = {refs([level + "Debug", level + "Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj("app-target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = {refs(["sources", "frameworks", "resources"])}; buildRules = (); dependencies = (); name = MyCoverStudio; packageProductDependencies = {refs(["core-product"])}; productName = MyCoverStudio; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
    obj("ui-target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("ui-configs")}; buildPhases = {refs(["ui-sources", "ui-frameworks"])}; buildRules = (); dependencies = {refs(["ui-dependency"])}; name = StartupUITests; productName = StartupUITests; productReference = {uid("ui-product")}; productType = "com.apple.product-type.bundle.ui-testing";')
    obj("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {uid("app-target")} = {{ CreatedOnToolsVersion = 26.0; }}; {uid("ui-target")} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {uid("app-target")}; }}; }}; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base,); mainGroup = {uid("main-group")}; packageReferences = {refs(["package"])}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["app-target", "ui-target"])};')
    project_text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n"
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("app-target")}" BuildableName="MyCoverStudio.app" BlueprintName="MyCoverStudio" ReferencedContainer="container:MyCoverStudio.xcodeproj"/>'
    ui_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("ui-target")}" BuildableName="StartupUITests.xctest" BlueprintName="StartupUITests" ReferencedContainer="container:MyCoverStudio.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ui_reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ui_reference}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return {PROJECT / "project.pbxproj": project_text, PROJECT / "xcshareddata/xcschemes/MyCoverStudio.xcscheme": scheme}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report stale generated files without writing.")
    args = parser.parse_args()
    stale = []
    for path, content in generate().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    if stale:
        print("Stale Xcode configuration: " + ", ".join(stale), file=sys.stderr)
        return 1
    print("Xcode project configuration is current." if args.check else "Generated native MyCoverStudio Xcode project.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
