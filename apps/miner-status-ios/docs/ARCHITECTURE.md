# 架構

## 資料流

```text
使用者設定的來源 ──GET──▶ StatusFeedClient ──▶ MinerStatusFeed（解碼＋白名單） ──▶ StatusEngine（狀態機） ──▶ MachineSnapshot ──▶ SwiftUI
                         （失敗 → FetchFailure）                                  ▲
                                                       SystemClock 提供 ClockReading（牆鐘＋單調時間）
```

離線示範以 `fixtures/demo-running.json` 為範本，依情境改寫時間與欄位後，**仍經過真實解碼器與狀態引擎**，不直接偽造快照。

## JSON 契約

`schema/miner-status.schema.json`（Draft 2020-12，`schemaVersion: 1`）。

- **白名單**：每一層 `additionalProperties: false`。只含電腦名稱、worker、預期運行、miner 是否運行、算力與單位、各 GPU 溫度／風扇百分比／功率、接受／過期／拒絕份額、資料時間、最後接受份額時間、停止原因，以及必要的 session、序號與各組資料時間。不含 token、PID、路徑、錢包、帳號、命令列或例外字串。
- **每個 key 都必填**：缺值必須明確寫 `null`（顯示「無資料」）；無法判定寫 `"unknown"`（顯示「未知」）。缺 key 視為格式錯誤。
- **時間**：RFC 3339，必須有 `Z` 或 `±hh:mm`。只有時分秒的 log 時間在校準日期與時區前一律填 `null`。
- **示範標示**：`dataOrigin: "demo"` 時 `demoNotice` 必須非空；`live` 時必須為 `null`。
- `publishedAt` 只代表發佈端寫出的時間；快取重寫不得讓任何 `observedAt` 變新。

Swift 解碼器比 schema 多兩條規則：重複 `machineId` 拒收；閏秒 `:60` 拒收。Python 契約檢查同步實作這兩條。已知差異：Python 的 `datetime` 不接受西元 0 年，Swift 解析器接受；實務上不影響。

## 狀態引擎（`StatusEngine`）

純值型別、無計時器、無 I/O。每次呼叫都帶 `ClockReading(wall:monotonic:)`，相同輸入必得相同結果。單調時間必須在裝置休眠時持續計時（Darwin 的 `ContinuousClock`），否則每次喚醒都會被判為時鐘跳動。

### 年齡

收到時「本機牆鐘 − 來源 `observedAt`」（負值歸 0）＋收到後經過的單調時間。來源時間超前本機超過 10 秒即拒收（時間無法驗證）。各項指標的年齡＝樣本年齡＋該指標比樣本舊多少；指標時間比樣本新超過 10 秒則為「時間無法驗證」。

### 接受樣本的條件

1. `sourceStatus == ok`
2. `sessionId`、`sampleSequence`、`observedAt` 皆非 null，否則為「資料不足」
3. 不是未來時間
4. 不是已退役的 session
5. `observedAt` 嚴格新於上一筆；同 session 內序號嚴格遞增

不符合者不更新新鮮度，並標記最近問題。

### 燈號判定順序

1. **灰**：沒有已接受樣本、年齡無法計算（單調時間倒退）、或年齡 > 300 秒。剛好 300 秒仍有效。
2. **紅**：miner 狀態為 `stopped` 且該觀測新鮮。之後即使請求失敗，只要仍在 300 秒內就維持紅燈，但資料標為歷史資料。
3. **黃**：上一筆接受樣本之後出過任何問題、狀態未知或不新鮮、同 session 有停止紀錄卻回報運行中、尚無份額證據。
4. **綠**：以上皆否，且有有效份額證據。

### 份額證據鏈

綠燈需要同一 session 的兩筆新鮮樣本之間 `accepted` 增加，而且：

- 兩筆都確認 running（觀測新鮮、無同 session 停止紀錄），份額時間都新鮮、可驗證且嚴格遞增。
- 該次增加在 300 秒內；目前樣本的份額時間本身也必須新鮮且可驗證。

