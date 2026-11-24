import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        List(selection: $workspace.selection) {
            if !workspace.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Matches") {
                    ForEach(workspace.filteredFiles, id: \.self) { url in
                        FileRow(
                            name: url.lastPathComponent,
                            detail: workspace.relativeDirectory(of: url),
                            url: url
                        )
                        .tag(url)
                    }
                }
            } else if let root = workspace.rootURL {
                Section(root.lastPathComponent) {
                    // Flat rows (not nested DisclosureGroups): nested groups in a macOS List
                    // leave stale rows behind when folders expand/collapse.
                    ForEach(workspace.visibleRows) { row in
                        if row.node.isDirectory {
                            TreeRow(row: row, isExpanded: workspace.isExpanded(row.node.url))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { workspace.toggleExpanded(row.node.url) }
                        } else {
                            TreeRow(row: row, isExpanded: false)
                                .tag(row.node.url)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Open in Default Editor") {
                    NSWorkspace.shared.open(url)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
        .overlay {
            if workspace.rootURL != nil, !workspace.filter.isEmpty, workspace.filteredFiles.isEmpty {
                ContentUnavailableView.search(text: workspace.filter)
            }
        }
    }
}

/// SF Symbol for a sidebar row: a bracket for JSON, a document for Markdown/Mermaid, a folder for directories.
private func sidebarSymbol(for url: URL?, isDirectory: Bool) -> String {
    if isDirectory { return "folder" }
    if let url, FileScanner.isJSON(url) { return "curlybraces" }
    return "doc.text"
}

/// One row of the sidebar tree: indentation, disclosure chevron (folders only), icon and name.
private struct TreeRow: View {
    let row: SidebarRow
    let isExpanded: Bool

    private static let indent: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
                .opacity(row.node.isDirectory ? 1 : 0)

            Label(row.node.name, systemImage: sidebarSymbol(for: row.node.url, isDirectory: row.node.isDirectory))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .animation(.easeOut(duration: 0.12), value: isExpanded)
    }
}

private struct FileRow: View {
    let name: String
    let detail: String
    let url: URL?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: sidebarSymbol(for: url, isDirectory: false))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}
