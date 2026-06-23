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
/// Authored PRs and committed-to PRs are derived from a single GraphQL search
/// over `involves:<login>`, then classified locally by inspecting each PR's
/// author and commit-author logins.
struct GitHubService {

    /// The GraphQL query. `$q` carries the search string so the login is never
    /// interpolated into the query body.
    private static let searchQuery = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 60) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            isDraft
            updatedAt
            repository { nameWithOwner }
            author { login }
            commits(first: 100) {
              nodes {
                commit {
                  authors(first: 10) {
                    nodes { user { login } }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Resolve the path to the `gh` executable, honouring common install locations.
    private func resolveGhPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH lookup via /usr/bin/env.
        return "env"
    }

    /// Fetch and classify all relevant open PRs.
    func fetchPullRequests() async throws -> [PullRequest] {
        let ghPath = resolveGhPath() ?? "gh"

        // First resolve the viewer login so we can scope the search to involves:<login>.
        let login = try await viewerLogin(ghPath: ghPath)
        let searchString = "is:open is:pr involves:\(login) archived:false"

        let arguments: [String]
        if ghPath == "env" {
            arguments = ["gh", "api", "graphql", "-f", "query=\(Self.searchQuery)", "-F", "q=\(searchString)"]
        } else {
            arguments = ["api", "graphql", "-f", "query=\(Self.searchQuery)", "-F", "q=\(searchString)"]
        }

        let output = try await run(executable: ghPath, arguments: arguments)
        return try parse(output, login: login)
    }

    /// Resolve the authenticated user's login.
    private func viewerLogin(ghPath: String) async throws -> String {
        let args: [String]
        if ghPath == "env" {
            args = ["gh", "api", "graphql", "-f", "query={ viewer { login } }"]
        } else {
            args = ["api", "graphql", "-f", "query={ viewer { login } }"]
        }
        let output = try await run(executable: ghPath, arguments: args)
        guard
            let data = output.data(using: .utf8),
            let root = try? JSONDecoder().decode(ViewerResponse.self, from: data)
        else {
            throw GitHubError.decodeFailed("viewer login")
        }
        return root.data.viewer.login
    }

    /// Decode the search payload and classify each PR.
    private func parse(_ output: String, login: String) throws -> [PullRequest] {
        guard let data = output.data(using: .utf8) else {
            throw GitHubError.decodeFailed("empty output")
        }

        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()

        let root: SearchResponse
        do {
            root = try decoder.decode(SearchResponse.self, from: data)
        } catch {
            throw GitHubError.decodeFailed(String(describing: error))
        }

        var results: [PullRequest] = []
        for node in root.data.search.nodes {
            // Inline fragment fields are absent for non-PR nodes; skip those.
            guard let id = node.id, let number = node.number else { continue }

            let authorLogin = node.author?.login ?? ""
            let relation: PullRequest.Relation
            if authorLogin.caseInsensitiveCompare(login) == .orderedSame {
                relation = .authored
            } else if node.committed(by: login) {
                relation = .committed
            } else {
                // Involved via comment/mention/assignment only — not requested.
                continue
            }

            let updated = node.updatedAt.flatMap { formatter.date(from: $0) } ?? Date.distantPast

            results.append(
                PullRequest(
                    id: id,
                    number: number,
                    title: node.title ?? "(no title)",
                    url: node.url ?? "",
                    repo: node.repository?.nameWithOwner ?? "",
                    author: authorLogin,
                    isDraft: node.isDraft ?? false,
                    updatedAt: updated,
                    relation: relation
                )
            )
        }

        return results.sorted { $0.updatedAt > $1.updatedAt }
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

            // Ensure Homebrew paths are visible when launched outside a shell.
            var environment = ProcessInfo.processInfo.environment
            let path = environment["PATH"] ?? ""
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + path
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Accumulate output as it streams so the child never blocks on a full pipe.
            // A serial queue serialises mutation of the buffers across handler callbacks.
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
                // Tear down handlers, then settle the buffer queue so all chunks are in.
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

private struct ViewerResponse: Decodable {
    struct DataBlock: Decodable { let viewer: Viewer }
    struct Viewer: Decodable { let login: String }
    let data: DataBlock
}

private struct SearchResponse: Decodable {
    struct DataBlock: Decodable { let search: Search }
    struct Search: Decodable { let nodes: [Node] }

    struct Node: Decodable {
        let id: String?
        let number: Int?
        let title: String?
        let url: String?
        let isDraft: Bool?
        let updatedAt: String?
        let repository: Repository?
        let author: Author?
        let commits: Commits?

        /// Whether the given login appears among any commit's authors.
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
    }

    struct Repository: Decodable { let nameWithOwner: String }
    struct Author: Decodable { let login: String }
    struct Commits: Decodable { let nodes: [CommitNode] }
    struct CommitNode: Decodable { let commit: Commit? }
    struct Commit: Decodable { let authors: Authors? }
    struct Authors: Decodable { let nodes: [AuthorNode] }
    struct AuthorNode: Decodable { let user: User? }
    struct User: Decodable { let login: String? }

    let data: DataBlock
}
