# Mobile Apps

個人手機 App 專案集。每個 App 有獨立目錄、使用說明與編譯流程。

0.3.1 保留資料夾索引跨勾選組合重用、手機本機診斷匯出及 VLC 解碼，新增掃描階段診斷並移除影片裁切選項，一律完整等比例顯示。來源 `1d2e425` 通過 34 項單元、5 項模擬器 UI 測試及 Release 封裝，已檢查原生影片、兩種 AVI 與診斷匯出畫面；已覆蓋更新手機，USB 讀回確認 0.3.1／build 4。新版實機功能與長時間穩定性待確認，偶發閃退原因仍未確認。

| App | 平台 | 用途 | 驗證狀態 |
| --- | --- | --- | --- |
| [光盒相簿](apps/album-ios) | iPhone / iOS 17+ | SMB 相簿、資料夾索引、照片預載、影片播放與診斷匯出 | 0.3.1 的 39 項測試、畫面檢查及封裝通過；已覆蓋安裝並讀回確認 build 4，新版功能回歸與偶發退出問題待實機驗證 |
| [礦機狀態](https://github.com/chunyen627-afk/mobile-apps/tree/claude/miner-status-ios-demo/apps/miner-status-ios) | iPhone / iOS 16+ | 以燈號與詳情顯示礦機挖礦狀態、估算收益與電費、累計收益估算（新台幣與約當 BTC）、今日電價、開挖建議；需控制密碼的遠端開始／停止與遠端開機；預設離線示範，可設定來源（僅前景） | 0.6.3 build 11：125 項單元、21 項模擬器 UI 測試 0 失敗，截圖已人工檢視（[run 40623881960](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40623881960)）。0.6.1 起只隨工具箱發布；單獨版最後一版是 [Release miner-status-0.6.0-build8](https://github.com/chunyen627-afk/mobile-apps/releases/tag/miner-status-0.6.0-build8)。build 2 實機通過並讀到真實資料；0.6.3 的累計收益實機待確認。程式在 `claude/miner-status-ios-demo` 分支，尚未合併 main |
| [工具箱](https://github.com/chunyen627-afk/mobile-apps/tree/claude/toolbox-ios/apps/toolbox-ios) | iPhone / iOS 17+ | 把光盒相簿和礦機狀態合成一個 App，底部分頁切換，只佔 1 個側載名額；沿用相簿的 Bundle ID，覆蓋安裝保留設定 | 0.4.2 build 8（相簿 0.3.2＋礦機 0.6.3）：相簿單元 41、礦機單元 125、工具箱 UI 4、相簿 UI 6 項測試 0 失敗，截圖已人工檢視；IPA 在公開 [Release toolbox-0.4.2-build8](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.4.2-build8)（[run 40631339706](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40631339706)）。手機上已裝較早版本的工具箱，0.4.2 尚未確認安裝。程式在 `claude/toolbox-ios` 分支，尚未合併 main |
| [桌面遙控](https://github.com/chunyen627-afk/mobile-apps/tree/claude/desk-remote/apps/desk-remote-ios) | iPhone / iOS 17+ ＋ Windows 小幫手 | 用手機操作自己電腦上的 Claude 與 Codex 桌面版：看對話、打字或傳照片、允許一次／拒絕、回答選項題、開新對話、停止、切換模型與權限模式、看額度與上下文、看電腦畫面；用 Face ID 核准需要系統管理員權限的指令。電腦端小幫手只走私人網路（ZeroTier） | 0.5.2 build 5：小幫手 87、單元 31、模擬器 UI 26 項測試通過，截圖已人工檢視（[run 40471604033](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40471604033)）；IPA 在公開 [Release desk-remote-0.5.2-build5](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.2-build5)。0.5.0 已裝到 iPhone，並在真的電腦上實測送出、允許一次、選項題、開新對話、停止、照片、推理強度、權限模式與管理員核准；在真的電腦上切換模型尚未實測。程式在 `claude/desk-remote` 分支，尚未合併 main |

## 目錄

```text
apps/
  album-ios/               光盒相簿（SwiftUI 原生 App）
.github/workflows/
  album-ios.yml            相簿的 macOS 編譯與測試
docs/
  ios-app-autonomous-ci.md 新 App 的 AI 自主建置流程與實戰日記
```

礦機狀態的 `apps/miner-status-ios/` 與 `miner-status-ios.yml` 目前在 `claude/miner-status-ios-demo` 分支，工具箱的 `apps/toolbox-ios/` 與 `toolbox-ios.yml` 在 `claude/toolbox-ios` 分支（直接引用相簿與礦機兩個資料夾的原始碼），驗穩後再整合。桌面遙控的 `apps/desk-remote-ios/`（含電腦端小幫手 `pc-helper/`）與 `desk-remote-ios.yml` 在 `claude/desk-remote` 分支，之後會成為工具箱的一個分頁。

後續新 App 放在 `apps/<名稱>/`，各自建立 README 與必要的 workflow，並依 [AI 自主建置流程](docs/ios-app-autonomous-ci.md) 建置與驗證。

**工具箱整合規劃**：免費 Apple 帳號每台裝置只能同時啟用 3 個側載 App（SideStore 本身佔 1 個），每 7 天最多建立 10 個 App ID。因此各工具整合成一個「工具箱」App，只佔 1 個名額、只需續簽一次。流程：每個新工具先做成單獨 App，模擬器測試與截圖檢視通過、實機確認能動，再以同一份原始碼整合進工具箱。工具箱已完成（2026-10-26）：相簿與礦機狀態兩個底部分頁，沿用相簿的 Bundle ID，覆蓋安裝時保留相簿資料。下一個預計加入的是桌面遙控。

STM32 板子相關內容留在 [stm32h7s78-project](https://github.com/chunyen627-afk/stm32h7s78-project)。

## 相簿下載與安裝

先在 macOS CI 的 iPhone 模擬器執行單元測試與實際 UI 操作，保留截圖，通過後才產出供手機更新的 IPA。Windows 本機沒有 Apple iOS 模擬器。模擬器使用人工產生的媒體，不含私人相簿；實際 SMB、iPhone 效能與裝置限定問題仍需實機確認。

前往 [0.3.1 已驗證編譯](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39559469901)，在 Artifacts 下載 `Lightbox-unsigned-ipa`。來源 `1d2e425`，Xcode 16.4、iPhone 16 Pro / iOS 18.5 模擬器，39 項測試與封裝檢查均通過，另保留截圖及閃退分析符號檔。產物到期時可從 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml) 手動重建。

產物為**未簽署 IPA**，需用自己的 Apple 帳號簽署後才能裝到 iPhone。Windows 可使用 Sideloadly；免費帳號簽署需每 7 天續簽。編譯成功不代表手機上的 SMB 連線與播放已經通過實測。完整功能、設定與限制請看 [相簿 README](apps/album-ios/README.md)。

2026-10-21 手機續簽進度：使用者已透過 SideStore 匯入相簿，切回 ZeroTier 後確認設定保留且可播放。重開登出問題經 USB 取證定位為缺少 App Group、反覆執行清除登入的維護；以官方 IPA 覆蓋後權限恢復，連續兩次重開均保持登入。17:13 使用者將 App 全部滑掉、關閉螢幕後，排程成功續簽相簿與 SideStore，USB 讀回兩份新描述檔確認有效至 10/28 17:13（台灣時間）。使用者接受實際續簽成功即可；鎖屏通知未顯示，後續發現通知標題空白，但原因及補填後結果未驗證。Windows 舊背景續簽已停用。下次依 [續簽快速重建與避坑](docs/iphone-renewal-rebuild.md) 接手，避免重走已排除的問題。

本公開倉庫使用 GitHub 標準 macOS runner，workflow 會在私人倉庫跳過。不要將照片、真實連線設定、密碼或 Apple 憑證提交到倉庫。

## 文件維護

通用入門與 AI 交接請先讀 [Windows → iPhone 免費開發與安裝快速上手](docs/windows-iphone-quickstart.md)。指南不包含特定 App 名稱、個人帳號、網路位址或私人路徑；倉庫內版本為原稿。當前以 iPhone 為優先；實際 0.3.1 IPA 宣告 iPhone／iPad，但 iPad 尚未驗證。

每次功能、操作方式、建置流程、限制或驗證結果變更時，同步更新對應 App 的 README；影響專案總覽時也更新此檔案。明確分開實作完成、編譯通過、模擬器通過與實機通過，並附上測試證據。

最後更新：2026-10-28。
