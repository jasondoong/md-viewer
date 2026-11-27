import SwiftUI

#if !SWIFT_PACKAGE
@main
#endif
struct MDPreviewApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
        }
        // Files opened from Finder go through AppDelegate → OpenRequests into an existing
        // window, instead of SwiftUI spawning a new window per file.
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
            WorkspaceCommands()
        }
    }
}

// MARK: - Focused value so menu commands talk to the active window's workspace

struct WorkspaceFocusedKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
}

// MARK: - Menu commands

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Commands {
        // ⌘P is used for Quick Open.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .newItem) {
            Button("Open Folder…") { workspace?.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(workspace == nil)

            Button("Quick Open…") {
                if workspace?.rootURL != nil { workspace?.showQuickOpen = true }
            }
                .keyboardShortcut("p")
                .disabled(workspace == nil)

            // Paste JSON opens the in-memory input sheet on the focused window's
            // workspace. It works even with no folder open (the sheet is attached at
            // the top level), so it only requires a focused window, not a folder.
            Button("Paste JSON…") { workspace?.showPasteInput = true }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        CommandMenu("Navigate") {
            Button("Next File") { workspace?.selectAdjacent(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(workspace == nil)

            Button("Previous File") { workspace?.selectAdjacent(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(workspace == nil)

            Divider()

            Button("Reload") { workspace?.reloadAll() }
                .keyboardShortcut("r")
                .disabled(workspace == nil)

            // A pasted document has no file location, so Finder reveal and opening in an
            // external editor are unavailable for it.
            Button("Reveal in Finder") { workspace?.revealSelectionInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace == nil || workspace?.isPastedSelected == true)

            Button("Open in Default Editor") { workspace?.openSelectionExternally() }
                .keyboardShortcut("e")
                .disabled(workspace == nil || workspace?.isPastedSelected == true)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { workspace?.zoom(by: 0.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { workspace?.zoom(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { workspace?.resetZoom() }
                .keyboardShortcut("0")
            Divider()
            Button("Expand All") { workspace?.requestJSONTreeExpandAll() }
                .disabled(workspace == nil || workspace?.documentKind != .json)
            Button("Collapse All") { workspace?.requestJSONTreeCollapseAll() }
                .disabled(workspace == nil || workspace?.documentKind != .json)
            Divider()
            Menu("Appearance") {
                AppearancePicker(selection: $appearance)
                    .pickerStyle(.inline)
                    .labelsHidden()
            }
            Button("Cycle Appearance") { appearance = appearance.next }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
        }
    }
}
