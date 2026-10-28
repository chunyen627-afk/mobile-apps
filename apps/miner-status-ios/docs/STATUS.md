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
- **啟動與讀取**：第一次啟動為示範；來源網址預設為空；讀取綁定前景。上次還在讀來源時，啟動會自動接回（0.6.1）。
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

## 0.3.1（build 5，待發布）：時間改成台灣時間＋幾秒前

- 使用者回報「礦機時間跟真實時間對不上」：資料其實只延遲約 1 秒，是電腦端送 UTC（`…Z`），App 又把時間字串原樣顯示，看起來慢 8 小時
- 電腦端已改送 `+08:00`（2026-10-25 起，手機不用重裝）；App 改顯示「10:12:57（3 秒前）」，不是今天的加上日期「10/24 17:40:00（16 小時 32 分前）」，不論來源送哪個時區都換算成台灣時間
- 套用在清單的資料時間、詳情的資料時間／份額資料時間／最後接受份額／最後份額、幣價時間
- [run 40154597025](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40154597025)：單元測試「4.2 秒後」被取整成 5 秒（改往零取整）；之後兩輪測試全過，但啟動冒煙檢查誤判 App 沒在跑——`launchctl list | grep -q` 在 pipefail 下 grep 提早結束讓前一個指令收到 SIGPIPE；另外失敗時 `exit` 在導向區塊內，錯誤提示被寫進 log 而沒出現在公開紀錄。兩者都已修正
- [run 40156528972](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40156528972)（`e43b455`）：單元測試 `Executed 111 tests, with 0 failures`、UI 測試 `Executed 15 tests, with 0 failures`、啟動冒煙通過；截圖確認清單與詳情顯示「17:30:30（5 秒前）」。IPA 349,158 bytes，SHA256 `5b7317e2…5103d363`（runner 內，未上傳）

## 0.4.0（build 6，待發布）：遠端開始／停止筆電挖礦、回到 App 不再誤報灰燈

- 使用者要求 App 能啟動挖礦；先只做筆電，開始＋停止，控制密碼由電腦端產生
- 電腦端已上線並實測（2026-10-25）：密碼錯誤被拒、停止→保護程式正常停止並還原時脈與記憶體時脈、開始→保護程式啟動並回到 26.9 TH/s、重複開始回「已經在挖礦了」；每次操作 ntfy 都有通知
- App：詳情頁「遠端控制」、設定頁控制密碼（鑰匙圈）、資料格式加選填 `control`（feature `control`）
- 修正：螢幕關掉幾分鐘再打開 App，會先用舊資料判斷而全部變灰並跳警告；改為回到前景後等第一筆新資料再判斷
- 尚未實機驗證：手機上的按鈕實際送出（模擬器測試只能驗證到測試伺服器回 501）
- [run 40208126240](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40208126240)：遠端控制 UI 測試通過，但 test01 的警告文字比對被 NSPredicate 漏看（文字其實正確）；改用 poll 直接讀
- [run 40209294577](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40209294577)（`fdba969`）：單元測試 `Executed 117 tests, with 0 failures`、UI 測試 `Executed 16 tests, with 0 failures`；截圖確認確認對話框「確定停止挖礦／取消」與送出後的結果訊息。IPA 379,229 bytes（runner 內，未上傳）
- [run 40210990544](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40210990544)（第一次發布）：test01、test11 又被 NSPredicate 漏看文字（runner 特別慢，UI 測試 598 秒），沒有建立 Release；共用的 `waitFor` 全面改用 poll
- [run 40212351070](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40212351070)（`880f001`）：單元測試 `Executed 117 tests, with 0 failures`、UI 測試 `Executed 16 tests, with 0 failures`

## 0.5.0（build 7，待發布）：開挖建議

- 使用者要求：收益回來時提醒可以把筆電開機挖，反過來收益差到扣電費不划算時也提醒停掉要算電費的那台；只對要算電費的機器
- 電腦端已上線（2026-10-26）：每 10 分鐘估算，6 小時平均越過門檻才改變建議並推播；關機中的機器設「達到某金額建議挖、低於稍低金額建議停」，在跑的機器設「扣電費後虧損就建議停」
- App：清單的「開挖建議」區塊、資料格式加選填 `advice`（feature `advice`）
- [run 40279093799](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40279093799)（`1cd5dc9`）：單元測試 `Executed 121 tests, with 0 failures`、UI 測試 `Executed 17 tests, with 0 failures`；截圖確認「開挖建議」區塊顯示關機中的示範筆電「建議挖礦」（綠）與虧損機器「建議停挖」（橘、NT$-35）。IPA 393,533 bytes（runner 內，未上傳）

## 0.6.3（build 11，開發中）：累計收益（估算）

