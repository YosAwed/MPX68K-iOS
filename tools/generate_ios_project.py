#!/usr/bin/env python3
"""Generate "MPX68K iOS.xcodeproj" from the macOS project.

The iOS app shares the emulation core and Swift layer with the macOS target
in X68000.xcodeproj (maintained upstream in YosAwed/MPX68K). Instead of
editing that project, this script reads the macOS target's Sources and
Resources phases, drops the macOS-only files, adds the iOS-only files and
writes a separate project. Re-run it after merging upstream:

    python3 tools/generate_ios_project.py

Object IDs are derived from content, so re-running produces a stable file.
"""

import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAC_PROJECT = os.path.join(ROOT, "X68000.xcodeproj", "project.pbxproj")
IOS_PROJECT_DIR = os.path.join(ROOT, "MPX68K iOS.xcodeproj")

MAC_TARGET_NAME = "X68000 macOS"
IOS_TARGET_NAME = "MPX68K iOS"
IOS_DIR = "X68000 iOS"

# Files from the macOS target that must not be built for iOS.
EXCLUDED_PREFIXES = ("X68000 macOS/",)

# iOS-only files, relative to ROOT.
IOS_SOURCES = [
    f"{IOS_DIR}/AppDelegate.swift",
    f"{IOS_DIR}/SceneDelegate.swift",
    f"{IOS_DIR}/GameViewController.swift",
    f"{IOS_DIR}/iOSKeyMap.swift",
    f"{IOS_DIR}/TouchMouseController.swift",
    f"{IOS_DIR}/VirtualPadView.swift",
]
IOS_RESOURCES = [
    f"{IOS_DIR}/Assets.xcassets",
    "Settings.bundle",
]
IOS_VARIANT_RESOURCES = [
    f"{IOS_DIR}/Base.lproj/LaunchScreen.storyboard",
]
IOS_REFERENCE_ONLY = [
    f"{IOS_DIR}/Info.plist",
]

# The macOS target links c68k as a static library from c68k.xcodeproj.
# The iOS target compiles the same sources directly.
C68K_SOURCES = [
    "X68000 Shared/px68k/m68000/c68k/c68k.c",
    "X68000 Shared/px68k/m68000/c68k/c68kexec.c",
]
C68K_FLAGS = "-O2"

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".c": "sourcecode.c.c",
    ".cpp": "sourcecode.cpp.cpp",
    ".h": "sourcecode.c.h",
    ".hpp": "sourcecode.cpp.h",
    ".inc": "text",
    ".png": "image.png",
    ".sks": "file.sks",
    ".txt": "text",
    ".plist": "text.plist.xml",
    ".xcassets": "folder.assetcatalog",
    ".bundle": "wrapper.plug-in",
    ".storyboard": "file.storyboard",
    ".xcconfig": "text.xcconfig",
}


def object_id(*parts):
    digest = hashlib.md5("\0".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def load_pbxproj(path):
    out = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        check=True, capture_output=True,
    ).stdout
    return json.loads(out)


def resolve_paths(objects, main_group):
    """Map every file reference / variant group ID to a ROOT-relative path."""
    paths = {}

    def walk(group_id, base):
        group = objects[group_id]
        for child_id in group.get("children", []):
            child = objects[child_id]
            tree = child.get("sourceTree", "<group>")
            rel = child.get("path", "")
            if tree == "SOURCE_ROOT":
                path = rel
            elif tree == "<group>":
                path = os.path.normpath(os.path.join(base, rel)) if rel else base
            else:
                continue
            if child["isa"] == "PBXGroup":
                walk(child_id, path)
            elif child["isa"] == "PBXVariantGroup":
                # Resolve through the Base localisation.
                for variant_id in child.get("children", []):
                    variant_path = objects[variant_id].get("path", "")
                    paths[child_id] = os.path.normpath(os.path.join(base, variant_path))
                    break
            else:
                paths[child_id] = path

    walk(main_group, "")
    return paths


def mac_build_files(data):
    objects = data["objects"]
    project = objects[data["rootObject"]]
    paths = resolve_paths(objects, project["mainGroup"])
    target = next(
        objects[t] for t in project["targets"]
        if objects[t].get("name") == MAC_TARGET_NAME
    )
    phases = {"PBXSourcesBuildPhase": [], "PBXResourcesBuildPhase": []}
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] not in phases:
            continue
        for build_file_id in phase["files"]:
            build_file = objects[build_file_id]
            ref = build_file.get("fileRef")
            if ref not in paths:
                continue
            path = paths[ref]
            if path.startswith(EXCLUDED_PREFIXES):
                continue
            flags = build_file.get("settings", {}).get("COMPILER_FLAGS")
            phases[phase["isa"]].append((path, flags))
    # Headers are resolved through the header map, which only contains
    # headers that are referenced by the project.
    headers = sorted(
        p for p in paths.values()
        if os.path.splitext(p)[1] in (".h", ".hpp", ".inc") and not p.startswith(EXCLUDED_PREFIXES)
    )
    return phases["PBXSourcesBuildPhase"], phases["PBXResourcesBuildPhase"], headers


