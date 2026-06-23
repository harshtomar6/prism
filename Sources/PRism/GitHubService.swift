import Foundation

/// Errors surfaced from interacting with the `gh` CLI.
enum GitHubError: LocalizedError {
    case ghNotFound
    case notAuthenticated
    case commandFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "GitHub CLI (gh) not found. Install it: brew install gh"
        case .notAuthenticated:
            return "Not logged in. Run: gh auth login"
        case .commandFailed(let message):
            return message
        case .decodeFailed(let message):
            return "Could not read GitHub response: \(message)"
        }
    }
}

/// Fetches open pull requests via the `gh` CLI.
///
/// GitHub's GraphQL cost analyzer rejects (502/504) a single request that runs
/// two `commits`-bearing searches plus `statusCheckRollup`. So the work is split
/// into three lighter calls:
///   A. `involves:@me` search with commit authors (+ `viewer.login`)
///   B. `review-requested:@me` search (lightweight, no commits)
///   C. batched `statusCheckRollup` for only the PRs that will be displayed
struct GitHubService {

    /// Shared PR field selection minus the expensive commit/rollup connections.
    private static let baseFields = """
    id number title url isDraft updatedAt reviewDecision mergeable
    repository { nameWithOwner } author { login }
    """

    private static var involvesQuery: String {
        """
        query {
          viewer { login }
          search(query: "is:open is:pr involves:@me archived:false", type: ISSUE, first: 50) {
            nodes { ... on PullRequest {
              \(baseFields)
              commits(last: 30) { nodes { commit { authors(first: 5) { nodes { user { login } } } } } }
            } }
          }
        }
        """
    }

    private static var reviewQuery: String {
        """
        query {
          search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 30) {
            nodes { ... on PullRequest { \(baseFields) } }
          }
        }
        """
    }

    private static func rollupQuery(ids: [String]) -> String {
        let array = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        query {
          nodes(ids: [\(array)]) {
            ... on PullRequest {
              id
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
          }
        }
        """
    }

    private static func filesQuery(ids: [String]) -> String {
        let array = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        query {
          nodes(ids: [\(array)]) {
            ... on PullRequest {
              id
              files(first: 100) { nodes { path } }
            }
          }
        }
        """
    }

    /// Resolve the path to the `gh` executable, honouring common install locations.
    private func resolveGhPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "env"
    }

    /// Fetch and classify all relevant open PRs, enriched with CI status.
    ///
    /// When `reviewPathFiltering` is true, the changed file paths of review PRs
    /// are also fetched so the UI can filter by folder.
    func fetchPullRequests(reviewPathFiltering: Bool = false) async throws -> [PullRequest] {
        let ghPath = resolveGhPath() ?? "gh"
        let formatter = ISO8601DateFormatter()

        // A + B run concurrently — neither depends on the other.
        async let involvesRaw = runGraphQL(ghPath: ghPath, query: Self.involvesQuery)
        async let reviewRaw = runGraphQL(ghPath: ghPath, query: Self.reviewQuery)

        let involves = try decode(InvolvesResponse.self, from: try await involvesRaw)
        let review = try decode(ReviewResponse.self, from: try await reviewRaw)
        let login = involves.data.viewer.login

        func make(_ node: PRNode, relation: PullRequest.Relation) -> PullRequest? {
            guard let id = node.id, let number = node.number else { return nil }
            let updated = node.updatedAt.flatMap { formatter.date(from: $0) } ?? Date.distantPast
            return PullRequest(
                id: id, number: number, title: node.title ?? "(no title)",
                url: node.url ?? "", repo: node.repository?.nameWithOwner ?? "",
                author: node.author?.login ?? "", isDraft: node.isDraft ?? false,
                updatedAt: updated, relation: relation,
                checks: .none, // filled in by the rollup pass
                review: ReviewState(decision: node.reviewDecision),
                merge: MergeState(mergeable: node.mergeable)
            )
        }

        var reviewIDs = Set<String>()
        var results: [PullRequest] = []

        for node in review.data.search.nodes {
            guard let pr = make(node, relation: .reviewRequested) else { continue }
            reviewIDs.insert(pr.id)
            results.append(pr)
        }

        for node in involves.data.search.nodes {
            guard let id = node.id, !reviewIDs.contains(id) else { continue }
            let authorLogin = node.author?.login ?? ""
            let relation: PullRequest.Relation
            if authorLogin.caseInsensitiveCompare(login) == .orderedSame {
                relation = .authored
            } else if node.committed(by: login) {
                relation = .committed
            } else {
                continue // involved via comment/mention/assignment only
            }
            if let pr = make(node, relation: relation) { results.append(pr) }
        }

        // C. Enrich the displayed PRs with CI status in one batched call.
        let checks = try await fetchRollups(ghPath: ghPath, ids: results.map(\.id))
        results = results.map { pr in
            var copy = pr
            if let state = checks[pr.id] { copy.checks = state }
            return copy
        }

        // D. (optional) Fetch changed paths for review PRs to support folder filtering.
        if reviewPathFiltering {
            let reviewIDs = results.filter { $0.relation == .reviewRequested }.map(\.id)
            let paths = try await fetchChangedPaths(ghPath: ghPath, ids: reviewIDs)
            results = results.map { pr in
                guard pr.relation == .reviewRequested else { return pr }
                var copy = pr
                copy.changedPaths = paths[pr.id] ?? []
                return copy
            }
        }

        return results.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Batched CI rollup lookup. Returns a map of PR id -> CheckState.
    private func fetchRollups(ghPath: String, ids: [String]) async throws -> [String: CheckState] {
        guard !ids.isEmpty else { return [:] }
        // nodes(ids:) accepts up to 100; chunk to stay within bounds.
        var map: [String: CheckState] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let raw = try await runGraphQL(ghPath: ghPath, query: Self.rollupQuery(ids: chunk))
            let decoded = try decode(RollupResponse.self, from: raw)
            for node in decoded.data.nodes {
                guard let node, let id = node.id else { continue }
                map[id] = CheckState(rollup: node.rollupState)
            }
        }
        return map
    }

