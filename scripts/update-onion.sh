#!/bin/bash
# Refresh data/onion/ from the Onion_Rime_Files checkout (SPEC §13.6 / M-B2).
#
# Curation = the dependency closure of bopomo_onionplus + the four bopomo
# mix-in schemas (SPEC §13.3 / §22):
#   main schema + 11 dependency schemas + their dicts / __include phrases
#   + bo_mixin1–4 (+ their mix-in dicts/essay, deps shared with onionplus)
#   + lua/ + opencc/ + essay .gram models + grammar.yaml
# Excluded: easy_en_super* (disabled in the schema), *_original backups,
# and the other onion families (terra/array/double, ocm_mixin shrimp/shape).
#
# Usage: scripts/update-onion.sh [path-to-Onion_Rime_Files]
# After running, re-run scripts/add-onion-files.py to register new files.

set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-../Onion_Rime_Files}"
RIMEFILES="$SRC/rimefiles"
SHARED="$SRC/squirrel_compile_files/SharedSupport"
DST="data/onion"

test -d "$RIMEFILES" || { echo "error: $RIMEFILES not found" >&2; exit 1; }
test -d "$SHARED" || { echo "error: $SHARED not found" >&2; exit 1; }

mkdir -p "$DST"

# bopomo_onionplus dependency closure — root files (schemas, dicts, phrases).
FILES=(
  # main schema (deps: symbols_bpmf cangjie5 easy_en_lower easy_en_upper
  # latinin1 jpnin1 hangeul_hnc greek cyrillic allbpm fullshape)
  bopomo_onionplus.schema.yaml
  bopomo_onionplus_space.schema.yaml
  bopomo_onionplus.extended.dict.yaml
  bopomo_onionplus_phrase.txt
  # bopomo mix-in schemas 1–4 (SPEC §22) — deps are the onionplus closure;
  # increment is the schemas + bo_mixin.* dicts + mix-in essay.
  bo_mixin1.schema.yaml
  bo_mixin2.schema.yaml
  bo_mixin3.schema.yaml
  bo_mixin4.schema.yaml
  bo_mixin.extended.dict.yaml
  bo_mixin_la.dict.yaml
  bo_mixin_jp.dict.yaml
  bo_mixin_kr_hnc.dict.yaml
  bo_mixin_en.dict.yaml
  bo_mixin_kr.dict.yaml
  bo_mixin_phrase.txt
  essay-zh-hant-mc-mixin.txt
  # extra import_tables bo_mixin.extended pulls in beyond the onionplus closure
  phrases.cht_en_w.dict.yaml
  phrases.jp_hk.dict.yaml
  phrases.jp_hkkreduce.dict.yaml
  phrases.kr.dict.yaml
  element_bopomo.yaml
  punct_bopomo.yaml
  phrases.chtp.dict.yaml
  lua_custom_phrase.txt
  mixin_bpmf.dict.yaml
  space.dict.yaml
  space_f.dict.yaml
  terra_pinyin_onion.dict.yaml
  terra_pinyin_onion_add.dict.yaml
  # symbols / full bopomofo
  symbols_bpmf.schema.yaml
  symbols_bpmf.dict.yaml
  allbpm.schema.yaml
  allbpm.dict.yaml
  # cangjie reverse lookup (onion-modified; overrides the plum copy)
  cangjie5.schema.yaml
  cangjie5.dict.yaml
  # English (easy_en_super* deliberately excluded — disabled in the schema)
  easy_en_lower.schema.yaml
  easy_en_lower.dict.yaml
  easy_en_upper.schema.yaml
  easy_en_upper.dict.yaml
  easy_en_lcomment.dict.yaml
  phrases.en_l_w.dict.yaml
  phrases.en_o_w.dict.yaml
  phrases.en_u_w.dict.yaml
  # Latin
  latinin1.schema.yaml
  latinin1.dict.yaml
  latinin1.extended.dict.yaml
  phrases.la_eu_w.dict.yaml
  phrases.la_py_w.dict.yaml
  # Japanese
  jpnin1.schema.yaml
  jpnin1.dict.yaml
  jpnin1.extended.dict.yaml
  phrases.jp_hkkseg.dict.yaml
  phrases.jp_hk_more.dict.yaml
  # Korean
  hangeul_hnc.schema.yaml
  hangeul_hnc.dict.yaml
  hangeul_hnc.extended.dict.yaml
  hangeul_hnc_hanja.dict.yaml
  # Greek / Cyrillic / fullshape
  greek.schema.yaml
  greek.dict.yaml
  greek.extended.dict.yaml
  phrases.gr_all.dict.yaml
  cyrillic.schema.yaml
  cyrillic.dict.yaml
  cyrillic.extended.dict.yaml
  phrases.cyr_all.dict.yaml
  fullshape.schema.yaml
  fullshape.dict.yaml
  fullshape.extended.dict.yaml
  phrases.fs_all.dict.yaml
  # essay supplements
  essay-jp-onion.txt
  essay-kr-hanja.txt
  essay-zh-hant-mc.txt
  # lua entry point
  rime.lua
)

missing=0
for f in "${FILES[@]}"; do
  if [[ -f "$RIMEFILES/$f" ]]; then
    cp "$RIMEFILES/$f" "$DST/"
  else
    echo "MISSING upstream: $f" >&2
    missing=1
  fi
done

# lua processors / opencc data (whole directories, minus backups).
rsync -a --delete --exclude '*_original*' "$RIMEFILES/lua/" "$DST/lua/"
rsync -a --delete --exclude '*_original*' "$RIMEFILES/opencc/" "$DST/opencc/"

# essay grammar models (Squirrel-specific assets).
cp "$SHARED"/*.gram "$SHARED/grammar.yaml" "$DST/"

# default schema list (ours, not upstream's all-schemas variant).
if [[ ! -f "$DST/default.custom.yaml" ]]; then
  cat > "$DST/default.custom.yaml" <<'YAML'
# 洋蔥注音預設方案清單（本客製版內建，SPEC §13.5 / §22）
# 第一項為預設方案；偏好設定 UI 可改寫順序（選中者排第一）後重新部署。
patch:
  schema_list:
    - schema: bopomo_onionplus
    - schema: bopomo_onionplus_space
    - schema: bo_mixin1
    - schema: bo_mixin2
    - schema: bo_mixin3
    - schema: bo_mixin4
    - schema: terra_pinyin
YAML
fi

echo "done → $DST ($(du -sh "$DST" | cut -f1)); missing=$missing"
echo "next: python3 scripts/add-onion-files.py && make release"
exit $missing
