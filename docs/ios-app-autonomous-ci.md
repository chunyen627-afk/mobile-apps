# 新 iOS App：AI 自主建置與驗證流程

更新：2026-10-24。目標是讓 AI 從建立專案、雲端編譯、修錯到拿到測試證據，全程**不需要使用者介入**。使用者只處理帳號、簽署安裝與需要同意的事項（見最後一節）。

完整的人工流程（簽署、安裝、續簽）見 [Windows／iPhone 快速上手](windows-iphone-quickstart.md)。本文件只管「從原始碼到 CI 證據」這一段。

## 一、專案結構：沿用 album-ios

每個 App 放在 `apps/<app>/`，結構比照 `apps/album-ios`：

| 項目 | 做法 |
| --- | --- |
| 專案規格 | `apps/<app>/project.yml`（XcodeGen），放在 App 根目錄；產生的 `.xcodeproj` 不進版控 |
| App target | `type: application`，明確的 `Info.plist`，固定的 Bundle ID |
| 無 UI 的核心（選用） | `type: framework` target，App 以 `- target:` 相依；原始碼可保留 `import <Core>` |
| 單元測試 | `type: bundle.unit-test`，由 App scheme 的 `testTargets` 執行 |
| 測試方式 | 在 iOS 模擬器用 `xcodebuild test`，**不用** SwiftPM 的 `swift test` |
| 套件 | 能不用就不用；需要時固定版本（`exactVersion`） |

`apps/miner-status-ios` 是依本文件建立的最小範例，新 App 可複製它的 `project.yml`、`scripts/build.sh` 與 workflow 再改名。

## 二、`scripts/build.sh` 必備步驟

1. `xcodegen generate`
2. 挑一台可用的 iPhone 模擬器，執行 `xcodebuild test`，並加上 `-derivedDataPath build/DerivedData` 和 `-resultBundlePath build/Tests.xcresult`
3. **數量閘門**：log 裡必須出現 `Executed <N> tests, with 0 failures`，N 為預期的測試數；找不到就失敗。測試被跳過或沒跑到，都不能算通過
4. 選用的啟動檢查：安裝 App 並啟動，8 秒後確認行程還在，再存一張 **JPEG** 截圖（PNG 容易超過 1 MB）
5. Release archive（關閉簽署）→ 檢查 bundle 內容（主程式、資源、內嵌 framework、Info.plist 關鍵值）
6. 封裝 IPA → `unzip -t` → 算 SHA256
7. **失敗時輸出 annotation**：用 `trap ... EXIT` 把失敗階段、`error:` 行與 log 結尾輸出為 `::error` 指令。換行要轉成 `%0A`，`%` 要轉成 `%25`，每一步最多 10 則

8. **成功時輸出 notice**：用 `::notice` 公開實際的 `Executed N tests, with 0 failures` 那一行、Xcode 與模擬器版本；workflow 再用 `::notice` 公開 IPA 大小與 SHA256

第 7、8 點是自主迭代的關鍵：**Actions 的 log 要登入才看得到，但 annotation 用公開 API 就讀得到。**

## 三、Workflow 必備設定

```yaml
on:
  push:
    branches: [<開發分支>]
    paths:
      - 'apps/<app>/**'
      - '.github/workflows/<app>.yml'
permissions:
  contents: read
concurrency:
  group: <app>-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    if: github.event.repository.private == false
    runs-on: macos-15
    timeout-minutes: 30
```

- 用 `push` 觸發。`workflow_dispatch` 只有在 workflow 檔已經在預設分支（main）時才能用
- 把 workflow 檔本身也列進 `paths`，否則只改 workflow 不會觸發
- 步驟：checkout → `brew install xcodegen` → `bash scripts/build.sh` → 把 IPA 大小與 SHA256 寫進 `$GITHUB_STEP_SUMMARY`
- Artifact：**不上傳大檔**。平常只上傳小報告（測試摘要、單張截圖），總和超過 1 MB 就讓 workflow 失敗，`retention-days: 1`
- 唯一例外是要實際使用這個 build 時（例如使用者要安裝的 IPA）：只上傳那一個 IPA，加大小上限（超過就失敗），保留 1 天
- xcresult、dSYM、完整 xcodebuild log 一律不上傳；錯誤靠 annotation 取得

## 四、自主迭代迴圈（不需要使用者）

1. Commit 並 push 到開發分支
2. 用公開 API 找這次的 run，**每 90 秒**查一次，直到 `status` 變成 `completed`（未登入的 API 每小時只有 60 次，查太密會被擋；可用 `https://api.github.com/rate_limit` 看剩餘次數）：
   `https://api.github.com/repos/<owner>/<repo>/actions/runs?branch=<分支>&per_page=5`，比對 `head_sha`
