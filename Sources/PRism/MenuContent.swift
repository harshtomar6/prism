import SwiftUI
import AppKit

/// The dropdown shown when the menu bar item is clicked.
struct MenuContent: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings: AppSettings

    /// When false, the list renders as a plain VStack instead of a ScrollView.
    /// Used for static snapshots — ImageRenderer does not rasterize ScrollView content.
    var scrollable: Bool = true

    /// When false, opening the menu does not clear unread markers (snapshots).
    var clearsUnreadOnAppear: Bool = true

    @State private var showingSettings = false

    private var isEmpty: Bool {
        store.reviewRequested.isEmpty && store.authored.isEmpty && store.committed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if showingSettings {
                SettingsPanel(settings: settings, scrollable: scrollable)
            } else if let error = store.errorMessage {
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
            section(title: "Needs my review", prs: store.reviewRequested,
                    filtered: settings.hasAnyReviewFilter)
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
        HStack(spacing: 8) {
            Text(showingSettings ? "Filters" : "Open Pull Requests")
                .font(.headline)
            Spacer()
            if store.isLoading && !showingSettings {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "chevron.left" : "slider.horizontal.3")
                    .foregroundStyle(showingSettings ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(showingSettings ? "Back to PRs" : "Filters")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func section(title: String, prs: [PullRequest], filtered: Bool = false) -> some View {
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(title) (\(prs.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if filtered {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .help("Filtered")
                    }
                }
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
            if !isEmpty && !showingSettings {
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

/// Filter configuration for the "Needs my review" list.
struct SettingsPanel: View {
    @ObservedObject var settings: AppSettings
    var scrollable: Bool = true
    /// When false, hides the text-field editors (used for clean snapshots).
    var interactive: Bool = true

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            Text("Show **Needs my review** PRs only when they match:")
                .font(.caption)
                .foregroundStyle(.secondary)

            FilterListEditor(
                title: "Repositories",
                systemImage: "folder",
                placeholder: "e.g. marketplace-backend",
                items: settings.reviewRepoFilters,
                interactive: interactive,
                onAdd: settings.addRepo,
                onRemove: settings.removeRepo
            )

            FilterListEditor(
                title: "Changed folders / paths",
                systemImage: "doc.text.magnifyingglass",
                placeholder: "e.g. apps/ad-publishing",
                items: settings.reviewPathFilters,
                interactive: interactive,
                onAdd: settings.addPath,
                onRemove: settings.removePath
            )

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)

        if scrollable {
            ScrollView { content }.frame(height: 340)
        } else {
            content
        }
    }

    private var footnote: String {
        var parts = ["A PR must match every active filter type (repo AND path); within a type, any match counts."]
        if settings.hasPathFilters {
            parts.append("Path filtering fetches each review PR's changed files.")
        }
        return parts.joined(separator: " ")
    }
}

/// An editable list of string filters: add via text field, remove via the chip's ✕.
private struct FilterListEditor: View {
    let title: String
    let systemImage: String
    let placeholder: String
    let items: [String]
    var interactive: Bool = true
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())

            if interactive {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if items.isEmpty {
                Text("No filters — all repos/paths shown.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack {
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            onRemove(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onAdd(value)
        draft = ""
    }
}

/// A single clickable PR row that opens the PR in the browser.
private struct PRRow: View {
    private enum CopyTarget { case link, branch }

    let pr: PullRequest
    @State private var hovering = false
    @State private var copied: CopyTarget?

    var body: some View {
        // The row opens via a tap gesture rather than a Button so the nested copy
        // Button can consume its own tap without also opening the browser.
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
                    copyControls
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
        .onTapGesture { openPR() }
        .onHover { hovering = $0 }
    }

    private func openPR() {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
    }

    /// Copy-branch and copy-link buttons, revealed on hover. Each is a `.plain`
    /// Button so its tap is consumed and does not open the PR.
    private var copyControls: some View {
        HStack(spacing: 8) {
            copyIcon(.branch, symbol: "arrow.triangle.branch", help: "Copy branch name", value: pr.branch)
            copyIcon(.link, symbol: "doc.on.doc", help: "Copy PR link", value: pr.url)
        }
    }

    @ViewBuilder
    private func copyIcon(_ target: CopyTarget, symbol: String, help: String, value: String) -> some View {
        if (hovering || copied == target) && !value.isEmpty {
            Button { copy(value, as: target) } label: {
                Image(systemName: copied == target ? "checkmark" : symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(copied == target ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .help(help)
        } else {
            // Reserve width so the title doesn't shift when the button appears.
            Color.clear.frame(width: 13, height: 1)
        }
    }

    private func copy(_ value: String, as target: CopyTarget) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copied == target { copied = nil }
        }
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
