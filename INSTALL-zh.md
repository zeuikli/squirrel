# 鼠鬚管（語音版）安裝說明

> 客製版 Squirrel：內建洋蔥注音 plus 詞庫 + 按住右 ⌥ 語音輸入 + 圖形化偏好設定。
> macOS 13+。本套件含洋蔥詞庫，**僅供個人／內部使用**；公開散佈請先取得
> [Onion_Rime_Files](https://github.com/oniondelta/Onion_Rime_Files) 作者授權。

---

## 方式 A：DMG 自動安裝（建議）

1. 雙擊開啟 `Squirrel-custom-1.1.6.dmg`。
2. 開「終端機」，把 DMG 視窗裡的 `install.sh` **拖進終端機視窗**，按 Enter 執行。
   腳本會自動：停止舊版 → 備份到垃圾桶 → 複製安裝 → 清除下載隔離（quarantine）→ 註冊 → 清除既有（含重複殘留）的輸入來源 → **重新啟用單一輸入法項目 → 選用並啟動鼠鬚管**。
   正常輸出會看到 `Enable succeeds` 與 `Selection succeeds` 兩行 —— **無需到「系統設定」手動移除／重新加入輸入法**。
3. 選單列即可看到並選「**鼠鬚管**」開始使用。
4. （建議）**登出 macOS 再登入一次**：僅為清除先前反覆安裝在系統累積的「重複鼠鬚管」選單項（純外觀）；登出前輸入法已可正常使用。
5. 完成首次設定（見下方「首次設定」）。

> 萬一選單列沒出現鼠鬚管：**重跑一次 `install.sh`** 即可（已內建註冊＋啟用＋選用）；通常不需要進系統設定手動加入。

## 方式 B：手動複製替換（已裝過鼠鬚管／進階使用者）

1. 結束運行中的鼠鬚管：
   ```bash
   killall Squirrel
   ```
2. 備份並移除舊版（官方版若裝在 `/Library/Input Methods/` 需 `sudo`；本客製版裝使用者層級）：
   ```bash
   mv ~/Library/Input\ Methods/Squirrel.app ~/.Trash/   # 有舊版才需要
   ```
3. 從 DMG（或建置產物）複製新版並清除隔離屬性：
   ```bash
   cp -R "/Volumes/Squirrel 鼠鬚管（語音版）/Squirrel.app" ~/Library/Input\ Methods/
   xattr -dr com.apple.quarantine ~/Library/Input\ Methods/Squirrel.app
   ```
4. 註冊輸入法，先全停用以清除既有（含重複殘留）項目，再加回並選用單一繁體項目：
   ```bash
   APP=~/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel
   "$APP" --register-input-source
   "$APP" --disable-input-source
   "$APP" --enable-input-source im.rime.inputmethod.Squirrel.Hant
   "$APP" --select-input-source im.rime.inputmethod.Squirrel.Hant
   open ~/Library/Input\ Methods/Squirrel.app
   ```
   應看到 `Enable succeeds` 與 `Selection succeeds`，選單列即出現鼠鬚管。
5. （建議）**登出再登入一次**清除重複選單項（純外觀，非必要）。
6. 完成首次設定（見下方）。

> 兩種方式都會保留你的個人詞頻（`~/Library/Rime/*.userdb`），不會被覆蓋。

---

## 首次設定（兩種方式共通）

### 1. 注音輸入（裝完即用）

預設方案為「☆注音(洋蔥plus版)☆」。**首次切換到鼠鬚管會自動部署詞庫（一次性，約 1–2 分鐘）**，完成時有系統通知；之後皆為秒級。編譯產物放在 `~/Library/Rime/build/`。
`Ctrl+\`` 開方案選單；右鍵輸入法圖示 → **Preferences…** 可調外觀、候選數、預設中英模式、選字標籤等。

### 2. 語音輸入權限（一次性）

| 權限 | 何時跳出 | 操作 |
|------|----------|------|
| 麥克風 | 啟動／首次按住右 ⌥ | 點「允許」 |
| 輔助使用（必要） | 啟動時通知提示 | 系統設定 → 隱私權與安全性 → 輔助使用 → 開啟 Squirrel |
| 輸入監控 | 僅當引擎切為 CGEventTap | 同上 → 輸入監控 → 開啟 Squirrel |

**「輔助使用」是單一開關，同時負責：① 監聽右 ⌥ 熱鍵 ② 在 VSCode 等 Electron app 自動貼上文字（送 ⌘V）。** 沒有子項目要勾。
權限狀態可在 Preferences… → Voice 頁最上方即時查看（✓／✗），缺的旁邊有 Grant 按鈕。

### 3. 語音後端（擇一）

> **金鑰／登入不再進 Keychain（1.1.6+）**：Groq key 與 ChatGPT/Gemini 登入 session 一律存本機檔案
> `~/Library/Application Support/Squirrel/`（權限 `0600`），**安裝／升級不會再跳「Squirrel 想使用鑰匙圈」提示**。
> ⚠️ **從舊版升級者**：舊的 ChatGPT/Gemini 登入存在系統 Keychain 加密區、新版讀不到，需在下方**重新登入一次**（Groq key 會自動沿用、無需重設）。

- **Groq（建議，最快）**：Preferences… → Voice → Backend 選 `Groq API (key)` → 貼上 API key → Save key（存 `~/Library/Application Support/Squirrel/groq-api-key`，`0600`）。
- **ChatGPT Web**：Backend 選 `ChatGPT Web (session)` → 「Sign in to ChatGPT…」登入 → 「Check status」顯示 Logged in ✓。登入成功會寫 `chatgpt-session.json`（`0600`）。
- **Gemini Web**：Backend 選 `Gemini Web (session)` → 「Sign in to Gemini…」登入 Google 帳號 → 關閉登入視窗 → 「Check status」顯示 Logged in ✓。登入成功會寫 `gemini-session.json`（`0600`）。吃 Gemini 訂閱、不需 API key（實驗性：走 gemini.google.com 的逆向 RPC，Google 改版可能失效）。
  > 註：Gemini **API key** 後端因免費層額度過小、易被限流（回 404），已移除；改用上面的 Gemini Web。

### 4. 使用

游標放任何文字框 → **按住右 ⌥ Option 講話 → 放開** → 等約 1 秒（雲端辨識）→ 辨識文字（台灣正體）自動上字。

上字方式依目標 app 自動選擇：
- 一般原生 app（備忘錄、Telegram、瀏覽器網址列…）→ 走輸入法原生通道，**不碰剪貼簿**。
- VSCode 等 **Chromium/Electron** app → 自動以「複製＋⌘V」貼上（需「輔助使用」權限；貼完不會更動你原本的剪貼簿用途，但辨識文字會留在剪貼簿）。

---

## 疑難排解

| 症狀 | 處理 |
|------|------|
| 登入後選單列沒有鼠鬚管 | 系統設定 → 鍵盤 → 輸入方式手動 ＋ 加入 |
| 輸入法選單出現幾十個重複「鼠鬚管」 | 反覆安裝的殘留：執行 `~/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel --disable-input-source` → **登出再登入**；或重跑 install.sh（已內建清除步驟）|
| 按右 ⌥ 完全沒反應 | Preferences → Voice 看權限是否全綠；輔助使用未授權則開啟 |
| 權限開了又自動關閉 | 系統設定該列表選取 Squirrel → **− 移除 → ＋ 重新加入** → 重啟輸入法 |
| VSCode/Electron app 沒上字 | 需「輔助使用」權限才能自動貼上；於 Preferences → Voice 確認該權限為 ✓ |
| 辨識成功但文字進到別的視窗 | 已修正（鎖定按鍵當下的 app）；若仍偶發，講話時讓目標視窗保持在最前 |
| 有提示音但不出字 | 後端問題：檢查 Groq key／ChatGPT 或 Gemini 登入狀態（Preferences → Voice → Check status）|
| 選單列圖示變黑塊 | 終端機執行 `killall TextInputMenuAgent`；仍黑則登出登入 |
| 升級後行為仍像舊版／改動沒生效 | 舊版被搬到垃圾桶但同 bundle id 被 LaunchServices 搶先啟動：**清空垃圾桶** → 重跑 `install.sh`（已內建 `lsregister -f` 防此情況）|
| 升級後 ChatGPT/Gemini 顯示未登入 | 正常：舊登入無法從 Keychain 遷移，於 Preferences → Voice **重新登入一次**即可 |
| 辨識出簡體字 | 確認 Preferences → Voice → LLM cleanup pass 開啟 |
| 想看部署紀錄 | `ls -t $TMPDIR/rime.squirrel/` 開最新 INFO log |

---

## 解除安裝

```bash
killall Squirrel
rm -rf ~/Library/Input\ Methods/Squirrel.app
# 個人詞庫與設定（可選）：rm -rf ~/Library/Rime
```
