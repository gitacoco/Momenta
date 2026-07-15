import Foundation

/// Turns raw Toggl DTOs into domain `TimeEntry` values.
///
/// Key invariants (Time data semantics):
/// - Running entries arrive with `duration = -start_epoch` and `stop = nil`.
///   They normalize to an open interval (`stop = nil`); elapsed time is always
///   computed from `start`/`now`, so a negative duration can never be summed.
/// - Entries resolve to a client through their project; projects without a
///   client, unknown projects, and project-less entries are uncategorized.
/// - Toggl's returned data is the single source of truth: every fetch fully
///   replaces the month, so edits in Toggl win automatically.
enum TogglNormalizer {
    static func normalize(
        entries: [TogglTimeEntryDTO],
        projects: [TogglProjectDTO]
    ) -> [TimeEntry] {
        let clientByProject = Dictionary(
            projects.map { ($0.id, $0.clientId) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { dto in
            let clientID = dto.projectId.flatMap { clientByProject[$0] ?? nil }
            let stop: Date?
            if let explicitStop = dto.stop {
                stop = explicitStop
            } else if dto.duration >= 0 {
                // Defensive: a completed entry that lost its stop timestamp
                // still has a non-negative duration to reconstruct it from.
                stop = dto.start.addingTimeInterval(TimeInterval(dto.duration))
            } else {
                stop = nil // running
            }
            return TimeEntry(id: dto.id, clientID: clientID, start: dto.start, stop: stop)
        }
    }
}
