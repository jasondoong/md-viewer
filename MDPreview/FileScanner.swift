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
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    static let skippedDirectories: Set<String> = ["node_modules", "DerivedData", "Pods", ".build", "build"]
    static let maxDepth = 16

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    struct Result: Sendable {
        let tree: [FileNode]
        /// Flat list of every markdown file, in sidebar (depth-first) order.
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
            } else if !isDir && isMarkdown(item) {
                // Symlinked markdown files are fine; symlinked directories are skipped to avoid cycles.
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

    /// Reads a text file, falling back to a lossy UTF-8 decode for odd encodings.
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
