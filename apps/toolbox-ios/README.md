# 工具箱（toolbox-ios）

把相簿、礦機狀態、桌面遙控和溫濕度放進同一個 iPhone App，底部分頁切換，以後的新工具也加在這裡。

免費 Apple 帳號每台手機同時只能有 3 個側載 App（SideStore 自己佔 1 個），每 7 天也只能建立 10 個 App ID。把工具合在一起，就只佔 1 個名額、只要續簽一次。

## 內容

| 分頁 | 來源 | 說明 |
| --- | --- | --- |
| 相簿 | [apps/album-ios](../album-ios) | SMB 相簿、照片與影片播放，功能同光盒相簿 0.3.2 |
| 礦機狀態 | [apps/miner-status-ios](../miner-status-ios) | 燈號、收益與電費、今日電價、開挖建議、遠端控制，功能同礦機狀態 0.6.4（被 iOS 關掉後重開會自動接回來源；挖另一種幣的機器，例如 FPGA 挖 QTC，用它自己的幣價算收益；累計收益估算與約當 BTC；礦池錢包餘額） |
| 桌面遙控 | [apps/desk-remote-ios](../desk-remote-ios) | 在手機上看 Claude／Codex 桌面版的對話、傳訊息（文字、語音、照片）、回答選項問題、按電腦上跳出的視窗、核准需要系統管理員權限的指令、看電腦畫面，功能同桌面遙控 0.6.2；電腦端要裝 `apps/desk-remote-ios/pc-helper` 的小幫手 0.5.29 以上 |
| 溫濕度 | [apps/thermo-ios](../thermo-ios) | 同時看多顆藍牙溫濕度計的溫度、濕度、電量與更新時間，點進去看 24 小時／7 天／30 天紀錄曲線，可改名與隱藏；經 ZeroTier 讀溫濕度計旁的閘道（`apps/thermo-ios/pc-gateway`），可同時設多個閘道。沒有單獨的 App |

- **程式只有一份**：工具箱直接編譯各工具資料夾裡的原始碼（溫濕度只有工具箱版，沒有啟動檔），只排除它們各自的啟動檔（`LightboxApp.swift`、`MinerStatusApp.swift`、`DeskRemoteApp.swift`）與 Info.plist。單獨的相簿、礦機與桌面遙控 App 仍可從同一份原始碼建置。
- **桌面遙控的通知連結**：小幫手的手機通知帶 `deskremote://` 連結，工具箱也接這個連結，點通知會切到桌面遙控分頁、直接開那個對話（分頁列先收到連結，再交給分頁）。單獨的桌面遙控 App 還裝著時，iOS 會挑其中一個開；停用單獨版後就固定開工具箱。
- **記住上次的工具**：下次打開時回到上次用的分頁。
- **各分頁保留自己的畫面**：切到另一個工具再切回來，畫面停在原處。

## 安裝與資料

