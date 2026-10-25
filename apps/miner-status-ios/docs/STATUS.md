# 狀態

最後更新：2026-10-24。

## Windows 上實際執行

使用 Python 3.11.9、jsonschema 4.23.0、tree-sitter-language-pack 1.10.1。

| 檢查 | 指令 | 結果 |
| --- | --- | --- |
| JSON 契約與 fixtures | `python -I tools/validate_contract.py --verbose` | PASS |
| Swift 語法剖析 | `python -I tools/check_swift_syntax.py` | 15 個 Swift 檔，0 個語法問題 |
| 靜態設定檢查 | `python -I tools/check_static_policy.py` | 147 項通過，0 項失敗 |

**契約檢查的範圍**

- schema 本身通過 Draft 2020-12 meta-schema 驗證；3 個 fixtures 全部有效，標示為 demo，且不含 IP、路徑或憑證類字詞。
- 104/104 個反例被拒收：
  - 各層缺 key、非白名單 key
  - 型別錯誤，包括布林與整數互相冒充
  - 列舉、範圍、識別欄位
  - 重複 `machineId`、demo 標示規則
  - 15 種無效時間，以及截斷的 JSON
- 13/13 個正例被接受。
- 2 月 30 日等案例會通過 schema 的正則；它們被拒收，證明自訂的 RFC 3339 日曆檢查確實生效。

**靜態設定檢查的範圍**

- **Info.plist**：只開 `NSAllowsLocalNetworking`，沒有任意載入或例外網域，沒有背景模式，並有本地網路用途說明。
- **XcodeGen 規格**（沿用 album-ios 架構）：iOS 16、核心為 framework target、單元測試 target 由 App scheme 執行、內建 `demo-running.json`、明確的 Info.plist、沒有任何套件相依。
- **App 與核心原始碼**：
  - 沒有 POST、PUT、PATCH、DELETE、背景工作、WebSocket、監聽或 WebView
  - 只有 `StatusClient.swift` 使用 URLSession
  - 沒有寫死的網址或 IPv4，只允許設定畫面的通用提示字樣
- **啟動與讀取**：每次啟動為示範；來源網址預設為空；讀取綁定前景。
- **測試**：只使用文件保留位址（`.example`、`192.0.2.0/24`）。
- **檢查本身會失敗**：在暫存副本中刻意加入 `NSAllowsArbitraryLoads`、`"POST"` 與寫死的網址後，檢查回報 4 項失敗並以 exit 1 結束，證明這些規則有效。

**語法剖析與人工檢查**

- tree-sitter 只代表語法可剖析，不代表型別檢查通過。
- 前幾輪曾找到並修正 `as? … ??` 剖析問題。
- 人工檢查時另修正了三處可能的編譯錯誤：
  - `Reported` 的 `case value` 與同名屬性衝突
  - 測試中 `Result` 擴充屬性與 `case failure` 同名
  - 測試中區域常數與方法同名

## CI 實際執行（GitHub 標準 macOS runner）

最新通過：[run 40102507820](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40102507820)，來源 `9f93659`，Xcode 16.4、iPhone 16 Pro 模擬器。以下數字取自該 run 的公開 annotation。