    /// Batched changed-paths lookup. Returns a map of PR id -> file paths.
    private func fetchChangedPaths(ghPath: String, ids: [String]) async throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        var map: [String: [String]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let raw = try await runGraphQL(ghPath: ghPath, query: Self.filesQuery(ids: chunk))
            let decoded = try decode(FilesResponse.self, from: raw)
            for node in decoded.data.nodes {
                guard let node, let id = node.id else { continue }
                map[id] = node.files?.nodes.compactMap { $0.path } ?? []
            }
        }
        return map
    }

    // MARK: - gh invocation

    private func runGraphQL(ghPath: String, query: String) async throws -> String {
        let base = ["api", "graphql", "-f", "query=\(query)"]
        let args = (ghPath == "env" ? ["gh"] : []) + base
        return try await run(executable: ghPath, arguments: args)
    }

    private func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let data = output.data(using: .utf8) else {
            throw GitHubError.decodeFailed("empty output")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decodeFailed(String(describing: error))
        }
    }

    /// Run an executable and return stdout, mapping failures to `GitHubError`.
    ///
    /// Pipes are drained continuously via `readabilityHandler`. Reading only in
    /// the termination handler deadlocks once output exceeds the OS pipe buffer
    /// (~64KB): the child blocks writing, never exits, and the handler never fires.
    private func run(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            if executable == "env" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            } else {
                process.executableURL = URL(fileURLWithPath: executable)
            }
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let path = environment["PATH"] ?? ""
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + path
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let bufferQueue = DispatchQueue(label: "github.process.buffers")
            var outData = Data()
            var errData = Data()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { bufferQueue.async { outData.append(chunk) } }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { bufferQueue.async { errData.append(chunk) } }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                bufferQueue.async {
                    let outString = String(data: outData, encoding: .utf8) ?? ""
                    let errString = String(data: errData, encoding: .utf8) ?? ""

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: outString)
                    } else {
                        let combined = errString.isEmpty ? outString : errString
                        if combined.lowercased().contains("authentication") || combined.lowercased().contains("gh auth login") {
                            continuation.resume(throwing: GitHubError.notAuthenticated)
                        } else {
                            continuation.resume(throwing: GitHubError.commandFailed(combined.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubError.ghNotFound)
            }
        }
    }
}

// MARK: - Response models

private struct InvolvesResponse: Decodable {
    struct DataBlock: Decodable {
        let viewer: Viewer
        let search: Search
    }
    struct Viewer: Decodable { let login: String }
    struct Search: Decodable { let nodes: [PRNode] }
    let data: DataBlock
}

private struct ReviewResponse: Decodable {
    struct DataBlock: Decodable { let search: Search }
    struct Search: Decodable { let nodes: [PRNode] }
    let data: DataBlock
}

private struct RollupResponse: Decodable {
    struct DataBlock: Decodable { let nodes: [RollupNode?] }
    let data: DataBlock
}

private struct RollupNode: Decodable {
    let id: String?
    let commits: Commits?

    var rollupState: String? {
        commits?.nodes.first?.commit?.statusCheckRollup?.state
    }

    struct Commits: Decodable { let nodes: [CommitNode] }
    struct CommitNode: Decodable { let commit: Commit? }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let state: String? }
}

private struct FilesResponse: Decodable {
    struct DataBlock: Decodable { let nodes: [FileNode?] }
    let data: DataBlock
}

private struct FileNode: Decodable {
    let id: String?
    let files: Files?
    struct Files: Decodable { let nodes: [PathNode] }
    struct PathNode: Decodable { let path: String? }
}

/// Decoded PR node shared by the involves and review searches.
private struct PRNode: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let url: String?
    let isDraft: Bool?
    let updatedAt: String?
    let reviewDecision: String?
    let mergeable: String?
    let repository: Repository?
    let author: Author?
    let commits: Commits?

    /// Whether the given login appears among any fetched commit's authors.
    func committed(by login: String) -> Bool {
        guard let nodes = commits?.nodes else { return false }
        for entry in nodes {
            for authorNode in entry.commit?.authors?.nodes ?? [] {
                if authorNode.user?.login?.caseInsensitiveCompare(login) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }

    struct Repository: Decodable { let nameWithOwner: String }
    struct Author: Decodable { let login: String }
    struct Commits: Decodable { let nodes: [CommitNode] }
    struct CommitNode: Decodable { let commit: Commit? }
    struct Commit: Decodable { let authors: Authors? }
    struct Authors: Decodable { let nodes: [AuthorNode] }
    struct AuthorNode: Decodable { let user: User? }
    struct User: Decodable { let login: String? }
}
