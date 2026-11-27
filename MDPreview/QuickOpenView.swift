import SwiftUI

/// ⌘P-style fuzzy file switcher.
struct QuickOpenView: View {
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var results: [URL] {
        workspace.quickOpenResults(for: query)
    }

    var body: some View {
        let results = self.results

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Go to file…", text: $query)
                    .accessibilityIdentifier("quickOpenSearch")
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { open(results) }
                    .onKeyPress(.downArrow) {
                        move(1, count: results.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1, count: results.count)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(12)

            Divider()

            if results.isEmpty {
                Text("No matching files")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, url in
                                row(url, isHighlighted: index == highlighted)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        highlighted = index
                                        open(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) { _, newValue in
                        guard results.indices.contains(newValue) else { return }
                        proxy.scrollTo(results[newValue])
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
        .onExitCommand { dismiss() }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ url: URL, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
            Text(url.lastPathComponent)
                .lineLimit(1)
            Text(workspace.relativeDirectory(of: url))
                .font(.callout)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if url.path == workspace.selection?.path {
                Text("current")
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor : Color.clear)
        )
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    private func open(_ results: [URL]) {
        guard results.indices.contains(highlighted) else { return }
        workspace.select(results[highlighted])
        dismiss()
    }
}
