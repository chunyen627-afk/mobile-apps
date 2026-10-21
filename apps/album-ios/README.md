# 光盒相簿 — iPhone 原生版原型

SwiftUI + SMB2/3 的個人相簿。目標：iPhone 17、iOS 27、6.3 吋；最低 iOS 17。

**狀態：修正版 Xcode 編譯、5 項模擬器單元測試與 IPA 封裝檢查通過。已透過 Sideloadly 側載至 iPhone，使用者確認 App 可開啟且 SMB 連線成功；遞迴掃描與照片／影片播放尚待實機驗證。**

2026-10-21 安裝證據：Sideloadly 0.71.1 顯示 `Done.`、`100%`，USB 裝置顯示 iOS 27.0；使用者完成手機端授權後回報 App 可以開啟，正在設定連線欄位。沒有更新或還原 iOS，也沒有將簽署帳號、裝置識別碼或密碼存入倉庫。

2026-10-21 連線結果：使用者先回報連線失敗，之後回報連線成功。尚未確認首次失敗原因，也未完成反覆連線穩定性驗證；不據此推定所有網路或帳號都可用。主機欄可直接填 IP／名稱，也接受 `smb://` 前綴；分享與資料夾仍填在各自欄位。

測試證據：[修正版 GitHub Actions](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39532413253)，來源 `342dc73e6bffc6e17aca47c47babb55c7f37c1b4`，Xcode 16.4、iPhone 16 Pro / iOS 18.5 模擬器，5 項單元測試、0 失敗。這不是 iPhone 17 / iOS 27 實機或 UI 操作測試。首次產物缺少動態程式庫，不應安裝；修正版已確認包含 `Frameworks/AMSMB2.framework/AMSMB2`。

修正版 IPA：462,276 bytes；SHA256：`123c49e6c13fc6fa64081b9b6ba07274d8b4fc6d57d93b50da3e6974ca43a59c`。下載後已驗證 artifact 雜湊、IPA ZIP 完整性、Bundle ID 與程式庫存在。後續重建的雜湊可能不同。

## 使用方式

輸入 SMB 主機、分享名稱、分享內起始資料夾及帳密。允許 iOS「區域網路」權限；使用 ZeroTier 位址時手機也須加入該網路。

| 欄位 | 填寫方式 |
| --- | --- |
| 主機 IP 或名稱 | 相簿電腦／NAS 的可達位址，不加分享路徑 |
| 分享名稱 | SMB 分享名稱，例如 `Photos`；不填 Windows 磁碟代號 |
| 起始資料夾 | 分享內的相對路徑，例如 `旅行`；留空則從分享根目錄開始 |
| 帳號／密碼 | 相簿主機的 SMB 登入資料，不是簽署 App 的 Apple 帳號；Windows PIN 不等同帳號密碼 |
| 網域 | 一般個人分享先留空；有網域需求時才填 |
| 要求 SMB3 加密 | 預設關閉；伺服器支援且需要加密時可開啟 |

填好後按「連接相簿」。Windows 已登入分享不代表手機自動取得相同權限。

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

Windows 請依 [Sideloadly 官方說明](https://sideloadly.io/) 安裝其指定的網頁版 iTunes、iCloud 與 Sideloadly。iTunes 在此提供 Apple 手機通訊元件，無需用來聽音樂；Apple Devices 的備份與同步功能不包含替未簽署 IPA 做開發簽署。安裝元件不代表要啟用 iCloud 照片同步。

本流程不更新或還原 iOS。iTunes 提示系統更新時選取消／稍後，由使用者日後在手機上決定升級。手機安裝 App 仍需完成信任電腦、簽署帳號驗證及開發者模式；這些與升級 iOS 是不同操作。

有 Mac 時安裝 Xcode、XcodeGen、Python 3，在倉庫根目錄執行：

```bash
cd apps/album-ios
bash scripts/build.sh
```

或開啟產生的 Lightbox.xcodeproj，選 Personal Team、唯一 Bundle Identifier 與實體 iPhone 後 Run。

## 驗證界線

Tests/SelectionTests.swift 驗證選取去重、根目錄包含規則、路徑邊界與媒體過濾。只有實際執行通過才能稱通過。

實機已由使用者確認：App 啟動與一次 SMB 連線成功。待驗：連線穩定性、中文子路徑、多層掃描、照片輪播、影片 seek/音訊、網路中斷、取消、旋轉、退出後鎖屏恢復。Windows 可讀或 TCP 445 可達不能代替手機完整 SMB 登入測試。

第三方來源與授權見 THIRD_PARTY.md。

## 更新紀錄

- 2026-10-21：原生相簿原型移入 `mobile-apps/apps/album-ios`，加入獨立 GitHub Actions 編譯流程；修正 IPA 缺少 SMB 動態程式庫的封裝設定，修正版編譯、5 項單元測試與封裝檢查通過；已完成側載，手機開發者授權與功能待驗。
