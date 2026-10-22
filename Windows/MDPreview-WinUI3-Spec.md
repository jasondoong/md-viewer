# MD Preview for Windows — WinUI 3 實作規格

> 給 AI 開發助手：請依照本文件，在 `Windows/MDPreview.Win/` 建立一個 **WinUI 3（Windows App SDK）+ C# + WebView2** 的桌面 app。
> 這是一個已經存在的 macOS SwiftUI app 的 Windows 版，功能、行為和預覽畫面要盡量一致。
> 開始前請先讀完本文件，並參考 `MDPreview/*.swift`（macOS 原始碼）了解既有行為。

---

## 1. 產品概述

一個輕量的 Markdown 預覽器：開啟一個資料夾，在左側樹狀瀏覽所有 Markdown 檔，右側即時預覽；可以快速切換檔案，外部編輯器存檔後預覽自動更新。

**只做預覽，不做編輯。**

### 功能清單（全部必做）

1. 開啟資料夾（選擇對話框、拖放、重開 app 自動回到上次的資料夾與檔案）
2. 左側樹狀列出資料夾內所有 Markdown 檔（遞迴子資料夾）
3. 側欄篩選框：依相對路徑過濾，結果以平面清單顯示
4. 快速開啟（Ctrl+P）：模糊搜尋檔名 / 路徑，上下鍵選擇、Enter 開啟、Esc 關閉
5. 上一個 / 下一個檔案（依側欄順序循環）
6. 檔案監看：目前檔案被外部修改時自動重新渲染並**保留捲動位置**；新增 / 刪除 / 改名時側欄自動更新
7. 預覽：GFM（表格、task list、刪除線）、程式碼高亮、YAML front matter 折疊、相對路徑圖片、文件內 `#anchor` 連結、`.md` 之間的連結（在 app 內切換）、外部連結用預設瀏覽器開
8. 外觀模式可切換：跟隨系統 / 淺色 / 深色（app 介面與預覽一起切換，並記住選擇）
9. 預覽縮放（Ctrl+= / Ctrl+- / Ctrl+0），記住縮放比例
10. 在檔案總管中顯示、用預設編輯器開啟、複製路徑

---

## 2. 技術選型（已決定，請勿更換）

| 項目 | 選擇 |
| --- | --- |
| UI 框架 | WinUI 3（Windows App SDK，最新穩定版） |
| 語言 / Runtime | C#，目前的 .NET LTS（例如 .NET 10） |
| Markdown 渲染 | WebView2，載入共用的 `Web/` 資源（**不要**改用 C# 的 Markdown 函式庫） |
| MVVM | `CommunityToolkit.Mvvm`（可選，建議使用） |
| 封裝方式 | **Unpackaged + self-contained**（`WindowsPackageType=None`），輸出可直接執行的資料夾 / zip |
| 最低系統 | Windows 10 1809（17763）；主要目標 Windows 11 |
| 架構 | x64 與 arm64 |

不使用 MSIX 的原因：只在公司內部分享，MSIX 側載需要安裝受信任憑證，比較麻煩。之後若要上 Microsoft Store 再加 MSIX。

---

## 3. 目錄結構

整個 `swift_poc` 資料夾會一起放到 Windows 電腦上（git 或 zip）。

```
swift_poc/
├─ Web/                         ← macOS 與 Windows 共用的預覽頁（見第 4 節）
├─ Samples/                     ← 測試用 md（含子資料夾、圖片、互相連結）
├─ MDPreview/                   ← macOS 版 Swift 原始碼（參考用，不要修改）
├─ MDPreview.xcodeproj/         ← macOS 專案（不要修改）
└─ Windows/
   ├─ MDPreview-WinUI3-Spec.md  ← 本文件
   ├─ Assets/
   │  ├─ AppIcon.ico            ← 已備好（16–256px）
   │  └─ AppIcon-1024.png
   └─ MDPreview.Win/            ← 請在這裡建立 WinUI 3 專案
```

`Web/` **不要複製**到 Windows 專案裡，用 csproj 連結，確保兩個平台永遠用同一份：

