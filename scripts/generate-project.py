#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project after adding source files."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(object_name, **values):
    key = identifier(object_name)
    objects[key] = values
    return key


def encode(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        body = "\n".join(f"{indent}\t{json.dumps(k)} = {encode(v, depth + 1)};" for k, v in value.items())
        return "{\n" + body + "\n" + indent + "}"
    if isinstance(value, list):
        body = "\n".join(f"{indent}\t{encode(v, depth + 1)}," for v in value)
        return "(\n" + body + "\n" + indent + ")"
    return json.dumps(str(value), ensure_ascii=False)


source_files = []
build_files = []
for source in sorted((ROOT / "SiriPlus").rglob("*.swift")):
    path = source.relative_to(ROOT / "SiriPlus").as_posix()
    file_id = add(path, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="<group>")
    source_files.append(file_id)
    build_files.append(add("build:" + path, isa="PBXBuildFile", fileRef=file_id))

source_files.append(add("Info.plist", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Resources/Info.plist", sourceTree="<group>"))
resource_files = []
for catalog in ["Localizable.xcstrings", "InfoPlist.xcstrings", "AppShortcuts.xcstrings"]:
    ref = add(catalog, isa="PBXFileReference", lastKnownFileType="text.json.xcstrings", path="Resources/" + catalog, sourceTree="<group>")
    source_files.append(ref)
    resource_files.append(add("build:" + catalog, isa="PBXBuildFile", fileRef=ref))
assets = add("Assets.xcassets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Resources/Assets.xcassets", sourceTree="<group>")
source_files.append(assets)
resource_files.append(add("build:Assets.xcassets", isa="PBXBuildFile", fileRef=assets))
source_files.append(add("SiriPlus.entitlements", isa="PBXFileReference", lastKnownFileType="text.plist.entitlements", path="Resources/SiriPlus.entitlements", sourceTree="<group>"))
source_group = add("sourceGroup", isa="PBXGroup", children=source_files, path="SiriPlus", sourceTree="<group>")
product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="SiriPlus.app", sourceTree="BUILT_PRODUCTS_DIR")

# Widget extension, embedded in the app's PlugIns folder.
widget_files = []
widget_sources = []
for source in sorted((ROOT / "SiriPlusWidget").glob("*.swift")):
    ref = add("widget:" + source.name, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=source.name, sourceTree="<group>")
    widget_files.append(ref)
    widget_sources.append(add("widget-build:" + source.name, isa="PBXBuildFile", fileRef=ref))
widget_catalog = add("widget:Localizable.xcstrings", isa="PBXFileReference", lastKnownFileType="text.json.xcstrings", path="Localizable.xcstrings", sourceTree="<group>")
widget_files += [
    widget_catalog,
    add("widget:Info.plist", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"),
    add("widget:entitlements", isa="PBXFileReference", lastKnownFileType="text.plist.entitlements", path="SiriPlusWidget.entitlements", sourceTree="<group>"),
]
widget_group = add("widgetGroup", isa="PBXGroup", children=widget_files, path="SiriPlusWidget", sourceTree="<group>")
widget_product = add("widgetProduct", isa="PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex="0", path="SiriPlusWidget.appex", sourceTree="BUILT_PRODUCTS_DIR")
widget_phases = [
    add("widgetSources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=widget_sources, runOnlyForDeploymentPostprocessing="0"),
    add("widgetFrameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
    add("widgetResources", isa="PBXResourcesBuildPhase", buildActionMask="2147483647", files=[add("widget-build:Localizable.xcstrings", isa="PBXBuildFile", fileRef=widget_catalog)], runOnlyForDeploymentPostprocessing="0"),
]

products = add("products", isa="PBXGroup", children=[product, widget_product], name="Products", sourceTree="<group>")
readme = add("readme", isa="PBXFileReference", lastKnownFileType="net.daringfireball.markdown", path="README.md", sourceTree="<group>")
main_group = add("mainGroup", isa="PBXGroup", children=[source_group, widget_group, products, readme], sourceTree="<group>")

phases = [
    add("sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=build_files, runOnlyForDeploymentPostprocessing="0"),
    add("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
    add("resources", isa="PBXResourcesBuildPhase", buildActionMask="2147483647", files=resource_files, runOnlyForDeploymentPostprocessing="0"),
    add("embedExtensions", isa="PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", name="Embed Foundation Extensions",
        files=[add("embed:widget", isa="PBXBuildFile", fileRef=widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})], runOnlyForDeploymentPostprocessing="0"),
]

config_lists = {}
for scope in ["project", "target", "widget"]:
    configs = []
    for configuration in ["Debug", "Release"]:
        if scope == "project":
            settings = {
                "CLANG_ENABLE_MODULES": "YES",
                "CLANG_ENABLE_OBJC_ARC": "YES",
                "COPY_PHASE_STRIP": "NO",
                "MACOSX_DEPLOYMENT_TARGET": "26.0",
                "SDKROOT": "macosx",
                "SWIFT_VERSION": "6.0",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
                "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
                "ENABLE_TESTABILITY": "YES" if configuration == "Debug" else "NO",
            }
            if configuration == "Debug":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
                # One binary instead of a stub plus SiriPlus.debug.dylib: with hardened runtime, a dylib signed
                # by the self-signed certificate (no Team ID) fails library validation and the app cannot launch.
                settings["ENABLE_DEBUG_DYLIB"] = "NO"
        elif scope == "widget":
            settings = {
                "PRODUCT_NAME": "SiriPlusWidget",
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.siriplus.app.widget",
                "INFOPLIST_FILE": "SiriPlusWidget/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "SiriPlusWidget/SiriPlusWidget.entitlements",
                "GENERATE_INFOPLIST_FILE": "NO",
                "MARKETING_VERSION": "0.3.0",
                "CURRENT_PROJECT_VERSION": "1",
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "",
                "ENABLE_APP_SANDBOX": "YES",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "APPLICATION_EXTENSION_API_ONLY": "YES",
                "SKIP_INSTALL": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
                "SWIFT_EMIT_LOC_STRINGS": "YES",
                "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            }
        else:
            settings = {
                "PRODUCT_NAME": "SiriPlus",
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.siriplus.app",
                "INFOPLIST_FILE": "SiriPlus/Resources/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "SiriPlus/Resources/SiriPlus.entitlements",
                "GENERATE_INFOPLIST_FILE": "NO",
                "MARKETING_VERSION": "0.3.0",
                "CURRENT_PROJECT_VERSION": "1",
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "",
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
                "SWIFT_EMIT_LOC_STRINGS": "YES",
                "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            }
        configs.append(add(scope + configuration, isa="XCBuildConfiguration", buildSettings=settings, name=configuration))
    config_lists[scope] = add(scope + "ConfigList", isa="XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")

widget_target = add("widgetTarget", isa="PBXNativeTarget", buildConfigurationList=config_lists["widget"], buildPhases=widget_phases, buildRules=[], dependencies=[], name="SiriPlusWidget", productName="SiriPlusWidget", productReference=widget_product, productType="com.apple.product-type.app-extension")
widget_proxy = add("widgetProxy", isa="PBXContainerItemProxy", containerPortal=identifier("project"), proxyType="1", remoteGlobalIDString=widget_target, remoteInfo="SiriPlusWidget")
widget_dependency = add("widgetDependency", isa="PBXTargetDependency", target=widget_target, targetProxy=widget_proxy)
target = add("appTarget", isa="PBXNativeTarget", buildConfigurationList=config_lists["target"], buildPhases=phases, buildRules=[], dependencies=[widget_dependency], name="SiriPlus", productName="SiriPlus", productReference=product, productType="com.apple.product-type.application")
project = add("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"}, buildConfigurationList=config_lists["project"], compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "ru", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target, widget_target])

directory = ROOT / "SiriPlus.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}) + "\n")
schemes = directory / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SiriPlus.app" BlueprintName="SiriPlus" ReferencedContainer="container:SiriPlus.xcodeproj"/>'
(schemes / "SiriPlus.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(directory)
