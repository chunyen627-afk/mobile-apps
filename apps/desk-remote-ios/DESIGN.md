# 桌面遙控（desk-remote-ios）設計

狀態：**設計稿，待使用者核准**。核准前不寫 App 與小幫手程式。
更新：2026-10-26。

## 0. 目標與前提

用 iPhone 原生輸入，操作自己 Windows 電腦上的 **Claude 桌面版（Code 分頁）** 與 **Codex 桌面版**：選電腦 → 選 Claude／Codex → 看最近對話或開新對話 → 像在桌面版一樣打字、看回覆、按權限的「允許一次」／「拒絕」。

已確認的事（2026-10-26 在辦公室電腦實測，探針腳本只在本機）：

| 項目 | Claude 桌面版 | Codex 桌面版（行程名 `ChatGPT`） |
| --- | --- | --- |
| 切換對話 | `claude://claude.ai/epitaxy/local_<id>` | 側邊欄 Button（名稱＝標題）；安裝檔內另有 `codex://threads/<id>` 連結，**未實測** |
| 確認目前對話 | `Document`（AutomationId `RootWebArea`）名稱＝「<標題> - Claude Code」 | 同一個 Document，名稱＝標題 |
| 送出訊息 | Edit「提示詞」SetFocus → 剪貼簿貼上 → Enter，顯示為本人訊息、不分岔 | Edit「與 Codex 協作」→ 貼上 → Enter |
| 讀內容 | Text 元素：回覆、指令結果、權限請求全文 | 「ChatGPT 說：」、回覆、「正在執行 <指令>」 |
| 權限 | 「拒絕」按鈕；「允許一次」在「更多允許選項」下拉裡，下拉**要真的滑鼠點擊**才開，開後 MenuItem 可 Invoke | 「允許一次」「拒絕」都是可直接 Invoke 的按鈕 |

不走的路：`claude -p --resume` 會跟桌面版記憶體裡的對話分岔；桌面版跨對話訊息會被標示且不能當成使用者核准；官方遠端控制被管理員關閉；遠端桌面打字難用。

使用者已決定：
- 平常用自動模式（Claude 自動／Codex 代我核准），App 只在真的有詢問時顯示權限卡片。
- 只有送出、開對話、按 Claude 的下拉時才需要前景；讀取與 Codex 的按鈕不需要。
- 需要管理員權限的指令走 **`elevate`（方案 A）**；其他程式跳出的 UAC 用使用者現有的 Google 遠端桌面處理。**不改 UAC 設定、不以管理員身分開桌面版。**
- 程式放 `chunyen627-afk/mobile-apps` 的 `apps/desk-remote-ios/`；之後成為工具箱第三個分頁。

## 1. 整體架構

```text
iPhone App ──HTTP（只走 ZeroTier，Bearer token）──▶ 小幫手 desk-remote-helper（使用者權限，互動工作階段）
                                                    ├─ 讀檔：對話清單、逐字稿 JSONL（不碰畫面）
                                                    ├─ UI 動作佇列 → 常駐 PowerShell UIA 工作程序 → Claude／Codex 視窗
                                                    ├─ ntfy：每個動作、權限詢問、elevate 請求
                                                    └─ 具名管道 ⇄ 提權夥伴 desk-remote-elevated（最高權限，同一工作階段）
                                                                     ▲
                                              AI 在終端機執行 elevate ─┘（具名管道，等待手機核准後拿到輸出）
```

| 元件 | 語言／執行方式 | 理由 |
| --- | --- | --- |
| 小幫手 HTTP 與邏輯 | Python 3.11 標準函式庫（同礦機彙整服務：`ThreadingHTTPServer`、`hmac`、`ipaddress`、`RotatingFileHandler`），`pythonw` 隱藏執行 | 跟現有電腦端服務同一套寫法與測試方式；不裝套件 |
| UI Automation | **一個常駐的** `powershell.exe -NoProfile` 工作程序，載入一次 `UIAutomationClient`，stdin/stdout 用 UTF-8 JSON 一行一個指令 | 直接沿用已驗證的探針寫法；避免每次動作都重開 PowerShell（約 1 秒）；不需安裝 comtypes |
| 提權夥伴 | 同一份 Python，以 `--elevated` 啟動 | 程式碼一份；權限邊界由排程工作決定 |
| `elevate` CLI | `elevate.cmd` → `python elevate.py`，放在使用者 PATH | Claude（Bash／PowerShell）與 Codex 都能叫 |

