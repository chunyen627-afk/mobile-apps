# Repository instructions

- 使用繁體中文撰寫使用者文件。
- 每個手機 App 位於 `apps/<app-name>/`，共用 CI workflow 放在 `.github/workflows/`。
- 修改功能、安裝方式、設定、建置流程、已知限制或驗證狀態時，必須在同次提交更新對應 App 的 README；總覽受影響時也更新根目錄 README。
- README 必須區分實作完成、編譯通過、模擬器測試通過與實機測試通過，不可用靜態檢查代替執行結果。已驗證結果附 workflow 或其他可查證證據。
- 不提交個人媒體、真實 SMB 位址與帳密、Apple 憑證、登入資訊或本機執行暫存。
- CI 只使用公開倉庫的標準 GitHub-hosted runner，不自行切換付費方案。
- 實機安裝只處理本專案 App；不得更新、還原或抹除 iPhone 的 iOS。系統升級由使用者在手機上自行決定。
