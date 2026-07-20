import Foundation
import Testing
@testable import Momenta

struct DisplaySettingsTests {
    @Test func legacySplitPreferenceMigrates() throws {
        for (split, expectedMode) in [
            (false, MenuBarObjectMode.aggregation),
            (true, MenuBarObjectMode.split),
        ] {
            let json = """
            {
              "aggregationPeriod": "week",
              "perClientSplit": \(split),
              "timeZoneIdentifier": "Pacific/Honolulu",
              "autoRefreshOnOpen": false
            }
            """

            let settings = try JSONDecoder().decode(
                DisplaySettings.self,
                from: Data(json.utf8)
            )

            #expect(settings.aggregationPeriod == .week)
            #expect(settings.menuBarObjectMode == expectedMode)
            #expect(settings.menuBarVisualization == .ring)
            #expect(settings.showsOverallPercentage == false)
            #expect(settings.timeZoneIdentifier == "Pacific/Honolulu")
            #expect(settings.autoRefreshOnOpen == false)
        }
    }

    @Test func newObjectModeWinsOverLegacyPreference() throws {
        let json = """
        {
          "aggregationPeriod": "day",
          "menuBarObjectMode": "both",
          "menuBarVisualization": "waterline",
          "showsOverallPercentage": true,
          "perClientSplit": false,
          "autoRefreshOnOpen": true
        }
        """

        let settings = try JSONDecoder().decode(
            DisplaySettings.self,
            from: Data(json.utf8)
        )

        #expect(settings.menuBarObjectMode == .both)
        #expect(settings.menuBarVisualization == .waterline)
        #expect(settings.showsOverallPercentage)
    }

    @Test func everyMenuBarCombinationRoundTrips() throws {
        var combinationCount = 0

        for mode in MenuBarObjectMode.allCases {
            for period in AggregationPeriod.allCases {
                for visualization in MenuBarVisualization.allCases {
                    var settings = DisplaySettings()
                    settings.menuBarObjectMode = mode
                    settings.aggregationPeriod = period
                    settings.menuBarVisualization = visualization
                    settings.showsOverallPercentage = true
                    settings.timeZoneIdentifier = "UTC"
                    settings.autoRefreshOnOpen = false

                    let data = try JSONEncoder().encode(settings)
                    let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)

                    #expect(decoded == settings)
                    combinationCount += 1
                }
            }
        }

        #expect(combinationCount == 18)
    }

    @Test func encodedSettingsDropLegacyKey() throws {
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .split

        let data = try JSONEncoder().encode(settings)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["perClientSplit"] == nil)
        #expect(object["menuBarObjectMode"] as? String == "split")
        #expect(object["menuBarVisualization"] as? String == "ring")
        #expect(object["showsOverallPercentage"] as? Bool == false)
    }

    @Test func unknownEnumValuesOnlyResetTheirOwnFields() throws {
        let json = """
        {
          "aggregationPeriod": "quarter",
          "menuBarObjectMode": "everything",
          "menuBarVisualization": "thermometer",
          "timeZoneIdentifier": "Pacific/Honolulu",
          "autoRefreshOnOpen": false
        }
        """

        let settings = try JSONDecoder().decode(
            DisplaySettings.self,
            from: Data(json.utf8)
        )

        #expect(settings.aggregationPeriod == .month)
        #expect(settings.menuBarObjectMode == .aggregation)
        #expect(settings.menuBarVisualization == .ring)
        #expect(settings.showsOverallPercentage == false)
        #expect(settings.timeZoneIdentifier == "Pacific/Honolulu")
        #expect(settings.autoRefreshOnOpen == false)
    }
}

struct MenuBarPresentationTests {
    private let month = YearMonth(year: 2026, month: 7)

    private func client(id: Int, name: String) -> ClientConfig {
        ClientConfig(
            id: id,
            workspaceID: 101,
            workspaceName: "Freelance",
            togglName: name,
            displayNameOverride: nil,
            colorHex: "#5B8DEF",
            isEnabled: true,
            isArchivedInToggl: false,
            pacing: .weekdays,
            goalHistory: [
                month: MonthlyGoal(hourlyRate: 100, input: .hours(80)),
            ]
        )
    }

    private var aggregate: AggregateProgress {
        AggregateProgress(shares: [
            .init(
                client: client(id: 1, name: "Cornerstone"),
                actualRevenue: 500,
                targetRevenue: 1_000
            ),
            .init(
                client: client(id: 2, name: "Providence"),
                actualRevenue: 750,
                targetRevenue: 1_000
            ),
        ])
    }