# ---------------------------------------------------------------------------
# OpenStep plist writer


def quote(value):
    if value and all(c.isalnum() or c in "._/$_" for c in value) and not value.startswith("$("):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def write_value(value, indent):
    pad = "\t" * indent
    if isinstance(value, dict):
        lines = ["{"]
        for key in sorted(value) if not value.get("isa") else _isa_first(value):
            lines.append(f"{pad}\t{quote(key)} = {write_value(value[key], indent + 1)};")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for item in value:
            lines.append(f"{pad}\t{write_value(item, indent + 1)},")
        lines.append(f"{pad})")
        return "\n".join(lines)
    return quote(str(value))


def _isa_first(obj):
    return ["isa"] + sorted(k for k in obj if k != "isa")


# ---------------------------------------------------------------------------


class ProjectBuilder:
    def __init__(self):
        self.objects = {}
        self.groups = {}  # dir path -> group id
        self.file_refs = {}  # path -> file ref id
        self.main_group = object_id("group", "<main>")
        self.objects[self.main_group] = {
            "isa": "PBXGroup", "children": [], "sourceTree": "<group>",
        }

    def group_for(self, directory):
        if directory in ("", "."):
            return self.main_group
        if directory in self.groups:
            return self.groups[directory]
        parent = self.group_for(os.path.dirname(directory))
        gid = object_id("group", directory)
        self.objects[gid] = {
            "isa": "PBXGroup", "children": [],
            "path": os.path.basename(directory), "sourceTree": "<group>",
        }
        self.objects[parent]["children"].append(gid)
        self.groups[directory] = gid
        return gid

    def file_ref(self, path):
        if path in self.file_refs:
            return self.file_refs[path]
        ext = os.path.splitext(path)[1]
        rid = object_id("file", path)
        self.objects[rid] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": FILE_TYPES.get(ext, "file"),
            "path": os.path.basename(path),
            "sourceTree": "<group>",
        }
        self.objects[self.group_for(os.path.dirname(path))]["children"].append(rid)
        self.file_refs[path] = rid
        return rid

    def variant_group(self, path):
        # path = dir/Base.lproj/Name.storyboard
        if path in self.file_refs:
            return self.file_refs[path]
        lproj_dir = os.path.dirname(path)
        name = os.path.basename(path)
        parent_dir = os.path.dirname(lproj_dir)
        base_id = object_id("variant-base", path)
        self.objects[base_id] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": FILE_TYPES.get(os.path.splitext(name)[1], "file"),
            "name": "Base",
            "path": f"{os.path.basename(lproj_dir)}/{name}",
            "sourceTree": "<group>",
        }
        vid = object_id("variant", path)
        self.objects[vid] = {
            "isa": "PBXVariantGroup", "children": [base_id],
            "name": name, "sourceTree": "<group>",
        }
        self.objects[self.group_for(parent_dir)]["children"].append(vid)
        self.file_refs[path] = vid
        return vid

    def build_file(self, phase, ref, path, flags=None):
        bid = object_id("build", phase, path)
        entry = {"isa": "PBXBuildFile", "fileRef": ref}
        if flags:
            entry["settings"] = {"COMPILER_FLAGS": flags}
        self.objects[bid] = entry
        return bid

    def sort_groups(self):
        def key(child_id):
            obj = self.objects[child_id]
            is_group = obj["isa"] == "PBXGroup"
            return (0 if is_group else 1, (obj.get("name") or obj.get("path", "")).lower())

        for gid in [self.main_group, *self.groups.values()]:
            self.objects[gid]["children"].sort(key=key)


def target_settings(debug):
    defs = ["HAVE_C68K", "C68K_NO_JUMP_TABLE", "TARGET_IOS"]
    if debug:
        defs = ["DEBUG=1", "$(inherited)"] + defs
    settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon-iOS",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "DQR9HH7KUY",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_PREPROCESSOR_DEFINITIONS": defs,
        "INFOPLIST_FILE": f"{IOS_DIR}/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "NANKIN.MPX68K-iOS",
        "PRODUCT_MODULE_NAME": "X68000",
        "PRODUCT_NAME": "MPX68K",
        "SDKROOT": "iphoneos",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_OBJC_BRIDGING_HEADER": "X68000 Shared/px68k/fmgen/X68000 macOS-Bridging-Header.h",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "VERSIONING_SYSTEM": "apple-generic",
    }
    if debug:
        settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
    return settings


def project_settings(debug):
    settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14",
        "CLANG_CXX_LIBRARY": "libc++",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEAD_CODE_STRIPPING": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu11",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "SDKROOT": "iphoneos",
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    }
    if debug:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        })
    else:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "VALIDATE_PRODUCT": "YES",
        })
    return settings


def config_list(builder, owner, settings_fn):
    ids = []
    for name, debug in (("Debug", True), ("Release", False)):
        cid = object_id("config", owner, name)
        builder.objects[cid] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": settings_fn(debug),
            "name": name,
        }
        ids.append(cid)
    lid = object_id("config-list", owner)
    builder.objects[lid] = {
        "isa": "XCConfigurationList",
        "buildConfigurations": ids,
        "defaultConfigurationIsVisible": "0",
        "defaultConfigurationName": "Release",
    }
    return lid


