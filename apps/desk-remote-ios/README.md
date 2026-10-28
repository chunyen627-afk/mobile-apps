# 桌面遙控（desk-remote-ios）

用 iPhone 原生輸入操作自己 Windows 電腦上的 **Claude 桌面版**與 **Codex 桌面版**：看對話與回覆、打字或傳照片、按權限的「允許一次」／「拒絕」、回答選項題、開新對話、停止、切換模型與權限模式、看電腦畫面，並在手機上用 Face ID 核准需要系統管理員權限的指令（`elevate`）。電腦端是一個只走私人網路（ZeroTier）的小幫手；桌面版的畫面由它用 UI Automation 操作。設計見 [DESIGN.md](DESIGN.md)（2026-10-26 核准）。

**換電腦或換 AI 接手**：照 [RESTORE.md](RESTORE.md) 做——新電腦還原步驟、要重新產生的東西（連線密碼、核准金鑰、ntfy 頻道都不在倉庫裡）、驗收清單，以及接手的 AI 一定要守的規則。

## 目前版本

| 項目 | 內容 |
| --- | --- |
| 手機 App | **0.5.4 build 7**（Bundle ID `org.personal.deskremote.app`，主畫面名稱「桌面遙控」）：[Release desk-remote-0.5.4-build7](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.4-build7)（2026-10-28 發布；發布紀錄見下方「驗證紀錄」） |
| 手機上已安裝 | 0.5.2 build 5（2026-10-27，使用者回報；App 畫面上沒有顯示自己的版本，從 SideStore 的 My Apps 看） |
| 電腦端小幫手 | 0.5.8（小幫手測試 102 項；0.5.3 起視窗切不到前面時改用第二種方法再試，仍失敗就在手機上寫出擋在前面的程式；0.5.4 起對話完成一輪不再發通知；0.5.5 起認得 Codex 匯入的舊對話，見下表；0.5.6 起可從手機叫出桌面版視窗，連續傳兩則訊息不再把自己的按鍵當成有人在用；0.5.7 起 Claude 每週額度以畫面上的使用量按鈕為準；0.5.8 起額度附上帳號的單向標記（不含帳號本身），讓手機認得兩台是同一個方案），辦公室與家用電腦都已更新為 0.5.8（2026-10-28）。裝在兩台：辦公室電腦、家用電腦（2026-10-27 經 SSH 安裝；從辦公室實測讀到兩個桌面版的對話、模型、上下文、額度與截圖，畫面操作還沒在這台實測）。都是登入時啟動的排程工作 `DeskRemoteHelper`；電腦頁「小幫手」那一欄是這個版本，不是 App 的 |
| 提權夥伴 | 只裝在辦公室電腦（排程工作 `DeskRemoteElevated`，最高權限、只聽 127.0.0.1）；家用電腦使用者決定先不裝 |
| 程式所在 | 分支 `claude/desk-remote`，尚未合併 main；之後會成為工具箱的第三個分頁 |

## 功能與驗證程度

「模擬器」＝macOS CI 的 iPhone 模擬器 UI 測試通過並人工看過截圖；「真電腦」＝在辦公室電腦的真實 Claude／Codex 桌面版上實測（每次都經使用者同意，用測試對話）；「手機」＝裝在 iPhone 上用過。