## 2. 電腦端小幫手

### 2.1 啟動與常駐

- 使用者登入時由**工作排程器**啟動（觸發：此使用者登入；「只在使用者登入時執行」；**一般權限**）。必須跑在互動工作階段，不能做成 Windows 服務（session 0 摸不到畫面）。
- 單一執行個體：具名 mutex `Local\DeskRemoteHelper`。
- 綁定位址等 ZeroTier 出現才開聽，**不退回其他網卡**（同礦機服務 `winerror 10049` 迴圈）。
- 設定與狀態只在本機：`%LOCALAPPDATA%\DeskRemote\config.json`（ACL 只給目前使用者）、`helper.log`（輪替 1 MB × 3）。倉庫只放 `config.example.json`（佔位值）。

### 2.2 對話清單

**Claude**：桌面版把每個 Code 對話的中繼資料存在
`%LOCALAPPDATA%\Claude-Data\claude_<套件代號>\claude-code-sessions\<帳號>\<組織>\local_<id>.json`（2026-10-26 確認，桌面版 3.6556）。用到的欄位：

| 欄位 | 用途 |
| --- | --- |
| `sessionId`（`local_<id>`） | 組 `claude://claude.ai/epitaxy/local_<id>` |
| `title` | 清單顯示、送出前比對 |
| `lastActivityAt`（毫秒） | 由新到舊排序 |
| `isArchived` | 預設不列出封存 |
| `cliSessionId` | 找逐字稿 `~/.claude/projects/*/<cliSessionId>.jsonl` |
| `cwd` | 只傳資料夾名稱（最後一段）給手機，不傳完整路徑 |
| `permissionMode` | 顯示「自動／手動／略過」 |
| `postTurnSummary.status_category`、`interruptedAwaitingPerson` | 粗略狀態（完成、需要處理） |

- 多個帳號資料夾時，取**最近有寫入**的那個（目前登入的帳號）；可在設定指定。
- 這是桌面版內部格式，沒有文件保證：解析失敗或欄位缺少時，退回 **UI Automation 讀側邊欄**（只有標題、沒有 id，此時只能「開啟目前畫面上的對話」），並在 App 顯示「清單格式改變，功能受限」。
- 不讀 `deleted_*`、`archived-sessions.idx` 以外的檔案，不寫任何桌面版檔案。

**Codex**：
1. 主要：唯讀開 `~/.codex/state_5.sqlite`（`mode=ro`）的 `threads` 表：`id`、`title`、`recency_at_ms`、`archived`、`rollout_path`、`cwd`、`agent_role`、`thread_source`。排除子執行緒（例如「Guardian review」這類有 `agent_role`／父執行緒的）。
2. 退路：`~/.codex/session_index.jsonl`（`id`、`thread_name`、`updated_at`）。
3. 再退：UIA 讀側邊欄 Button。

兩邊都只回傳：id、標題、資料夾名稱、更新時間、狀態、權限模式。上限 50 筆，App 由新到舊顯示。

### 2.3 開啟對話與安全檢查

| | Claude | Codex |
| --- | --- | --- |
| 開啟 | `Start-Process claude://claude.ai/epitaxy/local_<id>` | 先試 `codex://threads/<id>`（第一階段實測）；不行就 Invoke 側邊欄同名 Button，必要時先確保模式是「Codex」 |
| 等待 | 每 250 ms 讀 `RootWebArea` 名稱，最多 8 秒 | 同左 |
| 通過條件 | 名稱 ＝「<最新 title> - Claude Code」 | 名稱 ＝ 最新 title |

- **標題重複**（實際清單裡就有兩個「CODEX 對話討論 (fork)」）：只靠標題無法區分。做法：送出前**一律重新開一次連結**再比對標題（Claude 的連結本身帶 id），整段「開啟→比對→貼上→Enter」在同一個 UI 工作裡完成、中間檢查使用者有沒有碰電腦；Codex 若連結不可用而側邊欄有同名 Button，就拒絕並請使用者在電腦上改名。
- **送出後驗證**：10 秒內必須在該對話的 JSONL 看到這則使用者訊息；看到別的對話多了這段文字或沒看到，立刻 ntfy 警告並在 App 標紅。
- 分割畫面（同時開兩個對話）時可能有多個 `RootWebArea`：只對名稱相符的那個操作，找到多於一個相符就中止。

