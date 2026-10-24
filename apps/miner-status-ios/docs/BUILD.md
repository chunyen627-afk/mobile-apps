# 建置

以下步驟**尚未實際執行**：撰寫時沒有可用的 Swift／Xcode。第一次在 Mac 上照做時，請把實際結果記到 [狀態](STATUS.md)。

## 需求

- macOS 與 Xcode 15 以上（Swift 5.9，`swift-tools-version:5.9`）
- App 最低 iOS 16；核心套件另支援 macOS 13，供 `swift test` 使用

## 1. 核心與 XCTest

```sh
cd apps/miner-status-ios
swift build
swift test
```

測試以 `#filePath` 讀取 `fixtures/`，請在完整的原始碼目錄執行，不適用於打包進裝置的測試 bundle。

## 2. 建立 iOS App 專案（iOS 16+）

此目錄沒有 Xcode 專案檔，需手動建立：

1. 在 Xcode 選 File › New › Project › iOS › App，Interface 選 SwiftUI、Language 選 Swift，Minimum Deployments 設為 iOS 16.0。
2. 加入本機套件：File › Add Package Dependencies… › Add Local…，選 `apps/miner-status-ios`，把 `MinerStatusCore` 連結到 App target。
3. 刪除範本產生的 `<名稱>App.swift` 與 `ContentView.swift`（避免兩個 `@main`），再把 `iOSApp/MinerStatusApp.swift` 加入 App target。
4. 把 `fixtures/demo-running.json` 加入 App target 的 Copy Bundle Resources。缺少它時，App 會顯示載入錯誤，不會自行生成資料。
5. 在 iPhone 與 iPad 模擬器執行，逐一切換七種示範情境，核對燈號、文字、示範橫幅與詳情欄位。

## 3. IPA

尚未產生，也還沒有對應的 CI workflow。之後若要以 GitHub 標準 macOS runner 建置，需另外新增 workflow 並先確認觸發條件與費用；產出前必須完成模擬器驗證。未驗證的產物不交付安裝。

## 4. Windows 上可執行的檢查

```powershell
python -I tools\validate_contract.py --verbose
python -I tools\check_swift_syntax.py
```

需要已安裝 `jsonschema`；語法剖析另需 `tree-sitter-language-pack`。腳本不安裝套件。兩者都不能代替 Swift 編譯與 XCTest。
