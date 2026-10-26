# 桌面遙控（desk-remote-ios）

用 iPhone 原生輸入操作自己 Windows 電腦上的 Claude 桌面版與 Codex 桌面版：看對話清單、打字送出、看回覆、按權限的「允許一次」／「拒絕」，並在手機核准需要管理員權限的指令（`elevate`）。設計見 [DESIGN.md](DESIGN.md)（2026-10-26 核准）。

**目前到 P2**：P1 唯讀（清單、即時逐字稿）之外，手機可以送出訊息、按「允許一次」／「拒絕」、開新對話、把等待處理的對話在電腦上打開。`elevate` 在 P3。

## 驗證狀態

| 項目 | 狀態 |
| --- | --- |
| 小幫手 P1 讀取 | 辦公室電腦讀真實資料通過（2026-10-26）：經 ZeroTier 位址讀到 Claude 與 Codex 的真實對話清單與逐字稿，long-poll 正常；未帶 token 回 401 |
| 小幫手 P2 操作（`pc-helper/`） | 44 項 Python 單元測試在 Windows 本機通過（用假的視窗驅動）；另做 10 項變異測試（拿掉標題比對、有人在用的檢查、鎖定檢查、重送去重、權限詢問比對、同名對話拒絕、通知不含內文、允許一次的前景檢查、扣除自身輸入、送出後確認），全部被測試抓到 |
| 真的 Claude 桌面版實測（2026-10-26，使用者同意，只測 Claude） | **送出：通過**（對話開著時送出並在逐字稿確認；切換對話後送出，訊息被 Claude 收進佇列，因為該對話還在等權限）。**閒置門檻：通過**（等滿 60 秒才動作）。**偵測權限詢問、在電腦上打開對話：通過**。**允許一次：通過**（2026-10-27）：這一版的「允許一次」是權限區塊裡的一般按鈕（不在「更多允許選項」選單裡）；它的 Invoke 回報成功卻沒作用，改成確認該點最上層視窗是 Claude 後真實點一次，詢問消失、Claude 寫入測試檔並回覆，排隊中的訊息也接著處理。現在只有詢問真的消失才算成功。測試過程另外修掉三個問題：切換後輸入框還是舊頁面（改成只在標題相符的頁面找輸入框、等頁面穩定、貼上後讀回確認）、Alt 鍵技巧會打開 Electron 的選單列吃掉貼上與點擊（已拿掉）、滑鼠點擊前的元件檢查在 Chromium 下無效（改成檢查該點最上層視窗是 Claude）。Codex 與新對話尚未實測 |
| iPhone App P2 畫面 | **編譯通過、模擬器測試通過**：單元 18、UI 15 項，0 失敗，21 張截圖已人工檢視（[run 40346483209](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40346483209)） |
| P1 的 CI 證據 | 單元 15、UI 11 項 0 失敗（[run 40339664008](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40339664008)） |
| 實機 | 依決定在工具箱第三分頁驗證；尚未進行 |
| 小幫手常駐安裝 | `install.ps1` 已寫好，**尚未在電腦上執行** |

## 結構

```text
DESIGN.md                  設計與決定
project.yml                XcodeGen：App、DeskRemoteCore（framework）、單元與 UI 測試
iOSApp/                    SwiftUI 畫面；DeskRemoteApp.swift 是唯一 @main 檔，工具箱會排除它
Sources/DeskRemoteCore/    API 模型、HelperClient、TranscriptLog、DeskText（無 UI）
Tests/                     DeskRemoteCoreTests（單元）、DeskRemoteUITests（模擬器 UI）
fixtures/fake-helper/      人工編寫的示範資料：兩個桌面版的對話清單、逐字稿、權限詢問
pc-helper/                 電腦端小幫手（Python 標準函式庫）、UIA 工作程序、單元測試、安裝腳本、設定範例
scripts/build.sh           macOS CI：小幫手測試 → 產生專案 → 模擬器單元與 UI 測試 → Release 封裝
```

## 電腦端小幫手

