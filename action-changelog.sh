#!/usr/bin/env bash
# Release-notes changelog body. Prefers git-cliff (commits grouped by
# feat/fix/doc/… per cliff.toml); falls back to a flat commit list when
# git-cliff isn't installed. The release-notes template (custom-dmg.yml) adds
# the title + install footer, so this emits only the changelog body — the
# per-version "## <version>" header and <a name> anchor are stripped.

current=$(git describe --tags --abbrev=0)
previous=$(git describe --always --abbrev=0 --tags "${current}^" 2>/dev/null || true)
range="${previous:+${previous}..}${current}"

if command -v git-cliff >/dev/null 2>&1; then
  git-cliff --config cliff.toml "$range" 2>/dev/null \
    | sed -e '/^<a name=/d' -e '/^## /d' \
    | awk 'NF{f=1} f'
else
  echo "**Change log since ${previous:-the beginning}:**"
  echo
  git log --oneline --decorate "$range" --pretty="format:- %h %s" | grep -v Merge
fi