3. 失敗時讀出失敗的 job 與步驟：`.../actions/runs/<run_id>/jobs`
4. 讀錯誤內容：`.../check-runs/<job_id>/annotations`
5. 修正、提交、再 push，回到第 2 步
6. **完成的定義**：run 結論為 success，而且拿到 run 網址、實際執行的測試數、0 失敗。三項缺一項都不能宣稱完成。測試數與 IPA SHA256 從同一個 annotations API 的 notice 讀取；Step Summary 與 artifact 要登入才看得到，不能當作 AI 的證據來源

不要請使用者去複製 log。看不到錯誤時，代表 `build.sh` 的 annotation 沒有涵蓋到那一段，應該補上 annotation 再推一次。

## 五、一次性前置（每台電腦只做一次）

- **Git 認證用瀏覽器登入**：第一次 push 時讓 Git Credential Manager 跳出視窗，選 *Sign in with your browser*。這個授權本身就包含 workflow 權限
- 不要改用缺少 `workflow` 權限的 Personal Access Token，否則新增或修改 `.github/workflows/` 時 push 會被拒絕
- AI 不建立、不讀取、不輸入任何 token

## 六、Artifact 儲存管理

- 用公開 API 查用量：`.../actions/artifacts?per_page=100`
- 需要刪除時，AI 列出 run 連結與檔名，由使用者在 run 頁面最下方的 Artifacts 區按垃圾桶刪除。刪除無法復原，AI 不代為操作
- 新 App 的 workflow 只產生小檔、保留 1 天，到期自動刪除，正常情況下不需要手動清理

## 七、什麼時候才找使用者

| 需要使用者 | 不需要使用者 |
| --- | --- |
| Apple 帳號、簽署、把 IPA 裝到手機 | 寫程式、寫測試、改 `project.yml` 與 `build.sh` |
| 合併到 main、改其他 App 或它們的 workflow | 在開發分支 commit、push、追 run、讀 annotation、修錯 |
| 要安裝 build 時上傳 IPA；加長保留期 | 上傳 1 MB 以內、保留 1 天的報告 |
| 刪除 artifact、改 token 或帳號設定 | 用公開 API 查 run、artifact 與用量 |
| 任何付費資源 | 公開倉庫的標準 macOS runner（免費） |

## 已知的坑

| 現象 | 原因與做法 |
| --- | --- |
| push 被拒：`without workflow scope` | Token 缺 workflow 權限；改用瀏覽器登入，見第五節 |
| `Invalid username or token` | 存的認證失效（例如 token 被重新產生）；請使用者在終端機 push 一次，用瀏覽器登入 |
| Run 頁面顯示「Sign in to view logs」 | Log 要登入；改讀 annotation，見第四節 |
| 只改 workflow 卻沒觸發 | `paths` 沒包含 workflow 檔本身 |
| 測試全綠，但其實一項都沒跑 | 沒有數量閘門；見第二節第 3 點 |
| 報告超過 1 MB | 截圖改 JPEG；不要上傳完整的 xcodebuild log 或 xcresult |
| API 回應缺欄位（例如 `KeyError: 'jobs'`） | 公開 API 每小時 60 次用完了；等 `rate_limit` 的 reset 時間，輪詢間隔拉長 |
| 產物要下載到本機備份 | Artifact 下載要登入；請使用者下載，放到使用者指定的本機備份位置（私人路徑，只記在本機，不寫進倉庫） |

## 實戰日記

### 2026-10-24：礦機狀態第一次上 CI

從「Swift 程式從未編譯過」到 80 項測試通過，共 4 次 run，其中 3 次人工介入都已寫進本文件，下次不應再發生。

| Run | 結果 | 原因與處理 |
| --- | --- | --- |
| （push 失敗） | — | Token 缺 workflow 權限 → 第二次又遇到認證失效 → 使用者在終端機用瀏覽器登入後解決（第五節） |
| [40094203491](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094203491) | 失敗，28 秒 | 舊的 SwiftPM `swift test` 流程；log 要登入才看得到，只好請使用者幫忙 → 改成 album-ios 架構，並加上失敗 annotation |
| [40094798800](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40094798800) | 失敗 | Annotation 直接讀到編譯錯誤：修改 `self.trackers` 時同時讀 `self.policy`（Swift 重疊存取）→ 先複製到區域常數 |
| [40095024930](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40095024930) | 通過 | 但測試數只在要登入的 Summary 裡 → 加上成功 notice |
| [40095550434](https://github.com/chunyen627-afk/mobile-apps/actions/runs/40095550434) | 通過 | 公開 notice：80 項 0 失敗、Xcode 16.4、iPhone 16 Pro 模擬器、IPA 211,736 bytes |

學到的事：

- 在 Windows 寫、從沒編譯過的 Swift，第一次編譯就只錯 1 處；真正花時間的是 CI 基礎設施（權限、log 可見性），不是程式本身
- 沿用已經成功的 App 架構，比自創結構（SwiftPM＋`swift test`）少踩坑
- 每個 run 約 6 到 12 分鐘；輪詢時注意未登入 API 的 60 次／小時上限
