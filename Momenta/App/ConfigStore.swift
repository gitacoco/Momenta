import Foundation
import Observation

/// Persisted local client configuration. Toggl remains the source of truth
/// for client identity: `merge` reconciles the fetched Toggl client list into
/// local configs, and there is no way to create a client locally.
@MainActor
@Observable
final class ConfigStore {
    private static let storageKey = "momenta.clientConfigs"

    private let defaults: UserDefaults
    private(set) var clients: [ClientConfig] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ClientConfig].self, from: data) {
            clients = decoded
        }
    }

    // MARK: Updates

    func update(_ config: ClientConfig) {
        guard let index = clients.firstIndex(where: { $0.id == config.id }) else { return }
        clients[index] = config
        persist()
    }

    func client(id: Int) -> ClientConfig? {
        clients.first { $0.id == id }
    }

    /// Records a goal version. Default scope is "this month and onward":
    /// the version is written at `month`, any explicit versions in later
    /// months are replaced, and earlier months keep their recorded versions.
    /// With `retroactive`, every previously recorded month is overwritten too
    /// — only ever called after the user explicitly confirmed that.
    func setGoal(_ goal: MonthlyGoal, forClient clientID: Int, from month: YearMonth, retroactive: Bool) {
        guard var config = client(id: clientID) else { return }
        if retroactive {
            for key in config.goalHistory.keys {
                config.goalHistory[key] = goal
            }
        } else {
            for key in config.goalHistory.keys where key > month {
                config.goalHistory[key] = goal
            }
        }
        config.goalHistory[month] = goal
        update(config)
    }

    // MARK: Toggl reconciliation

    /// Merges the fetched Toggl client list into local configs:
    /// - new clients appear disabled (nothing enters the display unopted),
    /// - existing clients update identity fields but keep local config and,
    ///   crucially, their manual ordering,
    /// - clients gone from Toggl are kept as archived while local goal
    ///   history exists, otherwise dropped entirely.
    func merge(workspaces: [TogglWorkspace], togglClients: [TogglClientDTO]) {
        let workspaceNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let fetchedByID = Dictionary(uniqueKeysWithValues: togglClients.map { ($0.id, $0) })

        // Existing clients stay in their current (possibly user-arranged) order.
        var merged: [ClientConfig] = clients.compactMap { old in
            if let dto = fetchedByID[old.id] {
                var updated = old
                updated.togglName = dto.name
                updated.workspaceID = dto.wid
                updated.workspaceName = workspaceNames[dto.wid] ?? old.workspaceName
                updated.isArchivedInToggl = dto.archived == true
                return updated
            }
            guard !old.goalHistory.isEmpty else { return nil }
            var archived = old
            archived.isArchivedInToggl = true
            archived.isEnabled = false
            return archived
        }

        // Genuinely new clients append at the end, alphabetically per workspace.
        let knownIDs = Set(clients.map(\.id))
        let newcomers = togglClients
            .filter { !knownIDs.contains($0.id) }
            .sorted {
                (workspaceNames[$0.wid] ?? "", $0.name.lowercased())
                    < (workspaceNames[$1.wid] ?? "", $1.name.lowercased())
            }
            .map { dto in
                ClientConfig(
                    id: dto.id,
                    workspaceID: dto.wid,
                    workspaceName: workspaceNames[dto.wid] ?? "",
                    togglName: dto.name,
                    displayNameOverride: nil,
                    colorHex: Self.defaultColor(for: dto.id),
                    isEnabled: false,
                    isArchivedInToggl: dto.archived == true,
                    pacing: .weekdays,
                    goalHistory: [:]
                )
            }
        merged += newcomers

        clients = merged
        persist()
    }

    /// Reorders a displayed subset (one sidebar section) by drag and drop.
    /// `ids` is the subset in its current display order; positions of items
    /// outside the subset are untouched.
    func move(ids: [Int], fromOffsets: IndexSet, toOffset: Int) {
        var reordered = ids
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let members = Set(ids)
        var replacements = reordered.makeIterator()
        clients = clients.map { existing in
            guard members.contains(existing.id),
                  let nextID = replacements.next(),
                  let replacement = client(id: nextID) else { return existing }
            return replacement
        }
        persist()
    }

    // MARK: Plumbing

    private func persist() {
        if let data = try? JSONEncoder().encode(clients) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static let palette = [
        "#5B8DEF", "#F2994A", "#9B51E0", "#27AE60", "#EB5757",
        "#2D9CDB", "#F2C94C", "#BB6BD9", "#219653", "#56CCF2",
    ]

    static func defaultColor(for clientID: Int) -> String {
        palette[abs(clientID) % palette.count]
    }
}
