import SwiftUI

/// The tallest client row currently in the list.
///
/// A preference rather than per-row state: SwiftUI recomputes it from scratch
/// on every layout pass, so the maximum falls back down when the period switches
/// to shorter cards or the tallest client is disabled. A running `max` held in
/// state would only ever grow.
private struct TallestCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Reports this row's height towards the popover's card-count cap.
    func measuredAsClientCard() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: TallestCardHeightKey.self, value: proxy.size.height)
            }
        )
    }
}

/// Popover content: month navigation, unit toggle, client cards, warnings.
struct DashboardView: View {
    @Environment(AppState.self) private var appState

    /// Measured heights of the chrome around the scroll area, so the screen
    /// clamp tracks fonts, localization, and multi-line error footers instead
    /// of trusting an estimate.
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// Measured heights of the scroll area's own parts. The cap promises a
    /// number of client cards, so it has to be built from what a card and the
    /// Overall row actually render as — a written-down estimate goes stale the
    /// moment a card's metrics row, chart gutters, or fonts change.
    @State private var overallRowHeight: CGFloat = 0
    @State private var tallestCardHeight: CGFloat = 0

    /// Allowance for the popover parts outside this view: the arrow plus the
    /// system's margins against the menu bar and screen edges.
    private static let popoverArrowAllowance: CGFloat = 30

    /// How many client cards the popover shows before the list starts to
    /// scroll. Four is the working set most people keep enabled at once.
    private static let cardsBeforeScrolling = 4
    /// Must match the scroll content's `VStack` spacing and `padding`.
    private static let cardSpacing: CGFloat = 10
    private static let contentInset: CGFloat = 12
    private static let overallRowTopPadding: CGFloat = 2

    /// The height a list of exactly `cardsBeforeScrolling` cards occupies,
    /// derived from the measured parts rather than estimated beside them.
    ///
    /// Before the first measurement arrives there is nothing to derive from,
    /// so fall back to a height that clears four cards at system font sizes.
    private var preferredContentHeight: CGFloat {
        guard tallestCardHeight > 0 else { return 860 }
        let cards = CGFloat(Self.cardsBeforeScrolling)
        return Self.contentInset * 2
            + Self.overallRowTopPadding
            + overallRowHeight
            // One gap per card: Overall to the first, then between the rest.
            + cards * (tallestCardHeight + Self.cardSpacing)
    }