- 沿用相簿的 Bundle ID `org.personal.lightbox.album`，版本接續相簿編號（目前發布版 0.6.1 build 16（2026-11-08 發布、手機未裝）：併入桌面遙控 0.6.5＋小幫手 0.5.36——Codex 對話可從手機切推理強度、新對話頁可先選模型與推理強度（使用者 2026-11-08 要求），見桌面遙控 README；0.6.0 build 15：加入溫濕度分頁，已發布（手機未裝）；0.5.4 build 14 已裝機；0.5.4 併入桌面遙控 0.6.4：對話上方的跳出視窗卡片預設收合成一行＋橫向按鈕列、下一步摘要預設一行、輸入列上方的卡片最多 240 點超過就捲（使用者 11/05 反映卡片把打字的地方擠掉），搭配小幫手 0.5.34（Codex 選項題可從手機答；管理員程式的視窗交提權夥伴代按、電腦上也能核准），見桌面遙控 README；0.5.3 讓相簿連不到 NAS 時（經 ZeroTier 逾時）自動再試，最多 5 次，見相簿 README；0.5.2 修正相簿連著 NAS 一段時間後點進資料夾就閃退（忽略 SIGPIPE、失敗時重連再試一次），見相簿 README；0.5 是桌面遙控加進來成為第三個分頁；0.5.1 在相簿的診斷紀錄加上記憶體用量、目前分頁與每 15 秒一次的心跳，追 11/01 四次在前景突然結束、又沒有 iOS 閃退報告的原因，見相簿 README；也併入桌面遙控 0.6.3：電腦頁的記憶體列、版本後面的更新提醒、從手機重啟換新版小幫手，搭配小幫手 0.5.31）。
- **手機上已經有工具箱**：新版直接覆蓋安裝在工具箱上，不要先刪；相簿與礦機的設定都會保留，不用重填。
- **第一次從相簿換成工具箱**：覆蓋安裝在相簿上，相簿的連線設定、密碼與已存清單都會保留，不要先刪除相簿。
- 主畫面名稱是「工具箱」。`Info.plist` 的 `CFBundleDisplayName` 是英文 `Toolbox`，因為 SideStore 拿它當 Apple App ID 名稱，不接受中文；中文名稱放在 `zh-Hant.lproj/InfoPlist.strings`。
- 礦機的設定（資料來源網址、控制密碼、收益與電費設定）**不會**從單獨的礦機 App 帶過來，第一次在工具箱裡要重新設定一次。設定好之後，就可以在 SideStore 停用單獨的礦機 App，空出名額。
- 桌面遙控的配對（電腦的位址、連線密碼、核准金鑰）同樣**不會**從單獨的桌面遙控 App 帶過來（Bundle ID 不同，Keychain 不共用）：第一次在工具箱的桌面遙控分頁按「＋」重新配對每台電腦，核准金鑰也要重新貼。**單獨的桌面遙控 App 先留著**，等工具箱版在手機上確認能用再停用。手機上存的對話快取也是各自一份。
- 各工具的 UserDefaults 與 Keychain 鍵各有前綴（相簿 `connection`／`Lightbox.SMB`、礦機 `sourceURL`／`org.personal.minerstatus.control`、桌面遙控 `deskremote.*`／`org.personal.deskremote.*`、溫濕度 `thermo.*`），不會互相覆蓋。
- 溫濕度分頁第一次是示範資料，到右上角齒輪填閘道網址（一行一個）。
- 產物是**未簽署 IPA**，大小約 50 MB（主要是相簿用的 VLC 播放器），要用自己的 Apple 帳號簽署後安裝。
- 權限說明（相機、麥克風、語音辨識、Face ID）是桌面遙控用的，第一次拍照、講話或核准提權時 iOS 才會問。

## 建置與測試

只能在 macOS 上建置（Windows 沒有 iOS 模擬器）。CI：`.github/workflows/toolbox-ios.yml`，在 `claude/toolbox-ios` 分支 push 時執行；相簿、礦機、桌面遙控或溫濕度的原始碼有改動時也會觸發。整個流程約 30 分鐘（桌面遙控的 41 項 UI 測試佔一半）。

```bash
cd apps/toolbox-ios
bash scripts/build.sh
```

`scripts/build.sh` 依序做這些事：

0. 桌面遙控電腦端小幫手的單元測試（純 Python，165 項，其中 3 項只在 Windows 跑、在 macOS 算跳過）；溫濕度閘道的單元測試（純 Python，38 項，不需要藍牙）
1. 產生相簿圖示，下載並核對固定版本的 VLC（存在 `apps/album-ios`）
2. `xcodegen generate`
3. 啟動桌面遙控的 4 個假小幫手（跟它自己的 `scripts/build.sh` 一樣：正常、有人在用電腦、Codex 收到系統匣、桌面有視窗跳出）與溫濕度的假閘道（`--fake`，固定讀數＋造出來的曲線），在 iPhone 模擬器上跑七組測試，每組都要剛好跑到預期數量且 0 失敗：

   | 測試組 | 項目數 | 內容 |
   | --- | --- | --- |
   | 相簿單元測試 | 52 | 相簿自己的測試，原封不動（0.5.1 加了記憶體讀數與心跳兩項；0.5.2 加了 SIGPIPE 與重連重試五項；0.5.3 加了等 NAS 回應的四項） |
   | 礦機單元測試 | 126 | 礦機核心自己的測試，原封不動 |
   | 桌面遙控單元測試 | 45 | 桌面遙控核心自己的測試，原封不動 |
   | 溫濕度單元測試 | 32 | 閘道網址、JSON 與紀錄解析（含每日最高最低、本地時區的日界、名稱房間與推播條件）、送名稱到閘道、時間與電量文字、舒適度、房間分組（手機優先、閘道備援）、°F、改名與隱藏、舊版設定仍可讀 |
   | 工具箱 UI 測試 | 7 | 四個分頁都在、切換後畫面保留、礦機詳情頁在分頁裡能開也能返回、重開 App 回到上次的工具；桌面遙控在分頁裡連到假小幫手、電腦頁與對話在分頁裡開、輸入列在分頁列上面不被擋、切到相簿再回來畫面還在；溫濕度示範資料的列表（房間分組、低電量提醒）、詳情頁舒適度與曲線（切週、濕度）、用改名對話框（預先填好目前名字）與列表左滑改名、選房間後列表多一個房間分組、設定切 °F 後列表跟著變；對假閘道與一個連不到的閘道：過期與錯誤顯示、曲線、詳情頁的閘道名稱與推播條件、隱藏、設定頁、改名送到閘道後重開 App（手機設定清空）名稱仍在 |
   | 相簿 UI 測試 | 6 | 相簿自己的測試，原封不動，在工具箱裡執行，順便確認底部分頁列沒有擋到相簿畫面 |
   | 桌面遙控 UI 測試 | 41 | 桌面遙控自己的測試，原封不動，在工具箱裡執行（`DESK_UI_TEST=1` 會從桌面遙控分頁開始） |