```xml
<ItemGroup>
  <Content Include="..\..\Web\**\*" LinkBase="Web" CopyToOutputDirectory="PreserveNewest" />
  <Content Include="..\Assets\AppIcon.ico" Link="Assets\AppIcon.ico" CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
<PropertyGroup>
  <ApplicationIcon>..\Assets\AppIcon.ico</ApplicationIcon>
  <WindowsPackageType>None</WindowsPackageType>
  <WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>
  <SelfContained>true</SelfContained>
  <RuntimeIdentifiers>win-x64;win-arm64</RuntimeIdentifiers>
</PropertyGroup>
```

執行時 Web 資料夾位置：`Path.Combine(AppContext.BaseDirectory, "Web")`。
視窗圖示：`AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"))`。

---

## 4. 共用預覽頁 `Web/`（重要）

### 檔案

| 檔案 | 用途 |
| --- | --- |
| `index.html` | 預覽頁外殼，資源都用相對路徑載入 |
| `preview.js` | 渲染邏輯與原生橋接（**兩個平台共用，修改時必須保持 macOS 相容**） |
| `preview.css` | 版面與背景色 |
| `marked.umd.js` | marked 18（Markdown → HTML） |
| `highlight.min.js` | highlight.js 11 |
| `github-markdown.css` | GitHub 樣式（自動深淺色） |
| `hljs-github.min.css` / `hljs-github-dark.min.css` | 程式碼高亮主題（依 `prefers-color-scheme` 切換） |

### JS ↔ C# 介面約定

**C# → JS**（頁面載入完成後才能呼叫）：

```js
window.MDP.render({
  markdown: "<檔案全文>",
  base: "https://files.mdpreview/<目前檔案所在資料夾的相對路徑>/",  // 必須以 / 結尾
  resetScroll: true   // 換檔案 = true；同一檔案重新載入 = false（保留捲動位置）
});
window.MDP.setZoom(1.2);   // 縮放，1.0 = 100%
```

- 參數用 `System.Text.Json` 序列化成 JSON 物件字面值，再呼叫 `ExecuteScriptAsync($"window.MDP.render({json});")`。**不要**手動拼接字串跳脫。
- `base` 的每個路徑段都要用 `Uri.EscapeDataString` 編碼（中文、空白），路徑分隔改成 `/`。檔案在根目錄時 `base = "https://files.mdpreview/"`。

**JS → C#**（`CoreWebView2.WebMessageReceived`，訊息是 JSON 物件）：

```json
{ "type": "link", "href": "https://files.mdpreview/guide/setup.md" }
{ "type": "key",  "key": "p", "ctrl": true, "shift": false, "alt": false }
```

- `link`：使用者點了連結（`#anchor` 已在 JS 內處理，不會送過來）。
- `key`：WebView2 取得焦點時會吃掉鍵盤事件，所以 `preview.js` 會把 Ctrl / Alt 組合鍵、F5、Esc 轉送給 C#。C# 收到後要執行對應的快捷鍵（見第 7 節）。Ctrl+C / Ctrl+A / Ctrl+F 留給瀏覽器本身。

---

## 5. WebView2 設定

```csharp
await webView.EnsureCoreWebView2Async();
var core = webView.CoreWebView2;

// 1) 預覽頁資源
core.SetVirtualHostNameToFolderMapping("app.mdpreview", webDir, CoreWebView2HostResourceAccessKind.Allow);

// 2) 使用者資料夾（每次開啟新資料夾時重新設定）
core.ClearVirtualHostNameToFolderMapping("files.mdpreview");
core.SetVirtualHostNameToFolderMapping("files.mdpreview", rootFolder, CoreWebView2HostResourceAccessKind.Allow);

core.Profile.PreferredColorScheme = CoreWebView2PreferredColorScheme.Auto;
core.Settings.IsStatusBarEnabled = false;
core.Settings.IsZoomControlEnabled = false;      // 縮放由 app 控制，避免 Ctrl+滾輪雙重縮放
core.Settings.AreDevToolsEnabled = isDebugBuild;
core.Settings.AreBrowserAcceleratorKeysEnabled = false;

core.Navigate("https://app.mdpreview/index.html");
```

