# TouchBarLyrics

在 MacBook Pro 的 Touch Bar 上即時顯示 Spotify / Apple Music 正在播放歌曲的同步歌詞。

Show time-synced lyrics of the song playing in Spotify or Apple Music on the MacBook Pro Touch Bar.

- 前景是任何 App 都能顯示（不只在自己的視窗裡）
- 自動從 LRCLIB、網易雲音樂、QQ 音樂搜尋同步歌詞，比對曲名、歌手與長度，避免抓到翻唱版
- 簡體自動轉繁體、歌詞時間微調、選單列同步顯示
- 原生 Swift，只依賴系統框架，不需安裝 Xcode

## 系統需求

- 有 Touch Bar 的 MacBook Pro
- macOS 11 以上（在 macOS 15.5、MacBookPro17,1 上測試）
- Xcode Command Line Tools：`xcode-select --install`
- Spotify 桌面版或 Apple Music

## 安裝

```bash
git clone https://github.com/therealclvn/TouchBarLyrics.git
cd TouchBarLyrics
./build.sh
open build/TouchBarLyrics.app
```

想開機自動執行：把 `build/TouchBarLyrics.app` 移到「應用程式」資料夾，再到系統設定 → 一般 → 登入項目加入。

第一次播放時，macOS 會詢問是否允許 TouchBarLyrics 控制 Spotify / Music，請按「好」。
如果不小心拒絕，到系統設定 → 隱私權與安全性 → 自動化，把它打開。

## 使用方式

- **Control Strip 的 ♪ 按鈕**：叫出歌詞列；左側 ✕ 收起
- **換歌時自動彈出**歌詞列（可在選單關閉）
- **選單列 ♪ 圖示**：
  - 歌詞提早 / 延後 0.5 秒（`⌘]` / `⌘[`）
  - 簡體轉繁體
  - 同時在選單列顯示歌詞
  - 重新抓取這首歌的歌詞

Control Strip 沒出現 ♪ 的話：系統設定 → 鍵盤 → Touch Bar 設定，確認「顯示 Control Strip」已開啟。

## 運作原理

| 部分 | 作法 | 檔案 |
|---|---|---|
| 播放狀態 | AppleScript 每秒讀取曲目與進度，搭配播放器的系統通知；兩次讀取之間用時間推算，每 0.1 秒更新顯示 | `NowPlaying.swift` |
| 歌詞搜尋 | LRCLIB → 網易雲 → QQ 音樂（中日韓文歌曲先查後兩者），結果快取在 `~/Library/Caches/TouchBarLyrics/` | `LyricsService.swift` |
| 歌詞解析 | LRC 格式，支援一行多個時間標籤與 `[offset:]` | `LRC.swift` |
| Touch Bar | 私有 API 的 system modal Touch Bar 與 Control Strip 項目 | `TouchBar.swift` |

## 注意事項

- **使用 Apple 私有 API**：一般 App 只有在前景時才能控制 Touch Bar，要在聽歌時常駐顯示只能用未公開 API。因此本專案**無法上架 App Store**，未來 macOS 更新也可能失效。
- **非官方歌詞來源**：網易雲音樂與 QQ 音樂的介面並非公開 API，隨時可能改版或限流；本專案僅供個人學習使用，歌詞版權屬於原權利人。
- **未經 Apple 公證**：`build.sh` 只做 ad-hoc 簽章，自己在本機 build 可直接執行；把 build 好的 .app 傳給別人時，對方會被 Gatekeeper 擋下，需要右鍵 → 打開。
- **重新 build 後可能要重新授權**：簽章改變時 macOS 會再次詢問自動化權限。
- **Touch Bar 閒置會變暗**：這是 macOS 本身的行為，約一分鐘沒有鍵盤或觸控板輸入就會變暗，碰一下任何按鍵或觸控板即可恢復。
- 不支援 Spotify 網頁版。

## 疑難排解

| 狀況 | 處理 |
|---|---|
| 一直顯示「沒有播放中的音樂」 | 確認已允許自動化權限；可在「主控台」App 搜尋 `TouchBarLyrics:` 查看錯誤 |
| 找不到歌詞 / 抓到錯的版本 | 選單 →「重新抓取這首歌詞」；仍不對請開 issue 並附上曲名、歌手 |
| 歌詞時間對不上 | 用 `⌘]` / `⌘[` 微調 |

## 授權

[MIT](LICENSE)
