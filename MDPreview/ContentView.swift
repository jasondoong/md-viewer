import AppKit
import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var isDropTargeted = false
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @Environment(\.openWindow) private var openWindow

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

                // The paste input sheet works on memory-only content, so this entry
                // is available even when no folder is open (no folder gating).
                Button {
                    workspace.showPasteInput = true
                } label: {
                    Label("Paste JSON", systemImage: "doc.on.clipboard")
                }
                .help("Paste JSON (⇧⌘V)")
            }
        }
        .sheet(isPresented: $workspace.showQuickOpen) {
            QuickOpenView(workspace: workspace)
        }
        // The "Paste JSON" input sheet is attached at the top level so it is reachable
        // even when no folder is open (it works on memory-only pasted content).
        .sheet(isPresented: $workspace.showPasteInput) {
            PasteInputView(workspace: workspace, show: $workspace.showPasteInput)
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
        .onChange(of: OpenRequests.shared.pending, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            _ = workspace.handleDrop(OpenRequests.shared.take())
        }
        .onAppear {
            OpenRequests.shared.openWindow = openWindow
            OpenRequests.shared.liveWindowCount += 1
        }
        .onDisappear {
            OpenRequests.shared.liveWindowCount -= 1
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
        // A pasted document has no file location, so it is shown first, ahead of the
        // no-folder prompt and the file branches. It is rendered from memory as JSON
        // (documentKind .json, identity .pasted); `fileURL` is nil (no base, no local
        // resource URL).
        if workspace.isPastedSelected {
            MarkdownWebView(
                fileURL: nil,
                rootURL: nil,
                markdown: workspace.markdown,
                documentKind: workspace.documentKind,
                documentID: workspace.documentID,
                version: workspace.renderVersion,
                zoom: workspace.zoomLevel,
                onLinkClicked: { workspace.handleLink($0) },
                onZoomBy: { workspace.zoom(by: $0) }
            )
        } else if workspace.rootURL == nil {
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
                Text("Open a folder with ⌘O, or drag a folder or .md / .mmd file here.")
            } actions: {
                Button("Open Folder…") { workspace.chooseFolder() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let selection = workspace.selection {
            // An oversized JSON file is shown as its own prompt (with the actual size and
            // limit) so it is distinguishable from a generic read error below.
            if let oversize = workspace.jsonSizeLimitExceeded {
                ContentUnavailableView(
                    "JSON File Too Large",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(oversize.message)
                )
            } else if let error = workspace.loadError {
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
                    documentKind: workspace.documentKind,
                    documentID: workspace.documentID,
                    version: workspace.renderVersion,
                    zoom: workspace.zoomLevel,
                    onLinkClicked: { workspace.handleLink($0) },
                    onZoomBy: { workspace.zoom(by: $0) }
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

// MARK: - Paste JSON input

/// A multi-line input sheet for pasting JSON. Any text is accepted (including text that is
/// not valid JSON, which is still submitted so the preview can show the raw text and any
/// error). Submission is gated by an explicit UTF-8 byte limit; over the limit the submission
/// is refused and the limit is shown, with no truncation.
///
/// Enter inserts a newline (the default `TextEditor` behaviour), the Preview button submits,
/// and Esc / Cancel dismisses without submitting. The sheet state lives on the window's
/// `Workspace` (`showPasteInput`), so it is usable even with no folder open.
struct PasteInputView: View {
    let workspace: Workspace
    @Binding var show: Bool

    @State private var text = ""
    @FocusState private var editorFocused: Bool

    /// Whether the draft exceeds the explicit paste size limit (bounded UTF-8 scan).
    private var overLimit: Bool { Workspace.exceedsPasteSizeLimit(text) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste JSON").font(.headline)
                Text("Paste or type JSON here. Press Preview to show it, or Esc to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if overLimit {
                    Label(
                        "Content is larger than the \(ByteFormat.humanReadableBytes(Workspace.pasteInputSizeLimit)) limit. Submit is disabled; nothing is truncated.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .focused($editorFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    show = false
                }
                .keyboardShortcut(.cancelAction)

                // Only the Preview button commits; it is refused when over the limit. Empty
                // and invalid content are still accepted so the preview can show the raw text.
                Button("Preview") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(overLimit)
            }
            .padding()
        }
        .frame(width: 640, height: 480)
        .onExitCommand { show = false }
        .onAppear { editorFocused = true }
    }

    private func submit() {
        // Over the limit: refuse (the button is also disabled) and never truncate.
        guard !overLimit else { return }
        workspace.submitPastedJSON(text)
        show = false
    }
}