def main():
    missing = [p for p in IOS_SOURCES + IOS_RESOURCES + IOS_VARIANT_RESOURCES + IOS_REFERENCE_ONLY + C68K_SOURCES
               if not os.path.exists(os.path.join(ROOT, p))]
    if missing:
        sys.exit("missing files: " + ", ".join(missing))

    mac_sources, mac_resources, mac_headers = mac_build_files(load_pbxproj(MAC_PROJECT))
    builder = ProjectBuilder()

    source_ids = []
    for path, flags in mac_sources + [(p, None) for p in IOS_SOURCES] + [(p, C68K_FLAGS) for p in C68K_SOURCES]:
        source_ids.append(builder.build_file("sources", builder.file_ref(path), path, flags))

    resource_ids = []
    for path, _ in mac_resources + [(p, None) for p in IOS_RESOURCES]:
        resource_ids.append(builder.build_file("resources", builder.file_ref(path), path))
    for path in IOS_VARIANT_RESOURCES:
        resource_ids.append(builder.build_file("resources", builder.variant_group(path), path))
    for path in IOS_REFERENCE_ONLY + mac_headers:
        builder.file_ref(path)
    builder.file_ref("X68000 Shared/px68k/fmgen/X68000 macOS-Bridging-Header.h")

    # Products
    products_group = object_id("group", "<products>")
    product_ref = object_id("product", IOS_TARGET_NAME)
    builder.objects[product_ref] = {
        "isa": "PBXFileReference", "explicitFileType": "wrapper.application",
        "includeInIndex": "0", "path": "MPX68K.app", "sourceTree": "BUILT_PRODUCTS_DIR",
    }
    builder.objects[products_group] = {
        "isa": "PBXGroup", "children": [product_ref], "name": "Products", "sourceTree": "<group>",
    }
    builder.sort_groups()
    builder.objects[builder.main_group]["children"].append(products_group)

    sources_phase = object_id("phase", "sources")
    builder.objects[sources_phase] = {
        "isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
        "files": source_ids, "runOnlyForDeploymentPostprocessing": "0",
    }
    frameworks_phase = object_id("phase", "frameworks")
    builder.objects[frameworks_phase] = {
        "isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647",
        "files": [], "runOnlyForDeploymentPostprocessing": "0",
    }
    resources_phase = object_id("phase", "resources")
    builder.objects[resources_phase] = {
        "isa": "PBXResourcesBuildPhase", "buildActionMask": "2147483647",
        "files": resource_ids, "runOnlyForDeploymentPostprocessing": "0",
    }

    target_id = object_id("target", IOS_TARGET_NAME)
    builder.objects[target_id] = {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": config_list(builder, "target", target_settings),
        "buildPhases": [sources_phase, frameworks_phase, resources_phase],
        "buildRules": [],
        "dependencies": [],
        "name": IOS_TARGET_NAME,
        "productName": IOS_TARGET_NAME,
        "productReference": product_ref,
        "productType": "com.apple.product-type.application",
    }

    project_id = object_id("project")
    builder.objects[project_id] = {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": "YES",
            "LastSwiftUpdateCheck": "2700",
            "LastUpgradeCheck": "2700",
            "ORGANIZATIONNAME": "NANKIN",
        },
        "buildConfigurationList": config_list(builder, "project", project_settings),
        "developmentRegion": "en",
        "hasScannedForEncodings": "0",
        "knownRegions": ["en", "Base"],
        "mainGroup": builder.main_group,
        "minimizedProjectReferenceProxies": "1",
        "preferredProjectObjectVersion": "77",
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [target_id],
    }

    body = ["// !$*UTF8*$!", "{",
            "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;",
            "\tobjects = {"]
    for oid in sorted(builder.objects, key=lambda i: (builder.objects[i]["isa"], i)):
        body.append(f"\t\t{oid} = {write_value(builder.objects[oid], 2)};")
    body += ["\t};", f"\trootObject = {project_id};", "}", ""]

    os.makedirs(IOS_PROJECT_DIR, exist_ok=True)
    with open(os.path.join(IOS_PROJECT_DIR, "project.pbxproj"), "w", encoding="utf-8") as f:
        f.write("\n".join(body))
    write_scheme(target_id)
    print(f"wrote {os.path.relpath(IOS_PROJECT_DIR, ROOT)}: "
          f"{len(source_ids)} sources, {len(resource_ids)} resources")


def write_scheme(target_id):
    scheme_dir = os.path.join(IOS_PROJECT_DIR, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    ref = (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" '
           f'BuildableName = "MPX68K.app" BlueprintName = "{IOS_TARGET_NAME}" '
           f'ReferencedContainer = "container:MPX68K iOS.xcodeproj"></BuildableReference>')
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(os.path.join(scheme_dir, f"{IOS_TARGET_NAME}.xcscheme"), "w", encoding="utf-8") as f:
        f.write(scheme)


if __name__ == "__main__":
    main()
