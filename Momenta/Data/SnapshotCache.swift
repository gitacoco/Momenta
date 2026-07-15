import Foundation

/// Disk persistence for month snapshots, so the last successful data stays
/// visible offline and across relaunches. One JSON file in App Support.
struct SnapshotCache: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Momenta", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appending(path: "snapshots.json")
        }
    }

    func load() -> [YearMonth: TimeEntrySnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([YearMonth: TimeEntrySnapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [YearMonth: TimeEntrySnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
