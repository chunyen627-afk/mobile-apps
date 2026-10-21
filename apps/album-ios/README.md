# 光盒相簿 — iPhone 原生版原型

SwiftUI + SMB2/3 的個人相簿。目標：iPhone 17、iOS 27、6.3 吋；最低 iOS 17。

0.3.1 已覆蓋安裝，USB 讀回確認 build 4：診斷畫面分別顯示操作紀錄筆數、前次未正常結束線索及 iOS 系統報告數，避免把「0 份系統報告」誤認為沒有紀錄。掃描新增載入索引、目錄讀取前後、排序、寫入索引等階段與數量紀錄；目錄讀取採最多每兩秒一次抽樣，不寫入路徑或檔名，既有總容量上限不變。這是補強取證，並非已修復閃退。

依使用者明確需求，0.3.1 移除影片裁切按鈕及 AVPlayer／VLC 裁切分支，只保留等比例最大完整顯示；舊裁切偏好不再生效。直橫向皆按容器適配，不拉伸、不裁掉原始畫面，必要時保留黑邊。模擬器測試改為驗證原生與兩種 AVI 的直橫向完整顯示、可見邊界、播放／seek，並以舊裁切偏好開啟來驗證升級後仍完整顯示。

來源 `1d2e42568f254b6a650ec7ee7c91aafdebe6ca47` 已通過 34 項單元、5 項模擬器 UI 測試及 Release 封裝（[Actions 39559469901](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39559469901)）。已檢查原生影片、MPEG-4 AVI、MJPEG AVI 的完整顯示與診斷匯出截圖。先前兩輪失敗已保留 CI 證據：`168d3b9` 的舊裁切檢查失敗；`abdcc3d` 則因第二種 AVI 的控制列先自動隱藏，等不到進度列。最終測試先揭示控制列並暫停再檢查，保留比例、跳轉、時鐘前進、自動隱藏及重開檢查，39 項全部通過。

2026-10-21 15:24（Asia/Taipei）USB installation proxy 讀回 0.3.1／build 4，沿用既有簽署身分覆蓋更新。IPA 為 47,721,760 bytes，SHA256 `66316b2a375be2ae42f42395b89dc6abfe610a94150d19e76b257ec570e837ae`；三份下載 artifact 雜湊均已核對，對應測試附件與 dSYM 已保存。實際 IPA 的 `UIDeviceFamily=[1, 2]`、最低 iOS 17。尚待新版實機操作與長時間穩定性驗證。

優先支援 iPhone。版面以目前容器尺寸自動調整，不綁定 6.3 吋；照片、原生影片與 VLC 畫面會隨直橫向及可用寬高變化。現有模擬器證據涵蓋直橫向，不代表所有尺寸與未來機型皆已實測。雖然專案層設定 `TARGETED_DEVICE_FAMILY=1`，實際 0.3.0 IPA 的 `UIDeviceFamily` 為 `[1, 2]`，宣告 iPhone／iPad；產生專案的 target 設定可能覆蓋專案層設定，因此必須核對封裝產物。iPad／iPad mini 版面與實機均尚未驗證，不宣稱完整相容。通用環境與其他 AI 接手流程見 [Windows → iPhone 快速上手](../../docs/windows-iphone-quickstart.md)。

**0.3.0 已覆蓋安裝到手機並讀回確認 build 3。最終來源 `abf9c72efdfc206dc5905e66976caef743069fe5` 已通過編譯、32 項單元測試、5 項模擬器 UI 測試與 Release 封裝（[Actions 39549468250](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39549468250)）。Xcode 16.4、iPhone 16 Pro／iOS 18.5。測試涵蓋兩種 AVI 的完整顯示、暫停跳至約 15 秒、恢復後實際時鐘前進及橫向裁切；已檢查最終兩種 AVI 播放、MJPEG 跳轉／橫向與診斷匯出截圖。新版實機功能與長時間穩定性尚未確認。**

2026-10-21 13:45（Asia/Taipei）安裝證據：Sideloadly 顯示 `Done.`／`100%`，USB installation proxy 讀回 `CFBundleShortVersionString=0.3.0`、`CFBundleVersion=3`。沿用既有簽署身分覆蓋安裝，沒有移除 App 或更新／還原 iOS；保留原件、固定安裝副本與相符 dSYM。這些證據確認安裝版本，不能證明偶發閃退已解決。

