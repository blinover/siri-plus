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
source_files.append(add("SiriPlus.entitlements", isa="PBXFileReference", lastKnownFileType="text.plist.entitlements", path="Resources/SiriPlus.entitlements", sourceTree="<group>"))
source_group = add("sourceGroup", isa="PBXGroup", children=source_files, path="SiriPlus", sourceTree="<group>")
product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="SiriPlus.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
readme = add("readme", isa="PBXFileReference", lastKnownFileType="net.daringfireball.markdown", path="README.md", sourceTree="<group>")
main_group = add("mainGroup", isa="PBXGroup", children=[source_group, products, readme], sourceTree="<group>")

phases = [
    add("sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=build_files, runOnlyForDeploymentPostprocessing="0"),
    add("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
    add("resources", isa="PBXResourcesBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
]

config_lists = {}
for scope in ["project", "target"]:
    configs = []
    for configuration in ["Debug", "Release"]:
        if scope == "project":
            settings = {
                "CLANG_ENABLE_MODULES": "YES",
                "CLANG_ENABLE_OBJC_ARC": "YES",
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
        else:
            settings = {
                "PRODUCT_NAME": "SiriPlus",
                "PRODUCT_BUNDLE_IDENTIFIER": "dev.siriplus.app",
                "INFOPLIST_FILE": "SiriPlus/Resources/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "SiriPlus/Resources/SiriPlus.entitlements",
                "GENERATE_INFOPLIST_FILE": "NO",
                "MARKETING_VERSION": "0.1.0",
                "CURRENT_PROJECT_VERSION": "1",
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "DEVELOPMENT_TEAM": "",
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
                "SWIFT_EMIT_LOC_STRINGS": "YES",
            }
        configs.append(add(scope + configuration, isa="XCBuildConfiguration", buildSettings=settings, name=configuration))
    config_lists[scope] = add(scope + "ConfigList", isa="XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")

target = add("appTarget", isa="PBXNativeTarget", buildConfigurationList=config_lists["target"], buildPhases=phases, buildRules=[], dependencies=[], name="SiriPlus", productName="SiriPlus", productReference=product, productType="com.apple.product-type.application")
project = add("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"}, buildConfigurationList=config_lists["project"], compatibilityVersion="Xcode 14.0", developmentRegion="ru", hasScannedForEncodings="0", knownRegions=["ru", "en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])

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