| 功能 | Claude | Codex | 驗證 |
| --- | --- | --- | --- |
| 電腦清單、對話清單、即時逐字稿（工具呼叫收合、長輸出點開取全文） | ✅ | ✅ | 模擬器、真電腦讀真實資料、手機 |
| 送出訊息（閒置 60 秒才動作，有人在用時手機先確認） | ✅ | ✅ | 模擬器、真電腦 |
| 點進桌面版的對話清單時，桌面版沒有視窗（關掉或縮到系統匣）就在電腦上叫出來；不在手機上提示，電腦頁也不再寫「桌面版開著／沒開」（App 0.5.4 起） | ✅ | ✅ | 小幫手單元測試；真電腦（2026-10-28 家用電腦：兩個桌面版都縮在系統匣，由小幫手叫出，視窗確實出現；開啟本身不算有人在用）；模擬器（[run 40695880965](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40695880965)：小幫手 98、單元 35、UI 28，截圖已檢視） |
| 權限詢問：允許一次／拒絕（沒有「永遠允許」） | ✅ | ✅ | 模擬器、真電腦 |
| 選項題卡片（單選、複選、「其他」自己寫）、結尾建議按鈕 | ✅ | — | 模擬器、真電腦（含「其他」） |
| 開新對話 | ✅ | ✅ | 模擬器、真電腦 |
| 停止正在執行的那一輪 | ✅ | ✅（手機 0.5.2 起） | 模擬器、真電腦 |
| 傳照片（先貼照片再貼文字） | ✅ | ✅ | 模擬器；真電腦只測過 Claude |
| 切換模型 | ✅ | ✅ | 模擬器；**真電腦尚未實測** |
| 切換推理強度 | ✅ | —（不做，見「還沒做的」） | 模擬器、真電腦 |
| 切換權限模式 | ✅ | ✅（畫面不顯示目前模式，下一則回覆起生效；小幫手 0.5.5 起手機先顯示剛選的模式，App 0.5.4 起加註「（下一則回覆起生效）」，有回覆後改用紀錄裡的） | 模擬器、真電腦（Claude；Codex 2026-10-28 在匯入的舊對話選「代我核准」，下一輪紀錄確為 `auto_review`） |
| Codex 匯入的舊對話（Codex 自動從 Claude Code 對話紀錄匯入，`external_agent_session_imports.json`；紀錄與資料庫都沒有模型、上下文，畫面標題也可能跟資料庫不同） | — | ✅ 資訊列顯示「匯入的舊對話，回覆一次後才有資料」（App 0.5.4 起；之前整列不顯示、也就點不到切換）；小幫手 0.5.5 起也認得匯入時的標題，連結打開的頁面若是不屬於其他對話的新名字也認定是它並記住 | 單元測試；真電腦（2026-10-28：「測試:A1 回覆」畫面叫「測試 回覆」，切換代我核准與送出都成功）；模擬器（[run 40665672591](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40665672591)：小幫手 93、單元 35、UI 27，截圖已檢視） |
| 模型・推理強度・上下文 %、額度（5 小時／每週與重設時間） | ✅（每週以輸入框旁的使用量按鈕為準，視窗隱藏時用最後一次讀到的；紀錄檔的 5 小時數字超過 5 小時就不顯示） | ✅（每台電腦只知道它自己最後一次回覆時的數字；App 0.5.5 起（尚未發布）同一帳號的兩台都顯示較新的那筆，並註明「來自哪台」） | 模擬器、真電腦數字與桌面版自己回報的一致、手機；2026-10-28 兩台電腦的 Claude 每週都讀到畫面上的 61% |
| 局部選字複製（長按 →「拷貝全部」／「選取文字」） | ✅ | ✅ | 模擬器、手機 |
| 網址可點（Markdown 連結、直接寫出的 http(s) 網址、工具輸出裡的網址；電腦上的路徑不是連結） | ✅ | ✅ | 單元測試（0.5.2 起）、手機（使用者回報內文網址點得開） |
| 顯示 App 自己的版本（電腦清單最下面「App 版本 x（build n）」） | — | — | 模擬器（0.5.3 起）；手機待裝 |
| 連不上電腦時的 ZeroTier 重連提示與自動重試（手機換網路後 ZeroTier 會卡住，提示「把 ZeroTier 關掉再打開」；連不上時每 5 秒重試，手機一換網路就立刻重讀） | — | — | 模擬器（[run 40648993340](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40648993340)，0.5.3 起）；**手機換網路實測待做** |
| 看電腦畫面（只看不操作；鎖定時看不到） | — | — | 模擬器、真電腦截圖 API |
| 管理員指令核准（`elevate`，Face ID＋HMAC） | — | — | 真電腦＋手機核准執行 |
| 清除已完成的管理員指令紀錄（往左滑「移除」或「清除已完成的紀錄」；只記在這支手機，電腦端本來就只留最近 10 筆） | — | — | 模擬器（[run 40648993340](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40648993340)，0.5.3 起）；手機待裝 |
| ntfy 通知（只發需要處理的事）、點通知直接打開對話 | ✅ | ✅ | 模擬器；通知實際收到；**點通知打開尚未在手機實測** |
| 額度與上下文 ≥80% 提醒 | ✅ | ✅ | 單元測試；**尚未實際觸發** |

