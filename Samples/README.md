---
title: MD Preview sample
tags: [demo, test]
---

# MD Preview 範例

這個資料夾用來測試 **MD Preview** 的各項功能。

- 子資料夾文件：[安裝指南](guide/setup.md)
- 跳到本頁段落：[程式碼區塊](#程式碼區塊)
- 外部連結：[Swift.org](https://www.swift.org)

## 表格

| 功能 | 快捷鍵 |
| --- | :---: |
| 開啟資料夾 | ⌘O |
| 快速開啟 | ⌘P |
| 下一個 / 上一個檔案 | ⌥⌘↓ / ⌥⌘↑ |
| 重新載入 | ⌘R |

## 待辦清單

- [x] 資料夾樹狀瀏覽
- [x] 檔案變更自動重載
- [ ] 你的下一個功能

## 程式碼區塊

```swift
struct Greeting: View {
    var body: some View {
        Text("Hello, Markdown!")
    }
}
```

```bash
xcodebuild -project MDPreview.xcodeproj -target MDPreview -configuration Release
```

## 圖片（相對路徑）

![swatch](images/swatch.png)

> 用任何編輯器修改這個檔案並存檔，預覽會自動更新，捲動位置也會保留。
