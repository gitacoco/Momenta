import Foundation
import Testing
@testable import Momenta

struct TogglNormalizerTests {
    private let projects = [
        TogglProjectDTO(id: 31, workspaceId: 101, clientId: 7, name: "Website", active: true),
        TogglProjectDTO(id: 32, workspaceId: 101, clientId: nil, name: "Internal", active: true),
    ]

    private func dto(
        id: Int = 1,
        projectId: Int? = 31,
        start: Date,
        stop: Date? = nil,
        duration: Int
    ) -> TogglTimeEntryDTO {
        TogglTimeEntryDTO(
            id: id, workspaceId: 101, projectId: projectId,
            start: start, stop: stop, duration: duration, description: nil
        )
    }

    @Test func runningEntryBecomesOpenInterval() {
        let start = Date(timeIntervalSince1970: 1_784_127_600)
        // Toggl running entry: duration = -start_epoch, stop = nil.
        let raw = dto(start: start, stop: nil, duration: -1_784_127_600)
        let normalized = TogglNormalizer.normalize(entries: [raw], projects: projects)[0]

        #expect(normalized.stop == nil)
        #expect(normalized.isRunning)
        // Elapsed is computed from now, never from the negative duration.
        let now = start.addingTimeInterval(2 * 3600)
        #expect(normalized.elapsed(asOf: now) == 2 * 3600)
        #expect(normalized.elapsed(asOf: start) == 0)
    }

    @Test func completedEntryKeepsExplicitStop() {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let stop = start.addingTimeInterval(3600)
        let normalized = TogglNormalizer.normalize(
            entries: [dto(start: start, stop: stop, duration: 3600)],
            projects: projects
        )[0]
        #expect(normalized.stop == stop)
        #expect(!normalized.isRunning)
    }

    @Test func completedEntryWithMissingStopReconstructsFromDuration() {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let normalized = TogglNormalizer.normalize(
            entries: [dto(start: start, stop: nil, duration: 5400)],
            projects: projects
        )[0]
        #expect(normalized.stop == start.addingTimeInterval(5400))
    }

    @Test func clientResolutionThroughProjects() {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let entries = TogglNormalizer.normalize(
            entries: [
                dto(id: 1, projectId: 31, start: start, duration: 60),   // project with client
                dto(id: 2, projectId: 32, start: start, duration: 60),   // project without client
                dto(id: 3, projectId: nil, start: start, duration: 60),  // no project
                dto(id: 4, projectId: 999, start: start, duration: 60),  // unknown project
            ],
            projects: projects
        )
        #expect(entries[0].clientID == 7)
        #expect(entries[1].clientID == nil)
        #expect(entries[2].clientID == nil)
        #expect(entries[3].clientID == nil)
    }
}