### 2.4 送出文字

1. 檢查「有人在用電腦」（2.7）與鎖定（2.8），不通過就排隊或回錯誤。
2. 記下目前前景視窗與游標位置。
3. 開啟並比對對話（2.3）。
4. 保存剪貼簿 → 放入要送的文字 → 對 Edit SetFocus → Ctrl+V → 300 ms → 讀 Edit 內容確認貼上的字數 → Enter。
5. 還原剪貼簿、前景視窗與游標。

剪貼簿細節：
- 保存與還原**所有常見格式**（文字、Unicode、RTF、HTML、圖片、檔案清單），不是只有文字；無法完整保存時（例如延遲呈現的格式）先不送，回報「剪貼簿內容無法安全保存」。
- 放入時一併設定 `ExcludeClipboardContentFromMonitorProcessing`、`CanIncludeInClipboardHistory=0`、`CanUploadToCloudClipboard=0`，讓手機傳來的文字不進 Win+V 歷程、不同步到雲端剪貼簿。
- 備案（第一階段比較）：`SendInput` 的 `KEYEVENTF_UNICODE` 直接打字、換行用 Shift+Enter，完全不碰剪貼簿；長文字較慢。
- 文字上限 20,000 字；換行保留（貼上時換行不會送出）。
- 每則訊息帶手機產生的 `clientMsgId`，小幫手 10 分鐘內去重，手機重送不會重複貼上。

### 2.5 即時讀取逐字稿

主要讀**檔案**，畫面只補檔案沒有的東西：

| 來源 | 內容 | 優點／限制 |
| --- | --- | --- |
| Claude `~/.claude/projects/*/<cliSessionId>.jsonl` | `user`（文字、`tool_result`）、`assistant`（`text`、`tool_use`；`thinking` 只顯示「思考中」）| 完整、有結構、不受畫面捲動影響；檔案可達數十 MB，**只從尾端讀**，每個對話記住 byte offset 只讀新增行 |
| Codex rollout `sessions/YYYY/MM/DD/rollout-*-<id>.jsonl` | `response_item` 的 `message`（user／assistant）、`function_call`／`custom_tool_call` 與輸出、`event_msg` 的 `task_started`／`task_complete` | 同上 |
| UIA（只限目前開著的對話） | 權限詢問全文與按鈕、「執行中」狀態、尚未寫進檔案的串流文字 | 不需前景；桌面版同時只載入一個對話頁面，所以背景對話只能看檔案 |

- 略過的紀錄：`api-request*`、`attachment`、`file-history-*`、`queue-operation`、`developer` 訊息、`isSidechain`（子代理，收合成一列）。
- 每筆事件轉成統一格式：`{seq, ts, kind: user|assistant|tool_call|tool_result|permission|status, text, tool, collapsed, itemId}`；工具輸出超過 2 KB 只送前段並標 `truncated`，App 點開再用 `itemId` 取全文（上限 256 KB）。
- 格式不認得的行跳過並計數，`/v1/state` 回報「無法解析 N 行」，不讓整個對話讀不到。

### 2.6 權限詢問

偵測：只對目前開著的對話，UIA 掃描到「拒絕」＋（Claude）「更多允許選項」／（Codex）「允許一次」按鈕時，讀同一區塊的 Text 當詢問內容，產生 `promptId = sha256(對話 id ＋ 詢問全文)`。背景對話以中繼資料的「需要處理」狀態提示，使用者點進去時小幫手才把它開到前景。

