import Foundation
import Combine

/// User-configurable settings, persisted to `UserDefaults`.
///
/// Scopes every PR section by repository and by changed folder/path. A PR is
/// shown only when it satisfies every active filter type (repo AND path); within
/// a type, matching any entry is enough.
@MainActor
final class AppSettings: ObservableObject {
    @Published var repoFilters: [String] { didSet { persist() } }
    @Published var pathFilters: [String] { didSet { persist() } }

    private let repoKey = "prism.repoFilters"
    private let pathKey = "prism.pathFilters"
    // Legacy keys (filters used to be review-only); read once for migration.
    private let legacyRepoKey = "prism.reviewRepoFilters"
    private let legacyPathKey = "prism.reviewPathFilters"
    private let defaults = UserDefaults.standard
    private let persisting: Bool

    init(persisting: Bool = true) {
        // Set before the @Published assignments so didSet's persist() is gated.
        self.persisting = persisting
        repoFilters = defaults.stringArray(forKey: repoKey) ?? defaults.stringArray(forKey: legacyRepoKey) ?? []
        pathFilters = defaults.stringArray(forKey: pathKey) ?? defaults.stringArray(forKey: legacyPathKey) ?? []
    }

    #if DEBUG
    /// A non-persisting instance pre-seeded with sample filters, for screenshots.
    static func previewSeeded() -> AppSettings {
        let settings = AppSettings(persisting: false)
        settings.repoFilters = ["marketplace-backend"]
        settings.pathFilters = ["apps/ad-publishing"]
        return settings
    }
    #endif

    var hasPathFilters: Bool { !pathFilters.isEmpty }
    var hasAnyFilter: Bool { !repoFilters.isEmpty || !pathFilters.isEmpty }

    func addRepo(_ value: String) { add(clean(value), to: \.repoFilters) }
    func removeRepo(_ value: String) { repoFilters.removeAll { $0 == value } }
    func addPath(_ value: String) { add(clean(value), to: \.pathFilters) }
    func removePath(_ value: String) { pathFilters.removeAll { $0 == value } }

    /// Whether a PR passes the active filters.
    func keep(_ pr: PullRequest) -> Bool {
        let repoOK = repoFilters.isEmpty
            || repoFilters.contains { pr.repo.range(of: $0, options: .caseInsensitive) != nil }
        let pathOK = pathFilters.isEmpty
            || pr.changedPaths.contains { path in
                pathFilters.contains { path.range(of: $0, options: .caseInsensitive) != nil }
            }
        return repoOK && pathOK
    }

    private func add(_ value: String, to keyPath: ReferenceWritableKeyPath<AppSettings, [String]>) {
        guard !value.isEmpty, !self[keyPath: keyPath].contains(value) else { return }
        self[keyPath: keyPath].append(value)
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() {
        guard persisting else { return }
        defaults.set(repoFilters, forKey: repoKey)
        defaults.set(pathFilters, forKey: pathKey)
    }
}
