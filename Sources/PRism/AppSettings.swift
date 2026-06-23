import Foundation
import Combine

/// User-configurable settings, persisted to `UserDefaults`.
///
/// Currently scopes the *Needs my review* list by repository and by changed
/// folder/path. A review PR is shown only when it satisfies every active filter
/// type (repo AND path); within a type, matching any entry is enough.
@MainActor
final class AppSettings: ObservableObject {
    @Published var reviewRepoFilters: [String] { didSet { persist() } }
    @Published var reviewPathFilters: [String] { didSet { persist() } }

    private let repoKey = "prism.reviewRepoFilters"
    private let pathKey = "prism.reviewPathFilters"
    private let defaults = UserDefaults.standard
    private let persisting: Bool

    init(persisting: Bool = true) {
        // Set before the @Published assignments so didSet's persist() is gated.
        self.persisting = persisting
        reviewRepoFilters = defaults.stringArray(forKey: repoKey) ?? []
        reviewPathFilters = defaults.stringArray(forKey: pathKey) ?? []
    }

    #if DEBUG
    /// A non-persisting instance pre-seeded with sample filters, for screenshots.
    static func previewSeeded() -> AppSettings {
        let settings = AppSettings(persisting: false)
        settings.reviewRepoFilters = ["marketplace-backend"]
        settings.reviewPathFilters = ["apps/ad-publishing"]
        return settings
    }
    #endif

    var hasPathFilters: Bool { !reviewPathFilters.isEmpty }
    var hasAnyReviewFilter: Bool { !reviewRepoFilters.isEmpty || !reviewPathFilters.isEmpty }

    func addRepo(_ value: String) { add(clean(value), to: \.reviewRepoFilters) }
    func removeRepo(_ value: String) { reviewRepoFilters.removeAll { $0 == value } }
    func addPath(_ value: String) { add(clean(value), to: \.reviewPathFilters) }
    func removePath(_ value: String) { reviewPathFilters.removeAll { $0 == value } }

    /// Whether a review PR passes the active filters.
    func keepReview(_ pr: PullRequest) -> Bool {
        let repoOK = reviewRepoFilters.isEmpty
            || reviewRepoFilters.contains { pr.repo.range(of: $0, options: .caseInsensitive) != nil }
        let pathOK = reviewPathFilters.isEmpty
            || pr.changedPaths.contains { path in
                reviewPathFilters.contains { path.range(of: $0, options: .caseInsensitive) != nil }
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
        defaults.set(reviewRepoFilters, forKey: repoKey)
        defaults.set(reviewPathFilters, forKey: pathKey)
    }
}