- **只在 `NavigationCompleted`（成功）之後**才呼叫 `MDP.render`。在那之前的渲染請求要暫存，載入完成後送出最新一筆（參考 macOS `MarkdownWebView.swift` 的 `pending` / `flush()`）。
- `NavigationStarting`：只允許 `https://app.mdpreview/index.html`，其他一律 `Cancel = true`，若是使用者點擊造成的就交給連結處理邏輯。
- `NewWindowRequested`：`Handled = true`，把 `Uri` 交給連結處理邏輯。
- `ProcessFailed`：重新 `Navigate` 到預覽頁，載入後重新渲染目前檔案。
- 用 `SetVirtualHostNameToFolderMapping` 而不是 `file://`，這樣相對路徑圖片能正常顯示，而且只會讀到使用者開啟的資料夾內的檔案。
- 拖放：WebView2 會攔截拖進預覽區的檔案。若 WinUI 版本可行，請關閉 WebView2 的外部拖放，讓拖放交給視窗處理；做不到的話，至少側欄與空白狀態畫面要能接受拖放。

### 連結處理

| 連結 | 動作 |
| --- | --- |
| host = `files.mdpreview` | 解碼路徑段 → 組成本機路徑 → `Path.GetFullPath` 後確認在 root 內（不分大小寫比對）。是 Markdown 檔就在 app 內切換過去；是資料夾就用檔案總管開；其他存在的檔案用預設程式開；不存在就嗶一聲 |
| `http` / `https` / `mailto` | `Launcher.LaunchUriAsync` |
| 其他 scheme | 忽略 |

連結中的 `#fragment` 在跨檔案時忽略即可。

---

## 6. 畫面與互動

### 版面

- 左：側欄（可拖拉寬度，預設 270px，範圍 200–450），右：預覽。可用 `CommunityToolkit.WinUI.Controls.Sizers` 的 `GridSplitter`。
- 使用 Mica 背景與自訂標題列（`ExtendsContentIntoTitleBar`）。
- 視窗標題：目前檔名；副標顯示相對資料夾（根目錄時顯示資料夾名稱）。沒有選檔案時顯示資料夾名稱，都沒有就顯示 `MD Preview`。
- 頂端工具列：「外觀」下拉按鈕、「開啟資料夾」「快速開啟」按鈕（含 Tooltip 顯示快捷鍵）。

### 外觀模式（淺色 / 深色）

- 三個選項：**跟隨系統**（預設）、**淺色**、**深色**。工具列的「外觀」按鈕是下拉選單（`DropDownButton` + `RadioMenuFlyoutItem`），圖示依目前模式顯示：跟隨系統 = 半黑半白圓、淺色 = 太陽、深色 = 月亮。
- Ctrl+Shift+L 依「跟隨系統 → 淺色 → 深色 → 跟隨系統」循環切換。
- 套用方式（三處要一起改）：
  1. 視窗根元素 `((FrameworkElement)window.Content).RequestedTheme` = `ElementTheme.Default` / `Light` / `Dark`。快速開啟的 ContentDialog / Popup 也要設定相同的 `RequestedTheme`（它們的 XamlRoot 與主視窗相同，但仍需確認）。
  2. WebView2：`CoreWebView2.Profile.PreferredColorScheme` = `Auto` / `Light` / `Dark`。預覽頁的 CSS 用 `prefers-color-scheme` 切換，不需要改 `Web/`。
  3. 自訂標題列的按鈕顏色（`AppWindow.TitleBar.ButtonForegroundColor`、`ButtonHoverBackgroundColor` 等）依實際生效的主題更新；「跟隨系統」時要監聽系統主題變更（`UISettings.ColorValuesChanged`，回到 UI 執行緒處理）。
- 切換時不要重新載入預覽頁，捲動位置要保留。
- 選擇存在 `settings.json` 的 `"theme": "system" | "light" | "dark"`。macOS 版的對應實作在 `MDPreview/Appearance.swift`。

### 側欄

- 上方是篩選框（placeholder：`篩選檔案`）。
  - 篩選框為空：顯示 `TreeView`，根節點標題是資料夾名稱。
  - 有內容：改顯示平面清單「符合的檔案」，每列顯示檔名＋灰色小字的相對資料夾。沒有結果時顯示「找不到符合的檔案」。