- 使用者要求：顯示從開挖以來累計的估算收益（新台幣），標明是估算，月底再拿礦池網頁的帳號數字對帳。礦池把每種幣自動換成 BTC 存在帳號裡，帳號餘額沒有公開 API 可讀，所以只能估算。
- 電腦端：每 5 分鐘把每台**正在挖**的機器當下的估算收益（跟每天估算同一個數字）乘上經過的時間累加，各自用自己的幣，台幣用當時的幣價與匯率換算；存成檔案，重開服務不會歸零。服務沒在跑的時間不補算。
- 資料格式：feed 加選填 `cumulative`（feature `cumulative`）：`since`、`observedAt`、`totalTwd`、`totalBtc`（每筆依當時幣價換成 BTC 的合計，礦池帳號就是用 BTC 記帳，月底直接比 BTC），以及每台的 `machineId`、`coin`、`amount`、`twd`。舊版 App 不會要這個 feature，收到的資料不變。
- App：清單「今日估算」區塊加「累計收益（估算）」、約當 BTC 與開始時間，註明不是實際入帳；詳情頁加該機器的累計幣數與台幣。
- 示範資料：三天前開始累計，共 NT$349、約當 0.000134 BTC（A 4.8 PRL ≈ NT$289、B 0.025 QTC ≈ NT$60）。
- 測試：單元測試多兩項（累計的解碼、格式檢查），UI 測試多一項（test21：清單的累計、B 的詳情頁）；契約檢查多 4 個正向、9 個反向案例。
- [run 40620740699](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40620740699)（`e8a4637`）：App 編譯失敗，`EarningsViews.swift` 把不是 Optional 的 `Timestamp.date` 寫成 `guard let`；下一個 commit 修正。
- [run 40621432567](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40621432567)（`8805930`）：單元測試 `Executed 125 tests, with 0 failures`、UI 測試 `Executed 21 tests, with 0 failures`；截圖確認詳情頁 B 的「累計收益（估算）0.025 QTC、NT$60、不是實際入帳」，清單的累計那一行被截在畫面最底下（測試有找到它），下一個 commit 讓測試先往上捲再截圖。
- 遠端開始／停止（電腦端，同日）：除了筆電，office、RTX 5080、VCU118 也可以從 App 開始／停止（App 不用改，按鈕依來源的 `control` 顯示）。手機自己送出的指令不再發通知，刻意停止的機器顯示「手動停止」、不再發「已停止」通知。

## 0.6.2（build 10，已併入工具箱 0.4.1 build 7 發布）：挖另一種幣的機器也算收益

- 使用者要求：App 也要看到 FPGA 的收益。來源原本只有一組幣價（`market`），挖另一種幣（例如 QTC）的機器會被當成同一種幣計價而算錯，所以來源先不給它收益。
- 資料格式：每台的 `earnings` 加選填 `coin`、`coinUsd`（feature `coins`，只有挖的幣跟 `market` 不同的機器才有）。舊版 App 不會要這個 feature，收到的資料不變。
- App：有自己幣種的機器用它自己的幣價換算台幣（匯率仍用 `market`）；有幣種但沒價格時收益顯示「—」，不會改用 `market` 的幣價。詳情頁「挖到的幣」與「幣價」顯示該機器自己的幣。
- 示範資料：示範礦機 B 改成挖 QTC（150 MH/s、每天 0.0084 QTC、US$73），收益約 NT$20／天。
- 詳情頁「礦池認列算力」改成依大小用 TH/s、GH/s、MH/s 顯示（原本固定 TH/s，FPGA 的 150 MH/s 會變成 0.0 TH/s）；今日估算的說明改成近 30 分鐘平均與礦池公布的每單位收益（電腦端改成跟礦池網頁同一算法）。
- 測試：單元測試多兩項（自己的幣價換算、幣種格式檢查），UI 測試多一項（test20：B 那列與詳情頁用 QTC 計價）。
- [run 40541544053](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40541544053)（`e23865e`）：單元測試 `Executed 123 tests, with 0 failures`、UI 測試 `Executed 20 tests, with 0 failures`；截圖確認 B 那列「收益 ≈ NT$20/天・電費不計」、詳情頁「挖到的幣 0.008 QTC」，但「礦池認列算力」顯示成 0.0 TH/s，下一個 commit 修正。

## 0.6.1（build 9，開發中）：被 iOS 關掉後自動接回來源

- 使用者回報：放久一點再進 App，有時會跳回示範畫面。原因：iOS 會把放在背景太久的 App 關掉，而 App 每次啟動都從示範開始。
- 修正：開始讀取時記下 `resumeLive`；下次啟動時，如果這個標記還在、已存的網址也還有效，就自動用同一個來源開始讀取。按「停止讀取」會清掉標記，下次就從示範開始。
- UI 測試多一項（test19：重開後自動接回、停止後重開回到示範）；其他測試以 `-resumeLive NO` 啟動，一律從示範開始。
- [run 40333403998](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40333403998)（`2492e8a`）：單元測試 `Executed 121 tests, with 0 failures`；UI 測試沒有跑起來，runner 的 UI 測試工具初始化失敗（`Failed call to AXDisableAccessibilityOnTermination: kAXErrorCannotComplete`），是 runner 環境問題，不是程式錯誤；用這次紀錄的 commit 重跑

## 0.6.0（build 8，已發布 [Release miner-status-0.6.0-build8](https://github.com/chunyen627-afk/mobile-apps/releases/tag/miner-status-0.6.0-build8)）：遠端開機、依電價自動挖礦

- 使用者要求：開挖建議的筆電那列加遠端開機按鈕，開機後自動接回監控與遠端開始挖礦；並讓電腦端自動化：離峰划算就自動開機挖、尖峰只有划算才挖
- 網路喚醒已實測（2026-10-26）：筆電關機後由同一網路裡的另一台電腦送封包，6 秒後開機、約 40 秒後可遠端連線
- App：開挖建議的「遠端開機」按鈕與確認、資料格式 `advice` 每列加選填 `canWake`（feature `wake`）
- [run 40290433032](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40290433032)（`21d9ede`）：單元測試 `Executed 121 tests, with 0 failures`、UI 測試 `Executed 18 tests, with 0 failures`；截圖確認只有可喚醒的示範筆電有「遠端開機」、按下先跳確認、送出後顯示結果（測試伺服器回 501）。IPA 402,379 bytes（runner 內，未上傳）
- 電腦端自動化實測（2026-10-26，公告離峰日）：狀態服務重啟約 1.5 分鐘後自動叫醒筆電、3 分鐘後自動開始挖礦

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