任何一筆樣本「未確認挖礦」（非 running、份額時間缺失／過期／無法驗證、計數倒退）或任何拒收／失敗（請求失敗、來源無法讀取、機器缺席、重播、未來時間、退役 session、時鐘跳動），都會清除既有證據，並取消已持有樣本當作基準的資格。恢復後必須先有新基準，再看到一次增加才回綠。

計數不跨 session 比較；換 session 時舊 session 進入退役清單（每台保留最近 32 個）。

### 時鐘

- 牆鐘與單調時間的變化差超過 5 秒：視為牆鐘跳動，清除證據、轉黃。
- 單調時間倒退：年齡無法計算、轉灰；重播判斷的基準仍保留。
- 第一次讀數無從交叉檢查，只受未來時間規則限制。

### 輸出（`MachineSnapshot`）

燈號、唯一主因 `reason`、最近問題 `problem`、最後接受樣本、樣本年齡、`isHistorical`（年齡未知或超過 300 秒，或之後有更新失敗或被拒收），以及各指標新鮮度：新鮮、過期、無時間、時間無法驗證。停止原因只在屬於同一 session 時顯示。

## 唯讀 HTTP client（`StatusClient.swift`）

- **`SourceEndpoint`**：只接受有主機名稱的 `http`、`https` 網址。拒收空白、內含帳密與 `#` 片段。倉庫內沒有預設位址。
- **請求**：GET only，沒有 body、帳密、Cookie 或快取。逾時 10 秒，`Accept: application/json`。使用 ephemeral `URLSession`：不存 Cookie、快取與憑證，也不等待網路恢復。
- **只接受符合以下條件的回應**：HTTP 200、`Content-Type` 含 `json`、與設定網址同源（scheme、主機、埠）、不超過 512 KiB、通過白名單解碼器。其餘一律是 `FetchFailure`。
  - 轉址到其他來源的資料不採用。
  - 512 KiB 的上限是在下載完成後檢查；逾時限制了下載時間。
- **`StatusEngine.apply(_:at:)`**：成功時 `ingest`；`cancelled`（例如 App 離開前景）不改變任何狀態；其他失敗一律 `recordRequestFailure`，所以綠燈立即撤下，重連後要有新的基準與後續增加。`ClockReading` 必須在回應抵達後取得，作為接收時間。
- **`SystemClock`**：牆鐘加上 `ContinuousClock` 的單調時間，裝置休眠時仍持續計時。單調時間從建立時起算，每個引擎用一個。

## 顯示文字

`StatusText.swift` 放在核心，以便 XCTest 固定內容。灰燈與請求失敗的文字只描述無法確立的事（資料不足、時間無法驗證、資料逾時、請求失敗、無法建立連線、來源無法讀取），不宣稱主機離線。

## App

- **啟動時一律是離線示範**，不會自動連線。
- **示範模式**：
  - 範本來自 App bundle 內的 `demo-running.json`；載入失敗只顯示錯誤，不自行生成資料。
  - 情境有七種：首筆、確認挖礦、已停止、未知／無資料、逾時、請求失敗、資料不足／時間無法驗證。
  - 顯示示範橫幅與凍結的模擬時鐘；情境選單明示僅限示範。
- **自訂來源**：
  - 只有在「資料來源」按「開始讀取」才連線，而且從全新的引擎與時鐘開始。
  - 只在前景依 15、30 或 60 秒間隔讀取，期間每 5 秒重新評估年齡與 5 分鐘邊界。離開前景即取消讀取；回到前景立即讀一次。
  - 停止或切換來源後才抵達的回應會被丟棄。
  - 來源若回傳 `demo` 資料，橫幅與各列會標示為示範資料。
- 網址與間隔只存在裝置的 UserDefaults。
- 沒有任何控制礦機、背景讀取或通知功能。
- iPhone 用 `NavigationStack`；iPad 等寬版用 `NavigationSplitView`，未驗證。

## 尚未決定

- 真實資料的發佈端、傳輸方式（HTTP／HTTPS）、認證與存取範圍。目前的 client 不送任何認證資訊。
- 每台礦機的 worker 與預期運行狀態的可靠來源；沒有時維持 null。
- 發佈端重送完全相同的樣本會被視為重播並轉黃。輪詢間隔應大於來源更新間隔，或之後另行區分「相同重送」。