執行（App 送 `promptId` 與 `allow_once`／`deny`）：
1. 重新讀詢問全文、算 `promptId`，**跟手機送來的不同就拒絕**（使用者核准的必須就是他看到的那一個）。
2. Codex：Invoke「允許一次」或「拒絕」。不需前景。
3. Claude：「拒絕」直接 Invoke；「允許一次」要前景 → 檢查沒人在用 → 第一階段先試鍵盤開下拉（Focus 後 Enter／Space／Alt+↓）；不行再照探針用 `SetCursorPos`＋`mouse_event` 點下拉中心 → 等 MenuItem「允許一次」出現 → Invoke → 還原游標與前景。
4. 只提供「允許一次」與「拒絕」，**不提供「永遠允許」**，避免手機誤觸放寬權限。
5. 結果與詢問摘要送 ntfy。

所有 UI 文字（「提示詞」、「與 Codex 協作」、「允許一次」、「更多允許選項」、「拒絕」…）放在 `ui_strings.json`，桌面版改版或改語言時改設定、不改程式。

### 2.7 新對話

- Codex：Invoke「新對話」或「在 <專案> 中開始新對話」（手機從清單選專案），等 Document 名稱變化後送第一則訊息。
- Claude：UIA 找側邊欄的「新工作階段」類按鈕，使用桌面版目前預設的資料夾，畫面上的資料夾名稱回傳給手機確認後才送第一則訊息。選其他資料夾需操作資料夾選單，**放到後續階段**。
- 新對話出現在中繼資料／`threads` 表後，回傳新 id，App 直接進入聊天畫面。

### 2.8 有人在用電腦時暫停；鎖定不支援

- 用 `GetLastInputInfo` 算閒置秒數；**扣掉小幫手自己送出的輸入**（記錄自己 SendKeys／滑鼠的時間）。
- 需要前景的動作（送出、開對話、新對話、Claude 允許一次）只在閒置 ≥ `idle_seconds`（預設 60 秒）時執行；否則排隊並回 `409 busy-user`，App 顯示「電腦有人在用，閒置 N 秒後送出」與「取消」。App 可選「仍要送出」（再確認一次），因為在電腦前的也是使用者本人。
- 動作進行中若偵測到新的實體輸入，立即中止並還原剪貼簿與前景。
- 不需前景的動作（讀檔、Codex 按鈕、Claude 拒絕）不受影響。
- **鎖定畫面不支援**：`OpenInputDesktop` 失敗或 `LogonUI.exe` 在前景時視為鎖定，所有 UI 動作回 `423 locked`，App 顯示「電腦已鎖定，請先解鎖（可用 Google 遠端桌面）」；讀檔仍可用。

### 2.9 UI 動作佇列

畫面是單一共用資源：所有 UI 動作進一個佇列、一次一個，每個動作有逾時（預設 20 秒）。PowerShell 工作程序卡住或結束就重開。佇列狀態 `/v1/actions/<id>` 可查。

## 3. 管理員權限：`elevate`（方案 A）

### 3.1 元件

- **提權夥伴** `desk-remote-elevated`：工作排程器，觸發「此使用者登入」、**「以最高權限執行」**、「只在使用者登入時執行」→ 在同一個互動工作階段以使用者的管理員權杖執行。建立這個排程工作本身需要管理員權限，由使用者在電腦前（或 Google 遠端桌面）執行一次安裝腳本。
- 不開網路埠。只開具名管道 `\\.\pipe\DeskRemoteElevate`，ACL 只允許目前使用者連線。
- `elevate` CLI（一般權限）：

  ```text
  elevate -c "<PowerShell 指令>" [--cwd <資料夾>] [--timeout 600]
  elevate -f <腳本.ps1>          [--cwd <資料夾>] [--timeout 600]
  ```

  連到具名管道送出請求後**阻塞等待**，把結果的 stdout／stderr 原樣印出、以相同結束碼結束；手機拒絕或逾時則結束碼 126 並印出原因。

### 3.2 流程

