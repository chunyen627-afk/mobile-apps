# 溫濕度（thermo-ios）

在手機上同時看好幾顆藍牙溫濕度計的溫度、濕度、電量與最後更新時間，點進去看 24 小時／7 天／30 天的紀錄曲線（類似米家）。這是工具箱 App 的第四個分頁（[apps/toolbox-ios](../toolbox-ios)），沒有單獨的 App。

手機不在溫濕度計旁邊時藍牙收不到，所以中間放一個**閘道**：溫濕度計旁邊一台開著的電腦（之後也可以是 ESP32），收藍牙廣播、存紀錄，再用 HTTP／JSON 提供給手機。手機經 ZeroTier 虛擬區網連到閘道。

```
溫濕度計 ──藍牙廣播──▶ 閘道（電腦／ESP32）──HTTP over ZeroTier──▶ 工具箱「溫濕度」分頁
```

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
2. 執行 `python thermo_gateway.py --config thermo-gateway.json`；要開機自動啟動，可用 `pythonw` 搭配啟動資料夾裡的 `.vbs`。
3. 同一資料夾會產生 `thermo-state.json`（最後讀數）、`thermo-history.sqlite`（每 5 分鐘一筆的紀錄）、`thermo-gateway.log`。

API（只有 GET，唯讀）：

| 路徑 | 內容 |
| --- | --- |
| `/sensors` | `{"version":1,"gateway":名稱,"time":閘道時間,"sensors":[{"id":位址,"name","advertised_name","temperature","humidity","battery","voltage","rssi","updated","format","error"}]}` |
| `/history?id=<位址>&range=day\|week\|month` | `{"version":1,"id","range","bucket","time","points":[{"t","temperature","humidity","battery"}]}`，每點是 5 分鐘／30 分鐘／2 小時的平均 |
| `/health` | `{"ok":true}` |

`--fake fixtures/fake-sensors.json --bind 127.0.0.1 --port 8795` 是不用藍牙的假閘道（固定讀數＋造出來的 30 天曲線），CI 的模擬器 UI 測試用它。

## App 畫面

- **列表**：依閘道分組，每顆顯示名稱、溫度、濕度、電量（低於 20% 變紅）、多久前更新（超過 10 分鐘變橘、1 小時變紅）。在畫面上時每 30 秒更新，可下拉更新。閘道連不到時顯示原因，並保留上次讀到的資料。
- **詳情**：大字溫濕度與電量；紀錄曲線可切 24 小時／7 天／30 天與溫度／濕度／電量，附最低、平均、最高；閘道沒收到的時段留白。可在列表中隱藏；也列出電壓、訊號、讀取方式與裝置位址。
- **改名**（仿米家）：列表上長按或往左滑選「重新命名」，或在詳情頁點「名稱」那列／右上角的筆；對話框預先填好目前的名字。名稱只存在這支手機（米家是存在雲端），清空或改回閘道上的名稱就跟著閘道。
- **設定**（右上角齒輪）：閘道網址一行一個，可同時看公司電腦和家裡的閘道，最多 8 個。可只填 `位址:埠`。全部留空就顯示示範資料。
- 時間一律以閘道的時鐘計算，手機時鐘不準也不影響「幾分鐘前」。
- 原始碼：`Sources/ThermoCore`（JSON、紀錄、名稱，無畫面，有單元測試）、`iOSApp`（SwiftUI 畫面，用 Swift Charts 畫曲線）。鍵名：UserDefaults `thermo.gateways`、`thermo.preferences`。

## 驗證狀態

- 電腦端（2026-11-06，Windows office 電腦，Intel 藍牙）：實際讀到一顆刷了 pvvx 5.9 的 LYWSD03MMC（BTHome v2 明文）；閘道在 ZeroTier 位址上回應 `/sensors`，從另一台 ZeroTier 電腦連得到。閘道單元測試 30 項通過（本機 Python 3.11）。
- App：程式已寫好，**尚未編譯**（只能在 macOS CI 編譯）；編譯、單元測試、模擬器 UI 測試與實機結果見工具箱 README。
- ESP32 閘道：尚未實作（規劃用 ESP32-2432S028，提供同樣的 `/sensors`／`/history`）。
