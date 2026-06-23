import SwiftUI
import AppKit

/// The dropdown shown when the menu bar item is clicked.
struct MenuContent: View {
    @ObservedObject var store: PRStore

    /// When false, the list renders as a plain VStack instead of a ScrollView.
    /// Used for static snapshots — ImageRenderer does not rasterize ScrollView content.
    var scrollable: Bool = true

    /// When false, opening the menu does not clear unread markers (snapshots).
    var clearsUnreadOnAppear: Bool = true

    private var isEmpty: Bool {
        store.reviewRequested.isEmpty && store.authored.isEmpty && store.committed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let error = store.errorMessage {
                errorView(error)
            } else if isEmpty {
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
        // Opening the menu means the user has looked — clear unread markers.
        .onAppear { if clearsUnreadOnAppear { store.markAllSeen() } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(title: "Needs my review", prs: store.reviewRequested)
            section(title: "Created by me", prs: store.authored)
            section(title: "Committed to", prs: store.committed)
        }
        .padding(.vertical, 8)
    }

    /// Definite height for the scrollable list, derived from row count and capped.
    private var listHeight: CGFloat {
        let rows = store.reviewRequested.count + store.authored.count + store.committed.count
        let headers = [store.reviewRequested, store.authored, store.committed]
            .filter { !$0.isEmpty }.count
        let estimate = CGFloat(rows) * 44 + CGFloat(headers) * 24 + 16
        return min(max(estimate, 60), 460)
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
        HStack(spacing: 12) {
            if let updated = store.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isEmpty {
                Button {
                    store.openAll()
                } label: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open all in browser")
            }

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
            HStack(alignment: .top, spacing: 8) {
                leading

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if pr.isDraft {
                            tag("DRAFT", color: .secondary)
                        }
                        Text(pr.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        trailingBadges
                    }
                    Text("\(pr.repo) #\(pr.number)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovering ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Unread dot + CI status indicator, vertically aligned with the title.
    private var leading: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(pr.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
            checkIcon
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var checkIcon: some View {
        switch pr.checks {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "clock.fill").foregroundStyle(.orange)
        case .none:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary.opacity(0.5))
        }
    }

    @ViewBuilder
    private var trailingBadges: some View {
        if pr.merge == .conflicting {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("Merge conflict")
        }
        switch pr.review {
        case .approved:
            tag("APPROVED", color: .green)
        case .changesRequested:
            tag("CHANGES", color: .red)
        case .reviewRequired, .none:
            EmptyView()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
