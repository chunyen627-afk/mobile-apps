# Windows／iPhone 免費續簽：快速重建與避坑

更新：2026-10-21。這是一次實機成功流程的交接，不保證所有版本、帳號與網路均相同。全文不含私人帳號、裝置識別碼、網路位址或個人檔案路徑。

## 先看結論與最短路線

**Windows 用 iloader 安裝／配對 SideStore → iPhone 安裝 LocalDevVPN → SideStore 登入 → 匯入自己的 IPA → 手動 Refresh All → 驗證重開保留登入 → 設定捷徑排程 → 關螢幕驗證。**

已實測：SideStore 修復後，連續兩次滑掉重開保持登入；將 App 全部滑掉、關閉螢幕後，定時排程仍成功更新兩個 App 的描述檔，約 5 秒完成。電腦當時只讀取證據，沒有執行簽署或安裝。這是一次成功驗收，後續仍受網路、Apple 驗證與簽署期限影響。

免費帳號仍需在約 7 天期限內續簽。定時工作設在手機，不是 Windows 工作排程或 AI 提醒；初次安裝／配對需電腦，日常手機續簽使用 LocalDevVPN。

## 先辨別是否需要重建

| 現況 | 最短處理 |
| --- | --- |
| 登入保留、手動與排程均成功 | 保留現有設定，不為了沒有通知而重裝 |
| 只有排程失敗 | 先看排程與捷徑錯誤，確認 LocalDevVPN，再看登入狀態 |
| 滑掉重開就登出 | 直接檢查 App Group 與啟動維護紀錄，見下方修復；不要要求永遠不滑掉 |
| SideStore 可用，但 My Apps 缺少原本 App | 匯入同一個 App 的 IPA，沿用帳號與 Bundle Identifier；不先刪手機上的 App |
| 首次建置環境或 SideStore 已無法啟動 | 從下一節的 Windows 安裝／配對開始 |

## 重建順序：每一關通過才往下

1. **保存恢復材料。** 保留官方原始 SideStore IPA、自己的 IPA、來源版本／SHA256、配對資料及可取得的 App 資料備份。資料庫／設定備份不等於 Keychain 或完整裝置備份。帳密、配對檔、憑證及原始診斷只留本機。
2. **USB 先通。** 手機解鎖並信任 Windows，確認 Apple 通訊元件與 iloader 能識別裝置。不更新、還原或抹除 iOS；不要從虛擬區網探索開始排查。
3. **安裝 SideStore 並放置配對資料。** 優先依官方 iloader 流程；本人完成 Apple 登入與雙重驗證。依當日官方版本公告選 IPA，記錄實際版本，不只看「Stable」按鈕名稱。
4. **手機安裝 LocalDevVPN 並 Connect。** 在系統 VPN 設定確認實際已連線名稱；「個人級 VPN」只是分類，另一個 VPN 已連線不算通過。
5. **確認 SideStore 可啟動與登入。** 如遇下表的既知錯誤，走對應修復，不連續更換密碼或撤銷憑證。
6. **完成 SideStore 自己的續簽。** 在 My Apps 執行 Refresh。若出現 Revoke，先確認會影響的現有 App 及同帳號恢復材料，再處理；不要把 Revoke 當一般登入按鈕。接續要求 Re-sign 時完成重簽，再確認能重新開啟。
7. **匯入自己的 App。** My Apps → ＋ → 從「檔案」選自己的 IPA。沿用原帳號與 Bundle Identifier，不先移除 App。確認 My Apps 出現該 App、能開啟，原有設定與資料仍在。
8. **停用舊工具對同一批 App 的自動續簽。** 若從 Sideloadly 移交給 SideStore，避免兩套工具持續切換憑證。本次停止 Sideloadly Daemon 並移除其登入自啟，保留快取與安裝資料庫；重新開 Sideloadly 時仍須確認不會恢復舊自動續簽。
9. **驗證登入能保存。** 登入後，從多工畫面滑掉 SideStore 再開啟，連做兩次。兩次都保持登入才設定無人值守排程。
10. **驗證實際續簽。** 手動 Refresh All 成功後再設定排程；以 App 紀錄或描述檔建立／到期時間判定，不只看仍顯示「7 DAYS」。

