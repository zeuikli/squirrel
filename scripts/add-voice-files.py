#!/usr/bin/env python3
"""Add sources/Voice/*.swift and sources/Settings/*.swift to the Squirrel
Xcode target.

The project does not use Xcode 16 folder-synchronized groups, so new sources
must be registered in project.pbxproj explicitly. Idempotent: files already
present are skipped. Requires `pip3 install pbxproj`.
"""
import glob
import os
import sys

from pbxproj import XcodeProject

ROOT = os.path.join(os.path.dirname(__file__), "..")
PROJECT = os.path.join(ROOT, "Squirrel.xcodeproj", "project.pbxproj")
SOURCE_DIRS = ["Voice", "Settings"]


def main():
    project = XcodeProject.load(PROJECT)

    sources_groups = project.get_groups_by_name("Sources")
    if not sources_groups:
        sys.exit("error: 'Sources' group not found")
    sources_group = sources_groups[0]

    added, skipped = [], []
    for dirname in SOURCE_DIRS:
        group = project.get_or_create_group(dirname, parent=sources_group)
        for path in sorted(glob.glob(os.path.join(ROOT, "sources", dirname, "*.swift"))):
            rel = os.path.relpath(path, ROOT)
            name = os.path.basename(rel)
            if project.get_files_by_name(name):
                skipped.append(name)
                continue
            refs = project.add_file(rel, parent=group, target_name="Squirrel", force=False)
            (added if refs else skipped).append(name)

    project.save()
    print(f"added: {added}")
    print(f"skipped (already present): {skipped}")


if __name__ == "__main__":
    main()
