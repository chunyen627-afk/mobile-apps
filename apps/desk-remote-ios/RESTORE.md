# 桌面遙控：新電腦還原與新 AI 接手

目的：換一台電腦，或換一個新的 AI 模型來接手時，只靠這個倉庫就能把環境還原、知道規則與現況。倉庫裡**沒有**任何位址、連線密碼、核准金鑰或 ntfy 頻道；這些在新電腦上重新產生，再輸入手機。

先讀 [README.md](README.md)（功能、驗證程度、決定紀錄），再照本文做。

## 一、新電腦還原（約 30 分鐘）

### 1. 先裝好

| 項目 | 說明 |
| --- | --- |
| Windows 10／11，一般使用者帳號 | 小幫手以這個帳號登入時啟動 |
| Python 3.11 以上 | 只用標準函式庫；要有 `python.exe` 與 `pythonw.exe`。用獨立安裝的直譯器（python.org 版或 uv 管理的 `cpython-3.11.*`），不要用 Hermes 等其他工具的 venv，也不要往裡面裝東西 |
| Claude 桌面版、Codex 桌面版 | 都登入好；Codex 的權限慣例是「代我核准」，Claude 是「自動」 |
| ZeroTier | 加入同一個私人網路，記下這台電腦的 ZeroTier 位址與網段 |
| Google 遠端桌面 | 裝成服務（重開機停在登入畫面時也連得到） |
| 手機 | SideStore（裝 IPA）、ntfy App（收通知）、ZeroTier |

### 2. 放程式

```bash
git clone --branch claude/desk-remote https://github.com/chunyen627-afk/mobile-apps.git
```

把 `apps/desk-remote-ios/pc-helper/` 整個資料夾複製到一個**固定、不會被搬動的位置**（例如 `%USERPROFILE%\dev\desk-remote\pc-helper`）。排程工作與 `elevate` 指令都指向這個位置；倉庫的工作目錄會被切分支或刪掉，不要直接用它。之後改了程式，要把改過的檔案再複製過去、重啟小幫手。

### 3. 裝小幫手（一般權限）

在固定位置的 `pc-helper` 裡：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -BindIp <ZeroTier 位址> -Network <ZeroTier 網段，例如 10.x.y.0/24> -PcName 辦公室
```

- 產生 `%LOCALAPPDATA%\DeskRemote\config.json`（只有本人可讀），裡面的 `token` 就是手機要填的連線密碼。
- 註冊登入時啟動的排程工作 `DeskRemoteHelper` 並立刻啟動。啟動後約 30 秒才開始監聽（先讀完對話清單），之後 `helper.log` 會出現 `listening on the configured address`。
- `-Python` 要指向 `pythonw.exe`（不帶時找 PATH 上的第一個；PATH 上是別的工具的 venv 時一定要指定）。
- 也可以從另一台電腦用 SSH 以那個使用者身分安裝（2026-10-27 家用電腦就是這樣裝的）：用 `-EncodedCommand` 傳指令，免得中文被編碼弄壞；那個使用者要在主控台登入中，小幫手才會跑在桌面工作階段。

**防火牆**：小幫手跑的是 `pythonw.exe`，跟 `python.exe` 是不同的程式，既有的 Python 允許規則不算數。在系統管理員 PowerShell（或有管理員權限的 SSH）加一條只開這個埠、只接受 ZeroTier 網段的規則：

```powershell
New-NetFirewallRule -DisplayName 'Desk remote helper (ZeroTier only)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18790 -RemoteAddress <ZeroTier 網段> -Program '<pythonw.exe 完整路徑>' -Profile Any
```
- 其他設定參考 [pc-helper/config.example.json](pc-helper/config.example.json)：`notify`（ntfy 伺服器與私人頻道，頻道名稱當密碼看）、`idle_seconds`、`alerts`、`screen`、`drive_windows`、`claude.context_windows`。改完 `config.json` 要重啟小幫手：

```powershell
Stop-ScheduledTask DeskRemoteHelper; Start-ScheduledTask DeskRemoteHelper
```

### 4. 裝提權夥伴（使用者自己用系統管理員 PowerShell 執行）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-elevated.ps1
```

