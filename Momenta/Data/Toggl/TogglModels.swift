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
