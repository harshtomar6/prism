import Foundation

/// A pull request relevant to the current user, classified by how they relate to it.
struct PullRequest: Identifiable, Hashable {
    enum Relation: String {
        case authored = "Created"
        case committed = "Committed"
    }

    let id: String
    let number: Int
    let title: String
    let url: String
    let repo: String
    let author: String
    let isDraft: Bool
    let updatedAt: Date
    let relation: Relation
}
