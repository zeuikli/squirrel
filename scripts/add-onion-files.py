#!/usr/bin/env python3
"""Register data/onion/ in the Xcode copy phases so the Onion (洋蔥)
bopomo_onionplus data ships inside Squirrel.app/Contents/SharedSupport/
(SPEC §13.2–13.3).

 - data/onion/<root files>      → "Copy Shared Support Files" phase
 - data/onion/lua  (folder ref) → same phase (copied as SharedSupport/lua/)
 - data/onion/opencc/*          → "Copy opencc Files" phase (→ SharedSupport/opencc/)

Idempotent: entries already present (matched by file name) are skipped.
Requires `pip3 install pbxproj`.
"""
import os
import sys

from pbxproj import XcodeProject
from pbxproj.pbxsections.PBXBuildFile import PBXBuildFile
from pbxproj.pbxsections.PBXFileReference import PBXFileReference

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
PROJECT = os.path.join(ROOT, "Squirrel.xcodeproj", "project.pbxproj")
ONION = os.path.join(ROOT, "data", "onion")

SHARED_SUPPORT_PHASE = "44DA7A1614DD581B00C1ED3B"   # Copy Shared Support Files
OPENCC_PHASE = "4407F3CA14EC079A001329FE"           # Copy opencc Files


def add_to_phase(project, group, phase, rel_path, file_type=None):
    name = os.path.basename(rel_path)
    if project.get_files_by_name(name):
        return False
    ref = PBXFileReference.create(rel_path, tree="SOURCE_ROOT")
    ref["name"] = name
    if file_type:
        ref["lastKnownFileType"] = file_type
    project.objects[ref.get_id()] = ref
    group.add_child(ref)
    build_file = PBXBuildFile.create(ref)
    project.objects[build_file.get_id()] = build_file
    phase.add_build_file(build_file)
    return True


def main():
    if not os.path.isdir(ONION):
        sys.exit(f"error: {ONION} not found")
    project = XcodeProject.load(PROJECT)

    shared_phase = project.objects[SHARED_SUPPORT_PHASE]
    opencc_phase = project.objects[OPENCC_PHASE]
    if shared_phase is None or opencc_phase is None:
        sys.exit("error: expected copy phases not found in project.pbxproj")

    group = project.get_or_create_group("OnionData")

    added, skipped = [], []

    # Root files → SharedSupport. The lua/ folder ships as a folder reference.
    for entry in sorted(os.listdir(ONION)):
        full = os.path.join(ONION, entry)
        rel = os.path.join("data", "onion", entry)
        if entry == "opencc":
            continue
        if entry == "lua":
            ok = add_to_phase(project, group, shared_phase, rel, file_type="folder")
        elif os.path.isfile(full):
            ok = add_to_phase(project, group, shared_phase, rel)
        else:
            continue
        (added if ok else skipped).append(entry)

    # opencc data → SharedSupport/opencc (skip docs).
    for entry in sorted(os.listdir(os.path.join(ONION, "opencc"))):
        if entry == "README.md":
            continue
        rel = os.path.join("data", "onion", "opencc", entry)
        ok = add_to_phase(project, group, opencc_phase, rel)
        (added if ok else skipped).append(f"opencc/{entry}")

    project.save()
    print(f"added ({len(added)}): {added}")
    print(f"skipped ({len(skipped)}): {skipped}")


if __name__ == "__main__":
    main()
