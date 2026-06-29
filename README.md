    鼠鬚管
    爲物雖微情不淺
    新詩醉墨時一揮
    別後寄我無辭遠

    　　　——歐陽修

今由　[中州韻輸入法引擎／Rime Input Method Engine](https://rime.im)
及其他開源技術強力驅動

【鼠鬚管】輸入法
===
[![Download](https://img.shields.io/github/v/release/rime/squirrel)](https://github.com/rime/squirrel/releases/latest)
[![Build Status](https://github.com/rime/squirrel/actions/workflows/commit-ci.yml/badge.svg)](https://github.com/rime/squirrel/actions/workflows)
[![GitHub Tag](https://img.shields.io/github/tag/rime/squirrel.svg)](https://github.com/rime/squirrel)

式恕堂 版權所無

授權條款：[GPL v3](https://www.gnu.org/licenses/gpl-3.0.en.html)

項目主頁：[rime.im](https://rime.im)

您可能還需要 Rime 用於其他操作系統的發行版：

  * 【中州韻】（ibus-rime、fcitx-rime）用於 Linux
  * 【小狼毫】用於 Windows

本分支客製功能（語音版）
---

本分支在原版鼠鬚管之上整合以下功能（macOS 13+）：

  * **內建洋蔥注音 plus 詞庫**：預載「☆注音(洋蔥plus版)☆」與四個 mix-in 變體，另含**地球拼音（terra_pinyin）**，方案選單共 7 項；內含英／日／韓／希臘／西里爾等多語掛接，裝完即用、免手動安裝方案；首次切換自動部署（一次性約 1–2 分鐘，編譯產物置於 `~/Library/Rime/build/`）。
  * **語音輸入**：按住右 ⌥（Option）即說即上字，支援九種語言；後端可選（Gemini／Groq／ChatGPT），於偏好設定登入或填入 API key。
  * **圖形化偏好設定**：右鍵輸入法圖示 →「Preferences…」，可調外觀、候選數、預設中英模式、選字標籤、語音與方案層級設定，無需手改 YAML。
  * **iCloud 設定同步**：跨機同步個人設定。
  * **一鍵 DMG 安裝**：DMG 內附 `install.sh`，自動完成註冊／啟用／選用，並保留個人詞頻（`~/Library/Rime/*.userdb`）。

安裝與首次設定詳見 [INSTALL-zh.md](INSTALL-zh.md)。

> ⚠️ 本套件內含洋蔥詞庫（約 180MB），**僅供個人／內部使用**；公開散佈請先取得 [Onion_Rime_Files](https://github.com/oniondelta/Onion_Rime_Files) 作者授權。

iCloud 同步（跨機同步個人詞頻）
---

本分支以 Rime 原生同步機制（`sync_dir` 指向 iCloud Drive）跨機同步**個人化詞頻（`*.userdb`）與設定備份**，走一般檔案路徑、**零需 Apple Developer entitlement**。

啟用方式：

  1. 右鍵輸入法圖示 →「Preferences…」→ **General** 分頁 →「**Sync**」區。
  2. 開啟「**iCloud 同步**」開關 —— 會在 iCloud Drive 建立 `RimeSync/` 資料夾，並把同步路徑寫入 `~/Library/Rime/installation.yaml`（**即時生效，不需重新部署或重啟**）。
  3. 點「**立即同步**」可手動觸發一次同步（匯出本機 `*.userdb` 快照、並雙向合併其他機器的快照）。
  4. **每一台 Mac 都要各自開啟此選項**才會彼此合併。同步檔位於 `~/Library/Mobile Documents/com~apple~CloudDocs/RimeSync/<installation_id>/`。

關閉開關即移除同步路徑、回落本機 `~/Library/Rime/sync/`；個人詞頻不會被刪除。

> ⚠️ 若 iCloud 開啟「最佳化 Mac 儲存空間」，快照可能被收回為 placeholder，導致某次同步讀取失敗（**不會毀損本機資料**，librime 會報錯後跳過）。可於 Finder 對 `RimeSync` 資料夾選「立即下載／保留下載」。

安裝輸入法
---

本品適用於 macOS 13.0+

初次安裝，如果在部份應用程序中打不出字，請註銷並重新登錄。

使用輸入法
---

選取輸入法指示器菜單裏的【ㄓ】字樣圖標，開始用鼠鬚管寫字。
通過快捷鍵 `` Ctrl+` `` 或 `F4` 呼出方案選單、切換輸入方式。

定製輸入法
---

定製方法，請參考線上 [幫助文檔](https://rime.im/docs/)。

使用系統輸入法菜單：

  * 選中「在線文檔」可打開以上網址
  * 編輯用戶設定後，選擇「重新部署」以令修改生效

安裝輸入方案
---

使用 [/plum/](https://github.com/rime/plum) 配置管理器獲取更多輸入方案。

致謝
---

輸入方案設計：

  * 【朙月拼音】系列

    感謝 CC-CEDICT、Android 拼音、新酷音、opencc 等開源項目

程序設計：

  * 佛振
  * Linghua Zhang
  * Chongyu Zhu
  * 雪齋
  * faberii
  * Chun-wei Kuo
  * Junlu Cheng
  * Jak Wings
  * xiehuc

美術：

  * 圖標設計 佛振、梁海、雨過之後
  * 配色方案 Aben、Chongyu Zhu、skoj、Superoutman、佛振、梁海

本品引用了以下開源軟件：

  * Boost C++ Libraries  (Boost Software License)
  * capnproto (MIT License)
  * darts-clone  (New BSD License)
  * google-glog  (New BSD License)
  * Google Test  (New BSD License)
  * LevelDB  (New BSD License)
  * librime  (New BSD License)
  * OpenCC / 開放中文轉換  (Apache License 2.0)
  * plum / 東風破 (GNU Lesser General Public License 3.0)
  * Sparkle  (MIT License)
  * UTF8-CPP  (Boost Software License)
  * yaml-cpp  (MIT License)

感謝王公子捐贈開發用機。

問題與反饋
---

發現程序有 BUG，或建議，或感想，請反饋到 [Rime 代碼之家討論區](https://github.com/rime/home/discussions)

聯繫方式
---

技術交流，歡迎光臨 [Rime 代碼之家](https://github.com/rime/home)，
或致信 Rime 開發者 <rimeime@gmail.com>。

謝謝
