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

最新通過：[run 40095550434](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40095550434)，來源 `2031641`，Xcode 16.4、iPhone 16 Pro 模擬器。以下數字取自該 run 的公開 annotation。

| 檢查 | 結果 |
| --- | --- |
| `xcodegen generate`、模擬器 Debug 編譯（核心 framework、App、測試） | 通過 |
| XCTest | `Executed 80 tests, with 0 failures (0 unexpected)` |
| 模擬器啟動檢查（離線示範，8 秒後仍在執行） | 通過；截圖只存在 1 天期的 artifact，**尚未人工檢視** |
| Release archive、bundle 檢查（主程式、`demo-running.json`、`MinerStatusCore.framework`、ATS、無背景模式） | 通過 |
| 未簽署 IPA | 211,736 bytes，SHA256 `6ccd7347311e31e9e8b00ba71674d1b7c895c998ae58800a582b85a3ba74208b`；只在 runner 內，**未上傳** |

修正紀錄：

1. [run 40094203491](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094203491)：舊的 SwiftPM `swift test` 流程，建置步驟失敗（當時沒有 annotation，log 需登入）；改為 album-ios 架構
2. [run 40094798800](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094798800)：首次實際編譯，`StatusEngine.swift` 修改 `trackers` 時同時讀 `self.policy`，觸發重疊存取錯誤；改用區域常數
3. [run 40095024930](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40095024930)：全部通過；之後補上公開 notice，讓測試數與 IPA SHA256 不登入也能查證

## 未執行

| 項目 | 狀態 |
| --- | --- |
| 七種示範情境與自訂來源畫面 | 未人工檢視（iPhone 與 iPad 模擬器都還沒看） |
| iPad 版面 | 未驗證 |
| 簽署、安裝、實機 | 未執行；IPA 未上傳 |
| 真實資料來源 | 未連線；沒有已驗證可用的來源端點；ATS 對 HTTP 私有位址的效果未驗證 |

Python 檢查只驗證 JSON 契約與設定文字，**不是** Swift 程式的測試，不能互相替代。

## 下一步

1. 在 iPhone 與 iPad 模擬器逐一檢查七種示範情境與自訂來源畫面，包括錯誤與暫停狀態。
2. 要安裝到手機時，才在 workflow 上傳 IPA（加大小上限、短保留期），由本人簽署安裝。
3. 來源端確認可用後，在實機以自訂來源驗證：ATS、本地網路權限、失敗與重連。