## 還沒做的

- **Codex 推理強度**：Codex 的「效能」是 5 格、只能用方向鍵調的滑桿（第 2 格「標準」＝中、第 3 格「延伸」＝高、第 4 格「極高」），實測按一次方向鍵有時會移動後直接關掉選單，不夠可靠；Codex 的推理強度維持 `~/.codex/config.toml` 的 `model_reasoning_effort`。
- **Codex 選項題**：只處理 Claude 的 `AskUserQuestion`。
- 用相機直接拍照傳送（目前只能從相簿選）、封存／改名／搜尋對話。
- 併入工具箱第三個分頁；家用電腦的提權夥伴（使用者決定先不裝）。
- 從手機看 Codex 目前的權限模式（Codex 畫面不顯示，只能從下一則回覆的紀錄得知；手機選過的會先顯示，但在電腦上直接改的要等下一則回覆）。

## 驗證紀錄

| 版本 | CI（模擬器） | 發布 | 實機與真電腦 |
| --- | --- | --- | --- |
| P1 唯讀 | [run 40339664008](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40339664008)：單元 15、UI 11 | — | 真電腦讀真實資料通過（2026-10-26） |
| 0.3.0 build 1 | [run 40439161778](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40439161778)：小幫手 67、單元 23、UI 19 | [desk-remote-0.3.0-build1](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.3.0-build1) | 裝到 iPhone、連上辦公室電腦；手機核准 `elevate` 以管理員執行通過 |
| 0.4.0 build 2 | [run 40455358550](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40455358550)：小幫手 76、單元 26、UI 22 | [desk-remote-0.4.0-build2](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.4.0-build2) | 使用者跳過，直接裝 0.5.0 |
| 0.5.0 build 3 | [run 40465532207](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40465532207)：小幫手 84、單元 30、UI 26 | [desk-remote-0.5.0-build3](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.0-build3)（IPA 441,704 bytes，SHA256 `4bf107f3…4ed3`） | 已裝到 iPhone；真電腦實測推理強度、權限模式、照片、停止、開新對話、「其他」、Codex 停止 |
| 0.5.1 build 4 | 沒有發布（還在建置時就被 0.5.2 取代；內容是 Codex 對話也顯示停止） | — | — |
| 0.5.2 build 5 | [run 40471604033](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40471604033)：小幫手 87、單元 31、UI 26，截圖已檢視 | [desk-remote-0.5.2-build5](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.2-build5)（IPA 446,442 bytes，SHA256 `e85f3134…3842`） | 已裝到 iPhone（使用者回報） |
| 0.5.3 build 6 | [run 40651208666](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40651208666)：小幫手 89、單元 34、UI 26（同內容 [run 40648993340](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40648993340) 截圖已檢視） | [desk-remote-0.5.3-build6](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.3-build6)（IPA 462,686 bytes，SHA256 `b2faa6ff…581a`） | 待裝 |
| 0.5.4 build 7 | [run 40699706436](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40699706436) 通過（同內容 [run 40695880965](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40695880965)：小幫手 98、單元 35、UI 28，截圖已檢視） | [desk-remote-0.5.4-build7](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.4-build7)（IPA 467,444 bytes，SHA256 `a2136e0c…7c1a`） | 待裝 |

