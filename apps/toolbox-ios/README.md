# 工具箱（toolbox-ios）

把相簿、礦機狀態和桌面遙控放進同一個 iPhone App，底部分頁切換，以後的新工具也加在這裡。

免費 Apple 帳號每台手機同時只能有 3 個側載 App（SideStore 自己佔 1 個），每 7 天也只能建立 10 個 App ID。把工具合在一起，就只佔 1 個名額、只要續簽一次。

## 內容

| 分頁 | 來源 | 說明 |
| --- | --- | --- |
| 相簿 | [apps/album-ios](../album-ios) | SMB 相簿、照片與影片播放，功能同光盒相簿 0.3.2 |
| 礦機狀態 | [apps/miner-status-ios](../miner-status-ios) | 燈號、收益與電費、今日電價、開挖建議、遠端控制，功能同礦機狀態 0.6.4（被 iOS 關掉後重開會自動接回來源；挖另一種幣的機器，例如 FPGA 挖 QTC，用它自己的幣價算收益；累計收益估算與約當 BTC；礦池錢包餘額） |
| 桌面遙控 | [apps/desk-remote-ios](../desk-remote-ios) | 在手機上看 Claude／Codex 桌面版的對話、傳訊息（文字、語音、照片）、回答選項問題、按電腦上跳出的視窗、核准需要系統管理員權限的指令、看電腦畫面，功能同桌面遙控 0.6.2；電腦端要裝 `apps/desk-remote-ios/pc-helper` 的小幫手 0.5.29 以上 |

- **程式只有一份**：工具箱直接編譯三個 App 資料夾裡的原始碼，只排除它們各自的啟動檔（`LightboxApp.swift`、`MinerStatusApp.swift`、`DeskRemoteApp.swift`）與 Info.plist。單獨的相簿、礦機與桌面遙控 App 仍可從同一份原始碼建置。
- **桌面遙控的通知連結**：小幫手的手機通知帶 `deskremote://` 連結，工具箱也接這個連結，點通知會切到桌面遙控分頁、直接開那個對話（分頁列先收到連結，再交給分頁）。單獨的桌面遙控 App 還裝著時，iOS 會挑其中一個開；停用單獨版後就固定開工具箱。
- **記住上次的工具**：下次打開時回到上次用的分頁。
- **各分頁保留自己的畫面**：切到另一個工具再切回來，畫面停在原處。

## 安裝與資料

- 沿用相簿的 Bundle ID `org.personal.lightbox.album`，版本接續相簿編號（目前 0.5.1 build 11；0.5 是桌面遙控加進來成為第三個分頁；0.5.1 在相簿的診斷紀錄加上記憶體用量、目前分頁與每 15 秒一次的心跳，追 11/01 四次在前景突然結束、又沒有 iOS 閃退報告的原因，見相簿 README；也併入桌面遙控 0.6.3：電腦頁的記憶體列、版本後面的更新提醒、從手機重啟換新版小幫手，搭配小幫手 0.5.31）。
- **手機上已經有工具箱**：新版直接覆蓋安裝在工具箱上，不要先刪；相簿與礦機的設定都會保留，不用重填。
- **第一次從相簿換成工具箱**：覆蓋安裝在相簿上，相簿的連線設定、密碼與已存清單都會保留，不要先刪除相簿。
- 主畫面名稱是「工具箱」。`Info.plist` 的 `CFBundleDisplayName` 是英文 `Toolbox`，因為 SideStore 拿它當 Apple App ID 名稱，不接受中文；中文名稱放在 `zh-Hant.lproj/InfoPlist.strings`。
- 礦機的設定（資料來源網址、控制密碼、收益與電費設定）**不會**從單獨的礦機 App 帶過來，第一次在工具箱裡要重新設定一次。設定好之後，就可以在 SideStore 停用單獨的礦機 App，空出名額。
- 桌面遙控的配對（電腦的位址、連線密碼、核准金鑰）同樣**不會**從單獨的桌面遙控 App 帶過來（Bundle ID 不同，Keychain 不共用）：第一次在工具箱的桌面遙控分頁按「＋」重新配對每台電腦，核准金鑰也要重新貼。**單獨的桌面遙控 App 先留著**，等工具箱版在手機上確認能用再停用。手機上存的對話快取也是各自一份。
- 三個工具的 UserDefaults 與 Keychain 鍵各有前綴（相簿 `connection`／`Lightbox.SMB`、礦機 `sourceURL`／`org.personal.minerstatus.control`、桌面遙控 `deskremote.*`／`org.personal.deskremote.*`），不會互相覆蓋。
- 產物是**未簽署 IPA**，大小約 50 MB（主要是相簿用的 VLC 播放器），要用自己的 Apple 帳號簽署後安裝。
- 權限說明（相機、麥克風、語音辨識、Face ID）是桌面遙控用的，第一次拍照、講話或核准提權時 iOS 才會問。