- 建立只有管理員能改的 `%ProgramData%\DeskRemote`、新的核准金鑰、排程工作 `DeskRemoteElevated`（最高權限）與 `elevate` 指令。
- 最後顯示一次**核准金鑰**：直接輸入手機（可用 iPhone 的「原況文字」從螢幕拷貝），**不要截圖、不要貼進任何對話或檔案**。金鑰外流時：刪掉 `%ProgramData%\DeskRemote\elevated.json`，重跑本腳本換新，再重啟小幫手。
- 裝完重啟小幫手，讓它讀到提權夥伴的提交 token。

### 5. 開機自動啟動與電源

- Windows「設定 → 應用程式 → 啟動」：打開 **Claude**（Codex 預設已開）。
- 不睡眠、不休眠、不設閒置自動鎖定（鎖定時手機只能看、不能操作）。
- 是否設 Windows 自動登入由使用者決定（目前的決定：不設，重開機後用 Google 遠端桌面輸入密碼）。

### 6. 給 AI 的規則行

把下面這段加進這台電腦的 Claude Code 全域規則（`%USERPROFILE%\.claude\CLAUDE.md`）與 Codex 的 `AGENTS.md`（`%USERPROFILE%\AGENTS.md`、`%USERPROFILE%\.codex\AGENTS.md`），等手機能核准之後再加，否則 AI 會空等：

```markdown
## Administrator commands — use `elevate`

Nobody can click a UAC prompt for you on this PC. When a command needs administrator rights:
- Run it through `elevate` instead: `elevate -c "<PowerShell command>"` or, for anything
  multi-line, write a `.ps1` and run `elevate -f <script.ps1>` (optional `--cwd <dir>`,
  `--timeout <seconds>`, default 600, max 3600). Works from Git Bash and PowerShell.
- The command runs in Windows PowerShell 5.1 as administrator (not bash), only after the user
  approves it on their phone with Face ID. `elevate` then prints its output and returns its
  exit code.
- Approval can take up to 10 minutes: run `elevate` in the background (or with a shell timeout
  of at least 11 minutes) and wait for it to finish.
- Exit codes: 126 = denied, or not approved within 10 minutes; 124 = ran past `--timeout`;
  125 = refused (empty, too large, or too many requests: 3 waiting / 5 a minute); 127 = elevate not installed
  or its companion not running. Do not resend a denied request; ask the user instead.
- Keep each request to one clear step, so the phone shows exactly what will run.
- Never use `Start-Process -Verb RunAs`, `runas`, or change UAC settings instead.
```

### 7. 手機

