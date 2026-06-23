import Foundation

/// CI / status-check rollup state for a PR's latest commit.
enum CheckState {
    case success
    case failure
    case pending
    case none

    init(rollup: String?) {
        switch rollup {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: self = .none
        }
    }
}

/// Aggregate review decision on a PR.
enum ReviewState {
    case approved
    case changesRequested
    case reviewRequired
    case none

    init(decision: String?) {
        switch decision {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: self = .none
        }
    }
}

/// Whether GitHub can merge the PR cleanly.
enum MergeState {
    case mergeable
    case conflicting
    case unknown

    init(mergeable: String?) {
        switch mergeable {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        default: self = .unknown
        }
    }
}

/// A pull request relevant to the current user, classified by how they relate to it.
struct PullRequest: Identifiable, Hashable {
    enum Relation: String {
        case reviewRequested = "Needs my review"
        case authored = "Created by me"
        case committed = "Committed to"
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
    var checks: CheckState
    let review: ReviewState
    let merge: MergeState

    /// Set by the store: PR has activity newer than the last time the user looked.
    var isUnread: Bool = false
}
