#!/usr/bin/env bash
#
# gemini-smoke-test.sh — isolate the Gemini API path from the IME / mic.
#
# Replicates GeminiClient.transcribe / cleanup's exact generateContent request
# with curl, so you can see the raw HTTP status + body. Use this to tell apart
# "the backend/model/key is wrong" from "the app wiring is wrong".
#
# Key lookup (first hit wins), mirrors GeminiSecrets:
#   1. $1 if it looks like a key, or --key <k>
#   2. $GEMINI_API_KEY / $GOOGLE_API_KEY / $GOOGLE_GENAI_API_KEY
#   3. ~/Library/Rime/.env then ~/.env  (GEMINI_API_KEY=...)
#
# Usage:
#   scripts/gemini-smoke-test.sh models                  # list model ids your key can use
#   scripts/gemini-smoke-test.sh transcribe AUDIO [MODEL] # transcribe a .m4a/.wav file
#   scripts/gemini-smoke-test.sh cleanup "原始文字" [MODEL]
#   GEMINI_API_KEY=... scripts/gemini-smoke-test.sh models
#
set -uo pipefail
BASE="https://generativelanguage.googleapis.com/v1beta"

resolve_key() {
  for v in "${GEMINI_API_KEY:-}" "${GOOGLE_API_KEY:-}" "${GOOGLE_GENAI_API_KEY:-}"; do
    [ -n "$v" ] && { echo "$v"; return; }
  done
  for f in "$HOME/Library/Rime/.env" "$HOME/.env"; do
    [ -f "$f" ] || continue
    k=$(grep -E '^(export +)?(GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_GENAI_API_KEY)=' "$f" \
        | head -1 | sed -E 's/^(export +)?[A-Z_]+=//; s/^["'"'"']//; s/["'"'"']$//')
    [ -n "${k:-}" ] && { echo "$k"; return; }
  done
}

KEY="$(resolve_key)"
if [ -z "${KEY:-}" ]; then
  echo "✗ No Gemini key found. Set GEMINI_API_KEY=... or put it in ~/Library/Rime/.env" >&2
  exit 1
fi
echo "• key: ${KEY:0:6}…${KEY: -4} (len ${#KEY})" >&2

cmd="${1:-models}"
case "$cmd" in
  models)
    # Reveals exactly which model ids are valid for THIS key — the fast way to
    # catch a wrong/stale default model id (404 model not found).
    echo "• GET $BASE/models" >&2
    curl -sS "$BASE/models?key=$KEY&pageSize=200" \
      | /usr/bin/python3 -c '
import sys,json
d=json.load(sys.stdin)
ms=d.get("models",[])
if not ms: print(json.dumps(d,ensure_ascii=False,indent=2)); sys.exit()
for m in ms:
    methods=m.get("supportedGenerationMethods",[])
    if "generateContent" in methods:
        print(m["name"].replace("models/",""))
'
    ;;

  transcribe)
    AUDIO="${2:?usage: transcribe AUDIO [MODEL]}"
    MODEL="${3:-gemini-2.5-flash}"
    [ -f "$AUDIO" ] || { echo "✗ no such file: $AUDIO" >&2; exit 1; }
    case "$AUDIO" in *.wav) MIME="audio/wav";; *) MIME="audio/mp4";; esac
    B64=$(base64 < "$AUDIO" | tr -d '\n')
    INSTR='Transcribe this audio verbatim. The spoken language is "zh". Keep the original language — do not translate. Output only the transcript text with no quotes, labels, or commentary. If the audio is empty or unintelligible, output an empty string.'
    PAYLOAD=$(/usr/bin/python3 -c '
import json,sys
instr,mime,b64=sys.argv[1],sys.argv[2],sys.argv[3]
print(json.dumps({"contents":[{"role":"user","parts":[{"text":instr},{"inline_data":{"mime_type":mime,"data":b64}}]}],"generationConfig":{"temperature":0}}))
' "$INSTR" "$MIME" "$B64")
    echo "• POST $BASE/models/$MODEL:generateContent  (audio=$AUDIO mime=$MIME)" >&2
    printf '%s' "$PAYLOAD" | curl -sS -w '\n--- HTTP %{http_code} ---\n' \
      -H 'Content-Type: application/json' -X POST \
      "$BASE/models/$MODEL:generateContent?key=$KEY" --data-binary @-
    ;;

  cleanup)
    RAW="${2:?usage: cleanup \"text\" [MODEL]}"
    MODEL="${3:-gemini-2.5-flash}"
    MSG="你是逐字稿整理助手。只輸出整理後的結果。

$RAW"
    PAYLOAD=$(/usr/bin/python3 -c '
import json,sys
print(json.dumps({"contents":[{"role":"user","parts":[{"text":sys.argv[1]}]}],"generationConfig":{"temperature":0.2}}))
' "$MSG")
    echo "• POST $BASE/models/$MODEL:generateContent  (cleanup)" >&2
    printf '%s' "$PAYLOAD" | curl -sS -w '\n--- HTTP %{http_code} ---\n' \
      -H 'Content-Type: application/json' -X POST \
      "$BASE/models/$MODEL:generateContent?key=$KEY" --data-binary @-
    ;;

  *) echo "usage: $0 {models|transcribe AUDIO [MODEL]|cleanup TEXT [MODEL]}" >&2; exit 2;;
esac
