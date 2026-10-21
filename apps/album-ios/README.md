# 光盒相簿 — iPhone 原生版原型

SwiftUI + SMB2/3 的個人相簿。目標：iPhone 17、iOS 27、6.3 吋；最低 iOS 17。

**狀態：原始碼與編譯流程已建立，尚未經 Xcode 編譯、模擬器測試或 iPhone 實測；目前沒有已驗證可安裝的 IPA。**

## 使用方式

輸入 SMB 主機、分享名稱、分享內起始資料夾及帳密。允許 iOS「區域網路」權限；使用 ZeroTier 位址時手機也須加入該網路。

點資料夾名稱往下瀏覽，勾選資料夾或個別照片／影片，跨層選取後按開始播放。掃描包含所有子資料夾並去重，查看數量與失敗提示後再進播放器。

Windows 的 Z: 是電腦自己的對應代號，手機不能用它。假設分享是 \\computer\Photos、起始資料夾是「旅行」：主機填 computer 或可達 IP；分享填 Photos；資料夾填「旅行」。電腦現有登入不會授權給手機，需在 App 自行輸入帳密，不用把密碼交給 AI。

## 第一版功能與限制

- 原生 SwiftUI、自適應直橫向，照片完整顯示不裁切，播放器隱藏狀態列。
- 只讀 SMB，沒有刪除、上傳或修改伺服器檔案的操作。
- 密碼存 Keychain；選取、連線設定與收藏留在本機。
- 遞迴掃描可取消、父子選取去重、不跟隨符號連結；上限 100,000 個媒體項目，達上限或不可讀會提示。
- 照片輪播／影片播完接下一個、順序／隨機、最愛過濾、播放清單位置拉桿。
- 影片以 AVAssetResourceLoader 按 512 KiB 範圍讀取 SMB，支援 seek，不先下載整部。
- 影片用 iOS AVPlayer 解碼；MKV/AVI 等可列出，但不保證容器／編碼可播放，沒有轉碼。不相容時停下提示，可手動略過。
- ImageIO 照片縮小解碼，單張上限 80 MiB；GIF 第一版只顯示靜態首幀。
- 播放期間暫停自動鎖屏，退出恢復；進背景會暫停。
- 來源主機必須開機且網路可達，不需要 Windows 網頁轉接服務。

## 免費編譯與安裝

此 App 位於 [mobile-apps](https://github.com/chunyen627-afk/mobile-apps) 的 `apps/album-ios`，後續以此處為唯一開發來源。不要上傳個人照片、連線設定、Apple 憑證或密碼。

GitHub workflow 僅允許公開 repository 執行，以使用標準 macOS runner 的免費政策；私人庫會跳過。流程：產生圖示 → XcodeGen → 模擬器單元測試 → iPhone Release archive → Lightbox-unsigned.ipa。

在 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml) 選最新成功執行，下載 `Lightbox-unsigned-ipa` artifact 並解壓縮。產物保留 3 天；過期可按 Run workflow 重建。手機版原始碼、測試、腳本或 workflow 更新會自動編譯，單改 README 不會觸發。

未簽署 IPA 不能直接點開安裝。下載後用 Windows Sideloadly，以自己的免費 Apple 帳號簽署。登入、雙重驗證、信任電腦及 iPhone 開發者模式由使用者操作。免費簽署 7 天有效；Sideloadly 可在電腦運行、手機 USB/Wi-Fi 可達時嘗試自動續簽，不能保證每次成功。

有 Mac 時安裝 Xcode、XcodeGen、Python 3，在倉庫根目錄執行：

```bash
cd apps/album-ios
bash scripts/build.sh
```

或開啟產生的 Lightbox.xcodeproj，選 Personal Team、唯一 Bundle Identifier 與實體 iPhone 後 Run。

## 驗證界線

Tests/SelectionTests.swift 驗證選取去重、根目錄包含規則、路徑邊界與媒體過濾。只有實際執行通過才能稱通過。

實機待驗：SMB 登入、中文路徑、多層掃描、影片 seek/音訊、網路中斷、取消、旋轉、退出後鎖屏恢復。Windows 可讀或 TCP 445 可達不能代替手機完整 SMB 登入測試。

第三方來源與授權見 THIRD_PARTY.md。

## 更新紀錄

- 2026-10-21：原生相簿原型移入 `mobile-apps/apps/album-ios`，加入獨立 GitHub Actions 編譯流程；尚待首次 Xcode 編譯及實機驗證。
