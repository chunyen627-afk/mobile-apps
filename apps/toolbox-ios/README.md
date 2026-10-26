# 工具箱（toolbox-ios）

把相簿和礦機狀態放進同一個 iPhone App，底部分頁切換，以後的新工具也加在這裡。

免費 Apple 帳號每台手機同時只能有 3 個側載 App（SideStore 自己佔 1 個），每 7 天也只能建立 10 個 App ID。把工具合在一起，就只佔 1 個名額、只要續簽一次。

## 內容

| 分頁 | 來源 | 說明 |
| --- | --- | --- |
| 相簿 | [apps/album-ios](../album-ios) | SMB 相簿、照片與影片播放，功能同光盒相簿 0.3.2 |
| 礦機狀態 | [apps/miner-status-ios](../miner-status-ios) | 燈號、收益與電費、今日電價、開挖建議、遠端控制，功能同礦機狀態 0.6.0 |

- **程式只有一份**：工具箱直接編譯兩個 App 資料夾裡的原始碼，只排除它們各自的啟動檔（`LightboxApp.swift`、`MinerStatusApp.swift`）。單獨的相簿與礦機 App 仍可從同一份原始碼建置。
- **記住上次的工具**：下次打開時回到上次用的分頁。
- **各分頁保留自己的畫面**：切到另一個工具再切回來，畫面停在原處。

## 安裝與資料

- 沿用相簿的 Bundle ID `org.personal.lightbox.album`，版本接續相簿編號（0.4.0 build 6）。**覆蓋安裝在相簿上**，相簿的連線設定、密碼與已存清單都會保留，不要先刪除相簿。
- 主畫面名稱是「工具箱」。`Info.plist` 的 `CFBundleDisplayName` 是英文 `Toolbox`，因為 SideStore 拿它當 Apple App ID 名稱，不接受中文；中文名稱放在 `zh-Hant.lproj/InfoPlist.strings`。
- 礦機的設定（資料來源網址、控制密碼、收益與電費設定）**不會**從單獨的礦機 App 帶過來，在工具箱裡要重新設定一次。設定好之後，就可以在 SideStore 停用單獨的礦機 App，空出名額。
- 產物是**未簽署 IPA**，大小約 50 MB（主要是相簿用的 VLC 播放器），要用自己的 Apple 帳號簽署後安裝。

## 建置與測試

只能在 macOS 上建置（Windows 沒有 iOS 模擬器）。CI：`.github/workflows/toolbox-ios.yml`，在 `claude/toolbox-ios` 分支 push 時執行；相簿或礦機的原始碼有改動時也會觸發。

```bash
cd apps/toolbox-ios
bash scripts/build.sh
```

`scripts/build.sh` 依序做這些事：

1. 產生相簿圖示，下載並核對固定版本的 VLC（存在 `apps/album-ios`）
2. `xcodegen generate`
3. 在 iPhone 模擬器上跑四組測試，每組都要剛好跑到預期數量且 0 失敗：

   | 測試組 | 項目數 | 內容 |
   | --- | --- | --- |
   | 相簿單元測試 | 41 | 相簿自己的測試，原封不動 |
   | 礦機單元測試 | 121 | 礦機核心自己的測試，原封不動 |
   | 工具箱 UI 測試 | 4 | 兩個分頁都在、切換後畫面保留、礦機詳情頁在分頁裡能開也能返回、重開 App 回到上次的工具 |
   | 相簿 UI 測試 | 6 | 相簿自己的測試，原封不動，在工具箱裡執行，順便確認底部分頁列沒有擋到相簿畫面 |

4. 封裝 Release，檢查三個內嵌框架（AMSMB2、MobileVLCKit、MinerStatusCore）、Bundle ID、在地網路權限，以及沒有背景模式
5. 產出 `build/Toolbox-unsigned.ipa` 與 SHA256

截圖推到 `ci-screenshots-toolbox-ios` 分支，不必登入就能看。只有 commit 訊息帶 `[release-ipa]`（使用者同意發布後才加）時，才把 IPA 和閃退分析符號檔發布成公開 prerelease `toolbox-<版本>-build<N>`。

## 驗證狀態

- 尚未建置：等 CI 第一次執行
- 實機：尚未安裝
