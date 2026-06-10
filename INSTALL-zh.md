# 鼠鬚管（語音版）安裝說明

> 客製版 Squirrel：內建洋蔥注音 plus 詞庫 + 按住右 ⌥ 語音輸入 + 圖形化偏好設定。
> macOS 13+。本套件含洋蔥詞庫，**僅供個人／內部使用**；公開散佈請先取得
> [Onion_Rime_Files](https://github.com/oniondelta/Onion_Rime_Files) 作者授權。

---

## 方式 A：DMG 自動安裝（建議）

1. 雙擊開啟 `Squirrel-custom.dmg`。
2. 開「終端機」，把 DMG 視窗裡的 `install.sh` **拖進終端機視窗**，按 Enter 執行。
   腳本會自動：停止舊版 → 備份到垃圾桶 → 複製安裝 → 清除下載隔離（quarantine）→ 註冊並啟用輸入法。
3. **登出 macOS 再登入**（輸入法載入必要步驟）。
4. 選單列輸入法選「**鼠鬚管**」。沒看到的話：系統設定 → 鍵盤 → 文字輸入「輸入方式」→ 編輯 → ＋ → 中文（繁體）→ 鼠鬚管。
5. 完成首次設定（見下方「首次設定」）。

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
4. 註冊並啟用輸入法：
   ```bash
   ~/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel --register-input-source
   ~/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel --enable-input-source
   ```
5. **登出再登入**，於選單列選「鼠鬚管」。
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
| 輔助使用 | 啟動時通知提示 | 系統設定 → 隱私權與安全性 → 輔助使用 → 開啟 Squirrel |
| 輸入監控 | 僅當引擎切為 CGEventTap | 同上 → 輸入監控 → 開啟 Squirrel |

權限狀態可在 Preferences… → Voice 頁最上方即時查看（✓／✗），缺的旁邊有 Grant 按鈕。

### 3. 語音後端（擇一）

- **Groq（建議）**：Preferences… → Voice → Backend 選 `Groq API (key)` → 貼上 API key → Save key（存 Keychain，不落地檔案）。
- **ChatGPT Web**：Backend 選 `ChatGPT Web (session)` → 「Sign in to ChatGPT…」登入 → 「Check status」顯示 Logged in ✓。

### 4. 使用

游標放任何文字框 → **按住右 ⌥ Option 講話 → 放開** → 辨識文字（台灣正體）直接上字。
不經剪貼簿、不影響既有打字流程。

---

## 疑難排解

| 症狀 | 處理 |
|------|------|
| 登入後選單列沒有鼠鬚管 | 系統設定 → 鍵盤 → 輸入方式手動 ＋ 加入 |
| 按右 ⌥ 完全沒反應 | Preferences → Voice 看權限是否全綠；輔助使用未授權則開啟 |
| 權限開了又自動關閉 | 系統設定該列表選取 Squirrel → **− 移除 → ＋ 重新加入** → 重啟輸入法 |
| 有提示音但不出字 | 後端問題：檢查 Groq key 或 ChatGPT 登入狀態 |
| 選單列圖示變黑塊 | 終端機執行 `killall TextInputMenuAgent`；仍黑則登出登入 |
| 辨識出簡體字 | 確認 Preferences → Voice → LLM cleanup pass 開啟 |
| 想看部署紀錄 | `ls -t $TMPDIR/rime.squirrel/` 開最新 INFO log |

---

## 解除安裝

```bash
killall Squirrel
rm -rf ~/Library/Input\ Methods/Squirrel.app
# 個人詞庫與設定（可選）：rm -rf ~/Library/Rime
```
