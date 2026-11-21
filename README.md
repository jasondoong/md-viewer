# MD Preview

macOS 上的 Markdown 預覽器（SwiftUI + WKWebView）。開啟一個資料夾，在側欄樹狀瀏覽所有 `.md`，快速切換檔案。

## 需求

- macOS 14 Sonoma 以上
- Xcode 16 以上（專案使用 Xcode 16 的「同步資料夾」格式，`MDPreview/` 內新增的 .swift 檔會自動加入編譯）

## 執行

```bash
open MDPreview.xcodeproj   # 然後在 Xcode 按 ⌘R
# 或不開 Xcode，直接打包：
./build.sh                 # 產出 build/Release/MDPreview.app
```

第一次執行後按 ⌘O 選 `Samples/` 資料夾就能測試所有功能。

## 安裝與「打開檔案的應用程式」

建議只保留一份 app 在「應用程式」資料夾，Spotlight 和 Finder 的「打開檔案的應用程式」才不會出現重複或抓到舊版：

```bash
./build.sh                # build 並安裝到 /Applications（--no-install 只 build 不安裝）
```

build 產物放在 `build.noindex/`，資料夾名稱結尾的 `.noindex` 讓 Spotlight 不收錄，所以不會出現第二份。
Xcode 按 ⌘R 產生的 Debug 版在 `~/Library/Developer/Xcode/DerivedData/`，若它也出現在搜尋結果，
可到「系統設定 → Spotlight → 搜尋隱私」把 DerivedData 資料夾加進去。

之後在 .md 檔按右鍵 →「打開檔案的應用程式」就會看到 MD Preview；也可以把 .md 檔或資料夾拖到 Dock 上的圖示。
開啟單一 .md 檔時，會打開它所在的資料夾並選取該檔。

## 功能與快捷鍵

| 功能 | 操作 |
| --- | --- |
| 開啟資料夾 | ⌘O、工具列按鈕，或把資料夾 / .md 拖進視窗 |
| 快速開啟（模糊搜尋） | ⌘P，↑↓ 選擇、Enter 開啟、Esc 關閉 |
| 側欄篩選 | 側欄上方搜尋框 |
| 下一個 / 上一個檔案 | ⌥⌘↓ / ⌥⌘↑（側欄聚焦時也可直接用 ↑↓） |
| 重新載入 | ⌘R（平常不需要，存檔會自動重載） |
| 在 Finder 顯示 / 用預設編輯器開啟 | ⇧⌘R / ⌘E，或側欄右鍵 |
| 縮放 | ⌘= / ⌘- / ⌘0 |
| 外觀（系統 / 淺色 / 深色） | 工具列外觀按鈕、View → Appearance，或 ⇧⌘L 循環切換 |

- **遞迴子資料夾**：只顯示含有 md 的資料夾；略過隱藏檔、`node_modules`、`build` 等
- **自動重載**：FSEvents 監看整個資料夾，外部編輯器存檔即更新，且保留捲動位置；新增 / 刪除檔案時側欄同步更新
- **渲染**：GFM（表格、task list、刪除線）、程式碼高亮、YAML front matter 折疊顯示、相對路徑圖片、文件內 `#anchor` 與 `.md` 之間的連結
- **外觀**：預設跟隨系統，也可固定淺色或深色（app 與預覽一起切換）
- 重開 app 會回到上次的資料夾與檔案

## 結構

```
MDPreview.xcodeproj
MDPreview/              Swift 原始碼（同步資料夾）
  MDPreviewApp.swift    App 進入點、選單指令
  Workspace.swift       視窗狀態：資料夾、檔案樹、目前檔案、搜尋、連結處理
  FileScanner.swift     遞迴掃描 md 檔
  FolderWatcher.swift   FSEvents 監看
  ContentView.swift     NavigationSplitView 主畫面
  SidebarView.swift     側欄樹狀 / 篩選結果
  QuickOpenView.swift   ⌘P 快速開啟
  MarkdownWebView.swift WKWebView + 自訂 mdpreview:// scheme
  Appearance.swift      淺色 / 深色 / 跟隨系統切換
Web/                    預覽頁 HTML/JS/CSS（macOS 與 Windows 版共用）（marked 18、highlight.js 11、github-markdown-css 5）
Samples/                測試用 md
```

## 說明

- 為了能直接讀任意資料夾並記住上次位置，App Sandbox 是關閉的（自用工具的常見做法）。若要上架 Mac App Store，需要改用 security-scoped bookmarks。
- 預覽內容透過 `mdpreview://` 自訂 scheme 提供，只會讀取已開啟資料夾內的檔案。
