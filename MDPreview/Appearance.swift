import AppKit
import SwiftUI

/// Light / dark mode override. `.system` follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Setting NSApp.appearance (rather than SwiftUI's preferredColorScheme) switches every window
    /// and the WKWebView's `prefers-color-scheme`, and `nil` reliably returns to following the system.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// System → Light → Dark → System
    var next: AppearanceMode {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
}

/// Picker used in both the View menu and the toolbar menu.
struct AppearancePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        Picker("Appearance", selection: $selection) {
            ForEach(AppearanceMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
    }
}
