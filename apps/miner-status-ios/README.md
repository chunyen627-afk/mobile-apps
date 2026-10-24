# 礦機狀態（iPhone 示範版）

以燈號與白名單詳情顯示礦機挖礦狀態的 SwiftUI App。目前是**示範版**：只讀內建的人工示範資料，不連線、不輪詢、不控制礦機。

## 驗證狀態

| 項目 | 狀態 |
| --- | --- |
| JSON 契約（schema）、合成示範 fixtures | 實作完成；Windows 上以 Python 實際執行契約檢查通過（見 [狀態](docs/STATUS.md)） |
| 純 Swift 狀態核心 `MinerStatusCore` | 實作完成；**未編譯** |
| XCTest（65 項） | 已撰寫；**未編譯、未執行** |
| SwiftUI 示範 App | 實作完成；**未編譯、未在模擬器或實機檢視** |
| Swift 語法剖析（tree-sitter） | Windows 上執行通過；只代表可剖析，不代表型別檢查或編譯通過 |
| 真實資料來源 API、iPhone 讀取方式 | 未實作、未驗證 |
| IPA | 未產生 |

「實作完成」不等於「編譯通過」。Swift 編譯、XCTest、模擬器與實機都需要 Apple 工具鏈，詳見 [建置](docs/BUILD.md)。

## 燈號

| 燈號 | 意義 |
| --- | --- |
| 綠 | miner 運行中，且同一工作（session）的兩筆新資料之間觀測到接受份額增加 |
| 黃 | 連得到但無法確認挖礦：首筆資料、狀態未知、最近一次更新失敗或被拒收等 |
| 紅 | 近期資料明確確認 miner 已停止 |
| 灰 | 超過 5 分鐘沒有有效資料、資料不足或時間無法驗證；**不代表主機離線** |

算力大於 0、累計接受份額或「最後接受時間」單獨都不會亮綠。缺值（JSON null）顯示「無資料」，`"unknown"` 顯示「未知」；過期或未確認的數值標為歷史資料。完整規則見 [架構](docs/ARCHITECTURE.md)。

## 目錄

```text
Package.swift                 SwiftPM：MinerStatusCore + 測試
Sources/MinerStatusCore/      Codable 模型、狀態引擎、顯示文字（純 Swift，無 UI）
Tests/MinerStatusCoreTests/   XCTest
iOSApp/MinerStatusApp.swift   SwiftUI 示範 App（需另建 Xcode App 專案引用）
schema/                       JSON Schema（Draft 2020-12）
fixtures/                     合成示範資料（全部標示 demo）
tools/validate_contract.py    契約／fixture 檢查（Python + jsonschema）
tools/check_swift_syntax.py   Swift 語法剖析（選用，非編譯）
docs/                         架構、建置、狀態
```

## Windows 上可執行的檢查

需已安裝 Python 3 與 `jsonschema`；語法剖析另需 `tree-sitter-language-pack`。腳本不會安裝任何套件。

```powershell
python -I tools\validate_contract.py --verbose
python -I tools\check_swift_syntax.py
```

前者只檢查 JSON 契約，**不是** Swift 狀態引擎的測試；後者只檢查語法，不能代替 Swift 編譯。

## 限制

- 示範資料為人工編寫，App 全程顯示示範橫幅與凍結的模擬時鐘。
- 不提供背景輪詢或通知；iOS 無法保證背景精準每 5 分鐘更新。
- 真實來源的發佈方式、傳輸與認證尚未定案；接上前需另行設計並驗證。
- 不提交真實連線位址、主機資訊、帳密或原始礦機資料。