官方參考：[安裝流程](https://docs.sidestore.io/docs/installation/install)、[限制與常見問題](https://docs.sidestore.io/docs/faq)、[版本公告](https://github.com/SideStore/SideStore/releases/tag/0.7.0-alpha)。

## 本次最耗時的坑與已驗證修法

| 症狀 | 本次原因／有效處理 | 不要重走的路 |
| --- | --- | --- |
| iloader 登入 WebSocket 中斷 | 改用內建 Jkcoxson（Mac）後通過驗證 | 不直接認定密碼錯誤；不同伺服器的可用性會變動 |
| SideStore 登入錯誤 `-80045` | 在 User Customizations 關閉 On-Device Anisette、依提示重啟；Anisette Servers 選 Jkcoxson（Mac），再登入成功 | 不反覆 Revoke；這是本次版本的有效設定，不是永久保證 |
| 啟動提示擴充缺少有效 profile | 紀錄指向唯一非必要 WidgetKit 小工具；排除該小工具後可啟動 | 不把擴充描述檔、主程式權限與配對資料混為一談 |
| 每次滑掉重開都登出 | 主程式沒有 App Group，無法保存啟動維護進度，導致每次清除登入；依下節修復 | 不要求使用者永遠保持 App 開著，也不盲目清 Keychain |
| VPN 能連檔案服務，但無法電腦續簽 | VPN 上 TCP 可連不代表 Apple 配對／安裝協定可用；本次改走手機 SideStore | 不把 SMB 成功、Wi-Fi 同步已勾選或埠可連視為續簽成功 |
| 捷徑找不到 ZeroTier 的設定 VPN 項目 | 本機實測清單確實沒有；續簽後手動恢復 ZeroTier | 不把「打開 ZeroTier App」當成背景自動連線 |

本次有效登入輔助服務為 `https://mac-ani.jkcoxson.com/`。此為服務網址，非私人網路位址；是否仍適用須看當日官方狀態。相關 [登入錯誤回報](https://github.com/SideStore/SideStore/issues/1665)。

### 重開登出：精確修復流程

適用於本次 SideStore `0.7.0-20260911.328+6032424a` 的已定位問題，不應把所有登出都判成相同原因。

1. 讀取安裝資訊與描述檔：確認主程式是否缺少 `com.apple.security.application-groups`、安裝資訊是否沒有 `GroupContainers`。
2. 比對多次冷啟動紀錄：若每次都重跑 MaintenanceManager 步驟 1–3，且有無法取得 App Group container 的訊息，對照該版本原始碼。此版本的維護計數只能寫入共享容器，寫入失敗會在下次再執行清除登入。
3. 先保存可讀取的設定／資料庫與恢復 IPA，**不刪除 SideStore**。不要以目前已去掉群組權限的安裝快取當修復來源。
4. 連上 LocalDevVPN，登入原帳號，從 SideStore My Apps 的 ＋ 匯入官方原始 SideStore IPA，覆蓋同一個 App 身分。
5. 本次 IPA 只有非必要 Widget 擴充；「App Contains Extensions」選 **Remove App Extensions**。這個操作移除小工具，不是移除主程式的 App Group。若不同版本有不同擴充，先辨識用途，不能一律照刪。
6. 覆蓋後讀回：新描述檔與已安裝主程式都應有 App Group，且 `GroupContainers` 存在。第一次啟動可能再做一次維護、需登入一次；之後兩次滑掉重開必須保持登入，維護不可反覆清除登入。
7. 若 My Apps 清單缺少原有 App，重新匯入該 App 的同身分 IPA；手機上的 App 不先刪除。再測 Refresh All 與原有資料。

本次修復已通過第 6、7 步與鎖屏排程續簽。根因程式碼：[MaintenanceManager](https://github.com/SideStore/SideStore/blob/6032424a/SideStore/MaintenanceManager.swift)。

## 捷徑與排程：先短測再定期

在 iPhone 建立捷徑，動作依序為：

1. 「設定 VPN」：連線 LocalDevVPN。
2. 「等待」：5 秒。
3. SideStore 的 **Refresh All Apps**，不是「打開 App」。
4. 可選的「顯示通知」：標題「App 續簽」，內容「續簽流程已完成，記得恢復原本使用的 VPN」。

先設幾分鐘後的時間觸發，將 App 全部滑掉並關閉螢幕，再核對實際續簽紀錄。通過後將測試時間改成需要的定期時段；不要剛好等到第 7 天到期才嘗試，保留失敗重試時間，例如每週兩次。確切日期／時間由本人在手機設定，不能把建議寫成已完成設定。[Apple iOS 27 自動化操作說明](https://support.apple.com/en-me/guide/shortcuts/apdfbdbd7123/10.0/ios/27)。

**通知與續簽分開驗收。** 本次關螢幕排程沒有看到通知，手動執行會通知；後續發現「顯示通知」標題空白，但尚未證明空白是根因，也未驗證補填後結果。實際續簽已有兩份新描述檔證據，不能因沒通知而重裝。完成通知只表示流程走到該步，不能代替核對有效期限。[Apple 顯示通知動作](https://support.apple.com/zh-tw/guide/shortcuts/apd2175adcab/ios)。

## 交接與恢復時必須留下的紀錄

- 公開 Git：工具與版本、已驗證流程、錯誤原因、修復方法、實機驗收結果與未驗證限制。
- 本機私有交接：實際安裝檔位置／雜湊、App 身分、備份位置、成功紀錄位置、描述檔時間、目前排程與 VPN 狀態。不要提交配對檔、登入資料或原始診斷。
- 電腦取證可使用 pymobiledevice3：InstallationProxy 讀版本／群組，Misagent 讀描述檔時間／權限，HouseArrest 讀可存取的 App 紀錄。只輸出必要欄位，不輸出完整憑證、配對或帳密。
- 下一位 AI 先讀本指南與本機最新交接；若已有成功證據，從未完成的項目繼續，不重做整個安裝流程。
- 本次使用者已接受「實際續簽成功即可」，通知排查不是阻擋條件；若日後要求完善提醒，再接續驗證。
