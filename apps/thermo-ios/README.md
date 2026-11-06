# 溫濕度（thermo-ios）

在手機上同時看好幾顆藍牙溫濕度計的溫度、濕度、電量與最後更新時間，點進去看 24 小時／7 天／30 天的紀錄曲線（類似米家）。這是工具箱 App 的第四個分頁（[apps/toolbox-ios](../toolbox-ios)），沒有單獨的 App。

手機不在溫濕度計旁邊時藍牙收不到，所以中間放一個**閘道**：溫濕度計旁邊一台開著的電腦（之後也可以是 ESP32），收藍牙廣播、存紀錄，再用 HTTP／JSON 提供給手機。手機經 ZeroTier 虛擬區網連到閘道。

```
溫濕度計 ──BTHome 明文藍牙廣播──▶ 閘道（電腦／ESP32）──HTTP over ZeroTier──▶ 工具箱「溫濕度」分頁
                                    │
                                    └─（ESP32 不在 ZeroTier 上時）同一區網的電腦轉發
```

## 快速上手

1. **閘道**：在溫濕度計附近放一台長開的閘道，電腦跑 [pc-gateway](#閘道pc-gateway)，或 [ESP32 閘道](#esp32-閘道)。閘道要在 ZeroTier 上；ESP32 沒有 ZeroTier，要靠同一區網的一台電腦[轉發](#轉發閘道不在-zerotier-上時)。
2. **App 閘道欄**：工具箱 →「溫濕度」→ 右上角齒輪 →「閘道」，**一行一個閘道**，最多 8 個，例如：

   ```
   http://<公司閘道的 ZeroTier 位址>:18787
   http://<家裡轉發電腦的 ZeroTier 位址>:18787
   ```

   用 `http`（不是 `https`），結尾不用加 `/sensors`，App 會自己補；只填 `位址:埠` 也可以。手機要開著 ZeroTier。全部留空就顯示示範資料。
3. **新增一顆溫濕度計**：
   1. 先刷成 pvvx 韌體（見下一節），刷完藍牙名稱是 `ATC_` 加位址末 6 碼，每顆都不同；建議當下在背面貼標籤。
   2. 放到閘道收得到的地方（同一個房間或隔壁，約 10 公尺內）。閘道預設 `discover: true`，聽到就自動出現在 App 列表，閘道和 App 都不用設定。
   3. 在 App 長按或往左滑「重新命名」、選房間；名稱存在閘道上，推播也用這個名稱。不知道哪顆是哪顆時，對其中一顆哈氣或握在手裡，看 App 裡哪顆的數字在跳。

## 溫濕度計

- **建議刷 pvvx 自訂韌體**（[pvvx/ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer)，開源重寫的韌體，不是原廠改的）：刷完改送**明文 BTHome v2 廣播**，閘道不用連線、不用金鑰，一次被動收聽任意多顆，電量也在廣播裡。刷完藍牙名稱變成 `ATC_xxxxxx`，米家 App 不能再用（可以刷回原廠）。
- 小米 LYWSD03MMC 的原廠韌體 **2.1.1_0159** 不能直接刷：要先加入米家，再用 [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)（可用米家 App 掃 QR code 登入，不用打密碼）取得這顆的 Device known id、Mi Token、Mi Bind Key，在 pvvx 的 [TelinkMiFlasher](https://pvvx.github.io/ATC_MiThermometer/TelinkMiFlasher.html) 連上後按 Login，再選 `ATC_v59`（或更新版）刷入。舊版原廠韌體（例如 1.0.0_0109）可直接刷。詳見 pvvx issue #602。
- 不刷也行：在閘道設定裡把那顆標 `"gatt": true`，閘道每 5 分鐘連線讀一次（只支援 LYWSD03MMC 原廠韌體；比較耗電，連線時別的裝置連不上它）。
- 閘道認得的明文格式：BTHome v2（`0xFCD2`，未加密）、pvvx 自訂格式與 atc1441 格式（`0x181A`）。小米加密廣播（MiBeacon）一律略過，所以旁邊同事沒刷的溫濕度計不會出現。

## 閘道（pc-gateway）

`pc-gateway/thermo_gateway.py`，Python 3.10 以上，Windows 用 `bleak` 收藍牙（`pip install bleak`）。

1. 複製 `thermo-gateway.example.json` 為 `thermo-gateway.json`（放在閘道電腦上，**不要提交**），填：
   - `bind_ip`：這台電腦的 ZeroTier 位址（必須是明確位址，不接受 `0.0.0.0`）
   - `allowed_networks`：允許連入的網段（ZeroTier 網段）；網段外的連線一律 403
   - `sensors`：可選，預設名稱或要用連線讀取的原廠韌體（`"gatt": true`）；`discover: true`（預設）時，聽到的明文溫濕度計都會自動出現
   - `history_days`：紀錄保留天數，預設 90
   - `notify`：推播用的 ntfy `server`／`topic`；或 `{"from_file": "<另一個服務的設定檔>"}` 沿用它 `notify` 段的主題（例如礦機狀態服務的 aggregator.json，同一個手機訂閱就收得到），主題不用複製第二份。沒有主題就不推
   - `alerts`：推播條件，`temperature_high`／`temperature_low`（°C）、`humidity_high`／`humidity_low`（%）、`battery_low`（%）、`offline_after_seconds`、`hold_seconds`（超出範圍要持續多久才推，預設 600）；設成 `null` 就不推那一項；`sensors` 可對個別溫濕度計覆寫。預設 32／10°C、80／25%、15%、2 小時
2. 執行 `python thermo_gateway.py --config thermo-gateway.json`；要開機自動啟動，可用 `pythonw` 搭配啟動資料夾裡的 `.vbs`。
3. 先跑 `python thermo_gateway.py --config thermo-gateway.json --test-notify` 確認手機收到測試通知。
4. 同一資料夾會產生 `thermo-state.json`（最後讀數、手機給的名稱與房間）、`thermo-history.sqlite`（每 5 分鐘一筆的紀錄）、`thermo-gateway.log`。

API（讀取都是 GET；寫入只有 `POST /labels`）：

| 路徑 | 內容 |
| --- | --- |
| `/sensors` | `{"version":1,"gateway":名稱,"time":閘道時間,"sensors":[{"id":位址,"name","advertised_name","temperature","humidity","battery","voltage","rssi","updated","format","error"}]}` |
| `/history?id=<位址>&range=day\|week\|month` | `{"version":1,"id","range","bucket","time","utc_offset","points":[{"t","temperature","humidity","battery","temperature_min","temperature_max","humidity_min","humidity_max"}]}`。`day`：最近 24 小時，每 30 分鐘一點；`week`／`month`：最近 7／30 個日曆日（閘道電腦的時區，今天也算），每天一點，含當天最低與最高 |
| `/health` | `{"ok":true}` |
| `POST /labels` | `{"id":位址,"name":名稱或 null,"room":房間或 null}`，1 KB 以內；手機改名、選房間時送出，閘道記住，`/sensors` 的 `name`／`label`／`room` 就是它，推播也用這個名稱。唯一的寫入 |

`/sensors` 另有 `alerts`：`{"enabled":有沒有設主題,"temperature_high",…,"offline_after_seconds"}`，App 的「通知」區塊照著顯示。

**推播**（照礦機狀態服務的做法，經 ntfy）：溫度或濕度超出範圍持續 `hold_seconds` 才推；電量低於門檻、超過 `offline_after_seconds` 收不到讀數則立刻推。同一狀況只推一次，數值回到範圍內（溫度多 0.5°C、濕度多 2%、電量多 5% 的緩衝）才會再推；恢復不推。超過 30 分鐘沒更新的讀數不判斷溫濕度（交給「收不到訊號」）。通知只有名稱、房間與數值，沒有位址。

`--fake fixtures/fake-sensors.json --bind 127.0.0.1 --port 8795` 是不用藍牙的假閘道（固定讀數＋造出來的 30 天曲線），CI 的模擬器 UI 測試用它。

## App 畫面

功能照米家的溫濕度計頁面做：

- **列表**：依**房間**分組（沒指定的在「未指定房間」），每顆顯示名稱、溫度、濕度、**舒適度**（舒適／偏冷／偏熱／乾燥／潮濕）、電量（低於 20% 變紅）、多久前更新（超過 10 分鐘變橘、1 小時變紅）。最上面提醒「電量不足，請更換電池」；閘道連不到、還在讀或沒聽到任何溫濕度計時也在最上面說明，並保留上次讀到的資料。在畫面上時每 30 秒更新，可下拉更新。
- **詳情**：大字溫濕度、舒適度、電量與更新時間；**歷史紀錄**可切日／週／月與溫度／濕度／電量：日是 30 分鐘一點的曲線，週和月是每天一條從當天最低到最高的長條，附期間最低、平均、最高；閘道沒收到的時段留白。「裝置設定」有名稱、房間（客廳、臥室、書房、廚房、浴室、陽台、辦公室或自己新增）、在列表中隱藏；「裝置資訊」列出電壓、訊號、讀取方式、閘道與裝置位址。
- **改名**（仿米家）：列表上長按或往左滑選「重新命名」，或在詳情頁點「名稱」那列／右上角的筆；對話框預先填好目前的名字。名稱與房間會送到閘道保存（見下面「名稱與房間」那一點），清空就回到溫濕度計廣播的名稱。
- **設定**（右上角齒輪）：溫度單位（°C／°F）、舒適度範圍（預設 20–26°C、40–60%，可調）、閘道網址一行一個，可同時看公司電腦和家裡的閘道，最多 8 個。可只填 `位址:埠`。全部留空就顯示示範資料。
- 時間一律以閘道的時鐘計算，手機時鐘不準也不影響「幾分鐘前」。
- 原始碼：`Sources/ThermoCore`（JSON、紀錄、名稱，無畫面，有單元測試）、`iOSApp`（SwiftUI 畫面，用 Swift Charts 畫曲線）。鍵名：UserDefaults `thermo.gateways`、`thermo.preferences`（名稱、房間、隱藏、單位、舒適範圍；舊版存的設定缺的欄位用預設值）。
- **名稱與房間**存在手機上，也同步到閘道（像米家存雲端）：別支手機打開也看得到、推播用同一個名稱；同步失敗時詳情頁會說明，手機上的仍然有效。隱藏、單位、舒適範圍只在這支手機。
- **通知**：詳情頁「通知」區塊列出閘道的推播條件與是否開啟。條件目前在閘道電腦的設定檔改（米家是在 App 裡設自動化）。

## 轉發（閘道不在 ZeroTier 上時）

ESP32 只在家裡 Wi-Fi 區網，手機在外面透過 ZeroTier 連不到它。做法是找一台**同時在家裡區網和 ZeroTier 上、長開**的 Windows 電腦，用系統內建的 portproxy 把它的埠轉給 ESP32（以系統管理員執行）：

```bat
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=18787 connectaddress=<ESP32 的區網位址> connectport=18787
netsh advfirewall firewall add rule name="Thermo ESP32 forward (ZeroTier)" dir=in action=allow protocol=TCP localport=18787 localip=<這台電腦的 ZeroTier 位址> remoteip=<ZeroTier 網段>
```

- 設定存在系統裡，由開機自動啟動的 IP Helper 服務執行，重開機不用再設。
- 監聽 `0.0.0.0` 而不是 ZeroTier 位址：開機時 ZeroTier 若比 IP Helper 晚連上，綁特定位址會失敗且不重試。能從哪裡連進來由防火牆規則限制，只放行 ZeroTier 網段連到 ZeroTier 位址。
- ESP32 要在路由器綁固定 IP（DHCP 保留），位址一變轉發就斷。
- 檢查：`netsh interface portproxy show all`；取消：`netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=18787`。
- 手機 App 填轉發電腦的 ZeroTier 位址；電腦關機時就看不到 ESP32 那幾顆。

## ESP32 閘道

原始碼與完整操作步驟在 [`esp32/`](esp32/README.md)。ESP32 通電收 BLE、存近期歷史，提供工具箱既有的 HTTP JSON。區網不需電腦；遠端 ZeroTier 仍需要轉發電腦長開。

### 硬體

ESP32-2432S028（CYD），ESP32-WROOM-32、4 MB flash、無 PSRAM、USB 5V 供電。實測板為 ST7789 2.8 吋 320×240，觸控 XPT2046；ILI9341 僅提供建置選項，未上板驗證。接腳與面板設定見 [硬體說明](esp32/README.md#硬體與原始碼)。

### 韌體來源與建置

本倉庫 `esp32/src/main.cpp` 與 `include/` 是閘道 1.4 來源，解碼與分桶對照 `pc-gateway/thermo_gateway.py`。PlatformIO／Arduino，pioarduino 55.03.312-1（Arduino 3.3.12／IDF 5.5.5）；NimBLE-Arduino 2.3.6、ArduinoJson 6.21.5、WiFiManager 2.0.17、LovyanGFX 1.2.7。在 esp32 目錄執行 `python -m platformio run -e cyd-st7789`。此版開機直接進閘道，不含賽車模式。

### 燒錄方式

首次先私下備份原板完整 flash，再用 USB 與 PlatformIO upload；序列埠 115200。首次 LittleFS 未掛載才用 `FORMAT`，升級不要清除已存資料。詳見[燒錄步驟](esp32/README.md#燒錄方式)。WiFiManager 熱點名稱、隨機密碼及設定頁位址顯示在螢幕，選 2.4 GHz Wi-Fi，帳密存 NVS、不進原始碼。私人筆記使用已忽略的 `network.local.txt`，範例在 `network.example.txt`。

### 固定 IP 建議

小米路由器 DHCP 靜態分配，以 ESP32 的 **Wi-Fi MAC** 保留 `<閘道IP>`；板上也可用序列埠 `STATIC <閘道IP> <路由器IP> <子網路遮罩> <DNS伺服器IP>` 後 `REBOOT`，存 NVS。兩邊須一致，板上固定 IP 不代表路由器已保留。重開後以螢幕、序列埠與 `/health` 核對；轉發目標也必須相同。

### 轉發到電腦

實際採 Windows 內建 portproxy，規則見[上一節](#轉發閘道不在-zerotier-上時)。監聽 TCP 18787 轉到 `<閘道IP>:18787`，防火牆限 ZeroTier。已確認電腦 IP Helper 與 ZeroTier 服務為自動啟動、執行中，沒有額外 Python 轉發程式或登入啟動腳本。ESP32 通電自啟；手機填 `http://<轉發電腦ZeroTier位址>:18787`，電腦休眠或關機會中斷遠端。

### HTTP 介面

使用 `http://<閘道IP>:18787` 的 `/sensors`、`/history?id=<感測器位址>&range=day|week|month`、`/health`、`POST /labels`，欄位同上方 Python API。`/sensors` 每顆另明列 `label`、`room`；所有欄位與虛構 JSON 範例見[HTTP 完整說明](esp32/README.md#http-介面與差異)。

- `time` 與 `updated` 使用同一 NTP Unix 秒時鐘，未同步回 503；`utc_offset=28800`。Wi-Fi 關閉省電，BLE 被動掃描 40/160 ms，避免 100% 佔用天線。
- `alerts={"enabled":false}`，不推播；最多 4 顆，支援明文 BTHome／pvvx／atc1441，不支援原廠 GATT。被動掃描不一定收到廣播名稱，可從 App 改名。
- `/labels` 將名稱與房間存 LittleFS，重開保留；缺值 null。每 5 分鐘記一筆，保留最近 30 天，day 用 1800 秒、week/month 用 86400 秒，依台灣本地時間分桶，含平均與 min/max。
- LittleFS 640 KiB；4 顆 31 個日檔原始資料約 349 KiB，另留檔案系統與復原空間，尚未滿載 30 天實測。
- 預留 `/samples` 游標匯出供日後手機永久保存；**目前 App 仍使用 /history，尚未完成永久同步整合**。HTTP 無驗證／TLS，僅供可信區網與受限制的 ZeroTier 轉發。

### 螢幕畫面

原生繁體中文字型顯示名稱、溫濕度、電量與更新時間，每頁 3 顆。點擊換頁，閒置 10 秒熄背光，點一下喚醒；喚醒那一下不換頁。熄屏後 BLE、Wi-Fi、HTTP 繼續運作。此前背光閃爍根因未定位，不宣稱硬體故障已排除。

### 驗證狀態

2026-11-06：ST7789 實機可收 1 顆 pvvx BTHome，使用者確認溫濕度、中文、10 秒熄屏與喚醒正常；名稱保存跨重啟通過。Python 解碼 12 項、C++ 封包比對 2112 次與分桶測試通過。長時間 HTTP 曾出現逾時，不能宣稱全部連線驗收通過；手機 App 實機仍未確認。版本與證據摘要見 [esp32/VALIDATION.md](esp32/VALIDATION.md)。

## 驗證狀態

- 電腦端（2026-11-06，Windows office 電腦，Intel 藍牙）：實際讀到一顆刷了 pvvx 5.9 的 LYWSD03MMC（BTHome v2 明文）；閘道在 ZeroTier 位址上回應 `/sensors`，從另一台 ZeroTier 電腦連得到。閘道單元測試 30 項通過（本機 Python 3.11）。
- App：工具箱 [run 42174825284](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42174825284) 編譯通過，溫濕度單元測試 32 項、閘道 38 項與工具箱 UI 測試（含溫濕度兩項）全過，模擬器截圖已檢視；工具箱 0.6.0 build 15 已發布（[run 42197523584](https://github.com/chunyen627-afk/mobile-apps/actions/runs/42197523584)），**尚未實機**。
- 推播：office 閘道 11/06 已開，`--test-notify` 測試通知已送出（手機是否收到待使用者確認）。
- ESP32 閘道（2026-11-06）：原始碼已整理至 `esp32/`。先前公司電腦經 ZeroTier 轉發讀取 `/health`、`/sensors` 成功；家中已確認 NTP 時間與 `/history` 資料點。最新上板版本與未通過項目見上方 ESP32 章節及驗證紀錄，App 實機仍未確認。
