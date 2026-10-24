# 狀態

最後更新：2026-10-24。

## 已實際執行

在 Windows 上執行，使用 Python 3.11.9、jsonschema 4.23.0、tree-sitter-language-pack 1.10.1。

| 檢查 | 指令 | 結果 |
| --- | --- | --- |
| JSON 契約與 fixtures | `python -I tools/validate_contract.py --verbose` | PASS |
| Swift 語法剖析 | `python -I tools/check_swift_syntax.py` | 9 個 Swift 檔，0 個語法問題 |

契約檢查的範圍：

- schema 本身通過 Draft 2020-12 meta-schema 驗證；3 個 fixtures 全部有效，標示為 demo，且不含 IP、路徑或憑證類字詞。
- 104/104 個反例被拒收：
  - 各層缺 key、非白名單 key
  - 型別錯誤，包括布林與整數互相冒充
  - 列舉、範圍、識別欄位
  - 重複 `machineId`、demo 標示規則
  - 15 種無效時間（缺時區、不存在的日期、閏秒、全形數字、結尾換行等），以及截斷的 JSON
- 13/13 個正例被接受：全部可為 null 的欄位都填 null、`"unknown"`、邊界值、合法時間格式等。
- 2 月 30 日、非閏年 2 月 29 日等案例會通過 schema 的正則；它們被拒收，證明自訂的 RFC 3339 日曆檢查確實生效。

語法剖析曾在 App 檔發現 2 處 tree-sitter 無法剖析的 `as? … ?? …` 寫法，加上括號後通過；另把兩處三元運算改寫為 `if` 或區域常數。這只代表語法可剖析，不代表型別檢查通過。

## 未執行

| 項目 | 狀態 |
| --- | --- |
| `swift build` | 未執行；沒有 Swift 工具鏈 |
| XCTest 65 項（模型 16、引擎 41、fixture／文字 8） | 未編譯、未執行 |
| SwiftUI App | 未編譯；未在模擬器或實機檢視畫面 |
| iPad 版面 | 未驗證 |
| IPA、簽署、安裝 | 未產生 |
| 真實資料來源 API | 未實作、未驗證；目前沒有已驗證可用的來源端點 |

Python 契約檢查只驗證 JSON 契約，**不是** Swift 狀態引擎的測試；兩者沒有互相替代的關係。

## 下一步

1. 在 Mac 上執行 `swift test`，修正編譯錯誤，並記錄實際的通過與失敗數。
2. 依 [建置](BUILD.md) 建立 iOS 16 App 專案，在 iPhone 與 iPad 模擬器逐一檢查七種情境。
3. 定案真實資料的發佈端與傳輸方式，再撰寫連線層與對應測試。
4. 需要 CI 或 IPA 時，另外提出 workflow 與費用評估。
