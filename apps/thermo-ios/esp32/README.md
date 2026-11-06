# ESP32 溫濕度閘道

已上板使用的 CYD 閘道 1.4 原始碼，採用 PlatformIO／Arduino。這不是溫濕度計本身的韌體；溫濕度計先刷 pvvx 並送出明文 BTHome v2。整合摘要見[上一層 ESP32 章節](../README.md#esp32-閘道)。

## 硬體與原始碼

- ESP32-2432S028（CYD），ESP32-WROOM-32、4 MB flash、無 PSRAM；USB 5V 供電，燒錄需資料線。
- 實測是 **ST7789**，2.8 吋 320×240 橫向顯示；另有 ILI9341 建置環境，尚未在該款板實測。
- 顯示 HSPI：MOSI 13、MISO 12、SCLK 14、CS 15、DC 2、背光 21；本板 reset 設定 12，其他批次須對照接線。
- XPT2046 觸控：CLK 25、MISO 39、MOSI 32、CS 33；採輪詢，不使用 IRQ。旋轉與校正見 `include/display.h`。
- `src/main.cpp`：BLE、Wi-Fi、HTTP、NTP、LittleFS、畫面與序列埠控制。
- `include/core.h`：廣播解碼、合併、分桶，以 [Python 閘道](../pc-gateway/thermo_gateway.py) 為準。
- `tests/core_cli.cpp`、`tools/test_reference.py`：使用同倉庫 Python 單元測試封包，比對 C++ 結果。
- 此版開機直接進閘道，**不含賽車模式或開機選單**。舊韌體備份應私下保留，不提交含 NVS 的完整 flash。

## 建置

備妥 Python 3.10+、PlatformIO Core，在此目錄執行：

```sh
python -m platformio run -e cyd-st7789
```

ILI9341 板改用 `cyd-ili9341`。`platformio.ini` 固定 pioarduino `55.03.312-1`（Arduino 3.3.12／ESP-IDF 5.5.5），函式庫：NimBLE-Arduino 2.3.6、ArduinoJson 6.21.5、WiFiManager 2.0.17、LovyanGFX 1.2.7。

保留 `esp32-hal-alloc-ble-mem.h`，讓此 Arduino 版本保留 BLE 記憶體。不要直接降成 ESP-IDF 4.4，Wi-Fi／BLE 共存與關閉省電的行為不同。

## 燒錄方式

`<序列埠>` 換成裝置管理員的 COM 埠或其他系統對應埠。先停止佔用它的序列監控程式。

1. 首次改用此韌體，先用 esptool 的 `read-flash`／`read_flash`（依版本）讀出完整 4 MB，確認備份大小與可讀性。備份可能含帳密，不提交。首次燒錄會替換原程式與分割表。
2. 確認接受改用此分割表後執行：

   ```sh
   python -m platformio run -e cyd-st7789 -t upload --upload-port <序列埠>
   python -m platformio device monitor --port <序列埠> --baud 115200
   ```

3. 若顯示 `STORAGE not mounted`，首次安裝才送出 `FORMAT` 加換行，初始化儲存區。有既存資料時須先排查，不可直接清除；韌體不會自動格式化。
4. 已使用**相同分割表**的升級可用相同 upload 指令，勿 erase-flash、uploadfs 或重建檔案系統。LittleFS 名稱／歷史及 NVS Wi-Fi／靜態 IP 會保留。不同分割表不適用此保證。

程式區 `0x10000`、容量 `0x350000`；LittleFS `0x360000`、容量 `0xA0000`（640 KiB）。沒有第二個 OTA 槽，使用 USB 更新。分割標籤 `spiffs` 是 Arduino 預設尋找的名稱，實際格式仍是 LittleFS。

## Wi-Fi 與固定 IP

首次連線失敗時開 WiFiManager 設定熱點。手機連螢幕上的 `Thermo-Setup-…`，輸入螢幕顯示的隨機密碼，開啟螢幕上的熱點 IP，選家中 **2.4 GHz** Wi-Fi。帳密存 NVS，不寫入程式碼。設定熱點 300 秒後關閉，需要再設定時從序列埠送 `WIFI`。

1. 小米路由器的「區域網路／DHCP 靜態分配」（名稱依韌體而異）保留 `<閘道IP>`，對應 **ESP32 Wi-Fi MAC**，不是溫濕度計的藍牙 MAC。
2. 序列埠可送 `STATIC <閘道IP> <路由器IP> <子網路遮罩> <DNS伺服器IP>`，收到 `STATIC saved` 後送 `REBOOT`。參數須為實際 IPv4，閘道與路由器須同網段。存 NVS，未設定則用 DHCP。
3. 路由器保留與板上設定須一致，避免撞 IP；重開後檢查螢幕／序列埠 `IP http://…:18787 sleep=0` 及 `/health`。板上固定 IP 不代表路由器已綁定。

可複製 `network.example.txt` 為忽略的 `network.local.txt` 留操作筆記；不是自動讀取的設定。`secrets.h`、`include/secrets.h`、`*.local.json` 也忽略；本專案不需要編譯時 Wi-Fi 密碼。

## 開機與電腦轉發

ESP32 通電即自動跑閘道，斷網會重連。NTP 使用台灣 UTC+8，`time` 與 `updated` 都是 Unix 秒；未同步資料端點回 503，不以 `time: 0` 回成功。Wi-Fi 省電關閉，BLE 被動掃描 window 40 ms／interval 160 ms（25%），不連線溫濕度計。

電腦使用 Windows 內建 **portproxy**，沒有另寫 Python 轉發服務。指令見[轉發章節](../README.md#轉發閘道不在-zerotier-上時)，目標填路由器保留位址。防火牆限制 ZeroTier 位址與網段，不開放公網。

IP Helper、ZeroTier 服務須設「自動」並執行；portproxy 規則持久保存，開機由服務承接，不需登入腳本。以 `netsh interface portproxy show all` 及服務管理員檢查；未設自動時由管理員調整。電腦關機／休眠時遠端中斷，但 ESP32 繼續收資料。PC 藍牙閘道不能同時佔用相同監聽位址和埠。

## HTTP 介面與差異

區網用 `http://<閘道IP>:18787`，遠端 App 填 `http://<轉發電腦ZeroTier位址>:18787`。與 [Python API](../README.md#閘道pc-gateway) 相容；溫度 °C、濕度 %、電量 %、電壓 V、RSSI dBm，缺值為 null。

| 方法／路徑 | 回應／操作 |
| --- | --- |
| `GET /health` | `{"ok":true}`；只代表 HTTP 可回應，不代表 NTP／儲存／感測器均正常 |
| `GET /sensors` | 頂層 `version, gateway, time, sensors, alerts`；每顆 `id, name, label, room, advertised_name, temperature, humidity, battery, voltage, rssi, updated, format, error` |
| `GET /history?id=<感測器位址>&range=day` | `version, id, range, bucket, time, utc_offset, points`；每點 `t, temperature, humidity, battery, temperature_min, temperature_max, humidity_min, humidity_max` |
| `POST /labels` | JSON `{"id":"<感測器位址>","name":"臥室","room":"臥室"}`；成功 `{"ok":true}`。name／room 可 null；去頭尾空白並限 40 個 Unicode 字元，LittleFS 保存，重開仍在 |

**虛構** `/sensors` 範例：

```json
{"version":1,"gateway":"ESP32 溫濕度閘道","time":1700000010,"sensors":[{"id":"A4:C1:38:00:00:01","name":"臥室","label":"臥室","room":"臥室","advertised_name":null,"temperature":24.5,"humidity":51.5,"battery":99,"voltage":3.0,"rssi":-55,"updated":1700000000,"format":"bthome","error":null}],"alerts":{"enabled":false}}
```

- `id` 是完整大寫冒號位址。name 優先 label、其次廣播名稱、最後位址。被動掃描可能拿不到 scan response 中的名稱，`advertised_name: null` 正常；公開版沒有裝置專屬別名。
- 支援 BTHome v2 明文（0xFCD2）、pvvx 15 bytes／atc1441 13 bytes（0x181A）。略過加密廣播，不支援原廠 GATT 輪詢。
- 自動登錄最多 4 顆，已保存的裝置也佔名額，沒有刪除單顆 API；超額略過，序列埠 `limit_drops` 計數。
- `alerts` 固定 `{"enabled":false}`，不推播。HTTP 無驗證或 TLS，只供可信區網／受限制的 ZeroTier 使用。
- 每 5 分鐘記錄近期收到的數值。最多 31 個本地日檔，API 限最近 30 天。4 顆原始容量 `(8+4×8)×288×31=357120 bytes`，640 KiB 其餘空間供檔案系統、狀態與復原暫存；4 顆滿載 30 天未實測。
- day 最近 24 小時，1800 秒分桶；week／month 含今天的 7／30 本地日，86400 秒分桶，`utc_offset=28800`。溫濕度平均至小數 2 位並含 min/max，電量取最低，空桶不造數字。
- 非法 range 回 400、未知 id 回 404；labels 非法 JSON／超過 1024 bytes 回 400，儲存失敗回 500。
- 擴充 `GET /samples?id=<感測器位址>&after=<Unix秒>&limit=96`：回 `version,id,source,time,utc_offset,retention_start,gap,samples,next_after,has_more`；sample 是 `t,temperature,humidity,battery`。用 next_after 翻頁至 has_more=false，接收端去重，到期才刪除，不因手機讀取刪除。**目前 App 仍讀 /history，尚未整合手機永久同步**。

## 螢幕與序列埠

畫面顯示 IP，每頁最多 3 顆名稱／溫濕度／電量／更新秒數，中文用原生 efontTW。亮屏點擊換頁，閒置 **10 秒關背光**；點一下喚醒且不換頁。熄屏不停止 BLE、Wi-Fi、HTTP。行緩衝僅重畫改變的文字。此前整體背光閃爍的根因尚未定位，熄屏功能不代表硬體問題已修復。

序列埠 115200：`STATUS`、`REBOOT`、`WIFI`、`STATIC …`、`INVERT`（顏色反相並保存）。`FORMAT` 僅未掛載檔案系統時允許，會清除該儲存區。

## 驗證

備妥 C++17 g++（環境變數 `CXX` 可指定路徑），在本目錄跑：

```sh
python tools/test_reference.py
```

直接使用 `../pc-gateway/tests/test_thermo_gateway.py`，在暫存目錄編譯，比對 Python DecodeTests 封包、截斷／隨機封包、交替廣播合併、電壓估電量與日／週／月分桶，結果印到標準輸出。詳見 [VALIDATION.md](VALIDATION.md)。原始日誌有私人裝置資訊，不提交。編譯、上板、手機實機、路由器綁定與長時間穩定性分別驗收。
