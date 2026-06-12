#!/usr/bin/env python3
"""Generates Xcode project for ForceFinder."""

import os
from pathlib import Path

ROOT = Path("/home/claude/ForceFinder")
PROJECT_NAME = "ForceFinder"
PROJ_DIR = ROOT / f"{PROJECT_NAME}.xcodeproj"
SRC_ROOT = ROOT / PROJECT_NAME

def gather_sources():
    return [str(p.relative_to(SRC_ROOT)) for p in sorted(SRC_ROOT.rglob("*.swift"))]

counter = [0]
def gid(seed):
    counter[0] += 1
    h = abs(hash((seed, counter[0]))) % (1 << 96)
    return f"{h:024X}"

sources = gather_sources()
print("Found Swift sources:")
for s in sources: print("  ", s)

ids = {}
def make(name):
    if name not in ids: ids[name] = gid(name)
    return ids[name]

file_ids = {}
for s in sources:
    file_ids[s] = (make(f"FILE_REF::{s}"), make(f"BUILD_FILE::{s}"))

INFO_PLIST_ID  = make("FILE_REF::Info.plist")
ENTL_ID        = make("FILE_REF::ForceFinder.entitlements")
ASSETS_REF_ID  = make("FILE_REF::Assets.xcassets")
ASSETS_BLD_ID  = make("BUILD_FILE::Assets.xcassets")

GRP_MAIN       = make("GROUP::MAIN")
GRP_PRODUCTS   = make("GROUP::PRODUCTS")
GRP_TRANSMIT   = make("GROUP::ForceFinder")
GRP_MODELS     = make("GROUP::Models")
GRP_VIEWS      = make("GROUP::Views")
GRP_SERVICES   = make("GROUP::Services")

PHASE_SRC      = make("PHASE::Sources")
PHASE_RES      = make("PHASE::Resources")
PHASE_FRA      = make("PHASE::Frameworks")
TARGET_ID      = make("TARGET::App")
PROJECT_ID     = make("PROJECT::Root")
PROD_REF_ID    = make("PRODUCT::App")

CFG_DBG_PROJ   = make("CFG::Debug::Project")
CFG_REL_PROJ   = make("CFG::Release::Project")
CFG_DBG_TGT    = make("CFG::Debug::Target")
CFG_REL_TGT    = make("CFG::Release::Target")
CFG_LIST_PROJ  = make("CFGLIST::Project")
CFG_LIST_TGT   = make("CFGLIST::Target")

groups = {"Models": [], "Views": [], "Services": [], "_root": []}
for s in sources:
    parts = s.split("/")
    if len(parts) == 1: groups["_root"].append(s)
    else: groups.setdefault(parts[0], []).append(s)

sub_group_ids = {"Models": GRP_MODELS, "Views": GRP_VIEWS, "Services": GRP_SERVICES}

