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
            // The legacy boolean maps onto the mode that replaced it.
            #expect(settings.refreshMode == .manual)
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
                    settings.refreshMode = .manual

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
        #expect(settings.refreshMode == .manual)
    }

    @Test func selectedCardStyleSurvivesEveryPeriodSwitchAndRoundTrip() throws {
        for style in ClientCardStyle.allCases {
            for startingPeriod in AggregationPeriod.allCases {
                var settings = DisplaySettings()
                settings.aggregationPeriod = startingPeriod
                settings.cardViewStyle = style

                for selectedPeriod in AggregationPeriod.allCases {
                    settings.aggregationPeriod = selectedPeriod
                    #expect(settings.cardViewStyle == style)
                    let decoded = try JSONDecoder().decode(
                        DisplaySettings.self,
                        from: JSONEncoder().encode(settings)
                    )
                    #expect(decoded.cardViewStyle == style)
                    #expect(decoded.aggregationPeriod == selectedPeriod)
                }
            }
        }
    }

    @Test func legacyCardStyleMigratesFromTheActivePeriod() throws {
        for period in AggregationPeriod.allCases {
            for style in ClientCardStyle.allCases {
                let otherStyle: ClientCardStyle = style == .capsule ? .timeline : .capsule
                var object = [
                    "aggregationPeriod": period.rawValue,
                    "dayViewStyle": otherStyle.rawValue,
                    "weekViewStyle": otherStyle.rawValue,
                    "monthViewStyle": otherStyle.rawValue,
                ]
                object["\(period.rawValue)ViewStyle"] = style.rawValue
                var settings = try JSONDecoder().decode(
                    DisplaySettings.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
                for selectedPeriod in AggregationPeriod.allCases {
                    settings.aggregationPeriod = selectedPeriod
                    #expect(settings.cardViewStyle == style)
                }
            }
        }
    }

    @Test func legacyMissingStyleKeepsThePreviouslyDisplayedDefault() throws {
        for period in AggregationPeriod.allCases {
            let settings = try JSONDecoder().decode(
                DisplaySettings.self,
                from: JSONSerialization.data(withJSONObject: ["aggregationPeriod": period.rawValue])
            )
            #expect(settings.cardViewStyle == (period == .day ? .capsule : .timeline))
        }
    }

    @Test func sharedCardStyleWinsOverLegacyPreferences() throws {
        let settings = try JSONDecoder().decode(
            DisplaySettings.self,
            from: Data(#"{"aggregationPeriod":"month","cardViewStyle":"capsule","monthViewStyle":"timeline"}"#.utf8)
        )
        #expect(settings.cardViewStyle == .capsule)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        #expect(object["cardViewStyle"] as? String == "capsule")
        #expect(object["dayViewStyle"] == nil)
        #expect(object["weekViewStyle"] == nil)
        #expect(object["monthViewStyle"] == nil)
    }

    @Test func invalidSharedCardStyleFallsBackWithoutResettingOtherSettings() throws {
        let settings = try JSONDecoder().decode(
            DisplaySettings.self,
            from: Data(#"{"aggregationPeriod":"week","cardViewStyle":"unknown","weekViewStyle":"capsule","refreshMode":"manual"}"#.utf8)
        )
        #expect(settings.cardViewStyle == .capsule)
        #expect(settings.aggregationPeriod == .week)
        #expect(settings.refreshMode == .manual)
    }

    @Test func refreshModeAndIntervalRoundTrip() throws {
        var settings = DisplaySettings()
        settings.refreshMode = .interval
        settings.refreshIntervalMinutes = 45

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)

        #expect(decoded.refreshMode == .interval)
        #expect(decoded.refreshIntervalMinutes == 45)
    }

    @Test func outOfRangeIntervalIsClampedOnDecode() throws {
        for (stored, expected) in [(1, 5), (10_000, 240)] {
            let json = """
            {
              "aggregationPeriod": "month",
              "refreshMode": "interval",
              "refreshIntervalMinutes": \(stored)
            }
            """

            let settings = try JSONDecoder().decode(
                DisplaySettings.self,
                from: Data(json.utf8)
            )

            #expect(settings.refreshMode == .interval)
            #expect(settings.refreshIntervalMinutes == expected)
        }
    }

    @Test func unknownRefreshModeFallsBackToLegacyBoolean() throws {
        let json = """
        {
          "aggregationPeriod": "month",
          "refreshMode": "hourly",
          "autoRefreshOnOpen": false
        }
        """

        let settings = try JSONDecoder().decode(
            DisplaySettings.self,
            from: Data(json.utf8)
        )

        #expect(settings.refreshMode == .manual)
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
                targetRevenue: 1_000,
                actualHours: 5,
                targetHours: 10
            ),
            .init(
                client: client(id: 2, name: "Providence"),
                actualRevenue: 750,
                targetRevenue: 1_000,
                actualHours: 7.5,
                targetHours: 10
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

    @Test func clientsOffTodayDrawNoRing() {
        let progress = AggregateProgress(shares: [
            // Off today: no target in either unit.
            .init(
                client: client(id: 1, name: "Cornerstone"),
                actualRevenue: 0,
                targetRevenue: 0,
                actualHours: 0,
                targetHours: 0,
                targetIsAvailable: false,
                hoursTargetIsAvailable: false
            ),
            // Scheduled today, nothing logged yet.
            .init(
                client: client(id: 2, name: "Self-career"),
                actualRevenue: 0,
                targetRevenue: 0,
                actualHours: 0,
                targetHours: 2,
                targetIsAvailable: false,
                hoursTargetIsAvailable: true
            ),
        ])
        var settings = DisplaySettings()
        settings.menuBarObjectMode = .split
        settings.aggregationPeriod = .day

        let presentation = MenuBarPresentation(aggregate: progress, settings: settings, unit: .hours)

        #expect(presentation.clients.map(\.name) == ["Self-career"])
        #expect(presentation.clients[0].fraction == 0)
        // The ring disappears, the client doesn't: VoiceOver still announces
        // it, as a planned day off rather than missing data.
        #expect(presentation.accessibilityValue.contains("Cornerstone, day off"))
        #expect(presentation.accessibilityValue.contains("Self-career 0%"))
    }

    @Test func rawFractionsRemainTruthfulAndTargetlessClientsAreOmitted() {
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
        // Over-100% stays truthful; the client with no target draws no ring
        // rather than an empty one indistinguishable from 0% — but VoiceOver
        // still announces it.
        #expect(presentation.clients.map(\.name) == ["Cornerstone"])
        #expect(presentation.clients[0].fraction == 1.5)
        #expect(presentation.accessibilityValue.contains("150%"))
        #expect(presentation.accessibilityValue.contains("Providence, no goal"))
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