實測時發現並修好的問題（細節見 commit 紀錄）：
- **送出**：切換對話後輸入框還是舊頁面 → 只在標題相符的頁面找輸入框並讀回確認；Alt 鍵搶前景會打開 Electron 選單列 → 拿掉；Chromium 下點擊前的元件檢查無效 → 改成檢查該點最上層視窗。
- **允許一次**：Claude 的按鈕 Invoke 回報成功卻沒作用 → 只有詢問真的消失才算成功，否則確認後真實點一次。
- **Codex 匯入的舊對話**（2026-10-28）：從 Claude Code 匯入的對話沒有模型與上下文紀錄，手機資訊列整個不見；有的畫面標題跟資料庫不同（「測試:A1 回覆」顯示成「測試 回覆」，打開後資料庫標題又改成「測試：請回覆 A1」），小幫手比對標題失敗就中止，切換與送出都不能用 → 顯示「回覆一次後才有資料」、加認匯入標題、用連結打開的新名字（已在畫面上時先跳到別的對話再回來確認）。
- **Codex**：視窗常被關到系統匣 → 用對話連結叫回；這台電腦 Codex 不是以套件身分執行，`codex://` 開不了 → 用已安裝套件的 `ChatGPT.exe --single-argument <連結>`；新對話頁的輸入框叫「想做什麼都可以」；開新對話前視窗不在就先用最近一個對話的連結叫回。
- **額度不同步**（2026-10-28）：Claude 桌面版不再定時寫 `plan-usage-history.json`（辦公室 3.6556 從 10/27 17:49 停、家用電腦更新到 4.29 後停），手機顯示 53%、55%，畫面上是 61% → 每週改用使用量按鈕（讀到時間比紀錄檔新就用它），過期的 5 小時數字不顯示。Codex 兩台不同（辦公室 0%、11/4 重設；家用 14%、11/2 重設）是因為各自只有自己最後一次回覆時的數字，額度中間被重設過 → 小幫手附上帳號標記，手機記住每個帳號最新的一筆（存在手機，重開 App 也在），兩台都顯示較新的並寫「（來自某台）」；看某台電腦時每分鐘最多順便問一次其他電腦。
- **連續傳訊息被擋**（2026-10-28）：手機傳完一則、25 秒後再傳下一則，回「電腦有人在用，已取消」——小幫手每次動作開始時把自己上一則的按鍵記成真人最後操作 → 上一次的按鍵還是最後一次輸入時，沿用更早的真人操作時間並把兩次動作當成同一段。
- **前景**：對話已開著時小幫手自己的 SetForegroundWindow 會被 Windows 擋 → 一律用該對話的連結把視窗帶到前面。Claude 一度完全不理會自己的連結 → 連結沒切過去時改按側邊欄上同名的對話（同名或找不到就中止）。
- **選項題**：位置還在捲動時點錯選項 → 先捲到可見再點，送出前核對開著的選項恰好等於手機的選擇；「其他」的開關狀態不可信 → 以出現「其他選項」輸入框為準；單選題要先開「其他」（已選的選項不能單獨取消）。
- **停止**：Claude 把中斷寫成使用者訊息「[Request interrupted by user]」→ 改成「已中止」狀態並回到閒置；手機上「已停止」會跟著執行中那一列消失 → 改成留著。
- **`elevate`**：Git Bash 找不到 `elevate.cmd`、經 cmd 會重新解析引號 → 另放一個直接呼叫 Python 的 `elevate`；Git Bash 下中文亂碼 → 在 Git Bash 改用 UTF-8 輸出。
- **視窗切不到前面（10/27 晚，手機連三次「無法把視窗切到前面」）**：當時擋在前面的視窗已查不到，也重現不出來 → 0.5.3 起改用 AttachThreadInput 再試一次（不送按鍵），仍失敗就在手機訊息寫出擋在前面的程式；部署後在辦公室電腦實測 4 次都送出並在逐字稿確認：切換對話後送出、被檔案總管蓋住送出兩次、切換對話又被蓋住。
- **第二台電腦（家用電腦）**：經 SSH 執行 `install.ps1` 時 `USERDOMAIN` 是 `WORKGROUP`，排程工作的帳號組錯而註冊失敗 → 兩個安裝腳本改用 Windows 目前的身分；小幫手跑的 `pythonw.exe` 不在既有的 Python 防火牆規則內 → 另加只開 18790、只接受 ZeroTier 網段的規則（見 [RESTORE.md](RESTORE.md)）。
- **截圖**：畫面操作程式不能宣告高 DPI（點擊座標會變），截圖改由獨立的 DPI-aware 程序做。
- **UI 測試**：清單不排出畫面外的列；在彈出頁頂端往下滑會把它關掉；從外部開自訂網址 iOS 會先問 → 測試改用只往上捲、啟動參數帶連結。