1. AI 執行 `elevate`。夥伴讀進指令或腳本**內容**（只讀一次），存到 `%ProgramData%\DeskRemote\pending\`（ACL 只給 Administrators／SYSTEM），算 `sha256`，產生一次性 `nonce` 與到期時間（10 分鐘）。
2. 小幫手輪詢夥伴的待核准清單，推 ntfy（高優先，「需要管理員權限」）並在 App 首頁顯示卡片：完整指令／腳本內容、資料夾、發起時間、哪個程式發起（父行程名稱）。
3. 使用者在 App 按「允許」→ **Face ID／密碼確認**（LocalAuthentication）→ App 用 Keychain 裡的 **elevate 金鑰**算 `HMAC-SHA256(nonce ‖ sha256(內容) ‖ cwd ‖ 到期時間)` 送給小幫手 → 小幫手轉給夥伴。
4. 夥伴驗證 HMAC、未過期、nonce 未用過，才執行 `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <ProgramData 裡的副本>`。執行的是步驟 1 存下的副本，不是 AI 那邊可再修改的原檔（避免核准後被掉包）。
5. 輸出上限 1 MB、逾時預設 10 分鐘（上限 60 分鐘），結束後把輸出、結束碼回給 CLI；摘要（指令前 200 字、結束碼、耗時）送 ntfy、寫入夥伴自己的日誌（`%ProgramData%\DeskRemote\elevated.log`）。

### 3.3 為什麼要另一把金鑰

提權夥伴等於在 UAC 上開一個有門鎖的洞。小幫手以一般權限執行，若電腦上有以使用者身分執行的惡意程式，它可以冒充小幫手；所以**核准的證明不能來自小幫手**：
- elevate 金鑰只在**手機 Keychain**（本機限定、需裝置解鎖）與夥伴的 `%ProgramData%\DeskRemote\elevate.key`（ACL 只給 Administrators／SYSTEM）。小幫手與 `config.json` 都沒有它。
- HMAC 綁住內容雜湊：小幫手若給手機看的內容跟夥伴要執行的不同，簽章就對不上。
- 一次性 nonce、10 分鐘到期、同時最多 3 個待核准、每分鐘最多 5 個請求。

### 3.4 給 AI 的規則行（核准後由我加進規則檔）

加到 `~/.claude/CLAUDE.md`、家目錄 `AGENTS.md` 與 `~/.codex/AGENTS.md`（含手機 Flask 的 WIN_RULES 來源，改完照既有流程同步）：

> 需要系統管理員權限的指令（例如安裝驅動、改服務、寫 Program Files），一律改用 `elevate -c "<PowerShell 指令>"` 或 `elevate -f <腳本.ps1>`：它會推到使用者手機等核准，最多等 10 分鐘，輸出與結束碼原樣回傳；結束碼 126 代表被拒絕或逾時，不要重試同一指令。不要用 `Start-Process -Verb RunAs`、`runas`，也不要修改 UAC 或任何安全性設定。

### 3.5 不做的事

- 不改 UAC 設定、不關安全桌面、不以管理員身分開桌面版。
- 其他程式跳出的 UAC 視窗（安全桌面）不處理，使用者用 Google 遠端桌面自己按。
- 夥伴不接受網路請求、不執行沒有手機簽章的任何東西。

## 4. 通訊協定與安全

### 4.1 傳輸

- HTTP，**只綁 ZeroTier 位址**，`allowed_networks` 只含 ZeroTier 網段；設定為 `0.0.0.0` 或不在網段內就拒絕啟動（沿用礦機服務的 `load_config` 檢查）。ZeroTier 本身加密點對點流量。
- 即時更新用 **HTTP long-poll**（`wait` 最多 25 秒），不用 WebSocket：Python 標準函式庫沒有 WebSocket，而 App 只在前景讀取，long-poll 在 `URLSession` 上最單純、斷線好重試。若之後延遲不夠再評估。
- 每個回應 `Cache-Control: no-store`、`Connection: close`（long-poll 除外）、JSON 大小上限。

### 4.2 認證、鎖定、通知

- 除了 `/health`，每個請求要 `Authorization: Bearer <token>`，token 32 bytes 隨機（base64url），`hmac.compare_digest` 比對。
- 5 次錯誤鎖 10 分鐘（同礦機 `Controller`），鎖定時 ntfy 通知。
- ntfy：**每個寫入動作**（送出、開對話、新對話、允許／拒絕、elevate 請求與結果）都通知，內容只有電腦名稱、App、對話標題、動作，不含訊息全文與位址；另可選「權限詢問出現」「一輪完成」通知（預設開，彌補 App 只在前景讀取）。
- 同一對話送出間隔至少 2 秒；elevate 限流見 3.3。

### 4.3 API（v1）

| 方法與路徑 | 用途 |
| --- | --- |
| `GET /health` | 不需 token，`{ok}` |
| `GET /v1/state` | 電腦名稱、小幫手版本、Claude／Codex 是否在執行、閒置秒數、是否鎖定、待核准 elevate 數、解析警告 |
| `GET /v1/{claude\|codex}/sessions?limit=50` | 對話清單（新到舊） |
| `GET /v1/{app}/sessions/{id}/events?after=<cursor>&wait=25` | 逐字稿事件（long-poll） |
| `GET /v1/{app}/sessions/{id}/items/{itemId}` | 展開被截短的工具輸出 |
| `POST /v1/{app}/sessions/{id}/messages` | `{text, clientMsgId}` → `202 {actionId}` |
| `POST /v1/{app}/sessions/{id}/permission` | `{promptId, decision: allow_once\|deny}` |
| `POST /v1/{app}/sessions` | 新對話 `{text, project?}` |
| `GET /v1/actions/{actionId}` | 動作結果：`queued\|running\|done\|failed`＋原因 |
| `GET /v1/elevate` | 待核准清單（含內容、nonce、到期） |
| `POST /v1/elevate/{nonce}` | `{decision, hmac}` |

錯誤一律 `{ok:false, error:<代碼>, message:<中文說明>}`，代碼：`unauthorized`、`locked-out`、`busy-user`、`locked`、`app-not-running`、`title-mismatch`、`not-found`、`format-changed`、`timeout`。

### 4.4 倉庫與隱私

- 倉庫不含：私人 IP、ZeroTier 網路 ID、token、elevate 金鑰、帳號、使用者名稱、ntfy topic、真實對話內容。`config.example.json` 全用佔位值；測試 fixtures 全部人工編寫。
- 提交前檢查：完整讀 staged diff，掃描 IP、`token`、`key`、使用者名稱、topic 等字樣。
- 手機端 token 與 elevate 金鑰存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，每台電腦一組），不進 UserDefaults、不進備份。
- 配對：電腦端安裝腳本產生 token（一般步驟）與 elevate 金鑰（提權步驟），在電腦螢幕顯示 QR code，App 內用 VisionKit 掃描；也可手動貼上。QR 只顯示在本機螢幕，不寫檔、不經網路。

## 5. iPhone App

### 5.1 畫面

```text
電腦清單 ──▶ 選 Claude／Codex ──▶ 對話清單（新到舊） ──▶ 聊天畫面
   │                                   └─ ＋ 新對話
   └─ 設定：新增電腦（名稱、位址、埠、token、elevate 金鑰；掃 QR）
