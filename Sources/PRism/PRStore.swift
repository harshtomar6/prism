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
