import Foundation

/// Raw DTOs mirroring Toggl Track API v9 responses. Normalization into domain
/// types happens in BON-14's layer; these stay faithful to the wire format.

/// Response of `GET /me`. The API also returns the account's `api_token`
/// field; it is deliberately not modeled so it can never be held or logged.
struct TogglMe: Codable, Equatable, Sendable {
    var id: Int
    var fullname: String
    var email: String
    var defaultWorkspaceId: Int?
}

struct TogglWorkspace: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    /// Workspaces are billed and grouped through an organization. Older
    /// cached snapshots predate this field, so it stays optional.
    var organizationId: Int?

    init(id: Int, name: String, organizationId: Int? = nil) {
        self.id = id
        self.name = name
        self.organizationId = organizationId
    }
}

/// Subscription metadata belongs to an organization, not to the user account.
/// Only the stable fields needed by Settings are modeled.
struct TogglSubscription: Codable, Equatable, Sendable {
    var planName: String?
    var enterprise: Bool?

    init(planName: String? = nil, enterprise: Bool? = nil) {
        self.planName = planName
        self.enterprise = enterprise
    }
}

struct TogglOrganization: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var isMultiWorkspaceEnabled: Bool?
    var subscription: TogglSubscription?
    /// Deprecated API fields kept only as fallbacks for older Toggl responses.
    var pricingPlanName: String?
    var pricingPlanEnterprise: Bool?

    init(
        id: Int,
        name: String,
        isMultiWorkspaceEnabled: Bool? = nil,
        subscription: TogglSubscription? = nil,
        pricingPlanName: String? = nil,
        pricingPlanEnterprise: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.isMultiWorkspaceEnabled = isMultiWorkspaceEnabled
        self.subscription = subscription
        self.pricingPlanName = pricingPlanName
        self.pricingPlanEnterprise = pricingPlanEnterprise
    }

    var displayPlanName: String {
        if let name = subscription?.planName ?? pricingPlanName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return isEnterprise ? "Enterprise" : "Unknown"
    }

    var isEnterprise: Bool {
        if subscription?.enterprise == true || pricingPlanEnterprise == true {
            return true
        }
        let name = subscription?.planName ?? pricingPlanName
        return name?.localizedCaseInsensitiveCompare("Enterprise") == .orderedSame
    }

    var supportsMultipleWorkspaces: Bool {
        isMultiWorkspaceEnabled == true || isEnterprise
    }
}

/// A client as returned by `GET /workspaces/{id}/clients`.
struct TogglClientDTO: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var wid: Int
    var name: String
    var archived: Bool?
}

/// A project as returned by `GET /workspaces/{id}/projects`. Needed to map
/// time entries (which carry only `project_id`) up to their client.
struct TogglProjectDTO: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var workspaceId: Int
    var clientId: Int?
    var name: String
    var active: Bool
}

/// A time entry as returned by `GET /me/time_entries`. `duration` is passed
/// through raw: running entries carry `duration = -start_epoch` and a nil
/// `stop`; resolving that is the normalization layer's job (BON-14).
struct TogglTimeEntryDTO: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var workspaceId: Int
    var projectId: Int?
    var start: Date
    var stop: Date?
    /// Seconds; negative while the entry is running.
    var duration: Int
    var description: String?
}