- `desk_remote_helper.py`：只綁設定的 ZeroTier 位址，`/v1/*` 要 `Authorization: Bearer <token>`，錯 5 次鎖 10 分鐘並送 ntfy。
- 對話清單：Claude 讀桌面版自己的 `claude-code-sessions/*/*/local_*.json`；Codex 讀 `~/.codex/state_5.sqlite`（唯讀），讀不到時改用 `session_index.jsonl`。不寫桌面版任何檔案。
- 逐字稿：Claude `~/.claude/projects/*/<cliSessionId>.jsonl`、Codex rollout 檔，只從檔尾讀新增的完整行；工具輸出太長時只送前段，手機點開再取全文。
- **操作視窗（P2）**：一個常駐的 PowerShell（`uia_worker.ps1`，純 ASCII，控制項名稱從 `ui_strings.json` 傳入）做 UI Automation；判斷能不能做都在 Python 裡，有單元測試。
  - 每個動作排隊、一次一個；送出、開對話、新對話、Claude 的「允許一次」要電腦閒置 60 秒以上（扣掉小幫手自己的按鍵），否則回「有人在用」，手機確認後才強制。電腦鎖定時一律拒絕。
  - 送出前先用對話自己的連結（`claude://claude.ai/epitaxy/local_<id>`、`codex://threads/<id>`）打開，等頁面標題完全相符才打字；Codex 連結沒切過去時，只有標題唯一才改按側邊欄。標題不符、視窗切不到前面、剪貼簿無法安全保存時一律中止，不送任何字。
  - 剪貼簿：保存並還原文字、RTF、HTML、圖片、檔案清單；放入的文字標記為不進剪貼簿歷程與雲端剪貼簿。
  - 送出後 20 秒內要在該對話的逐字稿看到這段文字，看不到就回報「還沒看到」。同一個 `clientMsgId` 只送一次。
  - 權限：每 4 秒看一次目前開著的對話有沒有詢問；手機只能按「允許一次」或「拒絕」，送來的 `promptId` 必須等於畫面上的那個詢問。Claude 的「允許一次」先試鍵盤開選單，不行才點一次滑鼠（先確認游標下就是那個按鈕）。
  - ntfy：每個動作（只有電腦名稱、App、對話標題，不含訊息內文）、出現權限詢問、一輪完成都通知。
  - 設定 `drive_windows: false` 可回到唯讀；`idle_seconds` 改閒置門檻。
- 安裝：`install.ps1 -BindIp <ZeroTier 位址> -Network <網段>` 會在 `%LOCALAPPDATA%\DeskRemote\config.json` 產生隨機 token（只有本人可讀），並註冊登入時啟動的排程工作（一般權限）。連線密碼目前要從 config.json 手動輸入到手機；QR 配對在之後的階段。
- 測試：`cd pc-helper && python -m unittest discover -s tests -v`。

## API（v1）

| 方法與路徑 | 用途 |
| --- | --- |
| `GET /health`、`GET /v1/state` | 健康檢查；電腦狀態、閒置、鎖定、能做的事（`capabilities`） |
| `GET /v1/{claude\|codex}/sessions?limit=50` | 對話清單 |
| `GET /v1/{app}/sessions/{id}/events?after=&epoch=&prompt=&wait=25` | 逐字稿事件與目前的權限詢問（long-poll） |
| `GET /v1/{app}/sessions/{id}/items/{itemId}` | 被截短的工具輸出全文 |
| `POST /v1/{app}/sessions/{id}/messages` | `{text, clientMsgId, force?}` 送出訊息 |
| `POST /v1/{app}/sessions/{id}/permission` | `{promptId, decision: allow_once\|deny, force?}` |
| `POST /v1/{app}/sessions/{id}/open` | 在電腦上打開這個對話 |
| `POST /v1/{app}/sessions` | `{text, clientMsgId, force?}` 開新對話 |
| `GET /v1/actions/{id}` | 動作結果：`queued`／`running`／`done`／`failed`，送出是否已在逐字稿確認 |

錯誤：`409 busy-user`（含 `idleSeconds`）、`423 locked`、`409 prompt-changed`、`400`、`413`、`429`。

## 手機端

- 電腦清單 → 電腦（狀態、Claude／Codex）→ 對話清單（新到舊，右上角開新對話）→ 聊天畫面。
- 只在前景讀取：電腦清單 30 秒、電腦頁 15 秒、對話清單 10 秒、聊天畫面 long-poll；離開前景即停止。
- 連線密碼只存在 iPhone 鑰匙圈（本機限定），位址存在 UserDefaults；倉庫裡沒有任何位址或密碼。
- 聊天畫面：工具呼叫收合成一列；原生輸入框（多行、聽寫）；送出的訊息先以虛線泡泡顯示進度，逐字稿出現後才換成正式訊息；失敗時可重試或移除。
- 權限卡片有「允許一次」「拒絕」，沒有「永遠允許」。對話在等待處理但電腦上開著別的對話時，顯示「在電腦上打開這個對話」。
- 電腦有人在用時跳出確認「仍要送出」，取消就不送。
