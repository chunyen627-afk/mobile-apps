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

## 未執行

| 項目 | 狀態 |
| --- | --- |
| iPad 版面 | 未驗證（UI 測試只在 iPhone 模擬器執行） |
| 簽署、安裝、實機 | 未執行；IPA 已發布，待本人簽署安裝 |
| 真實資料來源 | 未連線；沒有已驗證可用的來源端點；ATS 對 HTTP 私有位址的效果未驗證 |

Python 檢查只驗證 JSON 契約與設定文字，**不是** Swift 程式的測試，不能互相替代。

## 下一步

1. 本人簽署並安裝 0.1.0 build 1，在實機確認開啟、示範情境與設定畫面。
2. 需要時加 iPad 模擬器的 UI 測試與截圖。
3. 來源端確認可用後，在實機以自訂來源驗證：ATS、本地網路權限、失敗與重連。