首頁頂端：待核准的 elevate 卡片（任何電腦）
```

- **電腦清單**：名稱、連線狀態燈、閒置／鎖定／有人在用、待核准數。
- **對話清單**：標題、資料夾名稱、相對時間、狀態標籤（執行中／需要處理／完成）、權限模式。下拉更新。
- **聊天畫面**：
  - 使用者訊息靠右、回覆靠左；Markdown 基本呈現（粗體、程式碼區塊、清單）。
  - 工具呼叫收合成一列（工具名稱＋指令首行），點開看輸出；子代理收合。
  - **權限卡片**：詢問全文、「允許一次」「拒絕」，按下後顯示處理中直到小幫手回報結果；同一卡片只能按一次。
  - 底部原生輸入框（多行、iOS 鍵盤與聽寫），送出後顯示「排隊中／已送出／已確認出現在對話」三段狀態；`busy-user` 時顯示倒數與「仍要送出」。
- **elevate 卡片**：完整內容（等寬字、可捲動）、資料夾、發起程式、剩餘時間；「允許」需 Face ID／密碼，「拒絕」不需要。

### 5.2 前景限定與限制

- 只在前景讀取：聊天畫面用 long-poll；對話清單每 10 秒；電腦清單每 30 秒。離開前景立即取消請求；回到前景先讀一次再更新畫面。
- 沒有背景執行與推播；App 關著時靠電腦端 ntfy 通知（權限詢問、elevate、一輪完成）。
- 送出中切到背景，請求可能被取消：用 `clientMsgId` 安全重送，回前景時查 `/v1/actions` 補狀態。
- 長回覆在手機上只顯示檔案已寫入的部分；串流中的半句只在該對話是電腦上目前開著的那個時才看得到。

### 5.3 專案結構（沿用礦機與工具箱的作法）

```text
apps/desk-remote-ios/
  DESIGN.md  README.md  project.yml
  Sources/DeskRemoteCore/      無 UI：API 模型、client、事件合併、HMAC、錯誤文字（framework）
  iOSApp/                      SwiftUI 畫面；DeskRemoteApp.swift 是唯一 @main 檔
  Tests/DeskRemoteCoreTests/   單元測試
  Tests/DeskRemoteUITests/     模擬器 UI 測試（含截圖）
  fixtures/                    人工編寫的對話清單、事件、權限、elevate 情境
  pc-helper/                   desk_remote_helper.py、uia_worker.ps1（UTF-8 BOM）、elevate.py、elevate.cmd、
                               install.ps1、ui_strings.json、config.example.json、tests/
  scripts/build.sh
