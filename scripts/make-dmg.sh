#!/bin/bash
# Assemble a distributable DMG of the customized Squirrel (SPEC §17).
#
# Pipeline: copy the Release build → verify the seal → stage app +
# INSTALL.md + install.sh → hdiutil. No prebuild inside the bundle
# (SPEC §17.3): schemas compile into ~/Library/Rime/build on the user's
# first deploy (one-time, 1–2 min), keeping the bundle read-only and the
# signature seal intact forever.
#
# Usage: scripts/make-dmg.sh [output.dmg]
#   SIGN_IDENTITY env var overrides the signing identity
#   (default: "Squirrel Dev Signing").
#
# ⚠️ The DMG bundles the Onion (洋蔥) lexicon (~180MB) — personal/internal
# use only; public distribution requires the upstream author's permission
# (SPEC §13.9).

set -euo pipefail

cd "$(dirname "$0")/.."
APP_SRC="build/Build/Products/Release/Squirrel.app"
OUT="${1:-package/Squirrel-custom.dmg}"
IDENTITY="${SIGN_IDENTITY:-Squirrel Dev Signing}"
VOLNAME="Squirrel 鼠鬚管（語音版）"
# Stage inside the repo: hdiutil sporadically reports "No space left on
# device" when the source folder lives under /var/folders tmp.
mkdir -p package
STAGING="$(mktemp -d "$PWD/package/staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

test -d "$APP_SRC" || { echo "error: $APP_SRC not found — run: make release SIGN_IDENTITY=\"$IDENTITY\"" >&2; exit 1; }
test -f INSTALL-zh.md || { echo "error: INSTALL-zh.md not found at repo root" >&2; exit 1; }

echo "[1/5] staging app…"
cp -R "$APP_SRC" "$STAGING/Squirrel.app"

echo "[2/5] ensuring no prebuild artifacts in the bundle (SPEC §17.3)…"
rm -rf "$STAGING/Squirrel.app/Contents/SharedSupport/build"

echo "[3/5] verifying signature seal…"
codesign --verify --deep "$STAGING/Squirrel.app" 2>/dev/null || {
  echo "  seal invalid (stale build?) — re-signing…"
  codesign --force --deep -s "$IDENTITY" "$STAGING/Squirrel.app"
  codesign --verify --deep "$STAGING/Squirrel.app" || { echo "error: seal verification failed" >&2; exit 1; }
}

echo "[4/5] staging docs + installer…"
cp INSTALL-zh.md "$STAGING/安裝說明 INSTALL.md"
cat > "$STAGING/install.sh" <<'INSTALLER'
#!/bin/bash
# Squirrel（語音版）自動安裝：複製 → 清 quarantine → 註冊 → 啟用。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/Squirrel.app"
DST="$HOME/Library/Input Methods/Squirrel.app"
test -d "$SRC" || { echo "找不到 Squirrel.app（請整個 DMG 內容一起執行）"; exit 1; }

echo "→ 停止運行中的鼠鬚管…"
killall Squirrel 2>/dev/null || true
sleep 1

if [ -d "$DST" ]; then
  if mv "$DST" "$HOME/.Trash/Squirrel.app.$(date +%H%M%S)" 2>/dev/null; then
    echo "→ 已備份既有版本到垃圾桶"
  else
    echo "→ 無法移到垃圾桶（權限受限），直接移除既有版本"
    rm -rf "$DST"
  fi
fi

echo "→ 安裝到 ~/Library/Input Methods …"
mkdir -p "$HOME/Library/Input Methods"
cp -R "$SRC" "$DST"

echo "→ 清除下載隔離屬性（quarantine）…"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true

echo "→ 註冊並啟用輸入法…"
"$DST/Contents/MacOS/Squirrel" --register-input-source || true
"$DST/Contents/MacOS/Squirrel" --enable-input-source || true

echo "→ 切回鼠鬚管並重整選單列圖示…"
"$DST/Contents/MacOS/Squirrel" --select-input-source || true
killall TextInputMenuAgent 2>/dev/null || true

echo ""
echo "✅ 安裝完成。"
echo "   1. 若選單列圖示未出現或輸入法清單沒有「鼠鬚管」→ 登出再登入一次"
echo "   2. 首次使用語音：按住右 ⌥ 講話 → 允許麥克風；系統設定開啟「輔助使用」的 Squirrel"
echo "   3. 右鍵輸入法選單 → Preferences… 設定 Groq API key 或登入 ChatGPT"
INSTALLER
chmod +x "$STAGING/install.sh"

echo "[5/5] creating DMG…"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# Explicit -size: hdiutil's auto size estimation fails with "No space left
# on device" on multi-hundred-MB source folders.
staging_mb=$(du -sm "$STAGING" | cut -f1)
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO \
  -size "$((staging_mb + 200))m" "$OUT" > /dev/null

du -sh "$OUT"
echo "done → $OUT"
