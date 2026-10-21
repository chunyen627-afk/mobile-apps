# Mobile Apps

個人手機 App 專案集。每個 App 有獨立目錄、使用說明與編譯流程。

| App | 平台 | 用途 | 驗證狀態 |
| --- | --- | --- | --- |
| [光盒相簿](apps/album-ios) | iPhone / iOS 17+ | SMB 相簿、掃描清單記憶、照片預載與影片滿版播放 | 0.2.0 修正及模擬器 UI 測試已加入，尚待本次 CI 驗證；0.1.0 實機回報重掃、控制列、切頁及重新勾選播放閃退問題 |

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

前往 [已驗證的修正版編譯](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39532413253)，在 Artifacts 下載 `Lightbox-unsigned-ipa`。Xcode 編譯、5 項單元測試與 SMB 動態程式庫封裝檢查均通過。產物到期時可從 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml) 手動重建。首次執行的舊產物缺少程式庫，不應安裝。

產物為**未簽署 IPA**，需用自己的 Apple 帳號簽署後才能裝到 iPhone。Windows 可使用 Sideloadly；免費帳號簽署需每 7 天續簽。編譯成功不代表手機上的 SMB 連線與播放已經通過實測。完整功能、設定與限制請看 [相簿 README](apps/album-ios/README.md)。

本公開倉庫使用 GitHub 標準 macOS runner，workflow 會在私人倉庫跳過。不要將照片、真實連線設定、密碼或 Apple 憑證提交到倉庫。

## 文件維護

每次功能、操作方式、建置流程、限制或驗證結果變更時，同步更新對應 App 的 README；影響專案總覽時也更新此檔案。明確分開實作完成、編譯通過、模擬器通過與實機通過，並附上測試證據。

最後更新：2026-10-21。