- `TreeView` 用 ViewModel 綁定，每個節點有 `IsExpanded`：
  - 資料夾節點不可「選取」，點擊時切換展開。
  - 選到檔案（無論從側欄、快速開啟、下一個檔案、點連結）時，**自動展開它所有的上層資料夾**並捲動到可見。
  - 重新掃描時保留使用者的展開狀態（用路徑當 key，不分大小寫）。
- 右鍵選單：在檔案總管中顯示、用預設編輯器開啟、複製路徑。
- 圖示：資料夾用 Folder，檔案用 Document（Segoe Fluent Icons）。

### 預覽區的空白狀態

| 狀態 | 顯示 |
| --- | --- |
| 尚未開啟資料夾 | App 圖示（`AppIcon-1024.png`，約 112px）、「MD Preview」、說明「按 Ctrl+O 開啟資料夾，或把資料夾 / .md 檔拖到這裡」、「開啟資料夾…」按鈕 |
| 掃描中 | ProgressRing「掃描中…」 |
| 資料夾內沒有 md | 「這個資料夾沒有 Markdown 檔」 |
| 有檔案但未選取 | 「從側欄選一個檔案，或按 Ctrl+P 快速開啟」 |
| 讀檔失敗 | 「無法讀取檔案」＋錯誤訊息 |

### 快速開啟（Ctrl+P）

- 置中浮動面板（`ContentDialog` 或自訂 Popup，約 600×400）：上方 TextBox（placeholder `前往檔案…`），下方結果清單。
- 每列：文件圖示、檔名、灰色的相對資料夾；目前開啟中的檔案右側顯示「目前」。
- 鍵盤：在 TextBox 的 `PreviewKeyDown` 處理 ↑ / ↓ 移動高亮、Enter 開啟、Esc 關閉；輸入變更時高亮回到第一筆。滑鼠點擊也可開啟。
- 結果排序規則見第 8 節。

### 拖放

- 拖入資料夾 → 開啟該資料夾。
- 拖入 Markdown 檔 → 若在目前 root 內就直接選取；否則開啟它的上層資料夾並選取該檔。
- 拖曳經過時，視窗內緣顯示 accent 色外框提示。

---

## 7. 快捷鍵

| 動作 | 快捷鍵 |
| --- | --- |
| 開啟資料夾 | Ctrl+O |
| 快速開啟 | Ctrl+P |
| 下一個 / 上一個檔案 | Ctrl+PageDown / Ctrl+PageUp，另外 Alt+↓ / Alt+↑ |
| 重新載入（檔案＋側欄） | F5 或 Ctrl+R |
| 在檔案總管中顯示 | Ctrl+Shift+R |
| 用預設編輯器開啟 | Ctrl+E |
| 放大 / 縮小 / 重設 | Ctrl+= / Ctrl+- / Ctrl+0（0.5–3.0，每次 0.1） |
| 聚焦側欄篩選框 | Ctrl+Shift+F |
| 循環切換外觀（系統 / 淺色 / 深色） | Ctrl+Shift+L |

- 用視窗層級的 `KeyboardAccelerator` 實作。
- 預覽區（WebView2）有焦點時，快捷鍵會經由第 4 節的 `type: "key"` 訊息送來，請導到**同一組**命令處理函式，不要寫兩套。
- 側欄有焦點時，↑ / ↓ 在 TreeView 內移動就會切換預覽（選取即開啟）。

---

## 8. 核心邏輯（請與 macOS 版保持一致）

### 8.1 掃描資料夾（參考 `FileScanner.swift`）

- Markdown 副檔名（不分大小寫）：`md`、`markdown`、`mdown`、`mkd`、`mkdn`、`mdx`
- 略過：
  - 名稱以 `.` 開頭，或具有 Hidden / System 屬性的檔案與資料夾
  - 名稱為 `node_modules`、`DerivedData`、`Pods`、`.build`、`build` 的資料夾
  - 資料夾的 reparse point（symlink / junction），避免無限迴圈；指向檔案的 symlink 可以保留
  - 深度超過 16 層
  - 沒有權限的資料夾（`UnauthorizedAccessException`）直接跳過，不要中斷整個掃描
