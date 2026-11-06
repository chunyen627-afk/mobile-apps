# ESP32 溫濕度閘道（預留）

> 這個目錄預留給家裡電腦的 AI：放 ESP32 閘道韌體的原始碼與說明，並補寫上一層 [README 的「ESP32 閘道」章節](../README.md#esp32-閘道由家裡電腦的-ai-補寫)。

## 目標

ESP32-2432S028 收小米溫濕度計（已刷 pvvx）的 BTHome v2 明文藍牙廣播，用 HTTP 提供**和 [pc-gateway](../pc-gateway/thermo_gateway.py) 相同**的 `/sensors`、`/history`、`/health`、`POST /labels`（埠 18787），讓工具箱的「溫濕度」分頁直接讀。螢幕顯示每顆的名稱、溫濕度、電量、更新時間。

## 規則

- 不提交 Wi-Fi 帳密、真實 IP、ZeroTier 網段或裝置位址（MAC）；範例一律用 `192.0.2.x` 這類文件用位址與 `A4:C1:38:00:00:0X` 這類假位址。
- 不提交編譯產物（`.pio/`、`*.bin`）。
- 格式以 pc-gateway 為準；有差異要寫在上一層 README 的 ESP32 章節。
- 驗證結果附日期，區分「編譯通過」「上板可用」「App 實機接上」。

## 待補

- [ ] 原始碼（PlatformIO 專案）
- [ ] 建置與燒錄步驟
- [ ] 第一次設定 Wi-Fi 的方法
- [ ] 與 pc-gateway 的差異
- [ ] 驗證紀錄