## 日常使用與重開機（辦公室電腦）

電腦只有使用者本人用；用手機遙控時電腦前沒人，「電腦有人在用」的檢查（只看實體鍵盤滑鼠，小幫手自己的按鍵不算）不會觸發。2026-10-27 查過：這台電腦不睡眠、不休眠、螢幕不關，也沒有設定閒置自動鎖定。

會讓手機操作失敗的情況：

| 情況 | 結果 | 處理 |
| --- | --- | --- |
| 重開機（例如 Windows 更新）後停在登入畫面 | 小幫手還沒啟動，手機連不上 | 用 Google 遠端桌面輸入密碼登入 |
| 手動鎖定（Win+L） | 還能看對話；送出、允許、切換、看畫面都會被拒絕 | 遠端解鎖，離開時不要鎖 |
| 關掉 Claude 桌面版 | Claude 的操作失敗（Codex 縮到系統匣沒關係，小幫手會叫回） | 讓 Claude 開著；App 0.5.4 起點進 Claude 的對話清單會自動開啟 |
| 同時用 Google 遠端桌面操作 | 遠端桌面的輸入也算「有人在用」，手機會先問 | 按「仍要送出」 |

登入 Windows 後自動啟動的項目（2026-10-27 檢查設定）：

| 項目 | 方式 |
| --- | --- |
| 小幫手 `DeskRemoteHelper`、提權夥伴 `DeskRemoteElevated` | 登入時的排程工作（一般權限／最高權限） |
| Claude 桌面版 | 套件的開機啟動（原本關著，使用者要求後打開，等同「設定 → 應用程式 → 啟動」） |
| Codex 桌面版 | 套件的開機啟動（原本就開著） |
| ZeroTier、Google 遠端桌面 | 開機就執行的系統服務（停在登入畫面時也連得到） |

**重開機的做法**（使用者決定）：不設定 Windows 自動登入（避免碰得到電腦的人直接進桌面）；重開後用 Google 遠端桌面輸入密碼登入，約 1 分鐘後上述項目都會起來，手機的電腦列顯示「連線正常」就能用。不需要另外做重開機測試，確認登入後會自動啟動即可。

## 決定紀錄

2026-10-26～27 與使用者討論後的結論：

