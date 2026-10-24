# 狀態

最後更新：2026-10-24。

## 已實際執行

在 Windows 上執行，使用 Python 3.11.9、jsonschema 4.23.0、tree-sitter-language-pack 1.10.1。

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
- **XcodeGen 規格**：iOS 16、本機套件 `..`、連結 `MinerStatusCore`、內建 `demo-running.json`、明確的 Info.plist、沒有遠端套件。
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

## 未執行

| 項目 | 狀態 |
| --- | --- |
| `swift build`、`swift test` | 未執行；沒有 Swift 工具鏈 |
| XCTest 80 項（模型 16、引擎 41、client 15、fixture／文字 8） | 未編譯、未執行 |
| `xcodegen generate`、`scripts/build.sh` | 未執行；沒有 Mac／Xcode／XcodeGen |
| SwiftUI App（示範與自訂來源） | 未編譯；未在模擬器或實機檢視畫面 |
| iPad 版面 | 未驗證 |
| IPA、簽署、安裝 | 未產生 |
| 真實資料來源 | 未連線；沒有已驗證可用的來源端點；ATS 對 HTTP 私有位址的效果未驗證 |
| CI | 已撰寫 `.github/workflows/miner-status-ios.yml`，**尚未執行**；見 [建置](BUILD.md#ci) |

Python 檢查只驗證 JSON 契約與設定文字，**不是** Swift 程式的測試，不能互相替代。

## 剩下的阻塞

唯一阻塞是需要 macOS 與 Xcode。可選的做法：

1. **自有 Mac**：在 `apps/miner-status-ios` 執行 `bash scripts/build.sh`，再在模擬器人工檢查畫面。
2. **GitHub 標準 macOS runner**：workflow 已撰寫，push 到 `claude/miner-status-ios-demo` 且變更 `apps/miner-status-ios/**` 時觸發，見 [建置](BUILD.md#ci)。

第一次編譯很可能出現需要修正的編譯錯誤，修正後才能談測試結果。

## 下一步

1. 在 Mac 或 CI 執行 `scripts/build.sh`，修正編譯錯誤，並記錄實際的通過與失敗數。
2. 在 iPhone 與 iPad 模擬器逐一檢查七種示範情境與自訂來源畫面，包括錯誤與暫停狀態。
3. 來源端確認可用後，在實機以自訂來源驗證：ATS、本地網路權限、失敗與重連。
