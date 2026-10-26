# 建置

下列步驟已在 GitHub 標準 macOS runner 實際執行通過（Xcode 16.4、iPhone 16 Pro 模擬器，證據見 [狀態](STATUS.md#ci-實際執行github-標準-macos-runner)）。自有 Mac 尚未執行過。

## 需求

- macOS、Xcode 15 以上（Swift 5.9，`swift-tools-version:5.9`）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 契約檢查另需 Python 3 與 `jsonschema`；沒有時建置腳本會標示 SKIPPED，不算通過
- App 最低 iOS 16。`Package.swift` 另支援 macOS 13，只供在 Mac 上選用 `swift test`，建置腳本與 CI 不使用

## 專案結構

沿用 `apps/album-ios` 的架構：本目錄的 `project.yml` 由 XcodeGen 產生 `MinerStatus.xcodeproj`，產生的專案檔不進版控。

| 項目 | 設定 |
| --- | --- |
| App target | `MinerStatus`；來源 `iOSApp`；明確的 `iOSApp/Info.plist`；scheme 執行 `MinerStatusCoreTests` |
| 核心 | framework target `MinerStatusCore`（`Sources/MinerStatusCore`），內嵌於 App；沒有任何套件相依 |
| 測試 | unit-test target `MinerStatusCoreTests`，在 iOS 模擬器執行；fixtures 以 `#filePath` 讀取 |
| 內建資源 | `fixtures/demo-running.json`（離線示範必需，缺少時 App 只顯示載入錯誤） |
| Bundle ID | `org.personal.minerstatus.app`；免費 Apple 帳號會佔用一個 App ID，之後請固定沿用 |
| App 名稱 | `Info.plist` 的 `CFBundleDisplayName` 為英文 `MinerStatus`（SideStore 拿它當 Apple App ID 名稱，中文會被拒絕）；主畫面的「礦機狀態」來自 `iOSApp/zh-Hant.lproj/InfoPlist.strings` |
| 裝置 | `TARGETED_DEVICE_FAMILY = 1,2`；iPhone 優先，iPad 版面未驗證 |
| ATS | 只開 `NSAllowsLocalNetworking`；不設 `NSAllowsArbitraryLoads`，也沒有背景模式 |

## 在 Mac 上建置

在本目錄（`apps/miner-status-ios`）執行：

```sh
bash scripts/build.sh
```

腳本依序執行：

1. `tools/validate_contract.py`（已安裝 `jsonschema` 才執行）
2. `xcodegen generate`
3. 在可用的 iPhone 模擬器上 `xcodebuild test`（不簽署），一次跑兩組：
   - 單元測試 121 項（`EXPECTED_TESTS`）
   - UI 測試 17 項（`EXPECTED_UI_TESTS`）：逐一切換 7 種示範情境並檢查兩台機器的燈號與「不是綠燈」警告區塊、每台與總計的估算收益與健康資訊、切換電費勾選後總計改變、電腦端判斷過時時顯示「電腦端沒有回應」、停止讀取需確認、打開詳情頁、網址驗證、自訂來源讀取本機假資料、讀取失敗提示、停止後回到示範、「今日電價」區塊與台電公告費率設定、遠端控制（存密碼、只對可控制機器顯示、要再確認、送出後顯示結果）、開挖建議（沒有機器列的關機機器也顯示、虧損顯示負數、回到示範後消失）；每個畫面存一張截圖
   - 自訂來源測試用的假資料：腳本在 Mac 的 `127.0.0.1:8765` 以 `fixtures/` 啟動暫時的 HTTP 伺服器，`8799` 埠刻意無人監聽；網址以 `TEST_RUNNER_` 環境變數傳給測試，測試程式內沒有任何位址
   - 兩組都必須剛好跑到預期數量且 0 失敗，否則失敗結束；摘要存到 `build/test-summary.txt`
   - 結束時（含失敗）把截圖匯出成 `build/screenshots-ui/*.jpg` 與 `INDEX.txt`
4. 選用（`RUN_SIM_SMOKE=1`）：安裝並啟動離線示範，8 秒後確認仍在執行，存一張截圖 `build/screenshots/launch-demo.jpg`
5. 裝置用 Release archive（關閉簽署）
6. 檢查 App bundle：主程式存在、內含 `demo-running.json` 與 `MinerStatusCore.framework`、`NSAllowsLocalNetworking` 為 true、沒有 `NSAllowsArbitraryLoads` 與 `UIBackgroundModes`，並列出最低 iOS 版本與 `UIDeviceFamily`
7. 封裝並以 `unzip -t` 檢查 `build/MinerStatus-unsigned.ipa`，SHA256 寫入 `build/MinerStatus-unsigned.ipa.sha256`

在 GitHub Actions 中失敗時，腳本會把失敗階段、錯誤行與 log 結尾輸出為 annotation，不登入也能從公開 API 讀取。

設 `RUN_TESTS=0` 可改為只編譯不測試，但不能據此宣稱測試通過。啟動檢查只確認 App 沒有立即閃退，不是 UI 測試；畫面仍需人工在 iPhone 與 iPad 模擬器逐一檢查七種示範情境與自訂來源畫面。

## 簽署與安裝

產物是**未簽署 IPA**。依根目錄 [Windows → iPhone 快速上手](../../docs/windows-iphone-quickstart.md)，用自己的 Apple 帳號以 Sideloadly 或 SideStore 簽署。帳號操作由本人完成。未經模擬器驗證的產物不交付安裝。

## 自訂來源的實機確認項目

- iOS 是否放行 HTTP 到指定位址：`NSAllowsLocalNetworking` 對虛擬區網或私有 IP 位址的效果尚未驗證。若被拒，App 會顯示「系統拒絕未加密的 HTTP 連線」。可行做法是讓來源改用 HTTPS，或另行評估只在本機設定、不進公開倉庫的 ATS 例外。
- 首次連線時 iOS 可能詢問「本地網路」權限。
- 來源服務本身是否已啟用、是否只允許特定來源連線，屬於來源端設定，不在本 App 處理範圍。

## CI

`.github/workflows/miner-status-ios.yml` 已實際執行通過，最新為 [run 40102507820](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40102507820)。測試數、工具版本與 IPA SHA256 以 `::notice` annotation 公開，不登入也能從 API 讀取。

- 觸發：只有 `push` 到 `claude/miner-status-ios-demo`，且變更 `apps/miner-status-ios/**` 或 workflow 檔本身時。沒有 `workflow_dispatch`，因為它要求 workflow 檔存在於預設分支，而本 App 不合併 main
- 條件：`if: github.event.repository.private == false`，標準 `macos-15` runner，`timeout-minutes: 30`，同 ref 取消舊執行
- 權限 `contents: write`：只用來把模擬器截圖強制推到專用分支 `ci-screenshots-miner-status-ios`（每次覆蓋、不留歷史、上限 5 MB、只有示範資料），讓截圖不登入也能檢視
- 步驟：checkout → `brew install xcodegen` → `RUN_SIM_SMOKE=1 bash scripts/build.sh`
- IPA **不上傳**：只在 runner 內產生，大小與 SHA256 印在執行紀錄與 Summary
- 只上傳 `MinerStatus-reports`（`test-summary.txt` 與一張啟動截圖），總和超過 1 MB 時 workflow 失敗且不上傳；保留 1 天，到期由 GitHub 自動刪除
- 給手機安裝的 IPA 以**公開 GitHub prerelease** 發布，只在 commit 訊息含 `[release-ipa]` 時執行；這個標記每次都要先經使用者同意才加。發布在所有測試與 bundle 檢查通過之後，IPA 超過 5 MB 或同一 build 號已發布過就失敗。Tag 為 `miner-status-<版本>-build<build 號>`，再發布前要先調高 `CURRENT_PROJECT_VERSION`

費用：公開倉庫使用標準 GitHub-hosted runner（含 `macos-15`）的分鐘數免費，見 [GitHub Actions 計費說明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。Artifact 儲存額度對公開倉庫是否另計，官方文件未寫明，因此只上傳小檔、保留 1 天。

實測：`macos-15` 映像為 Xcode 16.4、iPhone 16 Pro 模擬器；每次 run 約 6 到 12 分鐘（含排隊）。

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
