# Mobile Apps

個人手機 App 專案集。目前只維護一個 App：**工具箱**，把相簿、礦機狀態、桌面遙控和溫濕度放在同一個 App 裡，用分頁切換，以後的新工具也加在這裡。

| App | 平台 | 用途 | 驗證狀態 |
| --- | --- | --- | --- |
| [工具箱](https://github.com/chunyen627-afk/mobile-apps/tree/claude/toolbox-ios/apps/toolbox-ios) | iPhone／iPad，iOS 17+ | 相簿、礦機狀態、桌面遙控、溫濕度四個分頁（iPhone 在底部、iPad 在上方），只佔 1 個側載名額；沿用相簿的 Bundle ID，覆蓋安裝保留設定 | **0.6.3 build 18**（2026-11-09）：iPhone 與 iPad 模擬器整套測試都通過後才發布（[run 42567927606](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42567927606)），截圖已人工檢視；IPA 在公開 [Release toolbox-0.6.3-build18](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.6.3-build18)。2026-11-09 已裝到 iPhone；這版剪貼簿的新行為（點網址開瀏覽器、點圖片放大、按複製鈕才複製）尚未在手機上逐項確認；iPad 只驗過模擬器。程式在 `claude/toolbox-ios` 分支，尚未合併 main |

工具箱裡的四個分頁：

| 分頁 | 原始碼 | 內容 |
| --- | --- | --- |
| 相簿 | `apps/album-ios` | SMB 相簿、資料夾索引、照片預載、影片播放（含 AVI）與診斷匯出；連不到 NAS 時自動重試 |
| 礦機狀態 | `apps/miner-status-ios` | 燈號、估算收益與電費、累計收益（新台幣與約當 BTC）、今日電價、開挖建議、礦池錢包餘額；需控制密碼的遠端開始／停止與遠端開機；預設離線示範 |
| 桌面遙控 | `apps/desk-remote-ios` | 在手機上操作自己電腦的 Claude 與 Codex 桌面版：看對話、傳文字／語音／照片、回答選項題、按電腦上跳出的視窗、切換模型與推理強度、用 Face ID 核准系統管理員指令、看電腦畫面；手機與電腦互通的剪貼簿。電腦端小幫手在 `pc-helper/`，只走私人網路（ZeroTier） |
| 溫濕度 | `apps/thermo-ios` | 同時看多顆藍牙溫濕度計的溫度、濕度、電量，24 小時／7 天／30 天曲線，可改名、分房間、隱藏；經私人網路讀溫濕度計旁的閘道（`pc-gateway/` 電腦版、`esp32/` 小螢幕板版）。只有工具箱版 |

**單獨的 App 已停止維護（2026-11-08 起）**：光盒相簿、礦機狀態、桌面遙控原本各有單獨的 App，現在只隨工具箱一起測試與發布，不再單獨發版。同一份原始碼仍可建置單獨版。舊的單獨版 Release 留著但不再更新：礦機狀態最後一版 [miner-status-0.6.0-build8](https://github.com/chunyen627-afk/mobile-apps/releases/tag/miner-status-0.6.0-build8)、桌面遙控最後一版 [desk-remote-0.6.2-build14](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.6.2-build14)；相簿一直只有 CI 產物，沒有 Release。

## 下載與安裝

1. 到 [Releases](https://github.com/chunyen627-afk/mobile-apps/releases) 下載最新的 `toolbox-<版本>-build<N>` 裡的 IPA（約 50 MB）。
2. 產物是**未簽署 IPA**，要用自己的 Apple 帳號簽署（SideStore 或 Sideloadly）；免費帳號每 7 天續簽一次。
3. 手機上已經有工具箱或相簿時，**直接覆蓋安裝，不要先刪**，設定會保留。礦機與桌面遙控的設定不會從單獨的 App 帶過來，第一次要在工具箱裡重新設定。

詳細的安裝注意事項、各分頁設定與完整驗證紀錄見[工具箱 README](https://github.com/chunyen627-afk/mobile-apps/blob/claude/toolbox-ios/apps/toolbox-ios/README.md)。

## 建置與發布

只能在 macOS 建置（Windows 沒有 iOS 模擬器），全部在公開倉庫的標準 GitHub macOS runner 上跑：

- 每次推送：電腦端小幫手與閘道的 Python 測試、四個工具各自的單元測試、工具箱與各工具的模擬器 UI 測試（每組都要剛好跑到預期數量且 0 失敗），最後封裝 Release 並檢查內容。
- commit 訊息帶 `[ipad]` 或 `[release-ipa]` 時，再用 iPad mini 模擬器把整套跑一次，並截直向、橫向畫面。
- 帶 `[release-ipa]`（使用者同意發布後才加）時，**iPhone 與 iPad 兩邊都通過**，另一個 `release` 工作才把測過的 IPA 和閃退分析符號檔發布成公開 prerelease（2026-11-09 起；0.6.2 build 17 曾在 iPad 還有 2 項失敗時發出，因此改成兩邊都要過）。
- 模擬器只用人工產生的媒體與假的電腦端服務，不含私人資料；SMB、藍牙、實際網路與手機效能仍需實機確認。

## 目錄

```text
apps/
  album-ios/          相簿（SwiftUI）
  miner-status-ios/   礦機狀態（SwiftUI、XcodeGen）
  desk-remote-ios/    桌面遙控（SwiftUI；pc-helper/ 是電腦端小幫手）
  thermo-ios/         溫濕度（只在工具箱裡；pc-gateway/、esp32/ 是閘道）
  toolbox-ios/        工具箱（直接編譯上面四個資料夾的原始碼，不複製）
.github/workflows/    各 App 的 macOS 編譯與測試
docs/                 開發流程、續簽與交接文件
```

main 目前只有 `apps/album-ios`；其他 App 與 workflow 在 `claude/toolbox-ios` 分支，驗穩後再合併。

**為什麼合成一個 App**：免費 Apple 帳號每台裝置同時只能啟用 3 個側載 App（SideStore 自己佔 1 個），每 7 天最多建立 10 個 App ID。合成工具箱只佔 1 個名額、只需續簽一次。新工具先做成單獨 App 在 CI 驗證，穩定後再以同一份原始碼整合進工具箱。

STM32 板子相關內容留在 [stm32h7s78-project](https://github.com/chunyen627-afk/stm32h7s78-project)。

## 文件維護

- 入門與 AI 交接先讀 [Windows → iPhone 免費開發與安裝快速上手](docs/windows-iphone-quickstart.md)；新 App 依 [AI 自主建置流程](docs/ios-app-autonomous-ci.md)。
- 手機續簽、SideStore 登入或環境重建前，先讀 [續簽快速重建與避坑](docs/iphone-renewal-rebuild.md)。
- 功能、操作方式、建置流程、限制或驗證結果變更時，同步更新對應 App 的 README；影響總覽時也更新此檔案。明確分開實作完成、編譯通過、模擬器通過與實機通過，並附上測試證據。
- 不要把照片、真實連線設定、密碼、Apple 憑證或本機暫存提交到倉庫。

最後更新：2026-11-09。