0.3.0 IPA：47,717,867 bytes；SHA256：`9088bda2fe6e37c432cda7870b119468b414f8d928972ae05f329f8c44d6e6c2`。已核對三份下載 artifact 的 SHA256、IPA ZIP 完整性、版本 0.3.0／build 3、最低 iOS 17、AMSMB2／MobileVLCKit 動態程式庫，以及兩份人工 AVI 均未進入 Release。對應測試附件與 dSYM 已保存本機，後續重建雜湊可能不同。

2026-10-21 補充實機診斷：已經由 USB 的 App container 唯讀取得本機操作事件；診斷畫面「0 份」表示尚未收到 iOS 系統報告，不代表沒有操作紀錄。此次使用者回報退出，事件最後停在開始掃描，下次啟動記到 `previousSessionEndedInForeground`；尚無對應崩潰堆疊，不能確認終止原因。先前已完成的兩次單項目播放準備記錄 `reused=1`，確認這兩次使用索引，不能推論所有目錄皆已完整驗證。原始事件僅保存在本機。

影片需求確認：保持原比例放大至可用畫面能容納的最大尺寸，上下或左右至少一對邊貼齊，另一方向可留黑邊，不裁切、不拉伸。此手機目前讀回 `cropVideoToFill=false`；使用者已在 0.3.0 實機確認「已等比例貼齊上下或左右，畫面完整」。此結果限當次試播，不代表所有格式均已測試；影片本身已有的黑邊不會自動去除。

同日 USB 側錄期間重試：190 個資料夾、3,615 個媒體掃描完成，後續有照片及影片播放事件；使用者回覆此次沒有遇到閃退。此輪未重現不代表偶發問題已解決。

