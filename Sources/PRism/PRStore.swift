import Foundation
import SwiftUI
import AppKit
import Combine

/// Observable state backing the menu bar UI. Owns refresh scheduling, the
/// last-known set of pull requests, and per-PR "seen" tracking for unread dots.
@MainActor
final class PRStore: ObservableObject {
    @Published private(set) var reviewRequested: [PullRequest] = []
    @Published private(set) var authored: [PullRequest] = []
    @Published private(set) var committed: [PullRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let service = GitHubService()
    private var timer: Timer?
    private var started = false

    /// Unfiltered review PRs; `reviewRequested` is the filtered view of this.
    private var rawReview: [PullRequest] = []
    /// Whether the last fetch included changed-path data for review PRs.
    private var reviewFilesLoaded = false

    private var settings: AppSettings?
    private var cancellables = Set<AnyCancellable>()

    /// Wire up settings so filter changes re-apply (refetching files if needed).
    func attach(_ settings: AppSettings) {
        guard self.settings == nil else { return }
        self.settings = settings
        settings.objectWillChange
            .sink { [weak self] in
                // objectWillChange fires before the value updates; defer a tick.
                DispatchQueue.main.async { self?.onSettingsChanged() }
            }
            .store(in: &cancellables)
    }

    /// Poll interval in seconds.
    private let refreshInterval: TimeInterval = 180

    /// Persisted map of PR id -> last-seen updatedAt (epoch seconds).
    private let seenKey = "prism.seenUpdatedAt"
    private let seededKey = "prism.hasSeeded"
    private let defaults = UserDefaults.standard

    /// Total count for the menu bar badge.
    var totalCount: Int { reviewRequested.count + authored.count + committed.count }

    /// Number of PRs with new activity since the user last opened the menu.
    var unreadCount: Int {
        (reviewRequested + authored + committed).filter(\.isUnread).count
    }

    /// All PRs in display order (used for "open all").
    var allPRs: [PullRequest] { reviewRequested + authored + committed }

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let needFiles = settings?.hasPathFilters ?? false
        do {
            let prs = markUnread(try await service.fetchPullRequests(reviewPathFiltering: needFiles))
            reviewFilesLoaded = needFiles
            rawReview = prs.filter { $0.relation == .reviewRequested }
            authored = prs.filter { $0.relation == .authored }
            committed = prs.filter { $0.relation == .committed }
            applyReviewFilter()
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-derive the visible review list from `rawReview` using current settings.
    private func applyReviewFilter() {
        if let settings {
            reviewRequested = rawReview.filter(settings.keepReview)
        } else {
            reviewRequested = rawReview
        }
    }

    /// Settings changed: re-filter immediately; refetch if path data is now needed.
    private func onSettingsChanged() {
        applyReviewFilter()
        if (settings?.hasPathFilters ?? false) && !reviewFilesLoaded {
            Task { await refresh() }
        }
    }

    /// Open every listed PR in the browser.
    func openAll() {
        for pr in allPRs {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Unread tracking

    /// Flag PRs whose `updatedAt` is newer than the last time the user looked.
    /// On the very first run we record everything as seen so nothing spams unread.
    private func markUnread(_ prs: [PullRequest]) -> [PullRequest] {
        let seen = (defaults.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        let firstRun = !defaults.bool(forKey: seededKey)

        let flagged = prs.map { pr -> PullRequest in
            var copy = pr
            if firstRun {
                copy.isUnread = false
            } else if let seenAt = seen[pr.id] {
                copy.isUnread = pr.updatedAt.timeIntervalSince1970 > seenAt + 1
            } else {
                copy.isUnread = true // never seen before
            }
            return copy
        }

        if firstRun {
            persistSeen(flagged)
            defaults.set(true, forKey: seededKey)
        }
        return flagged
    }

    /// Mark all currently shown PRs as seen — called when the menu opens.
    func markAllSeen() {
        persistSeen(allPRs)
        reviewRequested = reviewRequested.map { var p = $0; p.isUnread = false; return p }
        authored = authored.map { var p = $0; p.isUnread = false; return p }
        committed = committed.map { var p = $0; p.isUnread = false; return p }
    }

    private func persistSeen(_ prs: [PullRequest]) {
        var seen = (defaults.dictionary(forKey: seenKey) as? [String: Double]) ?? [:]
        for pr in prs { seen[pr.id] = pr.updatedAt.timeIntervalSince1970 }
        defaults.set(seen, forKey: seenKey)
    }

    #if DEBUG
    /// Seed the store with generic sample data for screenshots/previews.
    /// Never used in release builds.
    func seedPreviewData() {
        started = true // suppress any live fetch
        reviewRequested = [
            PullRequest(id: "r1", number: 742, title: "Add rate limiting to public API", url: "", repo: "acme/gateway", author: "kim", isDraft: false, updatedAt: Date().addingTimeInterval(-600), relation: .reviewRequested, checks: .success, review: .reviewRequired, merge: .mergeable, isUnread: true),
            PullRequest(id: "r2", number: 89, title: "Bump Postgres driver to 16.2", url: "", repo: "acme/core", author: "sam", isDraft: false, updatedAt: Date().addingTimeInterval(-9_000), relation: .reviewRequested, checks: .pending, review: .reviewRequired, merge: .mergeable),
        ]
        authored = [
            PullRequest(id: "a1", number: 482, title: "Add dark mode tokens to design system", url: "", repo: "acme/web-ui", author: "you", isDraft: false, updatedAt: Date().addingTimeInterval(-1_800), relation: .authored, checks: .failure, review: .changesRequested, merge: .mergeable, isUnread: true),
            PullRequest(id: "a2", number: 1207, title: "Fix flaky checkout integration test", url: "", repo: "acme/payments", author: "you", isDraft: false, updatedAt: Date().addingTimeInterval(-7_200), relation: .authored, checks: .success, review: .approved, merge: .conflicting),
            PullRequest(id: "a3", number: 96, title: "Wire up GraphQL pagination for search", url: "", repo: "acme/search-api", author: "you", isDraft: true, updatedAt: Date().addingTimeInterval(-86_400), relation: .authored, checks: .pending, review: .none, merge: .mergeable),
        ]
        committed = [
            PullRequest(id: "c1", number: 311, title: "Migrate auth service to typed config", url: "", repo: "acme/auth", author: "dana", isDraft: false, updatedAt: Date().addingTimeInterval(-3_600), relation: .committed, checks: .success, review: .approved, merge: .mergeable),
            PullRequest(id: "c2", number: 58, title: "Refactor notification queue consumer", url: "", repo: "acme/notifications", author: "lee", isDraft: false, updatedAt: Date().addingTimeInterval(-172_800), relation: .committed, checks: .none, review: .none, merge: .mergeable),
        ]
        lastUpdated = Date().addingTimeInterval(-90)
    }
    #endif
}