def section_file_refs():
    lines = ["/* Begin PBXFileReference section */"]
    for s, (ref_id, _) in file_ids.items():
        name = s.split("/")[-1]
        lines.append(
            f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; '
            f'name = "{name}"; path = "{s}"; sourceTree = "<group>"; }};'
        )
    lines.append(
        f'\t\t{INFO_PLIST_ID} /* Info.plist */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};'
    )
    lines.append(
        f'\t\t{ENTL_ID} /* ForceFinder.entitlements */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = text.plist.entitlements; path = ForceFinder.entitlements; sourceTree = "<group>"; }};'
    )
    lines.append(
        f'\t\t{ASSETS_REF_ID} /* Assets.xcassets */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};'
    )
    lines.append(
        f'\t\t{PROD_REF_ID} /* ForceFinder.app */ = {{isa = PBXFileReference; '
        f'explicitFileType = wrapper.application; includeInIndex = 0; '
        f'path = ForceFinder.app; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    lines.append("/* End PBXFileReference section */")
    return "\n".join(lines)

def section_build_files():
    lines = ["/* Begin PBXBuildFile section */"]
    for s, (ref_id, bld_id) in file_ids.items():
        name = s.split("/")[-1]
        lines.append(
            f'\t\t{bld_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
            f'fileRef = {ref_id} /* {name} */; }};'
        )
    lines.append(
        f'\t\t{ASSETS_BLD_ID} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; '
        f'fileRef = {ASSETS_REF_ID} /* Assets.xcassets */; }};'
    )
    lines.append("/* End PBXBuildFile section */")
    return "\n".join(lines)

def section_groups():
    lines = ["/* Begin PBXGroup section */"]

    lines.append(f'\t\t{GRP_MAIN} = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{GRP_TRANSMIT} /* ForceFinder */,')
    lines.append(f'\t\t\t\t{GRP_PRODUCTS} /* Products */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')

    lines.append(f'\t\t{GRP_PRODUCTS} /* Products */ = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{PROD_REF_ID} /* ForceFinder.app */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tname = Products;')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')

    lines.append(f'\t\t{GRP_TRANSMIT} /* ForceFinder */ = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    for s in groups["_root"]:
        ref_id = file_ids[s][0]
        name = s.split("/")[-1]
        lines.append(f'\t\t\t\t{ref_id} /* {name} */,')
    for sub in ["Models", "Views", "Services"]:
        if sub in sub_group_ids:
            lines.append(f'\t\t\t\t{sub_group_ids[sub]} /* {sub} */,')
    lines.append(f'\t\t\t\t{ASSETS_REF_ID} /* Assets.xcassets */,')
    lines.append(f'\t\t\t\t{INFO_PLIST_ID} /* Info.plist */,')
    lines.append(f'\t\t\t\t{ENTL_ID} /* ForceFinder.entitlements */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tpath = ForceFinder;')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')

    for sub, gid_ in sub_group_ids.items():
        lines.append(f'\t\t{gid_} /* {sub} */ = {{')
        lines.append(f'\t\t\tisa = PBXGroup;')
        lines.append(f'\t\t\tchildren = (')
        for s in groups.get(sub, []):
            ref_id = file_ids[s][0]
            name = s.split("/")[-1]
            lines.append(f'\t\t\t\t{ref_id} /* {name} */,')
        lines.append(f'\t\t\t);')
        lines.append(f'\t\t\tpath = {sub};')
        lines.append(f'\t\t\tsourceTree = "<group>";')
        lines.append(f'\t\t}};')

    lines.append("/* End PBXGroup section */")
    return "\n".join(lines)

def section_sources_phase():
    lines = ["/* Begin PBXSourcesBuildPhase section */"]
    lines.append(f'\t\t{PHASE_SRC} /* Sources */ = {{')
    lines.append(f'\t\t\tisa = PBXSourcesBuildPhase;')
    lines.append(f'\t\t\tbuildActionMask = 2147483647;')
    lines.append(f'\t\t\tfiles = (')
    for s, (_, bld_id) in file_ids.items():
        name = s.split("/")[-1]
        lines.append(f'\t\t\t\t{bld_id} /* {name} in Sources */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    lines.append(f'\t\t}};')
    lines.append("/* End PBXSourcesBuildPhase section */")
    return "\n".join(lines)

def section_resources_phase():
    return f"""/* Begin PBXResourcesBuildPhase section */
\t\t{PHASE_RES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ASSETS_BLD_ID} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */"""

def section_frameworks_phase():
    return f"""/* Begin PBXFrameworksBuildPhase section */
\t\t{PHASE_FRA} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */"""

def section_target():
    return f"""/* Begin PBXNativeTarget section */
\t\t{TARGET_ID} /* ForceFinder */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "ForceFinder" */;
\t\t\tbuildPhases = (
\t\t\t\t{PHASE_SRC} /* Sources */,
\t\t\t\t{PHASE_FRA} /* Frameworks */,
\t\t\t\t{PHASE_RES} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = ForceFinder;
\t\t\tproductName = ForceFinder;
\t\t\tproductReference = {PROD_REF_ID} /* ForceFinder.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */"""

def section_project():
    return f"""/* Begin PBXProject section */
\t\t{PROJECT_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{TARGET_ID} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {CFG_LIST_PROJ} /* Build configuration list for PBXProject "ForceFinder" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = ko;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tko,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {GRP_MAIN};
\t\t\tproductRefGroup = {GRP_PRODUCTS} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TARGET_ID} /* ForceFinder */,
\t\t\t);
\t\t}};
/* End PBXProject section */"""

def section_build_configurations():
    common_settings = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
"""
    debug_proj = f"""\t\t{CFG_DBG_PROJ} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common_settings}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};"""

    release_proj = f"""\t\t{CFG_REL_PROJ} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common_settings}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t}};
\t\t\tname = Release;
\t\t}};"""

    target_settings = """\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = ForceFinder/ForceFinder.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 2;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = ForceFinder/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.1;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.example.ForceFinder";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
"""

    debug_tgt = f"""\t\t{CFG_DBG_TGT} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{target_settings}\t\t\t}};
\t\t\tname = Debug;
\t\t}};"""

    release_tgt = f"""\t\t{CFG_REL_TGT} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{target_settings}\t\t\t}};
\t\t\tname = Release;
\t\t}};"""

    return "/* Begin XCBuildConfiguration section */\n" + \
           "\n".join([debug_proj, release_proj, debug_tgt, release_tgt]) + \
           "\n/* End XCBuildConfiguration section */"

def section_configuration_lists():
    return f"""/* Begin XCConfigurationList section */
\t\t{CFG_LIST_PROJ} /* Build configuration list for PBXProject "ForceFinder" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_DBG_PROJ} /* Debug */,
\t\t\t\t{CFG_REL_PROJ} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "ForceFinder" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_DBG_TGT} /* Debug */,
\t\t\t\t{CFG_REL_TGT} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */"""

def write_project():
    body = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

{section_build_files()}

{section_file_refs()}

{section_frameworks_phase()}

{section_groups()}

{section_target()}

{section_project()}

{section_resources_phase()}

{section_sources_phase()}

{section_build_configurations()}

{section_configuration_lists()}

\t}};
\trootObject = {PROJECT_ID} /* Project object */;
}}
"""
    PROJ_DIR.mkdir(parents=True, exist_ok=True)
    (PROJ_DIR / "project.pbxproj").write_text(body, encoding="utf-8")

    wsdir = PROJ_DIR / "project.xcworkspace"
    wsdir.mkdir(exist_ok=True)
    (wsdir / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version = "1.0">\n'
        '  <FileRef location = "self:">\n'
        '  </FileRef>\n'
        '</Workspace>\n',
        encoding="utf-8"
    )
    shared = wsdir / "xcshareddata"
    shared.mkdir(exist_ok=True)
    (shared / "WorkspaceSettings.xcsettings").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        '<key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key><false/>\n'
        '</dict></plist>\n', encoding="utf-8"
    )
    print(f"Wrote {PROJ_DIR / 'project.pbxproj'}")

write_project()
