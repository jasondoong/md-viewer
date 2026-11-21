import AppKit
import Observation
import SwiftUI

/// Receives files/folders opened from Finder ("Open With", double-click, drop on the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            OpenRequests.shared.submit(urls)
        }
    }
}

/// Hands URLs from the app delegate to a window. If the app was just launched by opening a file,
/// the URLs wait here until the first window appears.
@MainActor
@Observable
final class OpenRequests {
    static let shared = OpenRequests()

    private(set) var pending: [URL] = []
    /// Captured from a window so a new one can be opened when every window is closed.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var liveWindowCount = 0

    func submit(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending = urls
        NSApp.activate()
        if liveWindowCount == 0, let openWindow {
            openWindow(id: MDPreviewApp.mainWindowID)
        }
    }

    /// Returns and clears the pending URLs (only the first window to ask gets them).
    func take() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