- 索引改為按連線與資料夾保存。取消、重選、換組合、縮小到子資料夾都重用；選到未知資料夾才補掃，選更上層時也跳過已知子樹。空資料夾同樣記住；不自動到期。手動「重新掃描」只更新選定子樹，失敗或取消不覆蓋原有完整索引。可遷移目前勾選組合對應的 0.2.0 完整索引；無法對應的舊索引需首次補掃。
- 自動在手機保存有容量上限的操作事件、數值錯誤代碼、記憶體警告與 MetricKit 系統報告；不自動上傳。操作紀錄不含 SMB 位址、帳密、媒體檔名或內容。事件輪替最多 3 × 256 KiB，系統報告最多 5 份、每份上限 2 MiB，另保留一份可替換的匯出檔。
- 連線前後皆可從主畫面「診斷紀錄」→「準備診斷檔」→「分享診斷檔」，儲存 JSON 或交給協助除錯的人。也可標記問題時間。未正常結束只是線索，強制關閉／重開機等也會造成；iOS 不保證每次終止皆交付完整診斷。MetricKit 真實回報仍須實機確認，參考 [Apple 說明](https://developer.apple.com/documentation/metrickit/mxmetricmanager)。
- 影片完整等比例顯示，長或寬貼齊可用螢幕、不裁切；比例不同會留黑邊。0.3.1 已移除裁切切換，舊裁切偏好不再生效。
- 加入 VideoLAN MobileVLCKit 3.7.3：AVI、MKV、WebM、WMV、MPEG、TS 等交給 VLC；MP4／MOV／M4V 優先 AVPlayer，解碼失敗自動嘗試 VLC。共用目前的 SMB 連線，最多 512 KiB 分段預讀緩衝，不先下載整部影片；支援暫停、跳轉及等比例完整顯示。已以 AVI／MPEG-4＋MP3、AVI／MJPEG＋PCM 驗證；其他編碼未逐一測試，並非保證所有編碼、損壞檔、DRM 影片都能播放。

**0.2.0（build 2）已通過編譯、20 項單元測試、3 項模擬器 UI 測試、13 張截圖檢查及 Release 封裝。已覆蓋安裝到手機並讀回確認版本；實機偶發閃退仍待紀錄分析，不能視為已解決。**

2026-10-21 新版實機證據：Sideloadly 0.71.1 顯示 `Done.`／`100%`，其後透過 USB installation proxy 讀回 `CFBundleShortVersionString=0.2.0`、`CFBundleVersion=2`。即時 syslog 已收到 Lightbox 執行與媒體播放相關訊息；未更新、還原 iOS 或移除舊 App。這些證據確認安裝與執行，不代表長時間穩定性通過。

使用者補充舊問題：並非僅重選時，任意位置皆可能偶發，整個 App 關閉回到 iPhone 主畫面，重開後需重新連接 SMB。已經要求 iOS 匯出待處理報告並檢查報告目錄及下一層，尚未找到涉及 Lightbox 的崩潰／Jetsam 報告；已建立有時間上限的 USB 即時收集流程。初步即時紀錄出現 SMB 流量相關 `invalid source ip`，目前只列為網路線索，尚無證據認定它造成 App 終止。原始裝置識別、連線資訊與日誌只保存在本機。

驗證證據：[Actions 39541264158](https://github.com/chunyen627-afk/mobile-apps/actions/runs/39541264158)，來源 `1a899d7c5ff0afce92a89ea49fe828d2b6ec74d0`，Xcode 16.4、iPhone 16 Pro / iOS 18.5。UI 測試包含重新勾選 4 → 3 → 4 個項目、重播及重啟後使用索引、照片預載、控制列隱藏、影片填滿／完整顯示、旋轉，以及拖曳後實際播放時間落在目標附近。截圖確認影片跳至約 10 秒。這不是 iPhone 17 / iOS 27 的實機測試。

此版 IPA：500,597 bytes；SHA256：`fdcebfeb3d9482e5a6d685cec20606986cf78c3dd2657b5173cfb85f3cc249a3`。下載後已確認 artifact 雜湊、IPA ZIP 完整性、版本、內含 `Frameworks/AMSMB2.framework/AMSMB2`，且 Release 不含模擬器測試入口。後續重建的雜湊可能不同。

額外取消處理：確認 AMSMB2 4.0.3 的 async continuation 不會自動中止底層讀取，已將 Task 取消連接到讀取 progress 回呼；退出／快速跳轉後，在下一個讀取區塊邊界停止工作，取消後的部分資料不會顯示。正在等待網路回應的單次操作仍受連線逾時限制。新增 2 項取消／完整讀取測試；這項修正尚不能證明是實機閃退的原因。

0.1.0 已側載並能開啟、連線與播放；使用者回報每次播放重掃、按鈕不隱藏、切照片出現黑色讀取畫面、影片留白，以及「重新勾選後按播放」兩次閃退。閃退原因尚未取得系統紀錄確認，不視為已修復。

2026-10-21 舊版安裝證據：Sideloadly 0.71.1 顯示 `Done.`、`100%`，USB 裝置顯示 iOS 27.0；使用者完成手機端授權後回報 App 可以開啟，之後確認連線並試播。沒有更新或還原 iOS，也沒有將簽署帳號、裝置識別碼或密碼存入倉庫。

2026-10-21 連線結果：使用者先回報連線失敗，之後回報連線成功。尚未確認首次失敗原因，也未完成反覆連線穩定性驗證；不據此推定所有網路或帳號都可用。主機欄可直接填 IP／名稱，也接受 `smb://` 前綴；分享與資料夾仍填在各自欄位。

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

### 掃描辨識的格式

| 類型 | 副檔名 | 播放方式與限制 |
| --- | --- | --- |
| 圖片 | JPG、JPEG、PNG、HEIC、HEIF、WebP、GIF、BMP、AVIF | ImageIO；GIF 目前只顯示首幀，實際解碼取決於系統與檔案內容 |
| 原生影片 | MP4、MOV、M4V | AVPlayer 優先；0.3.0 加入失敗時嘗試 VLC |
| VLC 擴充影片 | AVI、MKV、WebM、WMV、MPG、MPEG、TS、MTS、M2TS | 0.3.0 新增；已測兩種 AVI 編碼，不能由容器名稱保證所有內部編碼皆可播 |

目前手機已更新至 0.3.1，包含 VLC；實機各種編碼仍待確認。上述影片副檔名原本便能列入掃描，但 0.2.0 全部使用 AVPlayer，因此 AVI 等可能無法解碼。

### 0.2.0 操作變更

- 相同主機、分享、帳號與勾選範圍只在第一次完整掃描；重播及重開 App 使用手機內的索引。更換過濾、收藏或隨機設定不需重掃。索引只記檔案清單，不儲存密碼或照片。
- 電腦新增、刪除或移動檔案後，使用準備播放畫面的「重新掃描」或右上選單的「重新掃描已選範圍」。讀取失敗、取消或達數量上限不覆蓋完整索引。
- 顯示照片期間預載下一張，換頁時保留上一張直到下一張就緒；最多保留當前與下一張的解碼快取。快速跳轉會取消不相關預載。這是記憶體緩衝，不是離線下載，慢網路仍可能延長停留時間。
- 照片和影片的控制列在 4 秒未操作後隱藏；自動換頁不重設計時。點畫面重新顯示；暫停、錯誤及拖曳拉桿期間保留控制列。
- 影片取消固定上下留白，預設按比例填滿螢幕；可切換完整顯示。比例不同時，填滿會裁切邊緣，完整顯示會留黑邊。影片本身已編入的黑邊不會自動偵測裁除。支援自訂影片進度拉桿。

### 原有功能

- 原生 SwiftUI、自適應直橫向，照片完整顯示不裁切，播放器隱藏狀態列。
- 只讀 SMB，沒有刪除、上傳或修改伺服器檔案的操作。
- 密碼存 Keychain；選取、連線設定與收藏留在本機。
- 遞迴掃描可取消、父子選取去重、不跟隨符號連結；上限 100,000 個媒體項目，達上限或不可讀會提示。
- 照片輪播／影片播完接下一個、順序／隨機、最愛過濾、播放清單位置拉桿。
- AVPlayer 以 AVAssetResourceLoader、VLC 以可跳轉的 InputStream 讀取 SMB，單次最多 512 KiB，不先下載整部。關閉播放器會取消等待中的讀取；網路逾時會提示失敗。
- VLC 補充更多容器／編碼，沒有伺服器轉碼；不相容時停下提示，可手動略過。不能由副檔名保證解碼成功。
- ImageIO 照片縮小解碼，單張上限 80 MiB；GIF 第一版只顯示靜態首幀。
- 播放期間暫停自動鎖屏，退出恢復；進背景會暫停。
- 來源主機必須開機且網路可達，不需要 Windows 網頁轉接服務。

## 免費編譯與安裝

此 App 位於 [mobile-apps](https://github.com/chunyen627-afk/mobile-apps) 的 `apps/album-ios`，後續以此處為唯一開發來源。不要上傳個人照片、連線設定、Apple 憑證或密碼。

GitHub workflow 僅允許公開 repository 執行，以使用標準 macOS runner 的免費政策；私人庫會跳過。流程：產生圖示 → 下載並核對官方 VLC XCFramework 的 SHA256 → XcodeGen → 模擬器單元及 UI 測試 → iPhone Release archive → Lightbox-unsigned.ipa。VLC 原始壓縮套件約 264 MB，加入後 App 會變大。測試報告與截圖保留 3 天，對應 dSYM 符號檔保留 30 天，下載後可留在本機供後續分析。

AVI 模擬器素材為 FFmpeg 產生的 30 秒色彩測試圖與 440 Hz 音訊，包含 MPEG-4 Part 2／MP3（320×180）及 MJPEG／PCM u8（640×480），經同一個非同步範圍讀取介面播放。後者對應本機唯讀抽查到的相簿影片編碼；沒有複製或上傳私人影片，Release 排除兩份人工素材。這只能驗證指定編碼及串流介面，實際 SMB 延遲、其他編碼與 iPhone 17 效能仍須實機確認。

在 [Build Album iOS](https://github.com/chunyen627-afk/mobile-apps/actions/workflows/album-ios.yml) 選最新成功執行，下載 `Lightbox-unsigned-ipa` artifact 並解壓縮。產物保留 3 天；過期可按 Run workflow 重建。手機版原始碼、測試、腳本或 workflow 更新會自動編譯，單改 README 不會觸發。

未簽署 IPA 不能直接點開安裝。下載後用 Windows Sideloadly，以自己的免費 Apple 帳號簽署。登入、雙重驗證、信任電腦及 iPhone 開發者模式由使用者操作。免費簽署 7 天有效；Sideloadly 可在電腦運行、手機 USB/Wi-Fi 可達時嘗試自動續簽，不能保證每次成功。

2026-10-21 續簽設定：已確認 0.3.0 登錄自動續簽、IPA 已快取，背景 daemon 執行中且存在 Windows 登入啟動項目；iTunes「透過 Wi-Fi 與此 iPhone 同步」已勾選並套用。但使用者拔除 USB 後，iTunes／Sideloadly 皆未列出手機，usbmux 亦無裝置。已在使用者確認的同區網手機位址上驗證既有配對及裝置身分，但安裝資訊與崩潰報告服務連線中斷；無線安裝、續簽與紀錄傳輸尚未成功。Bonjour 與 Apple Mobile Device 服務運作中，未變更防火牆或手機系統。免費使用仍需定期續簽，即使不再開發；電腦需運行、未睡眠且與手機可互相連線。手機單獨上網不能替代電腦端簽署。

開發與雲端編譯不需連手機；IPA 更新可在無線配對正常時經 Wi-Fi 傳送。App 內「診斷紀錄」可在手機匯出分享，不必持續 USB 側錄；無線讀取系統崩潰報告／即時紀錄尚未驗證，必要時仍需 USB，不能把無線安裝能力當成所有除錯能力已可無線使用。

同日 ZeroTier 測試：手機虛擬位址的 TCP 62078 可建立連線，但送出 Apple 配對服務查詢後立即中斷；普通 Wi-Fi 上相同查詢可回覆。尚未完成虛擬區網續簽，SMB 相簿可用不能替代這項驗證。iloader 提示憑證數量上限，已比對唯一現有憑證正被相簿使用，因此當時取消撤銷。之後沿用 Sideloadly 既有憑證成功安裝 SideStore 0.7.0，USB 讀回確認版本，並經 iloader 放置配對資料、確認手機端檔案存在。iloader 工作已完成並關閉；後續轉移結果見下方，不能宣稱自動續簽已成功。

SideStore 首次開啟另遇到啟動失敗。USB 取得的 ConsoleLogs 明確記錄 `The app extension is missing a valid provisioning profile.`，對應安裝包唯一的 WidgetKit 小工具。Sideloadly 排除此小工具後以相同帳號及 Bundle ID 覆蓋安裝，使用者確認可進主畫面；當時沒有撤銷憑證。此步只確認啟動問題排除，此次電腦安裝不含桌面小工具。

後續登入實測回覆 `-80045`，USB 紀錄確認來自 Apple 驗證端。依 [SideStore 問題回報](https://github.com/SideStore/SideStore/issues/1665)，使用者停用 On-Device Anisette、改選 Jkcoxson Mac 後回報登入成功。LocalDevVPN 1.3.0 已經 USB 確認安裝，使用者確認連線。相簿掃描索引、偏好與診斷已額外保存於本機，0.3.1 IPA 放入手機後讀回核對雜湊；未上傳私人資料。

備份與後續安裝包準備完成後，使用者在 SideStore 依序完成 Revoke／Re-sign，回報 SideStore 可重新開啟；接著匯入相簿 IPA，回報安裝完成並顯示有效天數。首次再次 Refresh All 顯示未登入，重新登入後使用者確認 Refresh All 成功；切回 ZeroTier 後確認原設定保留、能正常播放。這確認本次手機手動續簽與切換後播放，不能直接推論背景／鎖屏續簽可靠。

後續手機自動化確實觸發，但回報未登入；使用者確認滑掉 SideStore 後重開會登出。USB 讀回顯示主程式沒有 App Group 權限及共享資料夾，五份啟動紀錄都重跑維護步驟 1–3。對照安裝版本的 [MaintenanceManager](https://github.com/SideStore/SideStore/blob/6032424a/SideStore/MaintenanceManager.swift)，維護進度保存在共享資料夾；缺少該資料夾就無法保存進度，每次重開再次清除 Keychain 與登入。已先備份可讀取的設定與資料庫，再由 SideStore 匯入官方原始 IPA，以相同身分覆蓋安裝並移除非必要 Widget 擴充；沒有刪除 App。2026-10-21 17:05 後 USB 確認新描述檔含 App Group，安裝資訊也出現對應共享資料夾；修復後第一次啟動完成維護。使用者回報連續兩次滑掉重開均保持登入，17:08:02、17:08:11 的兩份啟動紀錄也未再執行維護或報告缺少共享容器。這確認本次重開登出問題已排除，修復後捷徑與鎖屏續簽仍待驗證。私人紀錄與備份只保留本機。

轉移後已停止 Windows Sideloadly Daemon，移除其登入自啟項目，並確認背景程序與自啟項目均不存在；工具與既有 IPA 快取仍保留，未修改安裝資料庫。之後若重新開啟 Sideloadly，先確認不會恢復對相同 App 的自動續簽，避免與 SideStore 簽署憑證互相影響。

手機捷徑驗證中：連線 LocalDevVPN → 等待 5 秒 → SideStore「Refresh All Apps」→ 顯示完成通知。使用者手機的「設定 VPN」清單沒有 ZeroTier，因此目前需手動切回；不以開啟 ZeroTier App 取代背景連線。排程曾觸發但遇到上述登入問題，尚未完成修復後驗收。所用 SideStore 版本的捷徑動作在長時間執行時可能要求切到前景，不能假設鎖屏也一定無人值守完成；「7 DAYS」顯示有取整，應以實際續簽結果及描述檔時間驗證。

Windows 請依 [Sideloadly 官方說明](https://sideloadly.io/) 安裝其指定的網頁版 iTunes、iCloud 與 Sideloadly。iTunes 在此提供 Apple 手機通訊元件，無需用來聽音樂；Apple Devices 的備份與同步功能不包含替未簽署 IPA 做開發簽署。安裝元件不代表要啟用 iCloud 照片同步。

本流程不更新或還原 iOS。iTunes 提示系統更新時選取消／稍後，由使用者日後在手機上決定升級。手機安裝 App 仍需完成信任電腦、簽署帳號驗證及開發者模式；這些與升級 iOS 是不同操作。

有 Mac 時安裝 Xcode、XcodeGen、Python 3，在倉庫根目錄執行：

```bash
cd apps/album-ios
bash scripts/build.sh
```

或開啟產生的 Lightbox.xcodeproj，選 Personal Team、唯一 Bundle Identifier 與實體 iPhone 後 Run。

## 驗證界線

先模擬器、後手機：`Tests/ScanIndexTests.swift` 驗證磁碟索引重用、強制重掃、失敗及取消保護；`Tests/PlaybackTests.swift` 驗證預載共用、快取釋放、慢讀保留畫面、快速切頁與控制列計時；`Tests/CancellableReadTests.swift` 驗證取消與完整讀取。`Tests/UI/AlbumUITests.swift` 在真正的 iOS 模擬器點擊重選／重播、重啟、切頁、影片等比例完整顯示、旋轉與 seek，並保存畫面附件。模擬器測試素材僅存在於 Debug simulator，Release IPA 不含測試入口。

UI 測試使用人工產生媒體與模擬目錄，不能證明實際 SMB、iPhone 17 / iOS 27 的穩定性。每次編譯保存測試報告、UI 截圖及符號檔；通過測試才封裝。手機更新沿用簽署帳號與 Bundle ID 覆蓋安裝，通常不需移除舊 App。

閃退分析：iPhone「設定 → 隱私權與安全性 → 分析與改進 → 分析資料」尋找發生時間附近的 `Lightbox-…ips`／`Lightbox_…ips` 或 `JetsamEvent-…ips`。前者是崩潰報告，後者可能是記憶體壓力終止；需確認報告確實涉及本 App。原始裝置報告留在本機，不提交公開倉庫。[Apple 診斷說明](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)。

Tests/SelectionTests.swift 驗證選取去重、根目錄包含規則、路徑邊界與媒體過濾。只有實際執行通過才能稱通過。

實機已由使用者確認：0.1.0 啟動、SMB 連線及進入播放，並回報上述缺陷。0.2.0 曾以 USB 版本查詢與即時紀錄確認安裝／執行；目前已更新 0.3.0 並讀回版本，但完整功能回歸仍待驗，包括跨勾選組合索引、連線穩定性、中文子路徑、多層掃描、照片輪播、AVI／其他影片 seek 與音訊、診斷匯出及 MetricKit 回報、網路中斷、取消、旋轉、退出後鎖屏恢復及偶發閃退。尚未取得涉及本 App 的實機閃退報告，不能把模擬器通過視為閃退已解決。Windows 可讀或 TCP 445 可達不能代替手機完整 SMB 登入測試。

第三方來源與授權見 THIRD_PARTY.md。

## 更新紀錄

- 2026-10-21（0.3.0）：加入跨勾選組合資料夾索引、本機有容量上限的診斷匯出、影片預設完整顯示及 MobileVLCKit 3.7.3。37 項測試與 Release 封裝通過，兩種 AVI 經畫面檢查；已覆蓋更新手機並讀回確認 build 3，最終來源與 IPA 雜湊見上方。實機功能待確認，尚不能宣稱偶發實機閃退已修復。

- 2026-10-21（0.2.0）：加入持久掃描索引、下一張照片預載、讀取取消傳遞、控制列計時修正、影片滿版／完整顯示及精確跳轉。20 項單元測試、3 項模擬器 UI 測試、13 張截圖檢查及封裝通過；已覆蓋安裝並讀回確認手機版本，開始 USB 即時紀錄，偶發閃退與完整實機功能回歸仍待確認。

- 2026-10-21（0.1.0）：原生相簿原型移入 `mobile-apps/apps/album-ios`，加入獨立 GitHub Actions 編譯流程；修正 IPA 缺少 SMB 動態程式庫的封裝設定，修正版編譯、5 項單元測試與封裝檢查通過；已完成側載與手機開發者授權，使用者確認連線並試播。
