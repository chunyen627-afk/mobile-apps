# 只有 Windows，也能開發並安裝自己的 iPhone App

更新：2026-10-21。適用於個人自用原生 App；以 iPhone 為優先。本文件不含特定 App、個人帳號、網路位址或私人路徑。

## 先看這條最短流程

**Windows 寫程式 → GitHub 保存原始碼 → GitHub Actions 的 macOS 編譯與模擬器測試 → 下載未簽署 IPA → Windows 用 Sideloadly 簽署 → USB 安裝到 iPhone。**

Windows 不必安裝 macOS 虛擬機，也不必買 Mac；真正的 iOS 編譯與 Apple 模擬器在雲端 macOS 執行。手機裝好後是有圖示、可直接開啟的原生 App，全螢幕與版面由程式決定。

## 免費的前提與限制

| 項目 | 本流程的選擇與限制 |
| --- | --- |
| 開發工具 | Git、免費編輯器、Swift／SwiftUI、XcodeGen；AI 輔助不是必要條件，AI 服務費另計 |
| 雲端編譯 | 公開 GitHub 倉庫搭配標準 GitHub-hosted macOS runner；不要選 larger runner 或自行啟用付費方案 |
| 安裝簽署 | 自己的免費 Apple Account、Sideloadly；不必購買付費開發者會員 |
| 有效期限 | 免費開發簽署約 7 天，需續簽；不是永久免維護安裝 |
| 數量限制 | Apple Personal Team 目前列出每裝置最多 3 個 App、最多 3 台測試裝置、10 個 App ID，並有 7 天期限限制 |
| 分享給別人 | 分享教學與可分享的原始碼；每個人用自己的帳號簽署。這不等同 App Store 或 TestFlight 發布 |
| 全程免費 | 指符合上述條件的工具、建置與個人安裝，不包含原有硬體、網路或額外購買的服務 |

