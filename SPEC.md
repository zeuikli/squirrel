# SPEC — Squirrel（語音版）Code Review 與修正紀錄

> 本文件由一次針對 Squirrel 主體與語音輸入版（Groq / ChatGPT / Gemini / OpenCC）的完整 Code Review 產出，記錄找到的**顯性 bug**、**深層／隱性 bug**，以及以「提高語音辨識精準度與易用性」為目標的**優化**。每一項都標註嚴重度、根因、失敗情境與採用的修正。分支：`claude/squirrel-voice-review-optimize-78lngw`。
>
> 審查範圍：`sources/`（IMK 主體、面板、繪圖、主題、設定）與 `sources/Voice/`（錄音、三個語音後端、熱鍵、OpenCC 橋接、設定 UI）、`data/squirrel.yaml` 的 `voice_input/*`、`.github/workflows/*`、`Squirrel.xcodeproj/project.pbxproj`、封裝腳本。

---

## 1. 摘要

| 編號 | 檔案 | 類別 | 嚴重度 | 狀態 |
|------|------|------|--------|------|
| C1 | Main.swift / InputSource.swift | 輸入法註冊路徑錯誤 | 高 | 已修 |
| C2 | BridgingFunctions.swift | librime `data_size` 少算 4 bytes | 中（潛在） | 已修 |
| C3 | Info.plist / InputSource.swift / make-dmg.sh | 反覆安裝殘留多個輸入法項（含未用的簡體） | 中 | 已修 |
| P1 | SquirrelPanel.swift | 運算子優先序 bug 使 `memorize_size:false` 失效 | 中 | 已修 |
| P2 | SquirrelPanel.swift | `inputController` 強參考延後 session 釋放 | 低 | 已修 |
| P3 | SquirrelPanel.swift | 空候選列產生負長度 `NSRange` | 低（潛在） | 已修 |
| V1 | VoiceInputController.swift | 快速點按熱鍵 → 錄音競態，錄到滿 60 秒 | 高 | 已修 |
| V2 | VoiceInputController.swift | `no_active_client: discard` 從未生效 | 中 | 已修 |
| V3 | GeminiWebBridge.swift | `recycleIfIdle()` 從未被呼叫（記憶體無上限） | 中 | 已修 |
| V4 | ChatGPTBridge.swift | `duration_ms` 恆為 5000，未傳真實時長 | 中 | 已修 |
| V5 | VoiceInputController.swift | `stop()` 未重設狀態，選單列麥克風圖示殘留 | 低 | 已修 |
| V6 | VoiceInputController.swift | IMK 遞送在重新聚焦前送出，可能落到別的視窗 | 低 | 已修 |
| V7 | SquirrelInputController.swift | 三個 NotificationCenter observer 未在 deinit 移除 | 低 | 已修 |
| V8 | VoiceConfig.swift | `voice_input/hotkey/modifiers` 有文件卻無人讀取 | 中 | 已修 |
| V9 | SquirrelApplicationDelegate.swift | 結束時以 `Task` 停止語音，teardown 期間可能不執行 | 低 | 已修 |
| CI1 | .github/workflows | PR／push 無建置驗證，只有打 tag 才 build | 高 | 已修 |
| O1–O7 | Voice/* | 辨識精準度與易用性優化 | — | 已做 |

---

## 2. 主體（Squirrel core）發現

### C1 — 輸入法註冊指向不存在的路徑（高）
`sources/Main.swift:18`
```swift
static let appDir = "/Library/Input Library/Squirrel.app"...
```
`SquirrelInstaller.register()`（`InputSource.swift:50`）以 `TISRegisterInputSource(SquirrelApp.appDir)` 註冊，但：
- 專案安裝路徑一律是 **`/Library/Input Methods`**（`project.pbxproj` `INSTALL_PATH`、`Makefile:164`、`package/make_package:7`）；
- DMG 安裝到 **`~/Library/Input Methods`**（`scripts/make-dmg.sh:54`）。

macOS 根本沒有 `/Library/Input Library` 這個目錄。`--register-input-source`（`scripts/postinstall`、`make-dmg.sh` 都會呼叫）因此以一個不存在的路徑註冊——只是因為 macOS 會自動掃描標準 Input Methods 目錄，症狀才被掩蓋。

**修正**：改用執行檔本身的實際位置 `Bundle.main.bundleURL`，對「系統層 pkg」與「使用者層 DMG」兩種安裝都正確。

### C2 — `RIME_STRUCT` 的 `data_size` 少算 4 bytes（中，潛在）
`sources/BridgingFunctions.swift:27`
```swift
let offset = MemoryLayout.size(ofValue: \Self.data_size)   // 取到的是 KeyPath 物件大小 = 8
value.data_size = Int32(MemoryLayout<Self>.size - offset)  // → size - 8
```
`\Self.data_size` 是一個 `WritableKeyPath` 物件（參考型別），`size(ofValue:)` 回傳的是指標大小（64-bit 上為 **8**），不是欄位 `Int32` 的 **4**。librime 的慣例是 `data_size = sizeof(Type) - sizeof(data_size)`（即 `size - 4`）。目前值小了 4 bytes，librime 的 `RIME_STRUCT_HAS_MEMBER` 會把「結尾最後 4 bytes 內的欄位」判為不存在而回傳零值。

**修正**：改為 `MemoryLayout<Int32>.size`（= 4），得到 `size - 4`，與 librime 約定一致。此修正只會讓 librime 認得「更完整」的結構，不會越界，安全。

### C3 — 反覆安裝殘留多個輸入法項，一部分還是簡體（中）
使用者回報：裝完選單列仍留一堆「鼠鬚管」，一部分繁體、一部分簡體。兩個獨立成因：

1. **簡體那半 — bundle 宣告了從不使用的 Hans 模式**：`resources/Info.plist` 把 `Squirrel.Hans` 與 `Squirrel.Hant` 都列為可見（`tsInputModeIsVisibleKey=true` + 都在 `tsVisibleInputModeOrderedArrayKey`）。本 fork 只出台灣正體（洋蔥），`SquirrelInputController` runtime 完全不依 mode ID 分支，Hans 與 Hant 餵同一個 Rime 引擎——那個「簡體」項純粹是多餘。
2. **重複那堆 — LaunchServices 殘留多個 bundle 註冊**：每次安裝都在 LaunchServices 留下已註冊的 `Squirrel.app`——掛載中的 DMG 卷（`/Volumes/…`）、垃圾桶內的舊版備份（`install.sh` 搬到 Trash 卻不 unregister）、舊 build 副本。每一個都各自貢獻一組 Hant（升級前的舊版還含 Hans）選單項。`lsregister -f "$DST"` 只註冊新路徑、不移除舊的。

**修正**：
- `Info.plist`：Hans `tsInputModeIsVisibleKey→false`、`tsInputModePrimaryInScriptKey→false`、移出 `tsVisibleInputModeOrderedArrayKey`。保留 dict 條目讓升級時 `disable(allCases)` 仍能清掉舊版曾啟用的 Hans。
- `scripts/make-dmg.sh`（產生的 `install.sh`）：`lsregister -f "$DST"` 後逐一 unregister 除安裝目標外的每個 `Squirrel.app`（DMG／垃圾桶／舊版）。
- `sources/InputSource.swift`：`disable()` 改走含重複記錄的完整清單（原本的 `[String: TISInputSource]` dict 會把同 ID 折疊成一筆、只 disable 到其一）；`enable()`/`select()` 仍取單一乾淨記錄，避免把殘留重新啟用。

> 註：macOS 只在登入時重建輸入來源清單，故 LaunchServices 清乾淨後，選單列殘留項要**登出再登入**才會完全消失（`install.sh` 已提示）。

### P1 — 運算子優先序使 `memorize_size: false` 在直排失效（中）
`sources/SquirrelPanel.swift:448`
```swift
if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
    (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
```
`&&` 優先於 `||`，實際解析為 `(memorizeSize && A) || B`——第二段 `B`（游標接近右邊界）**沒有**被 `memorizeSize` 管控。使用者關閉 `memorize_size` 後，只要用直排候選且游標靠右，面板寬度仍會被「記住／凍結」，不會隨較短候選縮回。

**修正**：加括號讓 `memorizeSize` 同時管控兩段條件。

### P2 — `panel.inputController` 強參考延後 session 釋放（低）
`sources/SquirrelPanel.swift:13` 的 `var inputController` 是強參考，而共享面板的生命週期等同 App。控制器被 macOS 拆掉後，面板仍持有最後一個，使其 librime session（只在 `deinit`／`destroySession` 釋放）延後到下一個控制器覆寫該欄位才釋放。程式其餘所有控制器參考（`current`、`client`）都是 `weak`。

**修正**：改為 `weak var inputController`，與既有慣例一致。

### P3 — 空候選列的負長度 `NSRange`（低，潛在）
`sources/SquirrelPanel.swift:255`：`NSRange(location: 1, length: line.length - 1)`，若 `line.length == 0` 會變成 `length: -1` 而丟例外。實務上候選文字幾乎不可能為空，故列為潛在。

**修正**：條件改為 `line.length > 1` 才套用 `.noBreak`。

---

## 3. 語音版（Voice）發現

### V1 — 快速點按熱鍵造成錄音競態（高）
`sources/Voice/VoiceInputController.swift` `beginRecording()` 在 `Task {}` 內才真正 `recorder.start()`。若使用者快速一按即放（放開事件先於 `start()` 執行，例如首次要求麥克風權限時），`finishRecording()` 的 `guard recorder.isRecording` 會失敗而直接返回；接著錄音才啟動，然後一路錄到 `maxRecordingSeconds`（預設 60 秒）逾時才停，把約一分鐘的環境音轉錄成文字打進前景 App。

**修正**：加入 `hotkeyHeld` 旗標；`recorder.start()` 完成後若發現熱鍵早已放開，立即停止並丟棄本次錄音。

### V2 — `no_active_client: discard` 從未生效（中）
`VoiceConfig` 讀取 `noActiveClient`（`clipboard | discard`，`squirrel.yaml` 有文件），但 `deliver()` 在無 IMK client 時一律走剪貼簿貼上，`discard` 等同 `clipboard`，選項是死的。

**修正**：無 IMK client 時依 `settings.noActiveClient` 分流；`.discard` 時丟棄並提示，不污染剪貼簿。

### V3 — `GeminiWebBridge.recycleIfIdle()` 從未被呼叫（中）
該方法用來在長時間閒置後 reload WebView、限制 WebContent 記憶體成長，但整個專案沒有任何呼叫點，記憶體無上限。

**修正**：在每次語音 pipeline 開始時對 Gemini 後端呼叫 `recycleIfIdle()`（cookie 仍在 data store，reload 後維持登入）。

### V4 — ChatGPT 轉錄 `duration_ms` 恆為 5000（中）
`ChatGPTBridge.transcribe` 的 JS 硬編 `duration_ms: 5000`；真實時長在 `recorder.stop()` 後被丟棄。

**修正**：把真實錄音時長透過 pipeline 一路傳入 `SpeechProvider.transcribe(...)`，ChatGPT 後端改送真實毫秒數；Groq／Gemini 後端忽略此參數。

### V5 — `stop()` 未重設狀態（低）
語音輸入在錄音中被停用時，`status` 停留在 `.recording`，選單列的暫時性麥克風圖示殘留。

**修正**：`stop()` 結尾將 `status` 設回 `.ready`。

### V6 — IMK 遞送在重新聚焦生效前送出（低）
`deliver()` 的 IMK 分支在 `target.activate()` 後**立即** post commit；若辨識期間焦點漂移，重新聚焦尚未生效，文字可能落到漂移後的 App。貼上分支已有 0.15 秒延遲；IMK 分支在需要重新聚焦時應比照延遲。

**修正**：IMK 分支在確有重新聚焦時，延遲一個短間隔再送出 commit。

### V7 — 控制器的 NotificationCenter observer 未移除（低）
`SquirrelInputController.init` 註冊三個 block-based observer，`deinit` 未移除。IMK 一個 session 會建立多個控制器，token 累積且每次語音 commit 都會觸發（雖 `weak self` 使其成為 no-op，仍屬洩漏）。

**修正**：保存 token，於 `deinit` 逐一 `removeObserver`。

### V8 — `voice_input/hotkey/modifiers` 有文件卻無人讀取（中）
`squirrel.yaml` 示範 `custom_combo` 用 `modifiers: control+option`，但 `VoiceConfig.load` 只讀 `key_code`，從不讀 `modifiers`，也沒有 `"control+option"` → `NSEvent.ModifierFlags` 的解析器；預設值剛好等於示範值，才掩蓋了「改任何其他組合都無效」的事實。

**修正**：在 `VoiceConfig.load` 加入 `voice_input/hotkey/modifiers` 讀取與 `mod1+mod2` 字串解析（支援 `control/ctrl/⌃`、`option/opt/alt/⌥`、`command/cmd/⌘`、`shift/⇧`）。

### V9 — 結束時以 `Task` 停止語音（低）
`applicationWillTerminate` 以 `Task { @MainActor in controller.stop() }` 停止語音，teardown 期間該 Task 可能來不及執行，錄音暫存檔／event tap 殘留。

**修正**：委派方法本就在主執行緒，直接同步呼叫 `controller.stop()`。

---

## 4. 語音精準度與易用性優化（使用者指定重點）

### O1 — 暖機中即可開始錄音
原本後端 `.warming` 時按熱鍵會嗶一聲並丟棄整句（首次啟動體驗差）。錄音是本地行為，pipeline 本就會 `awaitWebReadyIfNeeded()` 等待 Web session 就緒；若 Groq 金鑰缺失，轉錄時會給出明確錯誤。**改為暖機中照常錄音**，把等待延到轉錄階段。

### O2 — Groq 轉錄加上 `temperature: 0`
明確送出 `temperature=0`（貪婪解碼、最穩定），避免依賴預設值漂移；保留 `language` 與 Traditional-Chinese 引導 `prompt`。

### O3 — Groq cleanup 改用 system／user 雙訊息
原本把「整理規則 + 原文」串成單一 user 訊息。改為 **system = 整理規則、user = 原始逐字稿**，指令遵循度更佳；temperature 維持 0.2 保守值。（ChatGPT／Gemini 的對話端點維持串接寫法。）

### O4 — 強化台灣正體 cleanup prompt
加入兩條規則：**中文標點一律全形（，、。！？：；「」）**、**英文品牌／專有名詞保留原始大小寫**；配合既有 OpenCC `s2twp` 的字形保證，使輸出更貼近台灣書寫慣例。

### O5 — Whisper 幻覺過濾
Whisper 在靜音／雜訊時常吐出固定幻覺句（如「請不吝點贊訂閱轉發打賞…」「字幕由 Amara.org 社群提供」「明鏡與點點欄目」等）。新增過濾：當**整段**轉錄（去空白後）等於已知幻覺句時，視為空結果丟棄，避免把雜訊打成字。僅比對整段、不做子字串比對，避免誤刪正常內容。

### O6 — Gemini 單次 transcribe+clean 的風格提示語言中立化
`transcribeAndClean` 的 `styleHint` 標籤原本恆為中文（`風格/偏好：`），非中文語言時改用語言中立措辭。

### O7 —（設定面）暖機錯誤更清楚
配合 O1，暖機失敗不再吞掉錄音；錯誤在實際轉錄時以既有 diagnostic／HUD 呈現。

---

## 5. CI / 建置（CI1）

### CI1 — PR／push 無建置驗證（高）
唯一會跑 `xcodebuild` 的工作流 `custom-dmg.yml` 只在**推版本 tag** 時觸發；PR 與一般 push 只跑 SwiftLint。新增 `sources/Voice/`、`sources/Settings/` 檔案需手動跑 `scripts/add-voice-files.py` 並提交 `project.pbxproj` 差異——若漏做，SwiftLint 仍會過，直到下次切版打 tag 才在最糟的時機爆掉。

**修正**：`custom-dmg.yml` 增加 `pull_request` 與 `push`（`master`）觸發，實際跑 `make release` 驗證可編譯；DMG 附加到 release 的步驟維持僅 tag 觸發（`if: github.ref_type == 'tag'`），非 tag 時仍上傳 artifact 方便下載驗證。

---

## 6. 已檢視、確認無虞（節錄）

- OpenCCBridge：`(opencc_t)-1` 失敗判斷正確；`s2twp.json` 相對路徑依賴 `Main.swift` 設定的 cwd=SharedSupport——正確。
- `GroqSecrets` Keychain 遷移、`SessionStore` `0600` 權限——正確。
- `HotkeyManager` tap 逾時後 re-enable、releases-before-presses——正確。
- `RimeCustomPatcher` 受管區塊解析與 `NSNull → ~` 刪除語義——正確。
- pbxproj：`sources/Voice/`、`sources/Settings/` 全數檔案均已登錄於 Sources build phase；`OpenCCBridge.mm` 有編譯、`-lopencc -lmarisa` 有連結、bridging header 有引入。
- `Info.plist`：`NSMicrophoneUsageDescription` 存在（雙語），首次取用麥克風不會崩潰。
- SwiftLint：`line_length 200`、`identifier min 3 warning`；本次新增程式碼皆保持 lint 乾淨。
- 發版流程：更新 `CURRENT_PROJECT_VERSION`（pbxproj 兩處）＋推 `X.Y.Z` tag 觸發 `custom-dmg.yml` 產出 DMG。
