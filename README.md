# Mobile Apps

個人手機 App 專案集。每個 App 有獨立目錄、使用說明與編譯流程。

| App | 平台 | 用途 | 驗證狀態 |
| --- | --- | --- | --- |
| [光盒相簿](apps/album-ios) | iPhone / iOS 17+ | 透過 SMB 瀏覽電腦相簿、勾選資料夾或影片、遞迴掃描與全螢幕播放 | 原始碼已建立；首次 Xcode 編譯及手機實測待完成 |

## 目錄

```text
apps/
  album-ios/               光盒相簿（SwiftUI 原生 App）
.github/workflows/
  album-ios.yml            相簿的 macOS 編譯與測試
```

後續新 App 放在 `apps/<名稱>/`，各自建立 README 與必要的 workflow。STM32 板子相關內容留在 [stm32h7s78-project](https://github.com/chunyen627-afk/stm32h7s78-project)。

## 相簿下載與安裝

前往 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml)，在成功執行的 Artifacts 下載 `Lightbox-unsigned-ipa`。目前仍在首次編譯驗證階段。

產物為**未簽署 IPA**，需用自己的 Apple 帳號簽署後才能裝到 iPhone。Windows 可使用 Sideloadly；免費帳號簽署需每 7 天續簽。編譯成功不代表手機上的 SMB 連線與播放已經通過實測。完整功能、設定與限制請看 [相簿 README](apps/album-ios/README.md)。

本公開倉庫使用 GitHub 標準 macOS runner，workflow 會在私人倉庫跳過。不要將照片、真實連線設定、密碼或 Apple 憑證提交到倉庫。

## 文件維護

每次功能、操作方式、建置流程、限制或驗證結果變更時，同步更新對應 App 的 README；影響專案總覽時也更新此檔案。明確分開實作完成、編譯通過、模擬器通過與實機通過，並附上測試證據。

最後更新：2026-10-21。