政策可能變動，使用前以 [GitHub Actions 計費說明](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 與 [Apple 帳號限制](https://developer.apple.com/help/account/basics/about-your-developer-account) 為準。

## 一次性準備

1. 準備 Windows 電腦、iPhone、可傳資料的 USB 線，以及 GitHub 和 Apple Account。
2. Windows 安裝 Git 與編輯器，例如 Visual Studio Code。瀏覽器可以管理 GitHub；GitHub CLI 屬選配。
3. 從 [Sideloadly 官方網站](https://sideloadly.io/) 下載 Windows 版，依網站目前指示安裝網頁版 iTunes、iCloud。不要混用不符合其要求的 Microsoft Store 版本。
4. iTunes 在這裡提供手機通訊元件，不必拿來聽音樂；不需要為了此流程啟用 iCloud 照片同步。Apple Devices 管理手機的功能，不等同開發簽署工具。
5. USB 接上並解鎖 iPhone，在手機上完成「信任這部電腦」。先確認 Sideloadly 能選到這支手機。

安裝工具、信任電腦與更新 iOS 是不同事情。若電腦詢問系統升級，選取消／稍後即可；不必為了安裝自製 App 更新或還原手機。

## 第一次把整條流程跑通

### 1. 先做最小原生畫面

先用 SwiftUI 做一個文字和按鈕，驗證開啟、點擊、直橫向與返回。第一次不要同時加入登入、網路、解碼器等多項功能。

Windows 可以編輯 Swift 原始碼，但本流程不在 Windows 執行 Xcode。請準備完整的 Xcode 專案，或使用 XcodeGen 宣告檔產生專案；只有一段 Swift 程式，還不足以產出可安裝 App。

交給 AI 建立專案時，明確要求：

> 建立可供個人免費簽署的 SwiftUI iPhone App。提供完整原始碼、XcodeGen 設定、測試、建置腳本與 GitHub Actions。先測試再產出未簽署的實體裝置 IPA。畫面依容器大小自適應，不寫死手機型號或尺寸。不要把 Apple 帳密或簽署憑證放入雲端。

新專案設定自己的唯一 Bundle Identifier，後續更新固定沿用；最低 iOS 版本應小於或等於手機版本。需要特殊系統能力時，先確認免費簽署能否使用，不能假設所有 entitlement 都可用。

### 2. 放進自己可管理的公開倉庫

將可公開的原始碼、測試、建置設定與說明提交到 GitHub。公開倉庫的內容人人可見；私人媒體、真實連線資訊、帳密、憑證與裝置紀錄都留在本機。

確認 GitHub Actions 已啟用。若從既有專案 Fork，檢查 Actions 是否需要手動啟用，以及 workflow 的分支、觸發條件與依賴是否仍適用。

### 3. 讓 macOS CI 負責建置

最小工作流程應依序做以下事情：

1. 取出指定來源版本，使用標準 macOS runner。
2. 檢查 Xcode 與可用模擬器版本，安裝 XcodeGen，解析專案依賴。
3. 產生 Xcode 專案，執行單元測試及必要的模擬器 UI 測試。
4. 測試通過後，為實體 iOS 裝置執行 Release archive；此階段關閉簽署。
5. 封裝正確結構的 IPA，檢查需要的動態程式庫均包含在內。
6. 上傳 IPA、測試結果／截圖及相同版本的 dSYM 符號檔為 Artifacts。

具體 runner、Xcode、SDK 與模擬器清單會變動，依 [Xcode 支援表](https://developer.apple.com/xcode/system-requirements) 與 [GitHub runner 映像清單](https://github.com/actions/runner-images) 選擇相容組合，不把舊教學版本當成永久固定值。

CI 要設定執行逾時、舊執行取消與短期產物保留；測試失敗就停止。不要把「測試找不到／被跳過」寫成通過，也不要把簽署帳號加入 workflow。

### 4. 下載真正可供手機安裝的產物

在 GitHub 的 Actions 開啟成功的那次執行，確認來源版本，再下載 IPA 對應的 Artifact 並解開外層 ZIP。

需要的是實體裝置的 `.ipa`，不是模擬器 `.app`，也不是專案原始碼 ZIP。未簽署 IPA 不能直接傳進手機點開安裝，下一步要先簽署。

同時保存對應的測試結果、來源 commit、版本與 dSYM。Artifact 可能到期；下載期限由 workflow 決定，過期就從相同來源重建。

### 5. 在 Windows 簽署並安裝

1. 開啟 Sideloadly，選擇接上的 iPhone。
2. 選擇剛解壓得到的 IPA，填自己的 Apple Account。
3. 按 Start；密碼、雙重驗證等帳號操作由本人在工具中完成，不貼給 AI。
4. 等待成功訊息。若停在錯誤，先記錄文字與階段，不要一直換帳號或更改 Bundle Identifier。
5. 在手機完成必要的開發者信任及開發者模式設定，再點主畫面圖示開啟。

常見位置：信任開發者在「設定 → 一般 → VPN 與裝置管理」；開發者模式在「設定 → 隱私權與安全性」。系統可能要求重新開機後確認，實際名稱依系統版本而異。[Sideloadly 官方安裝與排錯](https://sideloadly.io/faq)。

這種開發簽署的 App 要繼續使用，就需要保留開發者模式；不再使用時可以關閉。它不是越獄，也不是關閉全部系統保護。僅安裝自己信任的程式。[Apple 開發者模式說明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

### 6. 確認手機上真的完成

至少確認 App 可開啟、版本正確、主要操作可用，再測旋轉、前後景切換與實際網路。安裝工具顯示成功，只能證明安裝階段，不代表所有功能或長時間穩定性通過。

完成後可以拔 USB。程式開發、雲端編譯及電腦下載期間，手機可以關螢幕；安裝、信任與實機測試時，視提示解鎖。

## 平常更新與每週續簽

修改程式 → 提交 → CI 測試／封裝 → 下載新版 → 用相同 Apple Account、相同 Bundle Identifier 覆蓋安裝。不要先移除舊 App，以免刪掉本機資料；重要資料仍應有匯出或備份方式。

免費簽署到期時通常重簽即可，不必修改程式。Sideloadly 可設定自動續簽，但電腦需運行、手機需透過 USB 或設定好的 Wi-Fi 連線被偵測到；自動續簽不是離線永久有效。先把 USB 流程跑通，再設定無線續簽。[官方續簽與覆蓋安裝說明](https://sideloadly.io/faq)。

### 設定 Wi-Fi 自動續簽，減少每週操作

1. 第一次接上 USB，在 iTunes 的手機摘要頁，勾選「透過 Wi-Fi 與此 iPhone 同步」，按「套用」。
2. 在 Sideloadly 啟用該 App 的自動續簽，確認 App 已加入背景續簽清單，並保留可用的 IPA 快取。
3. 確認 Sideloadly Daemon 在背景運行、會隨 Windows 登入啟動。電腦休眠或關機時無法續簽。
4. 手機與電腦連到同一區網；電腦可走有線網路，重點是兩者能互相發現，訪客 Wi-Fi 的裝置隔離可能阻擋。
5. 拔掉 USB，先讓手機解鎖亮屏，確認工具仍能以 Wi-Fi 找到手機。必要時開啟 iTunes；只勾選設定不等於無線連線已驗證。
6. 成功後讓背景程式在到期前自動嘗試續簽。若長時間外出、電腦關機或簽署驗證失敗，可能仍要手動處理；可查看最近續簽結果。

**此方案仍由電腦執行簽署，手機單獨連上 Wi-Fi 並不能自行續簽。**不用每週改程式或插線，但須在期限內給電腦與手機一次可連線、可完成續簽的機會。[官方 Wi-Fi 與自動續簽條件](https://sideloadly.io/faq)。

## 最容易卡住的地方

### 外出續簽與虛擬區網

虛擬區網能連到檔案伺服器，不代表電腦能反向連到手機的 Apple 安裝服務。ZeroTier 官方指出 iOS／Android 的 VPN 介面不支援其 multicast／broadcast，會影響區網自動探索；即使指定 IP 或 TCP 埠可建立連線，仍須驗證配對、安裝與續簽完整流程。[ZeroTier 說明](https://docs.zerotier.com/bridging/#why-is-an-app-on-my-phone-not-working-over-zerotier)。

SideStore 是另一種手機端續簽方式，首次仍需電腦安裝與配對；不會取消免費帳號的 7 天期限，也會佔用一個側載 App 名額。官方流程使用 iloader 與手機的 LocalDevVPN。先完成一次手動續簽、確認 App 仍能開啟，再設定捷徑與自動化；不要把「已安裝工具」寫成「自動續簽已成功」。使用其他 VPN 時要驗證切換後的連線恢復，不能假設同時相容。[SideStore 安裝流程](https://docs.sidestore.io/docs/installation/install)、[限制](https://docs.sidestore.io/docs/faq)。

版本選擇以當日官方公告為準：2026-10-21 查到 SideStore 0.6.4 及以前有登入故障，官方 latest 為 0.7.0-alpha 修正版；「Stable」按鈕名稱不代表下載內容沒有 alpha 標記。遇到登入 WebSocket 中斷先檢查登入輔助伺服器，不要直接判斷密碼錯誤。[版本公告](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha)。

0.7.0-alpha 也不保證目前可以登入：2026 年 10 月另有 Apple 登入端回覆 `-80045` 的回報。先確認當前使用裝置端或遠端 Anisette，依官方倉庫的最新排查資訊調整並實測；不要反覆更換密碼或撤銷憑證來處理尚未定位的登入錯誤。[登入問題回報](https://github.com/SideStore/SideStore/issues/1665)。

切換簽署工具若提示憑證數量上限，不要直接撤銷現有憑證。它可能正是現有 App 使用的憑證；先比對，再準備同帳號、同 Bundle Identifier 的覆蓋重簽與資料保留方式。配對檔含敏感裝置信任資料，不上傳公開倉庫。

SideStore 安裝成功不等於可啟動。若改用其他簽署工具後提示缺少 profile，先讀完整錯誤，區分主程式、擴充套件與裝置配對資料；不要一律當成密碼或 VPN 錯誤。官方啟動排錯優先要求使用 iloader。若確定只有非必要小工具缺少描述檔，可評估排除該小工具後覆蓋安裝，但須清楚記錄功能差異，重新驗證開啟、續簽及自動化。[SideStore 啟動排錯](https://docs.sidestore.io/docs/troubleshooting/common-issues#unable-to-launch-sidestore)。

| 現象 | 優先檢查 |
| --- | --- |
| Windows 找不到 iOS 模擬器 | Apple 模擬器隨 Xcode 在 macOS 執行；本流程在 CI 跑測試與保存截圖，沒有本機互動模擬器 |
| Sideloadly 看不到手機 | 資料線、USB、手機解鎖與信任、Apple 通訊元件；先看 iTunes 能否辨識 |
| Apple 元件安裝卡住 | 查看是否有被遮住的確認視窗、版本衝突或待重新啟動；依官方要求修正，不重複疊裝 |
| 不受信任的開發者／開發者模式提示 | 完成手機端對應設定；不是要升級 iOS |
| 過幾天突然無法開啟 | 先檢查 7 天簽署期限，使用相同帳號與識別碼重簽 |
| App／App ID 數量達上限 | 檢查免費帳號限制；不要每次測試都產生新的識別碼 |
| 雲端編譯成功，手機一開就退出 | 檢查裝置版架構、動態程式庫封裝、權限說明、簽署與崩潰紀錄 |
| 模擬器正常，實機不正常 | 實際網路、記憶體、硬體、解碼與系統版本可能不同，需實機紀錄 |
| 換新版後原有資料消失 | 檢查是否先刪 App，或更換簽署帳號／Bundle Identifier |
| CI 一直取消或看不到最新產物 | 確認來源 commit、觸發條件、並行取消設定，以及是否下載了舊執行 |
| 編譯器或模擬器找不到 | 檢查目前 runner 的 Xcode／runtime 清單；不要盲目升級手機來配合 CI |

## 螢幕適配與 iPad 的界線

iPhone 版面以當前容器寬高、安全區域及直橫向計算，不依固定吋數。圖片／影片「完整顯示」會保留比例；螢幕與內容比例不同時留邊是正常結果。「填滿」則可能裁切。

iPad 與 iPad mini 也能使用開發簽署流程，但 iPhone-only App 可能在 iPad 以相容模式運作，不代表原生平板全螢幕。正式支援需啟用 iPhone／iPad 目標，另測平板版面、方向與視窗尺寸；不能只改一個設定就宣稱全部相容。本流程優先把 iPhone 完成。[Apple 相容性說明](https://developer.apple.com/help/app-review/before-submitting-for-review/test-compatible-devices)。

## 交接給另一位 AI 時，照這個順序

1. 先讀倉庫的 AGENTS.md、README 與本指南，再確認目前分支、未提交修改與唯一開發來源。
2. 讀現有 workflow、建置腳本、專案設定與測試，不另建一套重複來源。
3. 對上來源 commit、成功的 CI、下載的 IPA 與手機實際版本；不要假設最新提交已安裝。
4. 分開回報「已實作、編譯通過、模擬器通過、實機通過」。只能依證據更新狀態。
5. 將修正與必要測試一起提交，更新 README 的操作、限制、已知問題與驗證證據。
6. 先完成電腦／CI 可做的工作，最後才請使用者處理手機授權或帳號驗證，減少反覆安裝。
7. 沿用既有簽署設定覆蓋更新；不自行移除 App、更新／還原 iOS，也不以修正 App 為由改動其他手機資料。

可直接交給 AI 的需求：

> 先檢查現有專案與文件，延續唯一原始碼來源。使用 Windows 編輯、公開 GitHub 倉庫標準 macOS CI、模擬器測試及未簽署 IPA，最後由本人透過 Sideloadly 免費簽署到 iPhone。先把 iPhone 最小功能跑通，再逐項開發。更新保留既有資料，不升級或還原手機。每次提供來源版本、建置／測試證據與尚未實機確認的事項，並同步更新 README。

## 除錯資料從一開始就留好

每個 Release 保存對應的 dSYM 與來源版本；若有 App 內診斷，記錄版本、時間、操作與錯誤代碼，設定容量上限並提供匯出。不要把密碼、個人媒體或真實連線資訊寫入公開日誌。

閃退可從手機「設定 → 隱私權與安全性 → 分析與改進 → 分析資料」找對應時間的 App 崩潰報告或 JetsamEvent，確認報告確實涉及該 App。MetricKit 可提供部分系統診斷，但不保證每次退出都有報告，也不能補回從未記錄的舊事件。[Apple 崩潰與裝置紀錄](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)。

模擬器先攔截可重現的問題，再用手機確認實際體驗。真正減少來回安裝的方法，是清楚的測試、版本對應與診斷紀錄。
