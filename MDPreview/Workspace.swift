import AppKit
import Observation
import SwiftUI

/// All state for one window: the opened folder, its markdown tree, and the current file.
@MainActor
@Observable
final class Workspace {
    // Folder + tree
    private(set) var rootURL: URL?
    private(set) var tree: [FileNode] = []
    private(set) var allFiles: [URL] = []
    private(set) var isScanning = false

    // Current document
    var selection: URL? {
        didSet {
            if selection != oldValue { loadSelection() }
        }
    }
    private(set) var markdown = ""
    /// Bumped every time the content is (re)loaded so the web view knows to re-render.
    private(set) var renderVersion = 0
    private(set) var loadError: String?
    /// Set only when the current JSON selection exceeds the size limit and the full
    /// content was not read; `nil` otherwise.
    private(set) var jsonSizeLimitExceeded: JSONSizeLimitInfo?

    /// The kind of the current document, derived from the selection's extension.
    /// Mermaid (`.mmd`) is previewed as Markdown, so it reports `.markdown`.
    enum DocumentKind: Equatable {
        case markdown
        case json
    }

    /// A stable identity for the current document, deliberately kept separate from
    /// `renderVersion`. The path is the selection's standardized path, which preserves the
    /// symlink location the user selected rather than resolving it.
    enum DocumentID: Hashable {
        case file(path: String)
    }

    /// When the current selection is a JSON file that exceeds `FileScanner.jsonSizeLimit`,
    /// this holds the actual size and the limit so the UI can display them. `nil`
    /// otherwise (including Markdown and JSON that is within the limit).
    struct JSONSizeLimitInfo: Equatable {
        let actualSize: Int
        let limit: Int

        /// A human-readable "actual / limit" pair, e.g. "50.0 MiB / 50.0 MiB". Uses a
        /// deterministic 1024-based formatter so the size/limit shown in the UI are stable
        /// (and testable) regardless of locale.
        var sizeSummary: String {
            "\(ByteFormat.humanReadableBytes(actualSize)) / \(ByteFormat.humanReadableBytes(limit))"
        }

        /// The full prompt shown when a JSON file is too large to read. It states both the
        /// actual size and the limit so the user can tell an oversized file apart from a
        /// generic read error (which goes through `loadError` instead).
        var message: String {
            "JSON 檔案過大（\(sizeSummary)；\(actualSize) / \(limit) 位元組），超過上限，為避免載入超大檔案未讀取全文。"
        }
    }

    /// The kind of the current selection. `nil` when nothing is selected; even when the
    /// selected file fails to load, this still reflects the selection.
    var documentKind: DocumentKind? {
        guard let selection else { return nil }
        return FileScanner.isJSON(selection) ? .json : .markdown
    }

    /// The identity of the current document, separate from `renderVersion`. `nil` when
    /// nothing is selected; still present when the selected file fails to load.
    var documentID: DocumentID? {
        guard let selection else { return nil }
        return .file(path: selection.standardizedFileURL.path)
    }

    // UI state
    /// Expanded folders, keyed by path (URL equality is fussy about trailing slashes).
    var expanded: Set<String> = []
    var filter = ""
    var showQuickOpen = false
    var zoomLevel: Double = 1.0
    private(set) var recentFiles: [URL] = []

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var treeReloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAutoSelect = false

    private enum DefaultsKey {
        static let lastFolder = "lastFolder"
        static let lastFile = "lastFile"
        static let zoom = "zoomLevel"
    }

    init() {
        let defaults = UserDefaults.standard
        let savedZoom = defaults.double(forKey: DefaultsKey.zoom)
        if savedZoom > 0 { zoomLevel = savedZoom }

        if let path = defaults.string(forKey: DefaultsKey.lastFolder),
           isDirectory(URL(fileURLWithPath: path)) {
            // Read before open(folder:), which clears the saved file.
            let lastFile = defaults.string(forKey: DefaultsKey.lastFile)
            open(folder: URL(fileURLWithPath: path))
            if let filePath = lastFile,
               FileManager.default.fileExists(atPath: filePath),
               filePath.hasPrefix(path) {
                select(URL(fileURLWithPath: filePath))
            }
        }
    }

    // MARK: - Opening

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder containing Markdown files"
        if let rootURL { panel.directoryURL = rootURL }
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    func open(folder: URL) {
        let folder = folder.standardizedFileURL
        rootURL = folder
        tree = []
        allFiles = []
        expanded = []
        recentFiles = []
        filter = ""
        selection = nil
        pendingAutoSelect = true

        UserDefaults.standard.set(folder.path, forKey: DefaultsKey.lastFolder)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.lastFile)