4. 封裝 Release，檢查五個內嵌框架（AMSMB2、MobileVLCKit、MinerStatusCore、DeskRemoteCore、ThermoCore）、Bundle ID、在地網路權限、桌面遙控的四個權限說明與 `deskremote://` 連結、沒有背景模式、沒有測試資料或小幫手檔案被包進去
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
- 0.5.2 build 12（`15aaed4`，相簿連著 NAS 一段時間後點進資料夾不再閃退）：使用者 11/02 要求直接發布最新版，所以沒有先跑一次不發布的 CI，由帶 `[release-ipa]` 的 run 跑完全部七組測試（相簿單元改成 48 項），全過才上傳 IPA；截圖在發布後、裝手機前人工檢視
- 發布：[run 41358807102](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41358807102)（`71d913f`）小幫手 157、相簿單元 48、礦機單元 126、桌面遙控單元 45、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗，發布公開 prerelease [toolbox-0.5.2-build12](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.5.2-build12)；IPA 48,789,385 bytes，SHA256 `087b9545388944c0e9b6630070a1857702491d8ef8acfd064e102ced901f937c`。截圖已人工檢視：相簿分頁、診斷紀錄、桌面遙控電腦頁正常。0.5.1 build 11 也已發布（[run 41355453079](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41355453079)，[toolbox-0.5.1-build11](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.5.1-build11)），被 0.5.2 取代。11/02 實機：使用者確認閒置後點資料夾**不再閃退**，但斷線後很難再連上（作業逾時），由 0.5.3 處理
- [run 41422927208](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41422927208)（`7e52cc6`，0.5.3 build 13，相簿連不到 NAS 時最多試 5 次）：小幫手 157、相簿單元 52、礦機單元 126、桌面遙控單元 45、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；IPA 48,791,937 bytes（未上傳）。截圖已人工檢視：相簿分頁與播放準備頁正常。等 NAS 回應的按鈕文字在模擬器測不到（假資料不走網路），由單元測試涵蓋
- 發布：使用者 11/02 同意後，以同一份程式再加這一行說明推 `[release-ipa]`，由發布的 run 重跑測試並上傳 IPA
- 第一次發布 [run 41430257259](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41430257259)（`3658aa3`）沒有上傳：272 項過，3 項 UI 測試在等待時限內沒等到畫面（相簿兩項影片測試等進度列 8 秒、桌面遙控 test38 按鈕點擊判定），同一份程式在 run 41422927208 全過，runner 當時排隊壅塞，判定為偶發；只加這一行說明重推 `[release-ipa]`。第二次 [run 41437209560](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41437209560)（`bfae46f`）GitHub 沒分配到 macOS runner（The job was not acquired by Runner），測試沒跑，再推一次
- 發布：[run 41439342053](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41439342053)（`d19f74d`）小幫手 157、相簿單元 52、礦機單元 126、桌面遙控單元 45、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗，發布公開 prerelease [toolbox-0.5.3-build13](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.5.3-build13)；IPA 48,791,937 bytes，SHA256 `425fd5441d6e412324e201ee6e4eed2a33a42d0d3417a34342e8823352ad5832`。**尚未實機**
- 發布：使用者 11/05 選「直接發布」，0.5.4 build 14（併入桌面遙控 0.6.4 與小幫手 0.5.34，Swift 改動沒在本機編譯過）直接推 `[release-ipa]`，由發布的 run 跑全部測試並上傳 IPA
- [run 41947313140](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41947313140)（`179e706`，0.5.4 build 14 第一次發布）：275 項裡 271 過，失敗 test40／test41（開示範對話超過 10 秒，排在 test39 塞進超大訊息之後）、test36（長按捲軸軌道沒翻頁，計時敏感）、相簿 testPausedPhotoPinchPanResetAndTapGestures（與這次改動無關）；test40／41 等待拉長到 30 秒後再發一次
- [run 41951628058](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41951628058)（`b812a35`，第二次）：同樣 4 項失敗、數字一模一樣（test36「位置 0.58 大小 0.33 內容 1143」、test40／41 等 30 秒仍載不出來、test38），不是偶發：輸入列上方的 `frame(maxHeight: 240)` 即使沒有卡片也撐滿 240 點，把對話區壓到剩三分之一。改成量卡片實際高度再限高後第三次發布
- 發布：[run 41954886215](https://github.com/chunyen627-afk/mobile-apps/actions/runs/41954886215)（`1f84d46`，第三次）小幫手 165、相簿單元 52、礦機單元 126、桌面遙控單元 45、工具箱 UI 5、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；prerelease [toolbox-0.5.4-build14](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.5.4-build14)，IPA 48,797,424 bytes，SHA256 `ca088d60b3bd619ba44493e3d404e6b67ee920f58fb49b983b0a031196dea630`。截圖已檢視：任務清單收成一行貼在輸入列上方、鍵盤升起時對話仍看得到；跳出視窗卡片展開／收合正常。**尚未實機**
- 0.6.0 build 15（溫濕度分頁）：[run 42170681674](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42170681674)（`2821c29`，第一次跑完）編譯通過，304 項過、5 項失敗：溫濕度 3 項是測試本身的問題（示範紀錄測試的時間在 1970 年附近、月往回推成負數；電量與舒適度標籤的無障礙文字被圖示名稱蓋掉；假閘道開久了「40 分鐘前」變 47 分鐘），另外桌面遙控 test38／test39 偶發（沒改到桌面遙控）。截圖看到列表第二行時間與電量被擠成直排，改成舒適度一行、時間與電量一行不換行
- [run 42174825284](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42174825284)（`346b7bc`）小幫手 165、溫濕度閘道 38、相簿單元 52、礦機單元 126、桌面遙控單元 45、溫濕度單元 32、工具箱 UI 7、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；IPA 49,002,998 bytes（未上傳）。溫濕度 12 張截圖已逐張檢視：房間分組、舒適度、低電量提醒、日曲線與週每日高低長條、改名對話框、房間選擇、°F、兩個閘道（一個連不到）、隱藏、設定頁、改名存到閘道後重開 App 仍在。小瑕疵：詳情頁溫濕度那列的分隔線只畫半條
- 發布第一次：[run 42187212800](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42187212800)（`9fe2165`）308 項過，只有桌面遙控 test38 失敗：等更新說明文字時去問它「點得到嗎」，剛好文字在換，XCTest 直接判失敗（activation point invalid）；之前也失敗過，不是偶發。讀文字只要列表建出來就好，改成捲到存在為止、不問點不點得到（先在桌面遙控分支 `0b39577` 提交再合併）後再發一次
- 發布第二次：[run 42191989395](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42191989395)（`7d28a8e`）test38 已過；308 項過，只有相簿 testAVIPlaybackSeekPauseAndReopen 失敗：點畫面中央後 2 秒內控制列沒出現（CI 機器忙時點擊的延遲回呼更晚或點擊遺失）。改成等 5 秒，還沒出現就再點一次後第三次發布
- 發布：[run 42197523584](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42197523584)（`39f8533`，第三次）小幫手 165、溫濕度閘道 38、相簿單元 52、礦機單元 126、桌面遙控單元 45、溫濕度單元 32、工具箱 UI 7、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；prerelease [toolbox-0.6.0-build15](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.6.0-build15)，IPA 49,002,998 bytes，SHA256 `d1adb608d4f2a85c2f64bc1557fc36b0836385c64acfa78fdd103b53cbd12066`。**尚未實機**
- 0.6.1 build 16 發布：[run 42437904349](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42437904349)（`76be659`，第一次就過）小幫手 169、溫濕度閘道 38、相簿單元 52、礦機單元 126、桌面遙控單元 45、溫濕度單元 32、工具箱 UI 7、相簿 UI 6、桌面遙控 UI 41，全部 0 失敗；prerelease [toolbox-0.6.1-build16](https://github.com/chunyen627-afk/mobile-apps/releases/tag/toolbox-0.6.1-build16)，IPA 49,009,096 bytes，SHA256 `59bbe4359ea5f2c6b70fb1cb7fa966b28ee970587735c71875c8ccb67c3c8366`（下載後核對一致）。截圖已檢視：新對話頁有「模型」「推理強度」兩列、推理強度選單列出照目前的／低／中／高／超高。**尚未實機**（新對話帶模型／強度在真電腦上還沒試）