- **先做單獨 App**：使用者自己空出一個手機名額；之後再併入工具箱的第三個分頁。
- **權限**：平常用自動模式（Claude 自動、Codex 代我核准），手機只在有詢問時顯示「允許一次」／「拒絕」，不提供「永遠允許」。
- **UAC**：不改 UAC 設定，也不以管理員身分開桌面版；需要系統管理員權限的指令一律改用 `elevate`，由手機以 Face ID 核准（全域規則檔已寫明）。其他程式跳出的 UAC 用 Google 遠端桌面處理。
- **通知**：只發需要處理的事；手機自己做成功的操作與管理員指令結果不通知。ntfy 頻道和礦機的分開。10/28 再收斂：對話「完成一輪」也不通知（太頻繁，App 畫面看得到就好）；保留權限詢問、選項題、管理員指令等核准、手機操作失敗，以及上下文／額度 ≥80%、密碼錯誤鎖定這類嚴重注意事項。
- **截圖**：不留在電腦上（經管線直接傳，不寫硬碟）。
- **Codex 推理強度**：方向鍵滑桿不可靠，不做；維持 `config.toml` 的預設。
- **之後再看**：相機直接拍照、對話搜尋、草稿保留、電腦畫面自動更新、Codex 選項題、封存／改名對話，使用者認為目前不重要，實際用一段時間再決定。家用電腦（5080）10/27 也裝了小幫手。
- **手機換網路後 ZeroTier 會卡住（10/28）**：iPhone 從 Wi-Fi 換 4G（或反過來）後，ZeroTier 常顯示已連線卻連不到電腦，要手動把 VPN 關掉再打開。這是 ZeroTier 官方承認、尚未修好的已知問題；iOS 捷徑的「設定 VPN」也控制不到 ZeroTier。Tailscale 換網路恢復得快，但使用者決定**不換**（三台電腦、礦機 App 與這個 App 的位址都已用 ZeroTier 建好），換網路後手動重連 VPN 即可。

## 結構

```text
DESIGN.md                  設計與決定
RESTORE.md                 新電腦還原與新 AI 接手
project.yml                XcodeGen：App、DeskRemoteCore（framework）、單元與 UI 測試
iOSApp/                    SwiftUI 畫面；DeskRemoteApp.swift 是唯一 @main 檔，工具箱會排除它
Sources/DeskRemoteCore/    API 模型、HelperClient、TranscriptLog、DeskText、DeskLink／DeskPhoto（無 UI）
Tests/                     DeskRemoteCoreTests（單元）、DeskRemoteUITests（模擬器 UI）
fixtures/fake-helper/      人工編寫的示範資料：兩個桌面版的對話清單、逐字稿、權限詢問、額度、示範畫面
pc-helper/                 電腦端小幫手（Python 標準函式庫）、UIA 工作程序、截圖、提權夥伴、單元測試、安裝腳本、設定範例（列出所有設定）
pc-helper/tools/uia_scan.ps1  唯讀：列出桌面版視窗的控制項名稱，桌面版改版後用來修 ui_strings.json
scripts/build.sh           macOS CI：小幫手測試 → 產生專案 → 模擬器單元與 UI 測試 → Release 封裝
```

## 電腦端小幫手（`pc-helper/`）

- `desk_remote_helper.py`：只綁設定的 ZeroTier 位址，`/v1/*` 要 `Authorization: Bearer <token>`，錯 5 次鎖 10 分鐘並送 ntfy。不寫桌面版任何檔案。
- 資料來源：Claude 讀桌面版的 `claude-code-sessions/*/*/local_*.json`（標題、模型、推理強度、權限模式）、逐字稿 `~/.claude/projects/*/<cliSessionId>.jsonl`、額度 `plan-usage-history.json`；Codex 讀 `~/.codex/state_5.sqlite`（唯讀，讀不到改用 `session_index.jsonl`；rollout 沒寫模型時用其中的 `model`）、rollout 檔（`turn_context`、`token_count`）與 `external_agent_session_imports.json`（匯入對話的標題）。上下文上限只用桌面版回報過的（Opus 5 系列 100 萬），其他模型只顯示已用量（可在 `config.json` 的 `claude.context_windows` 補）。
- **操作視窗**：常駐的 PowerShell（`uia_worker.ps1`，純 ASCII；控制項名稱都在 `ui_strings.json`，桌面版改版時改這個檔）做 UI Automation，判斷能不能做都在 Python 裡、有單元測試。
  - 動作排隊、一次一個；要用前景的動作（送出、開對話、新對話、Claude 的選單）要電腦閒置 60 秒以上（扣掉小幫手自己的按鍵），否則回「有人在用」，手機確認後才強制。鎖定時一律拒絕。停止、Codex 的模型與權限只用 UI Automation，不需閒置。
  - 先用對話自己的連結打開、等頁面標題完全相符才動作；標題不符、視窗切不到前面、剪貼簿無法安全保存時一律中止，不送任何字。剪貼簿先保存後還原，放入的文字與照片標記為不進剪貼簿歷程與雲端剪貼簿。
  - 送出後 20 秒內要在該對話的逐字稿看到這段文字；同一個 `clientMsgId` 只送一次。照片寫到只有本人讀得到的暫存檔，貼上後立刻刪除。
