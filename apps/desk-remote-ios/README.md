# 桌面遙控（desk-remote-ios）

用 iPhone 原生輸入操作自己 Windows 電腦上的 **Claude 桌面版**與 **Codex 桌面版**：看對話與回覆、打字或傳照片、按權限的「允許一次」／「拒絕」、回答選項題、開新對話、停止、切換模型與權限模式、看電腦畫面，並在手機上用 Face ID 核准需要系統管理員權限的指令（`elevate`）。電腦端是一個只走私人網路（ZeroTier）的小幫手；桌面版的畫面由它用 UI Automation 操作。設計見 [DESIGN.md](DESIGN.md)（2026-10-26 核准）。

## 目前版本

| 項目 | 內容 |
| --- | --- |
| 手機 App | **0.5.2 build 5**（Bundle ID `org.personal.deskremote.app`，主畫面名稱「桌面遙控」）：[Release desk-remote-0.5.2-build5](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.2-build5)（測試全部通過才會發布；發布紀錄見下方「驗證紀錄」） |
| 手機上已安裝 | 0.5.0 build 3（2026-10-27）；0.5.2 待覆蓋安裝 |
| 電腦端小幫手 | 0.5.0（小幫手測試 87 項），已裝在辦公室電腦（登入時啟動的排程工作 `DeskRemoteHelper`） |
| 提權夥伴 | 已裝在辦公室電腦（排程工作 `DeskRemoteElevated`，最高權限、只聽 127.0.0.1） |
| 程式所在 | 分支 `claude/desk-remote`，尚未合併 main；之後會成為工具箱的第三個分頁 |

## 功能與驗證程度

「模擬器」＝macOS CI 的 iPhone 模擬器 UI 測試通過並人工看過截圖；「真電腦」＝在辦公室電腦的真實 Claude／Codex 桌面版上實測（每次都經使用者同意，用測試對話）；「手機」＝裝在 iPhone 上用過。

| 功能 | Claude | Codex | 驗證 |
| --- | --- | --- | --- |
| 電腦清單、對話清單、即時逐字稿（工具呼叫收合、長輸出點開取全文） | ✅ | ✅ | 模擬器、真電腦讀真實資料、手機 |
| 送出訊息（閒置 60 秒才動作，有人在用時手機先確認） | ✅ | ✅ | 模擬器、真電腦 |
| 權限詢問：允許一次／拒絕（沒有「永遠允許」） | ✅ | ✅ | 模擬器、真電腦 |
| 選項題卡片（單選、複選、「其他」自己寫）、結尾建議按鈕 | ✅ | — | 模擬器、真電腦（含「其他」） |
| 開新對話 | ✅ | ✅ | 模擬器、真電腦 |
| 停止正在執行的那一輪 | ✅ | ✅（手機 0.5.2 起） | 模擬器、真電腦 |
| 傳照片（先貼照片再貼文字） | ✅ | ✅ | 模擬器；真電腦只測過 Claude |
| 切換模型 | ✅ | ✅ | 模擬器；**真電腦尚未實測** |
| 切換推理強度 | ✅ | —（不做，見「還沒做的」） | 模擬器、真電腦 |
| 切換權限模式 | ✅ | ✅（畫面不顯示目前模式，下一則回覆起生效） | 模擬器、真電腦（Claude） |
| 模型・推理強度・上下文 %、額度（5 小時／每週與重設時間） | ✅ | ✅ | 模擬器、真電腦數字與桌面版自己回報的一致、手機 |
| 局部選字複製（長按 →「拷貝全部」／「選取文字」） | ✅ | ✅ | 模擬器、手機 |
| 網址可點（Markdown 連結、直接寫出的 http(s) 網址、工具輸出裡的網址；電腦上的路徑不是連結） | ✅ | ✅ | 單元測試；0.5.2 起，模擬器與手機待驗 |
| 看電腦畫面（只看不操作；鎖定時看不到） | — | — | 模擬器、真電腦截圖 API |
| 管理員指令核准（`elevate`，Face ID＋HMAC） | — | — | 真電腦＋手機核准執行 |
| ntfy 通知（只發需要處理的事）、點通知直接打開對話 | ✅ | ✅ | 模擬器；通知實際收到；**點通知打開尚未在手機實測** |
| 額度與上下文 ≥80% 提醒 | ✅ | ✅ | 單元測試；**尚未實際觸發** |