- 只顯示「遞迴後含有 Markdown 檔」的資料夾。
- 排序：每一層**資料夾在前、檔案在後**，各自用 Windows 檔案總管的自然排序（P/Invoke `shlwapi.dll` 的 `StrCmpLogicalW`）。
- 另外產生一個「所有檔案的平面清單」，順序 = 樹狀結構的深度優先順序，給「上一個 / 下一個檔案」和快速開啟使用。
- 掃描在背景執行緒進行，完成後回到 UI 執行緒套用。用遞增的 generation 編號丟棄過期的掃描結果。

### 8.2 開啟資料夾後自動選檔

依序：根目錄的 `README.md` → `index.md` → `readme.markdown`（不分大小寫）→ 根目錄第一個檔案 → 整體第一個檔案。
若是啟動時還原上次的檔案，或是拖放指定了檔案，就不要自動選。

### 8.3 讀檔

- 以 UTF-8 讀取（含 BOM 也要正確處理）；解碼失敗時退回寬鬆解碼，不要讓 app 崩潰。
- 編輯器存檔時檔案可能短暫被鎖住：遇到 `IOException` 時，重試 3 次、每次間隔 100ms。

### 8.4 檔案監看（參考 `FolderWatcher.swift`）

- `FileSystemWatcher`：`IncludeSubdirectories = true`；`NotifyFilter = FileName | DirectoryName | LastWrite | Size`；`InternalBufferSize = 64 KB`。
- 事件在背景執行緒觸發，一律用 `DispatcherQueue.TryEnqueue` 回到 UI 執行緒。
- 事件路徑等於目前檔案（不分大小寫）→ 約 150ms debounce 後重新讀檔並渲染，`resetScroll = false`。
- 任何事件 → 300ms debounce 後重新掃描側欄。
- 很多編輯器用「寫入暫存檔再改名」的方式存檔（atomic save）：`Renamed` 事件的新路徑等於目前檔案時，也要觸發重新載入。
- `Error` 事件（緩衝區溢位）→ 直接完整重新掃描並重新載入目前檔案。
- 開啟新資料夾時 Dispose 舊的 watcher。

### 8.5 模糊比對（快速開啟，請照抄演算法）

```text
score(query, candidate):
  q = query 轉小寫, c = candidate 轉小寫
  if q 為空: return 0
  if len(q) > len(c): return null
  qi = 0, score = 0, last = -2
  boundaries = { '/', '\', ' ', '-', '_', '.' }
  for ci, ch in c:
      if qi == len(q): break
      if ch != q[qi]: continue
      score += 1
      if ci == last + 1: score += 5            // 連續字元
      if ci == 0 or c[ci-1] in boundaries: score += 3   // 字首 / 分隔符後
      last = ci; qi += 1
  return score if qi == len(q) else null
```

快速開啟的結果：

- query 先移除空白。
- query 為空：最近開過的檔案（本次執行期間，最多 20 筆，最新的在前）＋ 所有檔案，去重後取前 60 筆。
- 否則對每個檔案：`nameScore = score(q, 檔名) * 2 + 10`、`pathScore = score(q, 相對路徑)`，取兩者中非 null 的最大值；都為 null 就排除。
- 依分數由高到低排序，同分時相對路徑較短的在前，取前 60 筆。

### 8.6 上一個 / 下一個檔案

在平面清單中依目前檔案的位置前後移動，頭尾循環；目前沒有選檔案時，下一個 = 第一個、上一個 = 最後一個。

### 8.7 設定保存

存在 `%LOCALAPPDATA%\MDPreview\settings.json`（unpackaged app 不能用 `ApplicationData.Current`）：

```json
{ "lastFolder": "D:\\notes", "lastFile": "D:\\notes\\README.md", "zoom": 1.0, "theme": "system",
  "window": { "x": 100, "y": 100, "width": 1200, "height": 800, "maximized": false } }
```

- 啟動時：資料夾還存在就開啟；`lastFile` 存在且位於該資料夾內就選取它。
- 開啟新資料夾時清除 `lastFile`；每次選檔時更新。
- 視窗位置若已不在任何螢幕內，就置中顯示。

### 8.8 路徑處理注意