## 建置與測試

只能在 macOS 上建置（Windows 沒有 iOS 模擬器）。CI：`.github/workflows/toolbox-ios.yml`，在 `claude/toolbox-ios` 分支 push 時執行；相簿、礦機或桌面遙控的原始碼有改動時也會觸發。整個流程約 30 分鐘（桌面遙控的 41 項 UI 測試佔一半）。

```bash
cd apps/toolbox-ios
bash scripts/build.sh
```

`scripts/build.sh` 依序做這些事：

0. 桌面遙控電腦端小幫手的單元測試（純 Python，157 項，其中 3 項只在 Windows 跑、在 macOS 算跳過）
1. 產生相簿圖示，下載並核對固定版本的 VLC（存在 `apps/album-ios`）
2. `xcodegen generate`
3. 啟動桌面遙控的 4 個假小幫手（跟它自己的 `scripts/build.sh` 一樣：正常、有人在用電腦、Codex 收到系統匣、桌面有視窗跳出），在 iPhone 模擬器上跑六組測試，每組都要剛好跑到預期數量且 0 失敗：

   | 測試組 | 項目數 | 內容 |
   | --- | --- | --- |
   | 相簿單元測試 | 43 | 相簿自己的測試，原封不動（0.5.1 加了記憶體讀數與心跳兩項） |
   | 礦機單元測試 | 126 | 礦機核心自己的測試，原封不動 |
   | 桌面遙控單元測試 | 45 | 桌面遙控核心自己的測試，原封不動 |
   | 工具箱 UI 測試 | 5 | 三個分頁都在、切換後畫面保留、礦機詳情頁在分頁裡能開也能返回、重開 App 回到上次的工具；桌面遙控在分頁裡連到假小幫手、電腦頁與對話在分頁裡開、輸入列在分頁列上面不被擋、切到相簿再回來畫面還在 |
   | 相簿 UI 測試 | 6 | 相簿自己的測試，原封不動，在工具箱裡執行，順便確認底部分頁列沒有擋到相簿畫面 |
   | 桌面遙控 UI 測試 | 41 | 桌面遙控自己的測試，原封不動，在工具箱裡執行（`DESK_UI_TEST=1` 會從桌面遙控分頁開始） |

4. 封裝 Release，檢查四個內嵌框架（AMSMB2、MobileVLCKit、MinerStatusCore、DeskRemoteCore）、Bundle ID、在地網路權限、桌面遙控的四個權限說明與 `deskremote://` 連結、沒有背景模式、沒有測試資料或小幫手檔案被包進去
5. 產出 `build/Toolbox-unsigned.ipa` 與 SHA256

截圖推到 `ci-screenshots-toolbox-ios` 分支（含桌面遙控自己那 70 多張，上限 10 MB），不必登入就能看。只有 commit 訊息帶 `[release-ipa]`（使用者同意發布後才加）時，才把 IPA 和閃退分析符號檔發布成公開 prerelease `toolbox-<版本>-build<N>`。

## 驗證狀態