發布：[run 40104542175](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40104542175)（來源 `9e8ec14`，同樣 80＋11 項 0 失敗）建立公開 prerelease [miner-status-0.1.0-build1](https://github.com/chunyen627-afk/mobile-apps/releases/tag/miner-status-0.1.0-build1)，`MinerStatus-0.1.0-build1-unsigned.ipa` 214,284 bytes，SHA256 `5b041860e9bc54b8e2c305bbc2ce1f04e7776d69e2d8212a8d4fb8dfab180887`。

| 檢查 | 結果 |
| --- | --- |
| `xcodegen generate`、模擬器 Debug 編譯（核心 framework、App、測試） | 通過 |
| 單元測試 | `Executed 80 tests, with 0 failures (0 unexpected)` |
| 模擬器 UI 測試 | `Executed 11 tests, with 0 failures (0 unexpected)`：7 種示範情境的燈號、詳情頁、網址驗證、自訂來源讀取本機假資料、讀取失敗、停止後回到示範 |
| 截圖人工檢視 | 13 張全部看過（分支 `ci-screenshots-miner-status-ios`）：燈號與原因文字符合規則，無截字或重疊 |
| Release archive、bundle 檢查（主程式、`demo-running.json`、`MinerStatusCore.framework`、ATS、無背景模式） | 通過 |
| 未簽署 IPA | 214,284 bytes，SHA256 `0b98b95f938d7655ac5df0df42d5d98a930ca0c48dd5dc8665e0eb53fc2c66e1`；只在 runner 內，**未上傳** |

UI 測試與截圖找到並修正的畫面問題：

1. 頂端模式橫幅蓋住導覽列，「資料來源」按鈕點不到（真機也會發生）→ 橫幅改放在各畫面導覽列下方
2. 清單內的情境選單點了打不開 → 改為點「目前情境」進入清單頁
3. 捲動時內容透過半透明橫幅，文字重疊 → 橫幅底色改為不透明
4. 返回鍵顯示英文「Back」 → 宣告 App 為繁體中文
5. 設定頁標題把「App」轉成「APP」→ 關閉該標題的自動大寫

修正紀錄：

1. [run 40094203491](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094203491)：舊的 SwiftPM `swift test` 流程，建置步驟失敗（當時沒有 annotation，log 需登入）；改為 album-ios 架構
2. [run 40094798800](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094798800)：首次實際編譯，`StatusEngine.swift` 修改 `trackers` 時同時讀 `self.policy`，觸發重疊存取錯誤；改用區域常數
3. [run 40095024930](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40095024930)：全部通過；之後補上公開 notice，讓測試數與 IPA SHA256 不登入也能查證

## 0.2.0（build 3）：收益、電費與警告

[run 40117533077](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40117533077)，來源 `4e5200e`：單元測試 `Executed 95 tests, with 0 failures`、UI 測試 `Executed 13 tests, with 0 failures`；15 張截圖已人工檢視。IPA 275,378 bytes，SHA256 `659acae1…4554b51`（runner 內，未上傳）。

- 新增：每台與總計的估算收益（幣量、BTC、台幣）、依台電簡易型二段式推算的電費、可勾選哪幾台算電費、額外耗電與費率設定；「N 台不是綠燈」警告區塊，以及即時模式下從綠燈變壞時的提示與震動
- 示範資料的收益數字已手算核對（1.6 PRL × US$1.85 × 32.5 ≈ NT$96；390 W × 24 h × 1.99 ≈ NT$19）
- UI 測試與截圖這輪抓到並修正：警告區塊被 VoiceOver 只讀成圖示名稱「警告」；收益設定頁掛在清單區塊上，捲動回收時會自己關掉
- 收益是估算，不是實際入帳；電費假設目前耗電持續一整天，國定假日未計為離峰

## 0.3.0（build 4）：電腦端判斷、健康資訊、今日電價

- 燈號改由電腦端判斷並附白話原因；電腦端超過 2 分鐘沒更新時 App 顯示灰燈「電腦端沒有回應」
- 健康資訊：最後份額、運轉時間、份額有效率、溫度與保護線、礦池在線
- 「今日電價」區塊（依手機時間）：現在尖峰／離峰與每度價格、下次換時段、今天時段表、週末與放假日全天離峰
- 台電公告費率與平日放假日由電腦端每天自動取得；放假日依政府行事曆，台電離峰日可能略有不同
- 停止讀取需再確認
- [run 40149190423](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40149190423)（`08eb00c`）：113 通過、2 失敗——收益設定按鈕被擠到螢幕最下方（移到區塊標題列）；判斷過時測試沒出現機器列，疑為網址欄只刪掉游標前的字、新舊網址混在一起（加清除鈕、測試改用清除鈕並核對網址）
- [run 40150845562](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40150845562)（`2b4ce11`）：單元測試 `Executed 108 tests, with 0 failures`、UI 測試 `Executed 15 tests, with 0 failures`；18 張截圖已人工檢視（今日電價週日顯示全天離峰、下次 10/27（二）06:00 改尖峰——10/26 補假已計入；設定頁顯示台電公告 2025-10-01 起）。網址欄修好後判斷過時測試通過，證實原因是新舊網址混在一起。IPA 347,513 bytes，SHA256 `e2602e69…5383efc30`（runner 內，未上傳）

## 實機

| 項目 | 結果 |
| --- | --- |
| build 1（`miner-status-0.1.0-build1`） | SideStore 安裝失敗：中文 `CFBundleDisplayName` 被當成 Apple App ID 名稱而遭拒（`invalid value '礦機狀態' … 'appIdName'`） |
| build 2（[`miner-status-0.1.0-build2`](https://github.com/chunyen627-afk/mobile-apps/releases/tag/miner-status-0.1.0-build2)，SHA256 `c5bfede7…f36309`） | 2026-10-25 本人以 SideStore 安裝，回報**打得開、畫面正常**（iPhone，離線示範） |
| 真實資料來源 | 2026-10-25 **通過**：手機經私人虛擬網路以 HTTP 讀取電腦端唯讀彙整服務，每 15 秒一次，兩台礦機都顯示**綠燈**。iOS 放行了此 HTTP 連線（`NSAllowsLocalNetworking`） |

電腦端架構（程式與位址只在本機，不進公開倉庫）：

- 一台電腦跑唯讀彙整服務：讀本機礦工的狀態檔與同一工作的 log，並向另一台的唯讀監控取資料，合成一份符合本 App schema 的 JSON；只綁私人虛擬網路位址、只回應該網段、只接受 GET，不輸出 token、PID 或路徑
- 另一台的唯讀監控只允許彙整服務那台連線（應用層與防火牆雙重限制），不對手機直接開放
- 兩邊都不啟停、不調整礦工，目前為手動啟動

接上真實來源時找到並修正的問題：引擎要求同一工作內每筆新資料的 `observedAt` 與 `sampleSequence` 都嚴格遞增，完全相同的重複一筆也會被當成 replay 而亮黃燈。彙整服務因此讓序號跟著資料時間走、輪詢頻率不低於手機讀取頻率，並在服務重啟後換新的工作代號。

## 未執行

| 項目 | 狀態 |
| --- | --- |
| iPad 版面 | 未驗證（UI 測試只在 iPhone 模擬器執行） |
| 真實資料來源 | 未連線；沒有已驗證可用的來源端點；ATS 對 HTTP 私有位址的效果未驗證 |

Python 檢查只驗證 JSON 契約與設定文字，**不是** Swift 程式的測試，不能互相替代。

## 下一步

1. 收益與電費功能（規格見 README 開發路線），同樣先模擬器驗證再實機確認。
2. 電腦端服務穩定後，再決定是否改為開機自動啟動（需另行同意）。
3. 需要時加 iPad 模擬器的 UI 測試與截圖。
3. 來源端確認可用後，在實機以自訂來源驗證：ATS、本地網路權限、失敗與重連。