.github/workflows/desk-remote-ios.yml
```

- Bundle ID `org.personal.deskremote.app`，iOS 17+（同工具箱），iPhone 優先。顯示名稱：`CFBundleDisplayName` 用英文 `DeskRemote`（SideStore 不收中文），`zh-Hant.lproj/InfoPlist.strings` 為「桌面遙控」。
- ATS 用 `NSAllowsLocalNetworking`、附 `NSLocalNetworkUsageDescription`、`NSCameraUsageDescription`（掃 QR）、`NSFaceIDUsageDescription`，與礦機一致；不要背景模式。

## 6. 工具箱整合

工具箱把每個工具的原始碼**直接編進同一個 `Lightbox` 模組**，只排除各自的 `@main` 檔；核心則各自是 framework target。因此：

- `@main` 只在 `iOSApp/DeskRemoteApp.swift`，裡面只有 `WindowGroup { DeskRemoteRootView() }`；工具箱排除這個檔。
- 進入點命名為 **`DeskRemoteRootView`**（礦機已用掉 `RootView`）。所有 App 層型別一律加 `Desk` 前綴，避免與相簿、礦機撞名；同一模組裡不可有重複的 `extension View` 方法名。
- 核心做成 `DeskRemoteCore` framework，工具箱照 `MinerStatusCore` 加一個 framework target 與它的單元測試 target。
- UserDefaults key 一律 `deskremote.` 開頭；Keychain service `org.personal.deskremote.*`。工具箱的 Bundle ID 不同，所以設定與金鑰不會從單獨 App 帶過去，要在工具箱重新配對一次（同礦機）。
- 需要在工具箱 `Info.plist` 補相機、Face ID 用途說明。
- 工具箱的 `ToolboxTool` 加 `desk` 分頁，UI 測試用 `TOOLBOX_TOOL=desk` 直接進入。
- 第三個分頁的工作在工具箱分支／session 做，本 App 只保證以上介面。

## 7. 階段、測試與風險

### 7.1 階段

| 階段 | 內容 | 驗收 |
| --- | --- | --- |
| P1 唯讀 | 小幫手：設定檢查、認證／鎖定、ntfy、對話清單（檔案）、逐字稿事件、`--fake` 模式；App：電腦／對話清單、聊天畫面（唯讀） | 小幫手單元測試在本機通過；CI 單元＋UI 測試通過、截圖人工檢視；本機實際讀到真實清單（只讀，不動畫面） |
| P2 UI 動作 | UIA 工作程序、動作佇列、開啟＋標題比對、送出＋剪貼簿保存、權限、新對話、閒置暫停、鎖定偵測；`codex://threads/<id>` 與 Claude 下拉鍵盤操作實測 | 用專門的測試對話實測（**每次先問使用者**，因為會切換畫面上的對話）；送出後 JSONL 驗證通過 |
| P3 elevate | 提權夥伴、具名管道、CLI、HMAC、Face ID、規則行 | 單元測試（簽章錯、過期、重放、內容掉包都要被拒）；使用者同意後實測一個無害指令（例如讀 `whoami /groups` 的完整性等級） |
| P4 手機實機 | 簽署安裝 | 模擬器 UI 測試通過且截圖看過才裝；**每次發布前先問** |
| P5 工具箱 | 第三個分頁 | 工具箱所有測試組數量閘門通過 |

