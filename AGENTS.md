# AGENTS.md

給開發者和 AI 助手：先讀本文件，再依任務閱讀相關 spec 和原始碼。文件可能落後於實作；以程式碼和實際驗證為準。

## 專案與範圍

MD Preview 是 macOS 14+ 的離線 Markdown、Mermaid 和 JSON 預覽器，使用 SwiftUI 和 WKWebView；Xcode 專案採用 Xcode 16 同步資料夾。它是預覽工具，不提供文件編輯、雲端同步或遙測。`SPEC-JSON-PREVIEW.md` 記錄 JSON 功能的原始規格與階段，其狀態標示可能落後；以程式碼和實際驗證為準。

## 程式入口

- `MDPreview/MDPreviewApp.swift`：視窗、選單與快捷鍵；`OpenRequests.swift`：Finder 開啟請求。
- `Workspace.swift`：每個視窗的資料夾、選取、讀檔、貼上 JSON、重載、連結與導覽狀態；`FileScanner.swift`：掃描和讀取檔案；`FolderWatcher.swift`：FSEvents。
- `ContentView.swift`、`SidebarView.swift`、`QuickOpenView.swift`：主畫面、側欄與快速開啟。
- `MarkdownWebView.swift`：WKWebView、原生橋接與 `mdpreview://` scheme；`Appearance.swift`：外觀設定。
- `Web/`：共用預覽頁與離線相依資源；`preview.js` 依文件類型分派 Markdown 或 JSON，`json-preview.js` 處理 JSON 解析與格式化，`json-tree.js` 處理樹狀顯示；`.mmd` 由 Workspace 包成 Mermaid code fence。不要在子專案維護另一份 `Web/`。
- `Support/Info.plist`：文件類型與 imported UTIs；`Samples/`：手動測試資料。

目前掃描 `.md`、`.markdown`、`.mdown`、`.mkd`、`.mkdn`、`.mdx`、`.mmd` 和 `.json`。掃描略過隱藏項目、部分建置目錄及符號連結目錄，深度上限為 16；符號連結檔案可出現在側欄。JSON 檔案讀取上限為 50 MiB，貼上內容上限為 5 MiB，貼上內容只存在視窗記憶體中。選取檔案或提交貼上內容後，Workspace 遞增 `renderVersion`；web view 傳送文件類型、識別、內容、base 和捲動狀態給 `window.MDP.render`。

## 維護約束

- 保持 `Web/` 單一來源；它會被打包進 app，不應將原始碼複製到子專案。修改共用 Web 資源時，也要留意其他 host 的相容性。
- `MDPreview/` 是 Xcode 同步資料夾；一般新增 Swift 檔不需修改 `.pbxproj`。若新增 Web 資源，確認打包和載入方式。
- 目前 App Sandbox 關閉。不要為現有架構引入 security-scoped bookmark；若改變發行或 sandbox 需求，先重新評估。
- 預覽 shell 和本機資源使用 `mdpreview://`，不要改用 `file://`。scheme handler 和 JSON 檔案讀取會解析符號連結並檢查資料夾邊界；其他檔案讀取與導覽路徑未必有相同檢查，不能將單一路徑前綴檢查視為完整安全邊界。修改相關程式時應考慮符號連結、路徑邊界和外部資源，避免擴大讀取範圍。
- HTTP、HTTPS、mailto 連結由系統開啟，不在預覽中導覽。預覽應能離線使用；不要新增網路依賴。現有 Markdown 可含遠端資源，勿將「離線可用」誤述為目前已阻擋所有網路請求。
- 新增副檔名時檢查掃描、拖放／Finder 開啟、內容判斷、連結處理和 `Info.plist` 文件類型。沿用系統已提供的 UTI；必要時才宣告自訂 UTI。
- 不要讓 JSON 文件的處理改變 Markdown 中 ` ```json ` 程式碼區塊的既有高亮。

## 建置與驗證

```bash
./build.sh --no-install  # Release 建置至 build.noindex/Release/MDPreview.app
./build.sh               # 建置並替換 /Applications/MDPreview.app
open MDPreview.xcodeproj # Xcode 執行
./test.sh                # Swift、Web 和 macOS UI 測試；需要 Xcode 和 Node.js
./test.sh --cov          # 額外報告 Swift 行覆蓋率
```

`build.sh` 預設會刪除並替換已安裝的 app；一般驗證使用 `--no-install`。Xcode 直接建置的位置可能不同。用 `Samples/` 測試表格、task list、刪除線、程式碼高亮、front matter、Mermaid、連結、圖片及自動重載；修改 Web 時確認 macOS 版行為。依變更增加適當測試，並回報未能驗證的項目。

JSON 的原始預期行為、驗收與階段見 `SPEC-JSON-PREVIEW.md`；其中提案狀態不代表目前實作狀態。避免在本文件重複維護驗收 checklist。