    /// The content remains scrollable for long client lists, but shorter
    /// lists report their natural height to the hosting controller.
    ///
    /// The cap sits at whatever four cards plus the Overall row measure, and is
    /// clamped to the status item's screen so a taller list can't grow the
    /// popover past the display it opens on.
    private var maximumContentHeight: CGFloat {
        let preferred = preferredContentHeight
        let chrome = headerHeight + footerHeight + 2 + Self.popoverArrowAllowance
        guard let screenHeight = appState.statusItemScreenVisibleHeight
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height
        else { return preferred }
        // No lower floor: a floor would be the one case that breaks the
        // promise this cap exists for. Real Macs leave 600pt+ after the
        // measured chrome, so it would only ever engage on a display where
        // honouring it means overflowing the screen.
        return max(0, min(preferred, screenHeight - chrome))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    headerHeight = $0
                }
            Divider()
            content
            Divider()
            footer
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    footerHeight = $0
                }
        }
        // Only the width is fixed. The hosting controller derives the
        // popover height from the view's actual content.
        .frame(width: 380)
        .task {
            // Only the explicit on-open mode may perform network work here.
            // Interval mode never starts network work from presentation.
            await appState.popoverDidOpen()
        }
    }

    // MARK: Header

    /// Navigation title at the active period's granularity.
    private var navTitle: String {
        switch appState.displaySettings.aggregationPeriod {
        case .day: return Format.dayTitle(appState.activeReference, timeZone: appState.timeZone)
        case .week: return Format.weekRange(appState.activeReference, timeZone: appState.timeZone)
        case .month: return Format.monthTitle(appState.selectedMonth, timeZone: appState.timeZone)
        }
    }

    private var header: some View {
        @Bindable var appState = appState
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button {
                    appState.stepBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!appState.canGoBackward)

                Text(navTitle)
                    .font(.headline)
                    // Widest possible title is a boundary-straddling week range
                    // (e.g. "Aug 28 – Sep 3", ~97pt); reserve just past it so the
                    // arrows never shift as the title changes.
                    .frame(minWidth: 100)

                Button {
                    appState.stepForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!appState.canGoForward)

                // BON-35: one-click return to the live period. Only meaningful
                // while historical (canGoForward), but kept in the layout via
                // opacity so the title and chevrons never shift as it appears.
                Button {
                    appState.resetReferenceToNow()
                } label: {
                    Image(systemName: "arrow.right.to.line")
                }
                .buttonStyle(.borderless)
                .help("Back to Today")
                .accessibilityLabel("Back to Today")
                .padding(.leading, 8)
                .opacity(appState.canGoForward ? 1 : 0)
                .disabled(!appState.canGoForward)
                .allowsHitTesting(appState.canGoForward)
                .accessibilityHidden(!appState.canGoForward)
            }

            Spacer()

            // No visible caption — the clock/$ glyphs read as hours vs revenue
            // on their own. The Picker keeps "Display goals in" as its
            // (hidden) accessibility label for VoiceOver.
            Picker("Display goals in", selection: $appState.displayUnit) {
                Image(systemName: "clock").tag(DisplayUnit.hours)
                Image(systemName: "dollarsign").tag(DisplayUnit.revenue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // SwiftUI exposes the selected segment as the single Tab stop on
            // macOS, but its generated segmented control does not move between
            // the image-only segments with the arrow keys. Handle the standard
            // group-navigation keys explicitly so both values remain keyboard
            // operable without adding another Tab stop.
            .onKeyPress(.leftArrow) {
                appState.displayUnit = .hours
                return .handled
            }
            .onKeyPress(.rightArrow) {
                appState.displayUnit = .revenue
                return .handled
            }
            .onKeyPress(.upArrow) {
                appState.displayUnit = .hours
                return .handled
            }
            .onKeyPress(.downArrow) {
                appState.displayUnit = .revenue
                return .handled
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if appState.visibleClients.isEmpty {
            EmptyStateView()
        } else {
            // The completeness gate: a straddled week with a missing past
            // month never renders partial numbers — it shows an explicit
            // pending state instead.
            switch appState.popoverData() {
            case .complete(let data):
                completeContent(data)
            case .loading(let missing):
                weekPendingCard(missing: missing, isLoading: true)
            case .unavailable(let missing):
                weekPendingCard(missing: missing, isLoading: false)
            }
        }
    }

    private func completeContent(_ data: AppState.PopoverData) -> some View {
        // One pass computed the month accrual, the period slices, and the
        // Overall; every row below reads from this shared snapshot.
        let period = appState.displaySettings.aggregationPeriod
        return ScrollView {
                VStack(spacing: Self.cardSpacing) {
                    // The Overall summary sits above the client cards for every
                    // period, following the h/$ toggle. Derived from the same
                    // slices the cards use, so nothing is computed twice.
                    if let overall = data.overall {
                        OverallRowView(
                            aggregate: overall,
                            unit: appState.displayUnit,
                            selectedPeriod: period,
                            onSelectPeriod: { selectedPeriod in
                                if selectedPeriod == appState.displaySettings.aggregationPeriod {
                                    appState.resetReferenceToNow()
                                } else {
                                    appState.displaySettings.aggregationPeriod = selectedPeriod
                                }
                            },
                            dayStyle: appState.displaySettings.dayViewStyle,
                            onSelectDayStyle: { style in
                                appState.displaySettings.dayViewStyle = style
                            }
                        )
                        .padding(.top, Self.overallRowTopPadding)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            // Measured without the top padding the cap adds
                            // back, so the two can't double-count it.
                            overallRowHeight = $0 - Self.overallRowTopPadding
                        }
                    }
                    if appState.selectedSnapshot == nil {
                        dataUnavailableBanner
                    }
                    if let uncategorized = appState.uncategorized, uncategorized.noClientHours > 0.05 {
                        uncategorizedBanner(hours: uncategorized.noClientHours)
                    }
                    // Revenue mode hides non-billable clients; when they are
                    // all there is, say so instead of showing a blank list.
                    if appState.visibleClientsForUnit.isEmpty, !appState.visibleClients.isEmpty {
                        nonBillableOnlyBanner
                    }
                    // Every enabled client gets a row — data (including
                    // rate-backfilled historical months), a setup prompt, or
                    // an explicit reason why there's nothing to show.
                    ForEach(appState.visibleClientsForUnit) { client in
                        if let card = cardData(client, period: period, monthProgress: data.progressByClientID, slices: data.sliceByClientID) {
                            ClientCardView(
                                data: card,
                                unit: appState.displayUnit,
                                dayStyle: appState.displaySettings.dayViewStyle,
                                // nil reference = following now (BON-21 semantics).
                                isCurrentPeriod: appState.selectedReference == nil,
                                // Whole days since 2001: stable within a day so
                                // the day card's rotating copy holds all day.
                                dailySeed: Int(appState.activeReference.timeIntervalSinceReferenceDate / 86_400),
                                onEditGoal: {
                                    appState.pendingSettingsDestination = .clients(clientID: client.id)
                                    openSettingsWindow()
                                }
                            )
                            .measuredAsClientCard()
                        } else if client.state(for: appState.selectedMonth) == .needsSetup {
                            setupCard(client)
                                .measuredAsClientCard()
                        } else if client.state(for: appState.selectedMonth) == .configured {
                            noDataCard(client)
                                .measuredAsClientCard()
                        }
                    }
                }
                .padding(Self.contentInset)
            }
            .onPreferenceChange(TallestCardHeightKey.self) { height in
                tallestCardHeight = height
            }
        // The frame caps long lists. `fixedSize` then asks the scroll
        // view for its ideal height, so short lists fit their content
        // instead of expanding to the cap.
        .frame(maxHeight: maximumContentHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Explicit pending state for a week whose past neighbour month isn't
    /// loaded: never a partial-denominator chart or ring.
    private func weekPendingCard(missing: Set<YearMonth>, isLoading: Bool) -> some View {
        let monthNames = missing.sorted()
            .map { Format.monthTitle($0, timeZone: appState.timeZone) }
            .joined(separator: ", ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading week data")
                        .font(.callout.weight(.semibold))
                    Text("Fetching \(monthNames) to complete this week.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week data incomplete")
                        .font(.callout.weight(.semibold))
                    Text("This week spans \(monthNames), which isn't loaded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Load") {
                    appState.prepareWeekNeighbors(userInitiated: true)
                }
                .disabled(appState.isLoading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isLoading ? Color.primary.opacity(0.04) : Color.orange.opacity(0.1))
        )
        .padding(12)
    }

    /// The period-appropriate data for a client's card, or nil when the client
    /// has no renderable progress for the shown period (setup / no-data rows
    /// fall through to their own cards).
    private func cardData(
        _ client: ClientConfig,
        period: AggregationPeriod,
        monthProgress: [Int: ClientProgress],
        slices: [Int: ClientPeriodSlice]
    ) -> ClientCardData? {
        switch period {
        case .month: return monthProgress[client.id].map(ClientCardData.month)
        case .day: return slices[client.id].map(ClientCardData.day)
        case .week: return slices[client.id].map(ClientCardData.week)
        }
    }

    /// Revenue mode with only non-billable clients: nothing earns money, so
    /// there are no cards — explain that instead of rendering an empty list.
    private var nonBillableOnlyBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "dollarsign.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No billable clients")
                    .font(.callout.weight(.semibold))
                Text("Your clients track hours only. Switch to hours to see them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show Hours") {
                appState.displayUnit = .hours
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// Shown when the selected month has no snapshot at all: the numbers
    /// aren't just empty, they're absent — say so and offer a retry.
    private var dataUnavailableBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No data for this month")
                    .font(.callout.weight(.semibold))
                Text(appState.dataUnavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                Task { await appState.refresh(force: true) }
            }
            .disabled(appState.isLoading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
    }

    /// A configured client whose data couldn't be loaded still shows up,
    /// with the reason, instead of silently vanishing.
    private func noDataCard(_ client: ClientConfig) -> some View {
        HStack(spacing: 8) {
            ClientAvatar(client: client, size: 16)
            Text(client.displayName)
                .font(.headline)
            Spacer()
            Text(appState.dataUnavailableReason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func setupCard(_ client: ClientConfig) -> some View {
        HStack(spacing: 8) {
            ClientAvatar(client: client, size: 16)
            Text(client.displayName)
                .font(.headline)
            Text(client.isBillable ? "needs a rate and goal" : "needs an hours goal")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Set up") {
                // Deep-link straight to this client's configuration.
                appState.pendingSettingsDestination = .clients(clientID: client.id)
                openSettingsWindow()
            }
            .font(.callout)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func uncategorizedBanner(hours: Decimal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("\(Format.hours(hours)) this month is not assigned to any client")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
    }

    // MARK: Footer

    private var footer: some View {
        // The outer stack carries no spacing of its own so the gap beside the
        // spacer can be set independently of the gaps inside each group.
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing…")
                        .foregroundStyle(.secondary)
                } else {
                    statusLine
                }
            }
            // Without this the stack hands the message and the spacer an
            // equal share of the free width, so the message wraps with room
            // still going spare. Priority sizes the message first; the spacer
            // takes what is genuinely left.
            .layoutPriority(1)

            // Collapsible to nothing, with 4pt of its own on each side: a
            // fully collapsed spacer still leaves 8pt between the message and
            // the controls.
            Spacer(minLength: 0)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Button {
                    // Manual refresh bypasses the throttle and refetches the
                    // selected historical month too.
                    Task { await appState.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .disabled(appState.isLoading)

                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens Momenta settings")
            }
        }
        // One environment font sizes the whole strip: status text, error
        // icons, and the Reconnect button all follow it.
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// One line that always tells the user how trustworthy the numbers are
    /// and what to do next.
    @ViewBuilder
    private var statusLine: some View {
        if let apiError = appState.lastAPIError {
            Image(systemName: apiError.statusIconName)
                .foregroundStyle(.orange)
            Text(staleSuffix(apiError.errorDescription ?? "Refresh failed"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if apiError == .unauthorized {
                Button("Reconnect") {
                    appState.pendingSettingsDestination = .account
                    openSettingsWindow()
                }
            }
        } else if let error = appState.lastError {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(staleSuffix(error))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if appState.isShowingStaleData {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            Text("Cached data — connect Toggl to refresh")
                .foregroundStyle(.secondary)
        } else if let fetchedAt = appState.selectedSnapshot?.fetchedAt {
            Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
        }
    }

    /// Failure messages mention that cached data is still being shown.
    private func staleSuffix(_ message: String) -> String {
        appState.selectedSnapshot != nil ? "\(message) Showing cached data." : message
    }
}

extension TogglAPIError {
    /// Status-line icon shared by the popover and the settings footer.
    var statusIconName: String {
        switch self {
        case .offline: return "wifi.slash"
        case .unauthorized: return "key.slash"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .server, .decoding, .other: return "exclamationmark.triangle"
        }
    }
}
