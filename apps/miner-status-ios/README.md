# 礦機狀態（iPhone）

以燈號與白名單詳情顯示礦機挖礦狀態的 SwiftUI App。

- **離線示範**（每次開啟的預設）：只讀內建人工示範資料，不連線。
- **自訂來源（唯讀）**：使用者在「資料來源」填入網址並按「開始讀取」後，才以 GET 讀取。App 只在前景讀取，沒有任何控制礦機的功能。倉庫內沒有任何真實位址。

## 驗證狀態

| 項目 | 狀態 |
| --- | --- |
| JSON 契約（schema）、合成示範 fixtures | 實作完成；Windows 上以 Python 實際執行契約檢查通過 |
| 純 Swift 核心 `MinerStatusCore`（模型、狀態引擎、顯示文字、唯讀 HTTP client） | 實作完成；**未編譯** |
| XCTest（80 項） | 已撰寫；**未編譯、未執行** |
| SwiftUI App（示範＋自訂來源） | 實作完成；**未編譯、未在模擬器或實機檢視** |
| Xcode 專案設定（XcodeGen `App/project.yml`）、建置腳本 `scripts/build.sh` | 已撰寫；**未產生專案、未執行** |
| Swift 語法剖析、靜態設定檢查 | Windows 上執行通過；只代表可剖析與設定內容相符，不代表編譯通過 |
| 真實資料來源 | 未連線驗證；沒有已驗證可用的來源端點 |
| CI workflow、IPA | 已撰寫 `miner-status-ios.yml`（push 到本分支才觸發）；**尚未執行**；IPA 只在 runner 內產生、不上傳 |

「實作完成」不等於「編譯通過」。Swift 編譯、XCTest、模擬器與實機都需要 Apple 工具鏈，詳見 [建置](docs/BUILD.md) 與 [狀態](docs/STATUS.md)。

## 燈號

| 燈號 | 意義 |
| --- | --- |
| 綠 | miner 運行中，且同一工作（session）的兩筆新資料之間觀測到接受份額增加 |
| 黃 | 連得到但無法確認挖礦：首筆資料、狀態未知、最近一次更新失敗或被拒收等 |
| 紅 | 近期資料明確確認 miner 已停止 |
| 灰 | 超過 5 分鐘沒有有效資料、資料不足或時間無法驗證；**不代表主機離線** |

算力大於 0、累計接受份額或「最後接受時間」單獨都不會亮綠。缺值（JSON null）顯示「無資料」，`"unknown"` 顯示「未知」；過期或未確認的數值標為歷史資料。

請求失敗（逾時、無法連線、非 200、非 JSON、過大、轉址到其他位址、格式不符）會立即撤下綠燈，重新連上後須重新建立基準。完整規則見 [架構](docs/ARCHITECTURE.md)。

## 自訂來源

1. 點右上角「資料來源」，填入 `http://` 或 `https://` 網址。網址不可包含帳密或 `#`。
2. 選讀取間隔（15、30 或 60 秒），按「開始讀取（唯讀）」。
3. App 離開前景即停止讀取；回到前景會立刻讀一次。按「停止讀取並回到離線示範」可結束。

注意事項：

- 網址只存在這台裝置（UserDefaults），不會進倉庫。
- 來源必須回傳符合 [schema](schema/miner-status.schema.json) 的 JSON，`Content-Type` 必須含 `json`。
- HTTP 未加密。App 只開啟 `NSAllowsLocalNetworking`，沒有全面關閉 ATS；iOS 是否放行指定位址需實機確認。

## 目錄

```text
Package.swift                 SwiftPM：MinerStatusCore + 測試
Sources/MinerStatusCore/      模型、狀態引擎、顯示文字、唯讀 HTTP client（無 UI）
Tests/MinerStatusCoreTests/   XCTest
iOSApp/                       SwiftUI App 原始碼與 Info.plist
App/project.yml               XcodeGen 規格（App target、本機套件、內建示範資料）
scripts/build.sh              Mac 建置：契約檢查、swift test、編譯、未簽署 IPA
schema/                       JSON Schema（Draft 2020-12）
fixtures/                     合成示範資料（全部標示 demo）
tools/                        Windows 可執行的契約、語法、靜態設定檢查
docs/                         架構、建置、狀態
```

## Windows 上可執行的檢查

需已安裝 Python 3；契約檢查需 `jsonschema`，語法剖析需 `tree-sitter-language-pack`。腳本不會安裝任何套件。

```powershell
python -I tools\validate_contract.py --verbose
python -I tools\check_swift_syntax.py
python -I tools\check_static_policy.py
```

三者都不能代替 Swift 編譯與 XCTest。

## 限制

- 不提供背景讀取或通知；只在前景讀取。
- 示範資料為人工編寫，示範模式全程顯示示範橫幅與凍結的模擬時鐘。
- 不提交真實連線位址、主機資訊、帳密或原始礦機資料。