    @Test func allEighteenPresentationsUseTheRequestedAxes() {
        var combinationCount = 0

        for mode in MenuBarObjectMode.allCases {
            for period in AggregationPeriod.allCases {
                for visualization in MenuBarVisualization.allCases {
                    var settings = DisplaySettings()
                    settings.menuBarObjectMode = mode
                    settings.aggregationPeriod = period
                    settings.menuBarVisualization = visualization

                    let presentation = MenuBarPresentation(
                        aggregate: aggregate,
                        settings: settings,
                        unit: .revenue
                    )

                    #expect(presentation.objectMode == mode)
                    #expect(presentation.period == period)
                    #expect(presentation.visualization == visualization)
                    switch mode {
                    case .aggregation:
                        #expect(presentation.aggregation != nil)
                        #expect(presentation.clients.isEmpty)
                    case .split:
                        #expect(presentation.aggregation == nil)
                        #expect(presentation.clients.map(\.name) == ["Cornerstone", "Providence"])
                    case .both:
                        #expect(presentation.aggregation != nil)
                        #expect(presentation.clients.map(\.name) == ["Cornerstone", "Providence"])
                    }
                    combinationCount += 1
                }
            }
        }

        #expect(combinationCount == 18)
    }

    @Test func rawFractionsRemainTruthfulAndZeroTargetsAreUnavailable() {
        let progress = AggregateProgress(shares: [
            .init(
                client: client(id: 1, name: "Cornerstone"),
                actualRevenue: 150,
                targetRevenue: 100
            ),
            .init(
                client: client(id: 2, name: "Providence"),
                actualRevenue: 25,
                targetRevenue: 0
            ),
        ])
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .both

        let presentation = MenuBarPresentation(aggregate: progress, settings: settings, unit: .revenue)

        #expect(presentation.aggregation?.fraction == 1.75)
        #expect(presentation.clients[0].fraction == 1.5)
        #expect(presentation.clients[1].fraction == nil)
        #expect(presentation.accessibilityValue.contains("150%"))
        #expect(presentation.accessibilityValue.contains("no goal"))
    }

    @Test func overallPercentageOnlyAppearsWhenEnabledAndVisible() {
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .both

        var presentation = MenuBarPresentation(aggregate: aggregate, settings: settings, unit: .revenue)
        #expect(presentation.overallPercentageText == nil)

        settings.showsOverallPercentage = true
        presentation = MenuBarPresentation(aggregate: aggregate, settings: settings, unit: .revenue)
        #expect(presentation.overallPercentageText == "62%")

        settings.menuBarObjectMode = .split
        presentation = MenuBarPresentation(aggregate: aggregate, settings: settings, unit: .revenue)
        #expect(presentation.overallPercentageText == nil)
    }

    @Test func overallFollowsTheSharedDisplayUnit() {
        let progress = AggregateProgress(
            shares: aggregate.shares,
            overallActualHours: 10,
            overallTargetHours: 40,
            overallHoursTargetIsAvailable: true
        )
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .both
        settings.showsOverallPercentage = true

        let revenue = MenuBarPresentation(aggregate: progress, settings: settings, unit: .revenue)
        let hours = MenuBarPresentation(aggregate: progress, settings: settings, unit: .hours)

        #expect(revenue.aggregation?.fraction == 0.625)
        #expect(revenue.overallPercentageText == "62%")
        #expect(hours.aggregation?.fraction == 0.25)
        #expect(hours.overallPercentageText == "25%")
        #expect(hours.clients.map(\.fraction) == [0.5, 0.75])
    }

    @Test func completedZeroPaceRendersAsFullProgress() {
        let cornerstone = client(id: 1, name: "Cornerstone")
        let progress = AggregateProgress(shares: [
            .init(
                client: cornerstone,
                actualRevenue: 0,
                targetRevenue: 0,
                targetIsAvailable: true
            ),
        ])
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .both

        let presentation = MenuBarPresentation(aggregate: progress, settings: settings, unit: .revenue)

        #expect(presentation.aggregation?.fraction == 1)
        #expect(presentation.clients[0].fraction == 1)
    }

    @Test func missingProgressProducesOneNeutralState() {
        let presentation = MenuBarPresentation(
            aggregate: AggregateProgress(shares: []),
            settings: DisplaySettings(),
            unit: .hours
        )

        #expect(presentation.isEmpty)
        #expect(presentation.accessibilityValue == "This month, progress unavailable")
    }
}
