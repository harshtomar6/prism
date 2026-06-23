import Foundation
import SwiftUI

/// Observable state backing the menu bar UI. Owns refresh scheduling and the
/// last-known set of pull requests.
@MainActor
final class PRStore: ObservableObject {
    @Published private(set) var authored: [PullRequest] = []
    @Published private(set) var committed: [PullRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let service = GitHubService()
    private var timer: Timer?
    private var started = false

    /// Poll interval in seconds.
    private let refreshInterval: TimeInterval = 180

    /// Total count for the menu bar badge.
    var totalCount: Int { authored.count + committed.count }

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

    #if DEBUG
    /// Seed the store with generic sample data for screenshots/previews.
    /// Never used in release builds.
    func seedPreviewData() {
        started = true // suppress any live fetch
        authored = [
            PullRequest(id: "a1", number: 482, title: "Add dark mode tokens to design system", url: "", repo: "acme/web-ui", author: "you", isDraft: false, updatedAt: Date().addingTimeInterval(-1_800), relation: .authored),
            PullRequest(id: "a2", number: 1207, title: "Fix flaky checkout integration test", url: "", repo: "acme/payments", author: "you", isDraft: false, updatedAt: Date().addingTimeInterval(-7_200), relation: .authored),
            PullRequest(id: "a3", number: 96, title: "Wire up GraphQL pagination for search", url: "", repo: "acme/search-api", author: "you", isDraft: true, updatedAt: Date().addingTimeInterval(-86_400), relation: .authored),
        ]
        committed = [
            PullRequest(id: "c1", number: 311, title: "Migrate auth service to typed config", url: "", repo: "acme/auth", author: "dana", isDraft: false, updatedAt: Date().addingTimeInterval(-3_600), relation: .committed),
            PullRequest(id: "c2", number: 58, title: "Refactor notification queue consumer", url: "", repo: "acme/notifications", author: "lee", isDraft: false, updatedAt: Date().addingTimeInterval(-172_800), relation: .committed),
        ]
        lastUpdated = Date().addingTimeInterval(-90)
    }
    #endif

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let prs = try await service.fetchPullRequests()
            authored = prs.filter { $0.relation == .authored }
            committed = prs.filter { $0.relation == .committed }
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