- [run 40330467762](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40330467762)（`d2a63c9`，第一次建置）：編譯成功，171 項通過。工具箱 test01 在收尾關閉 App 時報 `Failed to terminate …:0`；它的檢查本身都通過，截圖顯示兩個分頁正常。收尾改成先看 App 狀態，提前結束就明確報出來
- [run 40332751139](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40332751139)（`37f9db4`）：相簿單元 41、礦機單元 121、工具箱 UI 4、相簿 UI 6，全部 0 失敗；IPA 48,096,236 bytes。截圖已人工檢視：相簿頁下方的分頁列不擋畫面；礦機頁、礦機詳情頁在分頁裡正常，有返回鍵
- [run 40340299846](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40340299846)（`31f2b12`，已合併礦機 0.6.1：重開後自動接回來源，並修正啟動時第一次讀取被取消、清單空白最多 30 秒）：相簿單元 41、礦機單元 121、工具箱 UI 4、相簿 UI 6，全部 0 失敗；IPA 48,097,981 bytes。截圖已人工檢視：重開後回到上次的礦機分頁
- [run 40548727208](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40548727208)（`f122f5e`，0.4.1 build 7，已合併礦機 0.6.2：挖另一種幣的機器用它自己的幣價算收益、礦池認列算力依大小換單位）：相簿單元 41、礦機單元 123、工具箱 UI 4、相簿 UI 6，全部 0 失敗；IPA 48,102,374 bytes。截圖已人工檢視：礦機分頁的示範礦機 B 以 QTC 計價，分頁列不擋畫面
- [run 40623905139](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40623905139)（`679128b`，0.4.2 build 8，已合併礦機 0.6.3：累計收益估算與約當 BTC）：相簿單元 41、礦機單元 125、工具箱 UI 4、相簿 UI 6，全部 0 失敗；IPA 48,120,525 bytes。截圖已人工檢視：礦機分頁正常、分頁列不擋畫面；累計區塊的內容在礦機 App 的 run 40623881960 截圖確認
- 發布：[run 40631339706](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40631339706)（`7fa7c8a`，只多了上一行說明）重跑同樣四組測試，全部 0 失敗，發布公開 prerelease [toolbox-0.4.2-build8](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.4.2-build8)；IPA 48,120,525 bytes，SHA256 `1a94a5365783df14c9b84e0648d6e45ecaec96b5282d78e6c29009aa216ca8c7`
- 實機：使用者手機上已裝工具箱（較早的版本）；0.4.2 build 8 尚未確認安裝
- [run 41282168484](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41282168484)（`dc122bb`，0.5.0 build 10，第一次含桌面遙控分頁）：小幫手 140、相簿單元 41、礦機單元 126、桌面遙控單元 44、工具箱 UI 5、相簿 UI 6 全過；桌面遙控 UI 41 項裡 40 過、test39（超大訊息後落在最新）在分頁裡畫面空白沒救回來（單獨版同一份程式的 run 41281651314 有過，是偶發的空白畫面）。截圖已人工檢視：桌面遙控分頁的電腦清單、對話清單（分支線、按天分段）、對話頁都正常，輸入列在分頁列上方不被擋。空白救援已加強（`acce7a0`）再跑
- [run 41284785269](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41284785269)（`b187931`，0.5.0 build 10，含加強後的空白救援）：小幫手 140、相簿單元 41、礦機單元 126、桌面遙控單元 44、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；build.sh 33 分鐘；IPA 48,763,148 bytes，SHA256 `6ac2d6f9d7d442893d6c9c5707ca2097874d31b09b3d1edf4b39f9080c9fb7ca`（未上傳）。截圖已人工檢視：test39 的超大訊息後正確落在最新一則，工具箱三張桌面遙控截圖同上
- 發布：使用者 11/01 同意後，以同一份程式再加這一行說明推 `[release-ipa]`，由發布的 run 重跑六組測試並上傳 IPA（結果見下一行）
- 發布：[run 41293529419](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41293529419)（`4caf913`）六組測試加小幫手全部 0 失敗，發布公開 prerelease [toolbox-0.5.0-build10](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.5.0-build10)；IPA 48,763,148 bytes，SHA256 `cb71b85b7b2db4b263d2a179cfac79bcd67fef01934049fcdee90e04c175e658`。**尚未實機**：工具箱裡的桌面遙控要重新配對，單獨版先留著
- [run 41344142967](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41344142967)（`2a996f4`，0.5.1 build 11，診斷記錄加記憶體／分頁／心跳，併入桌面遙控 0.6.3 與小幫手 0.5.31）：小幫手 157、相簿單元 43、礦機單元 126、桌面遙控單元 45、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；IPA 48,787,217 bytes（未上傳）。截圖已人工檢視：桌面遙控分頁的記憶體列與重啟小幫手、版本後的更新提醒、從手機回覆防火牆視窗都正常，設定頁顯示 0.5.1 (build 11)
- 發布：使用者 11/02 同意後，以同一份程式再加這一行說明推 `[release-ipa]`，由發布的 run 重跑測試並上傳 IPA
