# 桌面遙控（desk-remote-ios）

用 iPhone 原生輸入操作自己 Windows 電腦上的 Claude 桌面版與 Codex 桌面版：看對話清單、打字送出、看回覆、按權限的「允許一次」／「拒絕」，並在手機核准需要管理員權限的指令（`elevate`）。設計見 [DESIGN.md](DESIGN.md)（2026-10-26 核准）。

**目前是 P1 唯讀版**：手機能看電腦清單、Claude／Codex 對話清單與即時逐字稿；送出訊息、權限按鈕、新對話與 `elevate` 在之後的階段。

## 驗證狀態

| 項目 | 狀態 |
| --- | --- |
| 電腦端小幫手 `pc-helper/`（唯讀） | 實作完成；24 項 Python 單元測試在 Windows 本機通過，另做 9 項變異測試（故意改壞標題過濾、驗證、網段、去重等），全部被測試抓到 |
| iPhone App（P1 唯讀畫面）、核心 `DeskRemoteCore` | 實作完成；**尚未編譯**，等 CI |
| 模擬器 UI 測試 | 尚未執行 |
| 小幫手讀真實資料 | 尚未執行 |
| 實機 | 依決定在工具箱第三分頁驗證；尚未進行 |

## 結構

```text
DESIGN.md                  設計與決定
project.yml                XcodeGen：App、DeskRemoteCore（framework）、單元與 UI 測試
iOSApp/                    SwiftUI 畫面；DeskRemoteApp.swift 是唯一 @main 檔，工具箱會排除它
Sources/DeskRemoteCore/    API 模型、HelperClient、TranscriptLog、DeskText（無 UI）
Tests/                     DeskRemoteCoreTests（單元）、DeskRemoteUITests（模擬器 UI）
fixtures/fake-helper/      人工編寫的示範資料：兩個桌面版的對話清單、逐字稿、權限詢問
pc-helper/                 電腦端小幫手（Python 標準函式庫）、單元測試、安裝腳本、設定範例
scripts/build.sh           macOS CI：小幫手測試 → 產生專案 → 模擬器單元與 UI 測試 → Release 封裝
```

## 電腦端小幫手（P1 唯讀）

- `desk_remote_helper.py`：只綁設定的 ZeroTier 位址，`/v1/*` 要 `Authorization: Bearer <token>`，錯 5 次鎖 10 分鐘並送 ntfy。
- 對話清單：Claude 讀桌面版自己的 `claude-code-sessions/*/*/local_*.json`；Codex 讀 `~/.codex/state_5.sqlite`（唯讀），讀不到時改用 `session_index.jsonl`。
- 逐字稿：Claude `~/.claude/projects/*/<cliSessionId>.jsonl`、Codex rollout 檔，只從檔尾讀新增的完整行；工具輸出太長時只送前段，手機點開再取全文。
- 不寫桌面版任何檔案，也還不碰視窗。
- 安裝：`install.ps1 -BindIp <ZeroTier 位址> -Network <網段>` 會在 `%LOCALAPPDATA%\DeskRemote\config.json` 產生隨機 token（只有本人可讀），並註冊登入時啟動的排程工作（一般權限）。連線密碼目前要從 config.json 手動輸入到手機；QR 配對在之後的階段。
- 測試：`cd pc-helper && python -m unittest discover -s tests -v`。

## API（v1，唯讀）

`GET /health`、`GET /v1/state`、`GET /v1/{claude|codex}/sessions?limit=50`、`GET /v1/{app}/sessions/{id}/events?after=&epoch=&prompt=&wait=25`（long-poll）、`GET /v1/{app}/sessions/{id}/items/{itemId}`。其他方法回 405。

## 手機端

- 電腦清單 → 電腦（狀態、Claude／Codex）→ 對話清單（新到舊）→ 聊天畫面。
- 只在前景讀取：電腦清單 30 秒、電腦頁 15 秒、對話清單 10 秒、聊天畫面 long-poll；離開前景即停止。
- 連線密碼只存在 iPhone 鑰匙圈（本機限定），位址存在 UserDefaults；倉庫裡沒有任何位址或密碼。
- 工具呼叫收合成一列；權限詢問顯示成卡片（這一版只能看）；輸入框先顯示但停用。