- **ntfy**（`config.json` 的 `notify.server`／`notify.topic`）：只發需要處理的事——權限詢問、新的選項題、管理員指令等核准、手機操作失敗、額度或上下文 ≥80%（`alerts` 可改門檻）、密碼錯誤鎖定；每則帶 `deskremote://open?…` 連結，點了直接打開那個對話。不含訊息內文與指令內容。
- **截圖**：`screen_capture.ps1` 以獨立的 DPI-aware 程序截整個桌面（1600 寬 JPEG 約 110–150 KB），經管線直接交給小幫手，**不寫入電腦硬碟**（使用者 10/27 要求截圖不留在電腦上；小幫手測試在 Windows 上實際截一次並確認沒有留下檔案）；手機只在記憶體顯示、不存相簿、連線不快取。`config.json` 設 `screen: false` 可關閉。
- **管理員權限**：`elevate -c "<PowerShell 指令>"` 或 `elevate -f <腳本.ps1>` 把請求送到提權夥伴（`desk_remote_elevated.ps1`）。手機用 Face ID 確認後，以這台電腦專屬的核准金鑰對「請求 id＋內容的 SHA-256＋資料夾＋到期時間」簽 HMAC，夥伴自己驗簽章才執行，輸出與結束碼原樣回到 `elevate`；小幫手沒有這把金鑰。一次最多 3 個等待、每分鐘 5 個、10 分鐘未核准就失效、同一核准只能用一次。辦公室電腦的 Claude Code 與 Codex 全域規則檔已寫明「需要系統管理員權限改用 `elevate`」。
- 安裝：`install.ps1 -BindIp <ZeroTier 位址> -Network <網段>`（產生只有本人可讀的 `%LOCALAPPDATA%\DeskRemote\config.json` 與隨機 token，註冊登入時啟動的排程工作）；提權夥伴用系統管理員 PowerShell 執行 `install-elevated.ps1`（建立只有管理員能改的 `%ProgramData%\DeskRemote`、新金鑰、排程工作與 `elevate` 指令，顯示一次金鑰給你輸入手機）。不改 UAC。
- 測試：`cd pc-helper && python -m unittest discover -s tests -v`。

## 發布與安裝

- 只有 commit 訊息帶 `[release-ipa]`（使用者同意後才加）時，CI 在全部測試通過後把未簽署 IPA 與閃退符號檔發布成公開 prerelease `desk-remote-<版本>-build<N>`；上限 5 MB，同一 build 號不重複發布。
- 安裝：在 SideStore 的 My Apps 按「＋」匯入 IPA；覆蓋安裝會保留已設定的電腦、連線密碼與核准金鑰。
- 第一次打開：右上角「＋」新增電腦，填私人網路位址、埠 `18790` 與電腦端 `config.json` 裡的 token；有裝提權夥伴的話再填管理員核准金鑰。手機要先連上 ZeroTier。

## API（v1）