### 7.2 測試

- **App（CI 模擬器）**：`build.sh` 在 Mac 的 `127.0.0.1` 用 `desk_remote_helper.py --fake fixtures/` 開假的小幫手：**真的 HTTP 與認證層**＋腳本化後端（固定清單、逐步吐出的事件、會出現的權限詢問、`busy-user`、`locked`、`title-mismatch`、elevate 請求），位址以 `TEST_RUNNER_DESK_HELPER` 傳入。UI 測試涵蓋每個畫面與錯誤狀態並截圖；單元與 UI 測試各自數量閘門；截圖推到 `ci-screenshots-desk-remote-ios`，每張都看過。
- **小幫手（本機）**：`python -m unittest`，fixtures 是人工編寫的 Claude 中繼資料／JSONL、Codex sqlite 與 rollout 樣本，**不放真實對話**。包含：大檔尾端讀取、半行、格式改變、標題重複、clientMsgId 去重、閒置判斷（扣除自己的輸入）、鎖定、Bearer 錯誤鎖定、綁定位址檢查、HMAC 驗證。
- **變異測試**：故意把標題比對、HMAC 比對、閒置判斷改壞，確認測試會失敗（避免全綠但測不到）。
- **實機 UI 自動化**：只在使用者同意的時段，用專門的測試對話；Codex 用另外建立的測試執行緒；不碰正在工作的對話（例如 FPGA、礦機）。

### 7.3 風險

| 風險 | 影響 | 對策 |
| --- | --- | --- |
| 桌面版改版：中繼資料格式、UI 文字、`RootWebArea` 名稱格式 | 清單或操作失效 | 版本檢查＋退回 UIA 側邊欄；UI 文字在 `ui_strings.json`；失敗明確回 `format-changed`，不亂猜 |
| 送錯對話 | 訊息進錯對話 | 連結帶 id＋標題比對＋同一工作內完成＋送出後 JSONL 驗證＋ntfy 警告；Codex 同名拒絕 |
| 搶走使用者的焦點、蓋掉剪貼簿 | 干擾正在用電腦的人 | 閒置門檻、偵測到輸入立即中止、完整保存與還原剪貼簿、不進剪貼簿歷程 |
| Claude「允許一次」要滑鼠點 | 視窗被擋、多螢幕座標錯 | 先試鍵盤；點擊前把視窗移到前景並確認座標落在下拉按鈕上（`ElementFromPoint` 驗證） |
| 前景權限限制（`SetForegroundWindow` 被拒） | 貼不進去 | 用 UIA `SetFocus`（探針已成功）；失敗則中止並回報，不盲送按鍵 |
| 電腦鎖定、登出、睡眠 | 無法操作 | 明確回報；讀檔仍可用；不嘗試繞過鎖定 |
| elevate 被濫用 | 取得管理員權限 | 手機持有的獨立金鑰＋內容雜湊＋nonce＋Face ID＋限流＋全部 ntfy |
| 小幫手 token 外洩 | 他人可在 ZeroTier 內操作對話 | 只綁 ZeroTier、5 次錯誤鎖定、每個動作 ntfy、可在電腦端換 token |
| 大型 JSONL（數十 MB）、sqlite 被桌面版鎖住 | 讀取慢或失敗 | 尾端讀取＋offset；sqlite 唯讀並短暫重試，失敗退回 `session_index.jsonl` |
| 手機名額已滿 | 單獨 App 無法實機驗證 | 見下方待決事項 2 |
| PowerShell 5.1 中文編碼 | 亂碼 | `.ps1` 存成 UTF-8 BOM＋CRLF，stdin/stdout 明確設 UTF-8，文字一律走 JSON |

## 8. 使用者決定（2026-10-26 核准）

設計核准，第 8 節全部照建議：

1. **名稱**：資料夾 `apps/desk-remote-ios`，主畫面「桌面遙控」。
2. **實機驗證**：單獨 App 只做到模擬器通過；實機驗證在工具箱第三分頁做。
3. **閒置門檻**：預設 60 秒，可選「仍要送出」強制。
4. **ntfy**：每個動作、權限詢問出現、一輪完成都通知（預設開）。
5. **電腦**：先只做辦公室這台；家裡那台之後再裝。
