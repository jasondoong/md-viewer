import Foundation

/// A node in the sidebar tree. Directories only appear if they (recursively) contain markdown files.
struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// `nil` for files, non-empty array for directories.
    let children: [FileNode]?

    var id: URL { url }
    var isDirectory: Bool { children != nil }
}

/// A visible row in the flattened sidebar tree.
struct SidebarRow: Identifiable, Hashable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

enum FileScanner {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx", "mmd"]
    static let mermaidExtensions: Set<String> = ["mmd"]
    static let jsonExtensions: Set<String> = ["json"]
    /// Maximum JSON file size that is read and rendered, in bytes (50 MiB). This is an
    /// initial safety bound and may be adjusted after measuring.
    static let jsonSizeLimit = 50 * 1024 * 1024
    static let skippedDirectories: Set<String> = ["node_modules", "DerivedData", "Pods", ".build", "build"]
    static let maxDepth = 16

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// JSON files (case-insensitive on the extension), e.g. `.json` / `.JSON`.
    static func isJSON(_ url: URL) -> Bool {
        jsonExtensions.contains(url.pathExtension.lowercased())
    }

    /// Any file type the preview can open: Markdown/Mermaid or JSON.
    static func isPreviewable(_ url: URL) -> Bool {
        isMarkdown(url) || isJSON(url)
    }

    struct Result: Sendable {
        let tree: [FileNode]
        /// Flat list of every previewable file (Markdown/Mermaid or JSON), in sidebar (depth-first) order.
        let files: [URL]
    }

    static func scan(_ root: URL) -> Result {
        let tree = scanDirectory(root, depth: 0)
        var files: [URL] = []
        flatten(tree, into: &files)
        return Result(tree: tree, files: files)
    }

    private static func scanDirectory(_ dir: URL, depth: Int) -> [FileNode] {
        guard depth < maxDepth else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var dirs: [FileNode] = []
        var files: [FileNode] = []

        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false

            if isDir && !isLink {
                if skippedDirectories.contains(item.lastPathComponent) { continue }
                let children = scanDirectory(item, depth: depth + 1)
                if !children.isEmpty {
                    dirs.append(FileNode(url: item, name: item.lastPathComponent, children: children))
                }
            } else if !isDir && isPreviewable(item) {
                // Symlinked previewable files are fine; symlinked directories are skipped to avoid cycles.
                files.append(FileNode(url: item, name: item.lastPathComponent, children: nil))
            }
        }

        let byName: (FileNode, FileNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // Folders first, then files — like most editors.
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }

    private static func flatten(_ nodes: [FileNode], into out: inout [URL]) {
        for node in nodes {
            if let children = node.children {
                flatten(children, into: &out)
            } else {
                out.append(node.url)
            }
        }
    }

    /// Result of a JSON pre-read size check. The check reads only metadata (the file
    /// size), never the full content.
    enum JSONSizeCheck: Equatable {
        /// Within the limit; the file may be read.
        case withinLimit
        /// Over the limit; the full content must NOT be read. Carries the actual size
        /// and the limit so the caller can surface them.
        case exceedsLimit(actualSize: Int, limit: Int)
    }

    /// A file's size in bytes from metadata only (no content read). `nil` when the
    /// size cannot be determined.
    static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Checks the JSON size limit before reading. Returns `.exceedsLimit` (with the
    /// actual size and the limit) when the size is over the limit, otherwise
    /// `.withinLimit`. A file whose size cannot be determined is treated as
    /// `.withinLimit` so the read itself can surface its own error (the existing
    /// read-error handling). Exactly at the limit is allowed.
    static func checkJSONSize(_ url: URL) -> JSONSizeCheck {
        guard let size = fileSize(url) else { return .withinLimit }
        return size > jsonSizeLimit
            ? .exceedsLimit(actualSize: size, limit: jsonSizeLimit)
            : .withinLimit
    }

    /// Reads a text file, falling back to a lossy UTF-8 decode for odd encodings.
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
