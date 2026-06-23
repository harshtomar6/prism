import SwiftUI
import AppKit

/// The dropdown shown when the menu bar item is clicked.
struct MenuContent: View {
    @ObservedObject var store: PRStore

    /// When false, the list renders as a plain VStack instead of a ScrollView.
    /// Used for static snapshots — ImageRenderer does not rasterize ScrollView content.
    var scrollable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let error = store.errorMessage {
                errorView(error)
            } else if store.authored.isEmpty && store.committed.isEmpty {
                emptyView
            } else if scrollable {
                ScrollView { list }
                    // A window-style MenuBarExtra self-sizes to content, but a ScrollView
                    // has zero ideal height and collapses to nothing. Give it a definite
                    // height from the row count, capped so long lists scroll.
                    .frame(height: listHeight)
            } else {
                list
            }

            Divider()

            footer
        }
        .frame(width: 380)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(title: "Created by me", prs: store.authored)
            section(title: "Committed to", prs: store.committed)
        }
        .padding(.vertical, 8)
    }

    /// Definite height for the scrollable list, derived from row count and capped.
    private var listHeight: CGFloat {
        let rows = store.authored.count + store.committed.count
        let headers = (store.authored.isEmpty ? 0 : 1) + (store.committed.isEmpty ? 0 : 1)
        let estimate = CGFloat(rows) * 42 + CGFloat(headers) * 24 + 16
        return min(max(estimate, 60), 440)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Open Pull Requests")
                .font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func section(title: String, prs: [PullRequest]) -> some View {
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) (\(prs.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)

                ForEach(prs) { pr in
                    PRRow(pr: pr)
                }
            }
        }
    }

    private var emptyView: some View {
        Text("No open pull requests 🎉")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load PRs", systemImage: "exclamationmark.triangle")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            if let updated = store.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A single clickable PR row that opens the PR in the browser.
private struct PRRow: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if pr.isDraft {
                        Text("DRAFT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(pr.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                Text("\(pr.repo) #\(pr.number)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(hovering ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