- Windows 路徑不分大小寫：所有路徑比對用 `StringComparison.OrdinalIgnoreCase`，比對前先 `Path.GetFullPath` 正規化並去掉結尾的 `\`。
- 支援長路徑（> 260 字元）與中文、空白路徑。

---

## 9. 建置與發佈

```powershell
cd Windows\MDPreview.Win
dotnet publish -c Release -r win-x64   -o ..\dist\win-x64
dotnet publish -c Release -r win-arm64 -o ..\dist\win-arm64
```

- 把 `dist\win-x64` 壓成 zip 分享即可，解壓後直接執行 `MDPreview.Win.exe`（可改產品名稱為 `MD Preview`）。
- 沒有程式碼簽章時，第一次執行會出現 SmartScreen 警告，按「其他資訊 → 仍要執行」。內部使用可以接受。
- WebView2 Runtime 在 Windows 11 已內建；Windows 10 若沒有，提示使用者安裝 Evergreen Runtime（`CoreWebView2Environment.GetAvailableBrowserVersionString()` 失敗時顯示說明與下載連結）。
- 請在 `Windows/README.md` 寫下建置步驟、需求（Windows 10 1809+、.NET SDK、Visual Studio 或 VS Code）與已知限制。

---

## 10. 驗收清單

用 `Samples/` 資料夾逐項測試：

- [ ] Ctrl+O 開啟 `Samples`，自動選取 `README.md`，預覽有標題、表格、task list、高亮的 Swift / bash 程式碼、折疊的 front matter、藍色長方形圖片
- [ ] 側欄顯示 `guide`（資料夾在前）與 `README.md`；`images` 資料夾因為沒有 md 而**不顯示**
- [ ] 點 README 內的「安裝指南」連結 → 切到 `guide/setup.md`，側欄 `guide` 自動展開並選取
- [ ] 點 setup.md 的「README」連結（`../README.md`）→ 切回來
- [ ] 點「程式碼區塊」錨點 → 平滑捲動到該段落，不換頁
- [ ] 點 Swift.org 連結 → 用預設瀏覽器開啟，app 內不跳頁
- [ ] Ctrl+P 輸入 `setp` → 第一筆是 `setup.md`；↑↓、Enter、Esc 都正常
- [ ] 預覽區有焦點時 Ctrl+P、Ctrl+O、F5、Ctrl+PageDown 仍然有效
- [ ] Ctrl+PageDown 連按：依側欄順序循環切換所有檔案
- [ ] 用記事本和 VS Code 修改並存檔目前檔案 → 預覽更新且捲動位置不變
- [ ] 在資料夾內新增 / 刪除 / 改名 md 檔 → 側欄 1 秒內更新
- [ ] 篩選框輸入 `guide` → 只顯示 guide 內的檔案；清空後回到樹狀並保留展開狀態
- [ ] 外觀設為「跟隨系統」時，切換 Windows 深色 / 淺色模式 → app、標題列按鈕與預覽都跟著變
- [ ] 外觀選「淺色」/「深色」→ 不受系統設定影響；預覽的程式碼高亮主題也跟著換；捲動位置不變
- [ ] Ctrl+Shift+L 在預覽區有焦點時也能循環切換；重開 app 後外觀選擇保留
- [ ] Ctrl+= / Ctrl+- / Ctrl+0 縮放預覽，重開 app 後縮放比例保留
- [ ] 關閉再開啟 app → 回到同一個資料夾與檔案
- [ ] 把資料夾、md 檔拖進視窗都能開啟
- [ ] 開啟有上千個 md、含 `node_modules` 的大型資料夾時 UI 不卡頓
- [ ] 中文、空白、長路徑的資料夾與檔名都正常（包含圖片）
- [ ] 確認 macOS 版仍正常（若有修改 `Web/`）

---

## 11. 不要做的事

- 不要修改 `MDPreview/`、`MDPreview.xcodeproj/`（macOS 版）。
- 不要把 `Web/` 複製一份到 Windows 專案裡另外維護。若一定要改 `Web/`，必須同時相容 macOS（WKWebView 的 `window.webkit.messageHandlers`）與 Windows（`window.chrome.webview`）。
- 不要加入編輯功能、雲端同步、遙測或任何網路請求（外部連結除外）。
- 不要用 `file://` 載入預覽或圖片。
