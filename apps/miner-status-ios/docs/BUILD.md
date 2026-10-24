# 建置

下列 Mac 步驟**尚未實際執行**：撰寫時沒有可用的 Swift、Xcode 或 XcodeGen。第一次在 Mac 上執行後，請把實際結果記到 [狀態](STATUS.md)。

## 需求

- macOS、Xcode 15 以上（Swift 5.9，`swift-tools-version:5.9`）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 契約檢查另需 Python 3 與 `jsonschema`；沒有時建置腳本會標示 SKIPPED，不算通過
- App 最低 iOS 16。核心套件另支援 macOS 13，供 `swift test` 使用

## 專案結構

`App/project.yml` 由 XcodeGen 產生 `App/MinerStatus.xcodeproj`。產生的專案檔不進版控。

| 項目 | 設定 |
| --- | --- |
| App target | `MinerStatus`；來源 `../iOSApp`；明確的 `iOSApp/Info.plist` |
| 本機套件 | `packages.MinerStatus.path: ..`；連結 product `MinerStatusCore` |
| 內建資源 | `../fixtures/demo-running.json`（離線示範必需，缺少時 App 只顯示載入錯誤） |
| Bundle ID | `org.personal.minerstatus.app`；免費 Apple 帳號會佔用一個 App ID，之後請固定沿用 |
| 裝置 | `TARGETED_DEVICE_FAMILY = 1,2`；iPhone 優先，iPad 版面未驗證 |
| ATS | 只開 `NSAllowsLocalNetworking`；不設 `NSAllowsArbitraryLoads`，也沒有背景模式 |

## 在 Mac 上建置

在本目錄（`apps/miner-status-ios`）執行：

```sh
bash scripts/build.sh
```

腳本依序執行：

1. `tools/validate_contract.py`（已安裝 `jsonschema` 才執行）
2. `swift test`（核心與 80 項 XCTest，在 macOS 主機執行）
3. `xcodegen generate`
4. 模擬器 Debug 編譯（不簽署）
5. 裝置用 Release archive（關閉簽署）
6. 檢查 App bundle：主程式存在、內含 `demo-running.json`、`NSAllowsLocalNetworking` 為 true、沒有 `NSAllowsArbitraryLoads` 與 `UIBackgroundModes`，並列出最低 iOS 版本與 `UIDeviceFamily`
7. 封裝並以 `unzip -t` 檢查 `build/MinerStatus-unsigned.ipa`

設 `RUN_TESTS=0` 可略過 `swift test`，但不能據此宣稱測試通過。目前沒有模擬器 UI 測試，畫面需人工在 iPhone 與 iPad 模擬器逐一檢查七種示範情境與自訂來源畫面。

## 簽署與安裝

產物是**未簽署 IPA**。依根目錄 [Windows → iPhone 快速上手](../../docs/windows-iphone-quickstart.md)，用自己的 Apple 帳號以 Sideloadly 或 SideStore 簽署。帳號操作由本人完成。未經模擬器驗證的產物不交付安裝。

## 自訂來源的實機確認項目

- iOS 是否放行 HTTP 到指定位址：`NSAllowsLocalNetworking` 對虛擬區網或私有 IP 位址的效果尚未驗證。若被拒，App 會顯示「系統拒絕未加密的 HTTP 連線」。可行做法是讓來源改用 HTTPS，或另行評估只在本機設定、不進公開倉庫的 ATS 例外。
- 首次連線時 iOS 可能詢問「本地網路」權限。
- 來源服務本身是否已啟用、是否只允許特定來源連線，屬於來源端設定，不在本 App 處理範圍。

## CI（未新增；需父層決定）

目前**沒有** workflow，本 App 的提交不會觸發任何 Actions。若要以雲端 macOS 建置，建議方案如下（尚未建立、未執行）：

- 檔案：`.github/workflows/miner-status-ios.yml`
- 條件：比照 `album-ios.yml`。`if: github.event.repository.private == false`，使用標準 `macos-15` runner，`timeout-minutes: 30`，同 ref 取消舊執行，`permissions: contents: read`
- 步驟：checkout → `brew install xcodegen` → `bash apps/miner-status-ios/scripts/build.sh` → 上傳 `MinerStatus-unsigned.ipa`（保留 3 天）
- 觸發：`workflow_dispatch` 只有在 workflow 檔已存在於預設分支（main）時才能手動執行。若只放在本分支，就需要 `push` 觸發才會跑。兩者都會改變倉庫行為，需事先決定

費用依據與未知項：

- 依本倉庫 `AGENTS.md`、根 README 與快速上手文件，公開倉庫使用標準 GitHub-hosted runner 不收費，既有 `album-ios.yml` 也以此為前提。本次**未**重新核對 GitHub 計費頁，啟用前請以 [GitHub Actions 計費說明](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 為準。
- 未知項：
  - 當時 `macos-15` 映像的 Xcode 與模擬器版本
  - 排隊時間與 `brew install xcodegen` 耗時
  - Artifact 儲存是否計入額度
  - 首次編譯若失敗需要的修正輪數

## Windows 上可執行的檢查

```powershell
python -I tools\validate_contract.py --verbose
python -I tools\check_swift_syntax.py
python -I tools\check_static_policy.py
```

- 契約檢查只驗證 JSON 契約。
- 語法剖析只確認 tree-sitter 可剖析。
- 靜態設定檢查只比對 Info.plist、XcodeGen 規格與原始碼文字：例如唯讀 GET、沒有寫死的位址、沒有背景模式、啟動時為示範。

三者都不能代替 Swift 編譯與 XCTest。
