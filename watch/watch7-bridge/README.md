# Watch7 橋接（手錶專用 App）

讓 Samsung Galaxy Watch7（Wear OS）直接接收 iPhone 的通知、來電提醒與媒體控制。這是裝在手錶上的 App，不是手機 App，所以放在 `watch/` 分類，不在 `apps/`。iPhone 上不需要安裝任何東西。

## 狀態（0.1.0）

| 項目 | 狀態 |
| --- | --- |
| 實作 | 第一版完成 |
| 編譯 | 通過。Windows 本機以 JDK 21、Android SDK 36、Gradle 8.13 建出 debug APK（約 6 MB） |
| 單元測試 | 10 項通過，涵蓋通知事件解析、分段重組（含切在中文字中間）、指令組裝、媒體資訊解析 |
| 模擬器測試 | 未進行。模擬器沒有藍牙，測不到連線 |
| 實機測試 | **未進行**。藍牙連線、配對、通知顯示、來電、媒體控制都還沒在手錶上跑過 |

單元測試只驗證資料解析，不代表在手錶上能用。

## 已實作

- 配對模式：手錶廣播，讓它出現在 iPhone 的「設定→藍牙」；逾時 2 分鐘自動結束。
- 配對後由手錶主動連回 iPhone：先直接連線重試 8 次（間隔 1 到 60 秒），再轉低功耗等待；每 60 秒由看門狗檢查，卡住超過 2 分鐘就整個重來。螢幕亮起、藍牙重開、開機、App 更新時也會主動重連。
- iPhone 通知轉成手錶通知：標題、內文、來源 App、時間。靜音或重連時重送的舊通知不震動。
- 通知上的動作按鈕會傳回 iPhone；在手錶上滑掉通知，iPhone 上的也會清除（該通知有提供清除動作時）。
- 來電以高優先通知顯示，可接聽或拒接。
- 畫面上顯示連線狀態、iPhone 電量、上次連線時間、正在播放的曲目，並可上一首、播放／暫停、下一首。

用的是 Apple 公開給藍牙配件的通知服務（ANCS）、媒體服務（AMS）與電池服務。

## 尚未實作

- 在手錶上講電話（通話音訊）。目前接聽後聲音在 iPhone。
- 每個 App 的通知過濾。
- 錶面上的複雜功能與資訊方塊。
- 系統媒體控制整合。目前只能在 App 畫面內控制。
- 綁定失效時的引導。

## 已知限制

- 不能在手錶上回覆訊息。這是 Apple 通知服務的限制。
- 手錶首次設定仍需要一支 Android 11 以上的手機，設定完成後才能安裝這個 App。
- 沒有「iPhone 導航、手錶同步顯示轉彎」；手錶上的 Google 地圖要靠手錶自己的網路。
- 耗電尚未量測。
- One UI 9 Watch（Wear OS 7）尚未測過，開發期間建議先不要更新手錶。

## 建置

需要 JDK 21 與 Android SDK（platform 36、build-tools、platform-tools）。在本目錄建立 `local.properties`，內容為 `sdk.dir=` 加上 SDK 路徑（Windows 路徑請用正斜線），然後：

```powershell
.\gradlew.bat testDebugUnitTest assembleDebug
```

產物在 `app\build\outputs\apk\debug\app-debug.apk`。APK 與 `local.properties` 不提交。

## 安裝到手錶

1. 手錶開啟開發人員選項與無線偵錯，並與電腦在同一個 Wi‑Fi。
2. 用手錶畫面上的配對碼與位址配對並連線，再安裝：

```powershell
adb pair <手錶IP>:<配對連接埠>
```

```powershell
adb connect <手錶IP>:<連接埠>
```

```powershell
adb install -r app\build\outputs\apk\debug\app-debug.apk
```

3. 打開 App，允許藍牙與通知權限。
4. 把 App 從手錶電池設定的「休眠中的應用程式」移除，否則連線會被系統默默中斷。

## 與 iPhone 配對

1. 手錶原本配對的 Android 手機先關閉藍牙。
2. 在手錶 App 按「配對 iPhone」。
3. 在 iPhone 打開「設定→藍牙」，點選出現的手錶，兩邊確認配對。
4. 在 iPhone 藍牙清單點手錶旁的資訊鈕，開啟「分享系統通知」。
5. iPhone 的「設定→通知→顯示預覽」不要設成「永不」。

最後更新：2026-11-28。
