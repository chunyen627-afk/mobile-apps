# Mobile Apps

個人手機 App 專案集。每個 App 有獨立目錄、使用說明與編譯流程。

0.3.1 保留資料夾索引跨勾選組合重用、手機本機診斷匯出及 VLC 解碼，新增掃描階段診斷並移除影片裁切選項，一律完整等比例顯示。來源 `1d2e425` 通過 34 項單元、5 項模擬器 UI 測試及 Release 封裝，已檢查原生影片、兩種 AVI 與診斷匯出畫面；已覆蓋更新手機，USB 讀回確認 0.3.1／build 4。新版實機功能與長時間穩定性待確認，偶發閃退原因仍未確認。

| App | 平台 | 用途 | 驗證狀態 |
| --- | --- | --- | --- |
| [光盒相簿](apps/album-ios) | iPhone / iOS 17+ | SMB 相簿、資料夾索引、照片預載、影片播放與診斷匯出 | 0.3.1 的 39 項測試、畫面檢查及封裝通過；已覆蓋安裝並讀回確認 build 4，新版功能回歸與偶發退出問題待實機驗證 |

## 目錄

```text
apps/
  album-ios/               光盒相簿（SwiftUI 原生 App）
.github/workflows/
  album-ios.yml            相簿的 macOS 編譯與測試
```

後續新 App 放在 `apps/<名稱>/`，各自建立 README 與必要的 workflow。STM32 板子相關內容留在 [stm32h7s78-project](https://github.com/chunyen627-afk/stm32h7s78-project)。

## 相簿下載與安裝

先在 macOS CI 的 iPhone 模擬器執行單元測試與實際 UI 操作，保留截圖，通過後才產出供手機更新的 IPA。Windows 本機沒有 Apple iOS 模擬器。模擬器使用人工產生的媒體，不含私人相簿；實際 SMB、iPhone 效能與裝置限定問題仍需實機確認。

前往 [0.3.1 已驗證編譯](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39559469901)，在 Artifacts 下載 `Lightbox-unsigned-ipa`。來源 `1d2e425`，Xcode 16.4、iPhone 16 Pro / iOS 18.5 模擬器，39 項測試與封裝檢查均通過，另保留截圖及閃退分析符號檔。產物到期時可從 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml) 手動重建。

產物為**未簽署 IPA**，需用自己的 Apple 帳號簽署後才能裝到 iPhone。Windows 可使用 Sideloadly；免費帳號簽署需每 7 天續簽。編譯成功不代表手機上的 SMB 連線與播放已經通過實測。完整功能、設定與限制請看 [相簿 README](apps/album-ios/README.md)。

本公開倉庫使用 GitHub 標準 macOS runner，workflow 會在私人倉庫跳過。不要將照片、真實連線設定、密碼或 Apple 憑證提交到倉庫。

## 文件維護

通用入門與 AI 交接請先讀 [Windows → iPhone 免費開發與安裝快速上手](docs/windows-iphone-quickstart.md)。指南不包含特定 App 名稱、個人帳號、網路位址或私人路徑；倉庫內版本為原稿。當前以 iPhone 為優先；實際 0.3.1 IPA 宣告 iPhone／iPad，但 iPad 尚未驗證。

每次功能、操作方式、建置流程、限制或驗證結果變更時，同步更新對應 App 的 README；影響專案總覽時也更新此檔案。明確分開實作完成、編譯通過、模擬器通過與實機通過，並附上測試證據。

最後更新：2026-10-21。