        watcher = FolderWatcher(url: folder) { [weak self] paths in
            MainActor.assumeIsolated {
                self?.handleFileSystemEvents(paths)
            }
        }
        reloadTree()
    }

    /// Handles folders or previewable files (Markdown/Mermaid or JSON) dropped onto the window.
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        if isDirectory(url) {
            open(folder: url)
            return true
        }
        if FileScanner.isPreviewable(url) {
            let parent = url.deletingLastPathComponent()
            if let rootURL, isDescendant(url.standardizedFileURL.path, of: rootURL.path) {
                select(url)
            } else {
                open(folder: parent)
                pendingAutoSelect = false
                select(url)
            }
            return true
        }
        return false
    }

    // MARK: - Selection

    func select(_ url: URL) {
        let normalized = url.standardizedFileURL
        // Prefer the exact URL instance from the scan so List selection highlights correctly.
        selection = allFiles.first { $0.path == normalized.path } ?? normalized
    }

    func selectAdjacent(_ offset: Int) {
        guard !allFiles.isEmpty else { return }
        let current = selection.flatMap { sel in allFiles.firstIndex { $0.path == sel.path } }
        let next: Int
        if let current {
            next = (current + offset + allFiles.count) % allFiles.count
        } else {
            next = offset >= 0 ? 0 : allFiles.count - 1
        }
        selection = allFiles[next]
    }

    private func loadSelection() {
        guard let url = selection else {
            markdown = ""
            loadError = nil
            renderVersion += 1
            return
        }
        loadContent(of: url)
        expandAncestors(of: url)

        recentFiles.removeAll { $0.path == url.path }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast(recentFiles.count - 20) }

        UserDefaults.standard.set(url.path, forKey: DefaultsKey.lastFile)
    }

    private func loadContent(of url: URL) {
        jsonSizeLimitExceeded = nil
        let readURL: URL
        if FileScanner.isJSON(url) {
            let resolvedURL = url.resolvingSymlinksInPath()
            guard let rootURL, isDescendant(resolvedURL.path, of: rootURL.resolvingSymlinksInPath().path) else {
                markdown = ""
                loadError = "該 JSON 檔案為指向目前資料夾外的符號連結，已拒絕讀取。"
                renderVersion += 1
                return
            }
            // Check the size before reading. Over the limit: do NOT read the full
            // content — record the actual size and the limit and surface a read error
            // (reusing the existing loadError path).
            switch FileScanner.checkJSONSize(resolvedURL) {
            case .withinLimit:
                break
            case .exceedsLimit(let actualSize, let limit):
                markdown = ""
                loadError = "JSON 檔案過大（\(actualSize) 位元組），超過 \(limit) 位元組的上限，未載入全文。"
                jsonSizeLimitExceeded = JSONSizeLimitInfo(actualSize: actualSize, limit: limit)
                renderVersion += 1
                return
            }
            readURL = resolvedURL
        } else {
            readURL = url
        }
        do {
            var text = try FileScanner.readText(readURL)
            if FileScanner.mermaidExtensions.contains(url.pathExtension.lowercased()) {
                text = "```mermaid\n" + text + "\n```"
            }
            markdown = text
            loadError = nil
        } catch {
            markdown = ""
            loadError = error.localizedDescription
        }
        renderVersion += 1
    }

    func reloadAll() {
        if let selection { loadContent(of: selection) }
        reloadTree()
    }

    // MARK: - Tree

    func reloadTree() {
        guard let root = rootURL else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileScanner.scan(root)
            await self?.apply(result, generation: generation)
        }
    }

    private func apply(_ result: FileScanner.Result, generation: Int) {
        guard generation == scanGeneration else { return }
        tree = result.tree
        allFiles = result.files
        isScanning = false

        if pendingAutoSelect {
            pendingAutoSelect = false
            if selection == nil, let first = preferredInitialFile() {
                selection = first
            }
        }
        if let selection {
            // Re-bind to the freshly scanned URL instance (keeps List highlight stable).
            if let match = allFiles.first(where: { $0.path == selection.path }), match != selection {
                self.selection = match
            }
        }
    }

    private func preferredInitialFile() -> URL? {
        guard let rootURL else { return allFiles.first }
        let topLevel = allFiles.filter { $0.deletingLastPathComponent().path == rootURL.path }
        let preferred = ["readme.md", "index.md", "readme.markdown"]
        for name in preferred {
            if let hit = topLevel.first(where: { $0.lastPathComponent.lowercased() == name }) { return hit }
        }
        return topLevel.first ?? allFiles.first
    }

    func expandAncestors(of url: URL) {
        guard let rootURL else { return }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.count > rootURL.path.count, dir.path.hasPrefix(rootURL.path) {
            expanded.insert(dir.path)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    func isExpanded(_ url: URL) -> Bool {
        expanded.contains(url.standardizedFileURL.path)
    }

    func toggleExpanded(_ url: URL) {
        let key = url.standardizedFileURL.path
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    /// The tree flattened into the rows currently visible in the sidebar (respecting `expanded`).
    var visibleRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        appendVisible(tree, depth: 0, into: &rows)
        return rows
    }

    private func appendVisible(_ nodes: [FileNode], depth: Int, into rows: inout [SidebarRow]) {
        for node in nodes {
            rows.append(SidebarRow(node: node, depth: depth))
            if let children = node.children, isExpanded(node.url) {
                appendVisible(children, depth: depth + 1, into: &rows)
            }
        }
    }

    // MARK: - File system events

    private func handleFileSystemEvents(_ paths: [String]) {
        if let selection {
            let selectedPath = selection.resolvingSymlinksInPath().path
            let touched = paths.contains { path in
                path == selection.path || URL(fileURLWithPath: path).resolvingSymlinksInPath().path == selectedPath
            }
            if touched { loadContent(of: selection) }
        }

        // Debounce tree rescans (editors often fire several events per save).
        treeReloadTask?.cancel()
        treeReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.reloadTree()
        }
    }

    // MARK: - Search

    func relativePath(of url: URL) -> String {
        guard let rootURL else { return url.lastPathComponent }
        let path = url.path
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    func relativeDirectory(of url: URL) -> String {
        let rel = relativePath(of: url)
        let dir = (rel as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    var filteredFiles: [URL] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allFiles }
        return allFiles.filter { relativePath(of: $0).localizedCaseInsensitiveContains(query) }
    }

    /// Fuzzy-ranked results for Quick Open.
    func quickOpenResults(for query: String, limit: Int = 60) -> [URL] {
        let q = query.replacingOccurrences(of: " ", with: "")
        if q.isEmpty {
            var seen = Set<String>()
            let ordered = (recentFiles + allFiles).filter { seen.insert($0.path).inserted }
            return Array(ordered.prefix(limit))
        }

        var scored: [(url: URL, score: Int, length: Int)] = []
        for url in allFiles {
            let rel = relativePath(of: url)
            let nameScore = FuzzyMatcher.score(q, in: url.lastPathComponent).map { $0 * 2 + 10 }
            let pathScore = FuzzyMatcher.score(q, in: rel)
            if let best = [nameScore, pathScore].compactMap({ $0 }).max() {
                scored.append((url, best, rel.count))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.length < $1.length }
        return scored.prefix(limit).map { $0.url }
    }

    // MARK: - Links & external actions

    /// Called when a link inside the preview is clicked.
    func handleLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case LocalSchemeHandler.scheme:
            guard url.host == LocalSchemeHandler.fileHost else { return }
            let fileURL = URL(fileURLWithPath: url.path(percentEncoded: false))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { NSSound.beep(); return }
            let insideRoot = rootURL.map { isDescendant(fileURL.standardizedFileURL.path, of: $0.path) } ?? false
            // Resolve the actual directory first so a directory named `*.json` takes
            // the Finder reveal branch instead of being treated as a previewable file.
            if isDirectory(fileURL) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else if FileScanner.isPreviewable(fileURL), insideRoot {
                select(fileURL)
            } else {
                NSWorkspace.shared.open(fileURL)
            }
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    func revealSelectionInFinder() {
        guard let selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selection])
    }

    func openSelectionExternally() {
        guard let selection else { return }
        NSWorkspace.shared.open(selection)
    }

    func resetZoom() {
        zoomLevel = 1.0
        UserDefaults.standard.set(zoomLevel, forKey: DefaultsKey.zoom)
    }

    func zoom(by delta: Double) {
        zoomLevel = min(3.0, max(0.5, ((zoomLevel + delta) * 10).rounded() / 10))
        UserDefaults.standard.set(zoomLevel, forKey: DefaultsKey.zoom)
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func isDescendant(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path != root && path.hasPrefix(prefix)
    }
}

/// A non-isolated helper so the byte-count formatting used by the oversized-JSON prompt
/// can be called synchronously from `JSONSizeLimitInfo` (which lives inside the `@MainActor`
/// `Workspace`).
enum ByteFormat {
    /// Human-readable byte count using 1024-based units (B, KiB, MiB, GiB, TiB). Deterministic
    /// and locale-independent so the size/limit shown in the UI are stable (and testable).
    /// Whole bytes are shown exactly; larger units keep one fractional digit.
    static func humanReadableBytes(_ bytes: Int) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }
}

enum FuzzyMatcher {
    /// Case-insensitive subsequence match. Returns nil if `query` isn't a subsequence of `candidate`.
    /// Rewards consecutive characters and matches at word boundaries.
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty, q.count <= c.count else { return q.isEmpty ? 0 : nil }

        var qi = 0
        var score = 0
        var last = -2
        let boundaries: Set<Character> = ["/", " ", "-", "_", "."]

        for (ci, ch) in c.enumerated() {
            guard qi < q.count else { break }
            guard ch == q[qi] else { continue }
            score += 1
            if ci == last + 1 { score += 5 }
            if ci == 0 || boundaries.contains(c[ci - 1]) { score += 3 }
            last = ci
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}