1. 從 [Releases](https://github.com/chunyen627-afk/mobile-apps/releases) 下載最新的 `desk-remote-*` IPA，用 SideStore「My Apps →＋」安裝。
2. 打開「桌面遙控」→ 右上角「＋」：名稱、ZeroTier 位址、埠 `18790`、`config.json` 的 `token`、核准金鑰。
3. ntfy App 訂閱 `config.json` 裡的頻道。

### 8. 驗收（照順序，前一步不過不要往下）

| 檢查 | 怎麼做 | 應該看到 |
| --- | --- | --- |
| 小幫手在跑 | `Get-ScheduledTask DeskRemoteHelper` | `Running` |
| API 可用 | 手機的電腦列 | 「連線正常」與閒置時間 |
| 讀得到對話 | 手機點 Claude／Codex | 對話清單與逐字稿 |
| 畫面操作 | 在測試對話從手機送一句話 | 電腦上出現、回覆回到手機 |
| 管理員核准 | `elevate -c "whoami /groups"`，手機用 Face ID 核准 | 指令輸出回到電腦、結束碼 0 |
| 通知 | 讓 AI 問一個權限 | ntfy 收到「在等你核准」，點了直接打開那個對話 |

## 二、新 AI 接手

### 先讀

1. 本文與 [README.md](README.md)：功能、驗證程度、還沒做的、決定紀錄、實測時踩過的坑。
2. [DESIGN.md](DESIGN.md)：架構與安全設計。
3. 倉庫根目錄的 `AGENTS.md` 與 [docs/ios-app-autonomous-ci.md](../../docs/ios-app-autonomous-ci.md)：CI 怎麼跑、怎麼讀公開 annotation 自己修。
4. `git log --oneline` 的 commit 訊息：每次修改都寫了原因與實測結果。

### 一定要守的規則

- **不要結束或重開 Claude 桌面版**，也不要 `taskkill /IM claude.exe`；這台電腦上的 AI 控制台關掉會停掉挖礦。重開機也會中斷挖礦，不要自己重開。
- **任何會動到桌面版畫面的實測**（送出、切換對話、按允許、開選單）都會切換使用者看得到的對話：**先問使用者**，用測試對話測，測完把畫面切回使用者原本開的對話。
- **發布前要使用者同意**：commit 訊息加 `[release-ipa]` 才會發布；全部測試通過才發布。手機安裝要等模擬器 UI 測試通過且截圖看過。
- 每次 commit／push 前**讀完整個暫存的 diff**，並做隱私掃描（ZeroTier 位址、帳號、token、頻道名稱、私人路徑都不能進倉庫）。
- 改檔用編輯工具，不要用 shell 的字串取代。PowerShell 腳本維持純 ASCII（中文用 `[char]0x....` 組，或放 `ui_strings.json`）；單元測試會檢查。
- 不安裝 `gh`、不產生或讀取 GitHub token；PR 由使用者在 GitHub 網頁按建立。GitHub 公開 API 每小時只能查 60 次，等 CI 時用 workflow 的 badge 或 Release 下載網址判斷，不要每分鐘查 API。
- 推送會取消同分支正在跑的 CI（含發布）：發布在跑時先把修改留在本機 commit，等發布完再推。
- 不改 UAC 或其他安全設定；需要管理員權限一律走 `elevate`。

### 桌面版改版後畫面元件改名

1. 症狀：手機操作回報「找不到按鈕」「選單沒有照預期切換」，或模型那一行不見了。
2. 用唯讀工具掃一次（不點、不按鍵）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File pc-helper\tools\uia_scan.ps1 -App claude -Out scan.txt
   ```

   要看選單裡的項目時，請使用者先手動把選單打開再掃。
3. 改 `pc-helper/ui_strings.json` 裡對應的名稱（不要改程式），跑 `python -m unittest discover -s tests`，複製到固定位置、重啟小幫手，再（經使用者同意）實測。

### 常用指令

| 用途 | 指令 |
| --- | --- |
| 小幫手單元測試 | `cd apps/desk-remote-ios/pc-helper && python -m unittest discover -s tests -v` |
| 重啟小幫手 | `Stop-ScheduledTask DeskRemoteHelper; Start-ScheduledTask DeskRemoteHelper` |
| 小幫手紀錄 | `%LOCALAPPDATA%\DeskRemote\helper.log`（只記事件，不記訊息內文） |
| 不經手機查狀態 | 讀 `config.json` 的 token，`GET http://<ZeroTier 位址>:18790/v1/state` 帶 `Authorization: Bearer <token>`（不要把 token 印出來） |
| 模擬器測試與截圖 | 推到 `claude/desk-remote` 會自動跑；截圖在 `ci-screenshots-desk-remote-ios` 分支（用 commit SHA 的 raw 網址讀，分支網址會被快取） |
| 發布 | 版本在 `project.yml`（`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 每次發布都要加），commit 訊息帶 `[release-ipa]` |