## 還沒做的

- **Codex 推理強度**：Codex 的「效能」是 5 格、只能用方向鍵調的滑桿（第 2 格「標準」＝中、第 3 格「延伸」＝高、第 4 格「極高」），實測按一次方向鍵有時會移動後直接關掉選單，不夠可靠；Codex 的推理強度維持 `~/.codex/config.toml` 的 `model_reasoning_effort`。
- **Codex 選項題**：只處理 Claude 的 `AskUserQuestion`。
- 用相機直接拍照傳送（目前只能從相簿選）、封存／改名／搜尋對話。
- 家裡的第二台電腦（使用者決定先不做）、併入工具箱第三個分頁。
- 從手機看 Codex 目前的權限模式（Codex 畫面不顯示，只能從下一則回覆的紀錄得知）。

## 驗證紀錄

| 版本 | CI（模擬器） | 發布 | 實機與真電腦 |
| --- | --- | --- | --- |
| P1 唯讀 | [run 40339664008](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40339664008)：單元 15、UI 11 | — | 真電腦讀真實資料通過（2026-10-26） |
| 0.3.0 build 1 | [run 40439161778](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40439161778)：小幫手 67、單元 23、UI 19 | [desk-remote-0.3.0-build1](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.3.0-build1) | 裝到 iPhone、連上辦公室電腦；手機核准 `elevate` 以管理員執行通過 |
| 0.4.0 build 2 | [run 40455358550](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40455358550)：小幫手 76、單元 26、UI 22 | [desk-remote-0.4.0-build2](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.4.0-build2) | 使用者跳過，直接裝 0.5.0 |
| 0.5.0 build 3 | [run 40465532207](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40465532207)：小幫手 84、單元 30、UI 26 | [desk-remote-0.5.0-build3](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.0-build3)（IPA 441,704 bytes，SHA256 `4bf107f3…4ed3`） | 已裝到 iPhone；真電腦實測推理強度、權限模式、照片、停止、開新對話、「其他」、Codex 停止 |
| 0.5.1 build 4 | 沒有發布（還在建置時就被 0.5.2 取代；內容是 Codex 對話也顯示停止） | — | — |
| 0.5.2 build 5 | 0.5.1 的內容＋網址可點；CI 跑完後補上 run 與 SHA256 | [desk-remote-0.5.2-build5](https://github.com/chunyen627-afk/mobile-apps/releases/tag/desk-remote-0.5.2-build5) | 待安裝 |

實測時發現並修好的問題（細節見 commit 紀錄）：
- **送出**：切換對話後輸入框還是舊頁面 → 只在標題相符的頁面找輸入框並讀回確認；Alt 鍵搶前景會打開 Electron 選單列 → 拿掉；Chromium 下點擊前的元件檢查無效 → 改成檢查該點最上層視窗。
- **允許一次**：Claude 的按鈕 Invoke 回報成功卻沒作用 → 只有詢問真的消失才算成功，否則確認後真實點一次。
- **Codex**：視窗常被關到系統匣 → 用對話連結叫回；這台電腦 Codex 不是以套件身分執行，`codex://` 開不了 → 用已安裝套件的 `ChatGPT.exe --single-argument <連結>`；新對話頁的輸入框叫「想做什麼都可以」；開新對話前視窗不在就先用最近一個對話的連結叫回。
- **前景**：對話已開著時小幫手自己的 SetForegroundWindow 會被 Windows 擋 → 一律用該對話的連結把視窗帶到前面。Claude 一度完全不理會自己的連結 → 連結沒切過去時改按側邊欄上同名的對話（同名或找不到就中止）。
- **選項題**：位置還在捲動時點錯選項 → 先捲到可見再點，送出前核對開著的選項恰好等於手機的選擇；「其他」的開關狀態不可信 → 以出現「其他選項」輸入框為準；單選題要先開「其他」（已選的選項不能單獨取消）。
- **停止**：Claude 把中斷寫成使用者訊息「[Request interrupted by user]」→ 改成「已中止」狀態並回到閒置；手機上「已停止」會跟著執行中那一列消失 → 改成留著。
- **`elevate`**：Git Bash 找不到 `elevate.cmd`、經 cmd 會重新解析引號 → 另放一個直接呼叫 Python 的 `elevate`；Git Bash 下中文亂碼 → 在 Git Bash 改用 UTF-8 輸出。
- **截圖**：畫面操作程式不能宣告高 DPI（點擊座標會變），截圖改由獨立的 DPI-aware 程序做。
- **UI 測試**：清單不排出畫面外的列；在彈出頁頂端往下滑會把它關掉；從外部開自訂網址 iOS 會先問 → 測試改用只往上捲、啟動參數帶連結。

## 結構

```text
DESIGN.md                  設計與決定
project.yml                XcodeGen：App、DeskRemoteCore（framework）、單元與 UI 測試
iOSApp/                    SwiftUI 畫面；DeskRemoteApp.swift 是唯一 @main 檔，工具箱會排除它
Sources/DeskRemoteCore/    API 模型、HelperClient、TranscriptLog、DeskText、DeskLink／DeskPhoto（無 UI）
Tests/                     DeskRemoteCoreTests（單元）、DeskRemoteUITests（模擬器 UI）
fixtures/fake-helper/      人工編寫的示範資料：兩個桌面版的對話清單、逐字稿、權限詢問、額度、示範畫面
pc-helper/                 電腦端小幫手（Python 標準函式庫）、UIA 工作程序、截圖、提權夥伴、單元測試、安裝腳本、設定範例
scripts/build.sh           macOS CI：小幫手測試 → 產生專案 → 模擬器單元與 UI 測試 → Release 封裝
```

## 電腦端小幫手（`pc-helper/`）

- `desk_remote_helper.py`：只綁設定的 ZeroTier 位址，`/v1/*` 要 `Authorization: Bearer <token>`，錯 5 次鎖 10 分鐘並送 ntfy。不寫桌面版任何檔案。
- 資料來源：Claude 讀桌面版的 `claude-code-sessions/*/*/local_*.json`（標題、模型、推理強度、權限模式）、逐字稿 `~/.claude/projects/*/<cliSessionId>.jsonl`、額度 `plan-usage-history.json`；Codex 讀 `~/.codex/state_5.sqlite`（唯讀，讀不到改用 `session_index.jsonl`）與 rollout 檔（`turn_context`、`token_count`）。上下文上限只用桌面版回報過的（Opus 5 系列 100 萬），其他模型只顯示已用量（可在 `config.json` 的 `claude.context_windows` 補）。
- **操作視窗**：常駐的 PowerShell（`uia_worker.ps1`，純 ASCII；控制項名稱都在 `ui_strings.json`，桌面版改版時改這個檔）做 UI Automation，判斷能不能做都在 Python 裡、有單元測試。
  - 動作排隊、一次一個；要用前景的動作（送出、開對話、新對話、Claude 的選單）要電腦閒置 60 秒以上（扣掉小幫手自己的按鍵），否則回「有人在用」，手機確認後才強制。鎖定時一律拒絕。停止、Codex 的模型與權限只用 UI Automation，不需閒置。
  - 先用對話自己的連結打開、等頁面標題完全相符才動作；標題不符、視窗切不到前面、剪貼簿無法安全保存時一律中止，不送任何字。剪貼簿先保存後還原，放入的文字與照片標記為不進剪貼簿歷程與雲端剪貼簿。
  - 送出後 20 秒內要在該對話的逐字稿看到這段文字；同一個 `clientMsgId` 只送一次。照片寫到只有本人讀得到的暫存檔，貼上後立刻刪除。
- **ntfy**（`config.json` 的 `notify.server`／`notify.topic`）：只發需要處理的事——權限詢問、新的選項題、管理員指令等核准、手機操作失敗、一輪完成、額度或上下文 ≥80%（`alerts` 可改門檻）、密碼錯誤鎖定；每則帶 `deskremote://open?…` 連結，點了直接打開那個對話。不含訊息內文與指令內容。
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
- 連線密碼與管理員核准金鑰只存在 iPhone 鑰匙圈（本機限定），位址存在 UserDefaults；倉庫裡沒有任何位址、密碼或金鑰。
- 聊天畫面：頂端一行「模型・推理強度・上下文 %」，點開看細節、額度並切換模型／推理強度／權限模式；工具呼叫收合成一列；輸入列可加照片；送出的訊息先以虛線泡泡顯示進度；處理中可按「停止」；長按訊息可「拷貝全部」或「選取文字」。
- 權限卡片只有「允許一次」「拒絕」。選項題卡片每題標示單選或可複選，可在「其他」自己寫。電腦有人在用時先跳確認，取消就不動作。