| 方法與路徑 | 用途 |
| --- | --- |
| `GET /health`、`GET /v1/state` | 健康檢查；電腦狀態、閒置、鎖定、`capabilities`、各 App 額度 `usage`、可選的 `models`／`efforts`／`modes`、可停止的 App `stop` |
| `GET /v1/{claude\|codex}/sessions?limit=50` | 對話清單 |
| `GET /v1/{app}/sessions/{id}/events?after=&epoch=&prompt=&question=&wait=25` | 逐字稿事件、目前的權限詢問與選項題、`meta`（模型、推理強度、上下文、權限模式）；long-poll，有變化就喚醒 |
| `GET /v1/{app}/sessions/{id}/items/{itemId}` | 被截短的工具輸出全文 |
| `POST /v1/{app}/sessions/{id}/messages` | `{text, clientMsgId, image?, force?}` 送出訊息；`image` 是 base64 JPEG／PNG（解碼後 ≤ 8 MB，這個路徑的請求上限 12 MB） |
| `POST /v1/{app}/sessions/{id}/permission` | `{promptId, decision: allow_once\|deny, force?}` |
| `POST /v1/claude/sessions/{id}/answer` | `{questionId, answers: [{labels, other?}], force?}` 回答選項題 |
| `POST /v1/{app}/sessions/{id}/model`、`…/effort`、`…/mode` | `{model}`／`{effort}`／`{mode}`，選 `state` 列出的其中一個 |
| `POST /v1/{app}/sessions/{id}/stop` | 按下正在執行那一輪的「停止」 |
| `POST /v1/{app}/sessions/{id}/open` | 在電腦上打開這個對話 |
| `POST /v1/{app}/sessions` | `{text, clientMsgId, project?, force?}` 開新對話 |
| `GET /v1/screen` | 電腦整個桌面的 JPEG；鎖定時 423 |
| `GET /v1/elevate`、`POST /v1/elevate/{id}` | 等待核准的管理員指令與最近結果；`{decision: allow\|deny, hmac?}`，允許必須帶手機算的簽章 |
| `GET /v1/actions/{id}` | 動作結果：`queued`／`running`／`done`／`failed`，以及是否已確認 |

錯誤：`401`、`409 busy-user`（含 `idleSeconds`）、`409 prompt-changed`、`423 locked`、`400`、`413`、`429`。

## 手機端

- 電腦清單 → 電腦頁（狀態、Claude／Codex、看電腦畫面、額度、管理員請求）→ 對話清單（新到舊，右上角開新對話）→ 聊天畫面。
- 只在前景讀取：電腦清單 30 秒、電腦頁 15 秒、對話清單 10 秒、聊天畫面 long-poll；離開前景即停止。關著 App 時靠 ntfy 通知。
- 連不上電腦（無法連線或逾時）時：錯誤下面寫「把 ZeroTier 關掉再打開」（手機 10 分鐘內換過網路時說得更明確），並改成每 5 秒重試；手機一換網路（Wi-Fi／行動網路、或換到另一個 Wi-Fi）就立刻重讀。App 無法替你開關 ZeroTier 的 VPN（iOS 不允許，捷徑也控制不到 ZeroTier），只能提示加自動重試；10/28 實測重連 ZeroTier 後約 1 分鐘才通（電腦端要等舊路徑逾時）。
- 連線密碼與管理員核准金鑰只存在 iPhone 鑰匙圈（本機限定），位址存在 UserDefaults；倉庫裡沒有任何位址、密碼或金鑰。
- 聊天畫面：頂端一行「模型・推理強度・上下文 %」，點開看細節、額度並切換模型／推理強度／權限模式；工具呼叫收合成一列；輸入列可加照片；送出的訊息先以虛線泡泡顯示進度；處理中可按「停止」；長按訊息可「拷貝全部」或「選取文字」。
- 權限卡片只有「允許一次」「拒絕」。選項題卡片每題標示單選或可複選，可在「其他」自己寫。電腦有人在用時先跳確認，取消就不動作。
