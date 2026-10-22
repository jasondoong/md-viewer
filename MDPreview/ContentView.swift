import AppKit
import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var isDropTargeted = false
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 270, max: 450)
        } detail: {
            DetailView(workspace: workspace)
        }
        .searchable(text: $workspace.filter, placement: .sidebar, prompt: "Filter files")
        .navigationTitle(workspace.selection?.lastPathComponent ?? workspace.rootURL?.lastPathComponent ?? "MD Preview")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    AppearancePicker(selection: $appearance)
                        .pickerStyle(.inline)
                } label: {
                    Label("Appearance", systemImage: appearance.symbol)
                }
                .help("Appearance: \(appearance.title) (⇧⌘L to cycle)")

                Button {
                    workspace.chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open Folder (⌘O)")

                Button {
                    workspace.showQuickOpen = true
                } label: {
                    Label("Quick Open", systemImage: "magnifyingglass")
                }
                .help("Quick Open (⌘P)")
                .disabled(workspace.rootURL == nil)
            }
        }
        .sheet(isPresented: $workspace.showQuickOpen) {
            QuickOpenView(workspace: workspace)
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.handleDrop(urls)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .focusedSceneValue(\.workspace, workspace)
        .onChange(of: appearance, initial: true) { _, mode in
            mode.apply()
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var subtitle: String {
        guard let selection = workspace.selection else { return "" }
        let dir = workspace.relativeDirectory(of: selection)
        return dir == "/" ? (workspace.rootURL?.lastPathComponent ?? "") : dir
    }
}

struct DetailView: View {
    let workspace: Workspace

    var body: some View {
        if workspace.rootURL == nil {
            ContentUnavailableView {
                VStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 112, height: 112)
                    Text("MD Preview")
                        .font(.title.weight(.semibold))
                }
            } description: {
                Text("Open a folder with ⌘O, or drag a folder or .md file here.")
            } actions: {
                Button("Open Folder…") { workspace.chooseFolder() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let selection = workspace.selection {
            if let error = workspace.loadError {
                ContentUnavailableView(
                    "Can't Read File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                MarkdownWebView(
                    fileURL: selection,
                    rootURL: workspace.rootURL,
                    markdown: workspace.markdown,
                    version: workspace.renderVersion,
                    zoom: workspace.zoomLevel,
                    onLinkClicked: { workspace.handleLink($0) }
                )
            }
        } else if workspace.isScanning {
            ProgressView("Scanning…")
        } else if workspace.allFiles.isEmpty {
            ContentUnavailableView(
                "No Markdown Files",
                systemImage: "doc.text.magnifyingglass",
                description: Text("This folder has no .md files.")
            )
        } else {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text",
                description: Text("Pick a file in the sidebar, or press ⌘P to jump to one.")
            )
        }
    }
}
