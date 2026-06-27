import SwiftUI
import SwiftData

struct LiveMatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let match: MatchRecord
    @Bindable var engine: MatchEngine
    @Query private var settings: [AppSettingsRecord]

    @State private var timer: Timer?
    @State private var pendingDraft: EventDraft?
    @State private var selectedTeamSide: TeamSide = .home
    @State private var selectedHomePlayerID: UUID?
    @State private var selectedOpponentPlayerID: UUID?
    @State private var showingMatchEndCard = false
    @State private var pendingConfirmation: LiveMatchConfirmation?
    @State private var pendingEventDeletion: MatchEventRecord?
    @State private var saveErrorMessage: String?
    @State private var playerSelectionMessage: String?
    @State private var headerMinY: CGFloat = 0
    @State private var lastClockSnapshotElapsedSeconds = 0

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private let clockSnapshotInterval = 15

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                quickActions
                controls
                recentTimeline
            }
            .padding(16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Live Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .coordinateSpace(name: "liveMatchScroll")
        .overlay(alignment: .top) {
            if showsCompactScorePill {
                CompactScorePill(match: match)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsCompactScorePill)
        .sheet(item: $pendingDraft) { draft in
            EventDetailSheet(draft: draft, match: match, playerTrackingMode: playerTrackingMode) { completedDraft in
                save(completedDraft)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingMatchEndCard) {
            MatchEndedCard(match: match) {
                dismiss()
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Confirm Action",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { confirmation in
            if confirmation == .finishRegulation {
                if match.homeScoreValue == match.awayScoreValue {
                    Button("End as Draw") {
                        perform(.endMatch)
                        pendingConfirmation = nil
                    }
                } else {
                    Button("Finish Match") {
                        perform(.endMatch)
                        pendingConfirmation = nil
                    }
                }
                Button("Start Extra Time") {
                    perform(.startExtraTime)
                    pendingConfirmation = nil
                }
                if match.homeScoreValue == match.awayScoreValue {
                    Button("Penalty Kicks") {
                        perform(.startPenaltyShootout)
                        pendingConfirmation = nil
                    }
                }
            } else if confirmation == .drawnMatchEnd {
                Button("End as Draw") {
                    perform(.endMatch)
                    pendingConfirmation = nil
                }
                Button("Penalty Kicks") {
                    perform(.startPenaltyShootout)
                    pendingConfirmation = nil
                }
            } else {
                Button(confirmation.actionTitle, role: confirmation.role) {
                    perform(confirmation)
                    pendingConfirmation = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message(for: match))
        }
        .confirmationDialog(
            "Delete Event",
            isPresented: Binding(
                get: { pendingEventDeletion != nil },
                set: { if !$0 { pendingEventDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingEventDeletion
        ) { event in
            Button("Delete Event", role: .destructive) {
                delete(event)
                pendingEventDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingEventDeletion = nil
            }
        } message: { event in
            Text(deleteMessage(for: event))
        }
        .alert("Couldn’t Save Match", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Try again.")
        }
        .alert("Select Player", isPresented: Binding(
            get: { playerSelectionMessage != nil },
            set: { if !$0 { playerSelectionMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playerSelectionMessage ?? "Choose a player before logging this event.")
        }
        .onAppear {
            engine.restore(match: match)
            normalizeSelectedPlayers(preferFirstActive: true)
            saveMatchState()
            startClock()
        }
        .onChange(of: selectedTeamSide) { _, _ in
            normalizeSelectedPlayers(preferFirstActive: true)
        }
        .onChange(of: playerSelectionFingerprint) { _, _ in
            normalizeSelectedPlayers(preferFirstActive: true)
        }
        .onChange(of: match.events.count) { _, _ in
            normalizeSelectedPlayers(preferFirstActive: true)
        }
        .onDisappear {
            timer?.invalidate()
            saveClockSnapshotIfNeeded(force: true)
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .inactive || newValue == .background {
                saveClockSnapshotIfNeeded(force: true)
            }
        }
        .onPreferenceChange(HeaderOffsetPreferenceKey.self) { headerMinY = $0 }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            ScoreboardHeaderView(match: match)
            teamSidePicker
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeaderOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named("liveMatchScroll")).minY
                )
            }
        )
    }

    private var teamSidePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Logging For")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Picker("Team Side", selection: $selectedTeamSide) {
                Text(match.displayTeamName).tag(TeamSide.home)
                Text(match.displayOpponentName).tag(TeamSide.opponent)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(match.isPenaltyShootoutActive ? "Penalty Kicks" : "Quick Actions")
                .font(.title3.weight(.semibold))

            if match.isPenaltyShootoutActive {
                shootoutActions
            } else if visibleActions.isEmpty {
                emptyStateLabel("No quick actions enabled for this match.")
            } else {
                playerFirstSelector
                if let substitutionText {
                    Text(substitutionText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleActions, id: \.self) { action in
                        QuickEventButton(eventType: action, detailAction: { openDetail(for: action) }) {
                            log(action)
                        }
                        .disabled(isQuickActionDisabled(action))
                    }
                }
                if visibleActions.contains(.substitution), !match.canUseSubstitution(for: selectedTeamSide) {
                    Text("No substitutions remaining for \(match.displayName(for: selectedTeamSide)).")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shootoutActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(match.compactScoreLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach([MatchEventType.penaltyScored, .penaltyMissed, .penaltySaved], id: \.self) { action in
                    QuickEventButton(eventType: action) {
                        logShootoutAttempt(action)
                    }
                    .disabled(match.isFinished)
                }
            }
        }
    }

    private var playerFirstSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill.badge.checkmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(match.accent.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Events Log To")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(selectedPlayerTitle)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                Text(match.displayName(for: selectedTeamSide))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if tracksPlayers, !selectablePlayersForSelectedTeam.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectablePlayersForSelectedTeam) { player in
                            PlayerSelectionChip(
                                player: player,
                                isSelected: selectedPlayer?.id == player.id,
                                accentColor: match.accent.color
                            ) {
                                setSelectedPlayerID(player.id, for: selectedTeamSide)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(playerSelectionHelpText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(match.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(match.accent.color.opacity(0.28), lineWidth: 1)
        )
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button(match.isLive ? "Pause" : "Resume") {
                    engine.togglePause()
                    saveMatchState()
                }
                .buttonStyle(.borderedProminent)
                .disabled(match.isFinished)

                Button("Undo Last") {
                    pendingConfirmation = .undoLast
                }
                .buttonStyle(.bordered)
                .disabled(match.isFinished || match.events.isEmpty)
            }

            HStack {
                Button(periodActionTitle) {
                    pendingConfirmation = periodConfirmation
                }
                .buttonStyle(.bordered)
                .disabled(match.isFinished)

                Button("End Match", role: .destructive) {
                    pendingConfirmation = .endMatch
                }
                .buttonStyle(.bordered)
                .disabled(match.isFinished)
            }
        }
    }

    private var recentTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Events")
                .font(.title3.weight(.semibold))

            let recentEvents = Array(match.events.sortedForRecentTimeline().prefix(10))
            if recentEvents.isEmpty {
                emptyStateLabel("No events logged yet.")
            } else {
                ForEach(recentEvents) { event in
                    SwipeDeleteTimelineRow(
                        event: event,
                        detailText: match.timelineDetailText(for: event),
                        allowsDelete: !match.isFinished,
                        onDelete: { pendingEventDeletion = event }
                    )
                    .contextMenu {
                        if !match.isFinished {
                            Button(role: .destructive) {
                                pendingEventDeletion = event
                            } label: {
                                Label("Delete Event", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyStateLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
            .padding(.horizontal, 12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var visibleActions: [MatchEventType] {
        MatchEventType.sanitizedTrackedEvents(from: match.trackedEventTypes)
    }

    private var quickActionConfiguration: QuickActionConfiguration {
        settings.preferredSettingsRecord?.quickActions ?? .init()
    }

    private var periodActionTitle: String {
        if match.isPenaltyShootoutActive {
            return "Finish Shootout"
        }
        if match.currentPeriodNumber < match.totalPeriodNumber {
            return match.currentPeriodNumber == MatchFormat.regulationPeriodCount && match.usesExtraTime
                ? "Start Extra Time"
                : "Next Period"
        }
        if match.homeScoreValue == match.awayScoreValue {
            return "Full Time"
        }
        return match.canStartExtraTimeFromRegulation ? "Full Time" : "Finish Match"
    }

    private var periodConfirmation: LiveMatchConfirmation {
        if match.isPenaltyShootoutActive {
            return .finishShootout
        }
        if match.canStartExtraTimeFromRegulation {
            return .finishRegulation
        }
        if match.currentPeriodNumber >= match.totalPeriodNumber, match.homeScoreValue == match.awayScoreValue {
            return .drawnMatchEnd
        }
        return .advanceHalf
    }

    private var substitutionText: String? {
        guard !match.substitutionsAreUnlimited else { return nil }
        return "Subs \(match.displayTeamName): \(match.substitutionCount(for: .home))/\(match.substitutionLimitValue) • \(match.displayOpponentName): \(match.substitutionCount(for: .opponent))/\(match.substitutionLimitValue)"
    }

    private var playerTrackingMode: PlayerTrackingMode {
        quickActionConfiguration.playerTrackingMode
    }

    private var tracksPlayers: Bool {
        playerTrackingMode != .off
    }

    private var selectedPlayer: PlayerRecord? {
        guard let selectedPlayerID = selectedPlayerID(for: selectedTeamSide) else { return nil }
        return selectablePlayersForSelectedTeam.first { $0.id == selectedPlayerID }
    }

    private var selectedPlayerTitle: String {
        guard tracksPlayers else { return "Team-level logging" }
        if let selectedPlayer {
            return playerLabel(for: selectedPlayer)
        }
        if playerTrackingMode == .required {
            return "Roster required"
        }
        if hasPlayersForSelectedTeam {
            return "Choose a player"
        }
        return "Team-level logging"
    }

    private var playerSelectionHelpText: String {
        if !tracksPlayers {
            return "Player tracking is off for quick actions."
        }
        if hasPlayersForSelectedTeam {
            return "Choose a player before logging an event."
        }
        if playerTrackingMode == .required {
            return "Player tracking is required, so add a player before logging events for this side."
        }
        return "No players are rostered for this side, so quick events log to the team."
    }

    private var selectablePlayersForSelectedTeam: [PlayerRecord] {
        selectablePlayers(for: selectedTeamSide)
    }

    private var playerSelectionFingerprint: String {
        match.players
            .map { "\($0.id.uuidString):\($0.validTeamSide?.rawValue ?? "invalid"):\($0.isStarter)" }
            .sorted()
            .joined(separator: "|")
    }

    private func log(_ eventType: MatchEventType) {
        guard !match.isFinished else { return }
        if eventType == .substitution {
            openDetail(for: eventType)
            return
        }

        if shouldBlockQuickLogForMissingPlayer {
            playerSelectionMessage = "Choose a \(match.displayName(for: selectedTeamSide)) player before logging \(eventType.title)."
            return
        }
        let playerID = playerIDForQuickLog()

        do {
            try engine.log(eventType: eventType, in: match, context: context, teamSide: selectedTeamSide, playerID: playerID)
            MatchSyncService.shared.broadcastMatchState(match)
        } catch {
            showSaveError(error)
        }
    }

    private func logShootoutAttempt(_ eventType: MatchEventType) {
        guard eventType.isShootoutAttempt, !match.isFinished else { return }
        do {
            try engine.log(eventType: eventType, in: match, context: context, teamSide: selectedTeamSide)
            MatchSyncService.shared.broadcastMatchState(match)
        } catch {
            showSaveError(error)
        }
    }

    private func isQuickActionDisabled(_ action: MatchEventType) -> Bool {
        match.isFinished
        || match.isPenaltyShootoutActive
        || (action == .substitution && !match.canUseSubstitution(for: selectedTeamSide))
    }

    private var hasPlayersForSelectedTeam: Bool {
        hasPlayers(for: selectedTeamSide)
    }

    private var shouldBlockQuickLogForMissingPlayer: Bool {
        guard tracksPlayers, selectedPlayer == nil else { return false }
        return playerTrackingMode == .required || hasPlayers(for: selectedTeamSide)
    }

    private func openDetail(for eventType: MatchEventType) {
        guard !match.isFinished else { return }
        pendingDraft = draft(for: eventType)
    }

    private func draft(for eventType: MatchEventType) -> EventDraft {
        var draft = EventDraft(type: eventType, teamSide: selectedTeamSide)
        if tracksPlayers, let selectedPlayerID = selectedPlayerID(for: selectedTeamSide) {
            draft.primaryPlayerID = selectedPlayerID
        }
        return draft
    }

    private func playerIDForQuickLog() -> UUID? {
        guard tracksPlayers, hasPlayers(for: selectedTeamSide) else {
            return nil
        }
        return selectedPlayer?.id
    }

    private func hasPlayers(for teamSide: TeamSide) -> Bool {
        match.players.contains { $0.validTeamSide == teamSide }
    }

    private func selectablePlayers(for teamSide: TeamSide) -> [PlayerRecord] {
        let sidePlayers = match.players
            .filter { $0.validTeamSide == teamSide }
            .sortedForPlayerSelection()
        let activePlayerIDs = match.liveActivePlayerIDs(for: teamSide)
        let activePlayers = sidePlayers.filter { activePlayerIDs.contains($0.id) }
        return activePlayers.isEmpty ? sidePlayers : activePlayers
    }

    private func selectedPlayerID(for teamSide: TeamSide) -> UUID? {
        switch teamSide {
        case .home:
            selectedHomePlayerID
        case .opponent:
            selectedOpponentPlayerID
        }
    }

    private func setSelectedPlayerID(_ playerID: UUID?, for teamSide: TeamSide) {
        switch teamSide {
        case .home:
            selectedHomePlayerID = playerID
        case .opponent:
            selectedOpponentPlayerID = playerID
        }
    }

    private func normalizeSelectedPlayers(preferFirstActive: Bool) {
        for teamSide in TeamSide.allCases {
            let selectablePlayers = selectablePlayers(for: teamSide)
            let selectedPlayerID = selectedPlayerID(for: teamSide)
            if let selectedPlayerID, selectablePlayers.contains(where: { $0.id == selectedPlayerID }) {
                continue
            }
            setSelectedPlayerID(preferFirstActive ? selectablePlayers.first?.id : nil, for: teamSide)
        }
    }

    private func rememberSelection(from draft: EventDraft) {
        if draft.type == .substitution, let playerOnID = draft.secondaryPlayerID {
            setSelectedPlayerID(playerOnID, for: draft.teamSide)
        } else if let primaryPlayerID = draft.primaryPlayerID {
            setSelectedPlayerID(primaryPlayerID, for: draft.teamSide)
        }
        normalizeSelectedPlayers(preferFirstActive: true)
    }

    private func playerLabel(for player: PlayerRecord) -> String {
        if let jerseyNumber = player.jerseyNumberValue {
            return "#\(jerseyNumber) \(player.displayName)"
        }
        return player.displayName
    }

    private func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard match.isLive, !match.isFinished else { return }
            Task { @MainActor in
                engine.tick()
                MatchSyncService.shared.broadcastMatchState(match)
                saveClockSnapshotIfNeeded()
            }
        }
    }

    private func perform(_ confirmation: LiveMatchConfirmation) {
        switch confirmation {
        case .undoLast:
            do {
                try engine.undoLastEvent(context: context)
                MatchSyncService.shared.broadcastMatchState(match)
            } catch {
                showSaveError(error)
            }
        case .advanceHalf:
            engine.advanceHalf()
            if saveMatchState(), match.isFinished {
                showingMatchEndCard = true
            }
        case .finishRegulation:
            break
        case .startExtraTime:
            engine.startExtraTime()
            _ = saveMatchState()
        case .startPenaltyShootout:
            engine.startPenaltyShootout()
            _ = saveMatchState()
        case .finishShootout:
            engine.finishPenaltyShootout()
            if saveMatchState(), match.isFinished {
                showingMatchEndCard = true
            }
        case .drawnMatchEnd:
            break
        case .endMatch:
            engine.endMatch()
            if saveMatchState() {
                showingMatchEndCard = true
            }
        }
    }

    @discardableResult
    private func save(_ draft: EventDraft) -> Bool {
        do {
            try engine.applyDraft(draft, to: match, context: context)
            rememberSelection(from: draft)
            MatchSyncService.shared.broadcastMatchState(match)
            return true
        } catch {
            showSaveError(error)
            return false
        }
    }

    private func delete(_ event: MatchEventRecord) {
        do {
            try engine.deleteEventGroup(containing: event, in: match, context: context)
            MatchSyncService.shared.broadcastMatchState(match)
        } catch {
            showSaveError(error)
        }
    }

    @discardableResult
    private func saveMatchState() -> Bool {
        do {
            try context.save()
            lastClockSnapshotElapsedSeconds = match.elapsedClockSeconds
            MatchSyncService.shared.broadcastMatchState(match)
            clearFinishedActiveMatchIfNeeded()
            return true
        } catch {
            context.rollback()
            showSaveError(error)
            return false
        }
    }

    @discardableResult
    private func saveClockSnapshotIfNeeded(force: Bool = false) -> Bool {
        guard !match.isFinished else { return true }
        let safeElapsedSeconds = match.elapsedClockSeconds
        guard force || safeElapsedSeconds - lastClockSnapshotElapsedSeconds >= clockSnapshotInterval else { return true }

        do {
            try context.save()
            lastClockSnapshotElapsedSeconds = safeElapsedSeconds
            return true
        } catch {
            context.rollback()
            showSaveError(error)
            return false
        }
    }

    private func clearFinishedActiveMatchIfNeeded() {
        engine.clearActiveMatchIfFinished(match)
    }

    private func showSaveError(_ error: Error) {
        saveErrorMessage = error.localizedDescription
    }

    private func deleteMessage(for event: MatchEventRecord) -> String {
        if linkedEvents(for: event).count > 1 {
            return "This removes this event and any event logged from the same tap."
        }
        return "This removes \(event.displayTitle) from the match timeline."
    }

    private func linkedEvents(for event: MatchEventRecord) -> [MatchEventRecord] {
        match.events.linkedEventGroup(containing: event)
    }

    private var showsCompactScorePill: Bool {
        headerMinY < -60
    }
}

private struct SwipeDeleteTimelineRow: View {
    let event: MatchEventRecord
    let detailText: String?
    let allowsDelete: Bool
    let onDelete: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var isTrackingHorizontalSwipe = false
    @State private var dragStartOffsetX: CGFloat = 0

    private let deleteWidth: CGFloat = 88
    private let deleteCommitTranslation: CGFloat = 108
    private let deleteCommitPredictedTranslation: CGFloat = 154

    var body: some View {
        ZStack(alignment: .trailing) {
            if allowsDelete {
                Button(role: .destructive) {
                    withAnimation(.snappy) {
                        offsetX = 0
                    }
                    onDelete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(.white)
                    .background(Color.red)
                }
                .buttonStyle(.plain)
            }

            TimelineRowView(event: event, detailText: detailText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .systemBackground))
                .offset(x: offsetX)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            guard allowsDelete else {
                                offsetX = 0
                                isTrackingHorizontalSwipe = false
                                dragStartOffsetX = 0
                                return
                            }
                            if !isTrackingHorizontalSwipe {
                                let horizontalMovement = abs(value.translation.width)
                                let verticalMovement = abs(value.translation.height)
                                guard horizontalMovement > verticalMovement else { return }
                                isTrackingHorizontalSwipe = true
                                dragStartOffsetX = offsetX
                            }
                            let proposedOffset = dragStartOffsetX + value.translation.width
                            offsetX = min(0, max(-deleteWidth, proposedOffset))
                        }
                        .onEnded { value in
                            defer {
                                isTrackingHorizontalSwipe = false
                                dragStartOffsetX = 0
                            }
                            guard allowsDelete else {
                                offsetX = 0
                                return
                            }
                            guard isTrackingHorizontalSwipe else { return }
                            let finalOffset = dragStartOffsetX + value.translation.width
                            let predictedOffset = dragStartOffsetX + value.predictedEndTranslation.width
                            let shouldCommitDelete = value.translation.width < -deleteCommitTranslation
                                || value.predictedEndTranslation.width < -deleteCommitPredictedTranslation
                            let shouldReveal = finalOffset < -deleteWidth / 2 || predictedOffset < -deleteWidth
                            withAnimation(.snappy) {
                                offsetX = shouldCommitDelete ? 0 : (shouldReveal ? -deleteWidth : 0)
                            }
                            if shouldCommitDelete {
                                onDelete()
                            }
                        }
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: offsetX)
        .onChange(of: allowsDelete) { _, canDelete in
            guard !canDelete else { return }
            isTrackingHorizontalSwipe = false
            dragStartOffsetX = 0
            withAnimation(.snappy) {
                offsetX = 0
            }
        }
    }
}

private struct PlayerSelectionChip: View {
    let player: PlayerRecord
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                }
                Text(label)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? .white : accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? accentColor : Color(uiColor: .systemBackground),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(accentColor.opacity(isSelected ? 0 : 0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(label), selected" : label)
    }

    private var label: String {
        if let jerseyNumber = player.jerseyNumberValue {
            return "#\(jerseyNumber) \(player.displayName)"
        }
        return player.displayName
    }
}

private struct EventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: EventDraft
    let match: MatchRecord
    let playerTrackingMode: PlayerTrackingMode
    let onSave: (EventDraft) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    Text(draft.type.title)
                    if tracksPlayers && !primaryPlayers.isEmpty {
                        Picker(primaryPlayerLabel, selection: $draft.primaryPlayerID) {
                            if !requiresPrimaryPlayer {
                                Text("Skip").tag(Optional<UUID>.none)
                            }
                            ForEach(primaryPlayers) { player in
                                Text(playerLabel(for: player)).tag(Optional(player.id))
                            }
                        }
                    }
                    if tracksPlayers && (showsAssistPicker || showsSecondaryPicker) && !secondaryPlayers.isEmpty {
                        Picker(secondaryPickerLabel, selection: $draft.secondaryPlayerID) {
                            if !requiresSecondaryPlayer {
                                Text("Skip").tag(Optional<UUID>.none)
                            }
                            ForEach(secondaryPlayers) { player in
                                Text(playerLabel(for: player)).tag(Optional(player.id))
                            }
                        }
                    }
                }

                if !tagOptions.isEmpty {
                    Section(contextSectionTitle) {
                        Picker(contextPickerLabel, selection: $draft.tag) {
                            ForEach(tagOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField(notesPlaceholder, text: $draft.note, axis: .vertical)
                }
            }
            .navigationTitle("Smart Detail")
            .onAppear {
                normalizeDraftSelections()
            }
            .onChange(of: draft.primaryPlayerID) { _, _ in
                normalizeDraftSelections()
            }
            .onChange(of: primaryPlayerIDs) { _, _ in
                normalizeDraftSelections()
            }
            .onChange(of: secondaryPlayerIDs) { _, _ in
                normalizeDraftSelections()
            }
            .onChange(of: playerTrackingMode) { _, _ in
                normalizeDraftSelections()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") {
                        if onSave(sanitizedDraft.withoutOptionalDetail) {
                            dismiss()
                        }
                    }
                    .disabled(requiresAnyPlayerSelection)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if onSave(sanitizedDraft) {
                            dismiss()
                        }
                    }
                    .disabled(requiresAnyPlayerSelection)
                }
            }
        }
    }

    private func playerLabel(for player: PlayerRecord) -> String {
        if let jerseyNumber = player.jerseyNumberValue {
            return "#\(jerseyNumber) \(player.displayName)"
        }
        return player.displayName
    }

    private var filteredPlayers: [PlayerRecord] {
        match.players
            .filter { $0.validTeamSide == draft.teamSide }
            .sortedForPlayerSelection()
    }

    private var activePlayers: [PlayerRecord] {
        let activeIDs = match.liveActivePlayerIDs(for: draft.teamSide)
        return filteredPlayers.filter { activeIDs.contains($0.id) }
    }

    private var selectableActivePlayers: [PlayerRecord] {
        activePlayers.isEmpty ? filteredPlayers : activePlayers
    }

    private var inactivePlayers: [PlayerRecord] {
        let activeIDs = Set(selectableActivePlayers.map(\.id))
        return filteredPlayers.filter { !activeIDs.contains($0.id) }
    }

    private var showsAssistPicker: Bool {
        draft.type == .goal
    }

    private var showsSecondaryPicker: Bool {
        draft.type == .substitution
    }

    private var tracksPlayers: Bool {
        playerTrackingMode != .off
    }

    private var requiresPrimaryPlayer: Bool {
        (playerTrackingMode == .required || requiresCompleteSubstitution)
        && !primaryPlayers.isEmpty
        && canRequirePlayerSelection
    }

    private var requiresSecondaryPlayer: Bool {
        (playerTrackingMode == .required || requiresCompleteSubstitution)
        && showsSecondaryPicker
        && !secondaryPlayers.isEmpty
        && canRequirePlayerSelection
    }

    private var requiresCompleteSubstitution: Bool {
        tracksPlayers && draft.type == .substitution
    }

    private var canRequirePlayerSelection: Bool {
        guard draft.type == .substitution else { return true }
        return !primaryPlayers.isEmpty && !inactivePlayers.isEmpty
    }

    private var requiresAnyPlayerSelection: Bool {
        (requiresPrimaryPlayer && !hasValidPrimaryPlayerSelection)
        || (requiresSecondaryPlayer && !hasValidSecondaryPlayerSelection)
    }

    private var hasValidPrimaryPlayerSelection: Bool {
        guard let primaryPlayerID = draft.primaryPlayerID else { return false }
        return primaryPlayers.contains { $0.id == primaryPlayerID }
    }

    private var hasValidSecondaryPlayerSelection: Bool {
        guard let secondaryPlayerID = draft.secondaryPlayerID else { return false }
        return secondaryPlayers.contains { $0.id == secondaryPlayerID }
    }

    private var sanitizedDraft: EventDraft {
        var sanitized = draft
        guard tracksPlayers else {
            sanitized.primaryPlayerID = nil
            sanitized.secondaryPlayerID = nil
            return sanitized
        }

        let validPrimaryIDs = Set(primaryPlayers.map(\.id))
        if let primaryPlayerID = sanitized.primaryPlayerID, !validPrimaryIDs.contains(primaryPlayerID) {
            sanitized.primaryPlayerID = nil
        }

        let validSecondaryIDs = Set(secondaryPlayers(forPrimaryPlayerID: sanitized.primaryPlayerID).map(\.id))
        if let secondaryPlayerID = sanitized.secondaryPlayerID, !validSecondaryIDs.contains(secondaryPlayerID) {
            sanitized.secondaryPlayerID = nil
        }

        if sanitized.type == .substitution, sanitized.primaryPlayerID == sanitized.secondaryPlayerID {
            sanitized.secondaryPlayerID = nil
        }
        if sanitized.type == .goal, sanitized.primaryPlayerID == sanitized.secondaryPlayerID {
            sanitized.secondaryPlayerID = nil
        }
        return sanitized
    }

    private var primaryPlayerLabel: String {
        switch draft.type {
        case .goal: "Scorer"
        case .ownGoal: "Responsible Player"
        case .substitution: "Player Off"
        default: "Primary Player"
        }
    }

    private var secondaryPickerLabel: String {
        draft.type == .substitution ? "Player On" : "Assist By"
    }

    private var tagOptions: [String] {
        switch draft.type {
        case .goal:
            ["Open Play", "Set Piece", "Penalty"]
        case .ownGoal:
            ["Open Play", "Set Piece", "Deflection"]
        case .shotOnTarget, .shotOffTarget:
            ["Open Play", "Set Piece", "Penalty"]
        case .foulCommitted:
            ["Trip", "Push", "Handball", "Hold", "Charge", "Dangerous Play", "Other"]
        case .keyPass, .assist, .cornerWon:
            ["Open Play", "Set Piece"]
        default:
            []
        }
    }

    private var contextSectionTitle: String {
        draft.type == .foulCommitted ? "What Kind?" : "Context"
    }

    private var contextPickerLabel: String {
        draft.type == .foulCommitted ? "Foul Type" : "Event Context"
    }

    private var notesPlaceholder: String {
        switch draft.type {
        case .substitution:
            "Optional note"
        default:
            "Notes"
        }
    }

    private var primaryPlayers: [PlayerRecord] {
        switch draft.type {
        case .substitution:
            return activePlayers
        default:
            return selectableActivePlayers
        }
    }

    private var secondaryPlayers: [PlayerRecord] {
        secondaryPlayers(forPrimaryPlayerID: draft.primaryPlayerID)
    }

    private var primaryPlayerIDs: [UUID] {
        primaryPlayers.map(\.id)
    }

    private var secondaryPlayerIDs: [UUID] {
        secondaryPlayers.map(\.id)
    }

    private func secondaryPlayers(forPrimaryPlayerID primaryPlayerID: UUID?) -> [PlayerRecord] {
        if draft.type == .substitution {
            let candidates = inactivePlayers
            guard let primaryPlayerID else { return candidates }
            return candidates.filter { $0.id != primaryPlayerID }
        }

        guard draft.type == .goal, let primaryPlayerID else {
            return selectableActivePlayers
        }
        return selectableActivePlayers.filter { $0.id != primaryPlayerID }
    }

    private func normalizeDraftSelections() {
        if let firstOption = tagOptions.first, !tagOptions.contains(draft.tag) {
            draft.tag = firstOption
        }

        guard tracksPlayers else {
            draft.primaryPlayerID = nil
            draft.secondaryPlayerID = nil
            return
        }

        if let primaryPlayerID = draft.primaryPlayerID,
           !primaryPlayers.contains(where: { $0.id == primaryPlayerID }) {
            draft.primaryPlayerID = nil
        }

        let validSecondaryIDs = Set(secondaryPlayers(forPrimaryPlayerID: draft.primaryPlayerID).map(\.id))
        if let secondaryPlayerID = draft.secondaryPlayerID,
           !validSecondaryIDs.contains(secondaryPlayerID) {
            draft.secondaryPlayerID = nil
        }
    }
}

private struct MatchEndedCard: View {
    let match: MatchRecord
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Match Finished")
                    .font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 8) {
                    Text(match.displayTitle)
                        .font(.headline)
                    Text(match.compactScoreLine)
                        .font(.title3.weight(.semibold))
                    Text("\(match.events.count) events logged")
                        .foregroundStyle(.secondary)
                    Text("Played on \(match.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button("Done") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Spacer()
            }
            .padding()
        }
    }
}

private enum LiveMatchConfirmation: Equatable {
    case undoLast
    case advanceHalf
    case finishRegulation
    case startExtraTime
    case startPenaltyShootout
    case finishShootout
    case drawnMatchEnd
    case endMatch

    var actionTitle: String {
        switch self {
        case .undoLast:
            "Undo Last Event"
        case .advanceHalf:
            "Continue"
        case .finishRegulation:
            "Full Time"
        case .startExtraTime:
            "Start Extra Time"
        case .startPenaltyShootout:
            "Penalty Kicks"
        case .finishShootout:
            "Finish Shootout"
        case .drawnMatchEnd:
            "Full Time"
        case .endMatch:
            "End Match"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .undoLast, .advanceHalf, .finishRegulation, .startExtraTime, .startPenaltyShootout, .finishShootout, .drawnMatchEnd:
            nil
        case .endMatch:
            .destructive
        }
    }

    func message(for match: MatchRecord) -> String {
        switch self {
        case .undoLast:
            return "This removes the most recent logged event and updates the score if needed."
        case .advanceHalf:
            if match.currentPeriodNumber < match.totalPeriodNumber {
                return "Move from \(match.currentHalfTitle) to \(MatchFormat.title(forPeriod: match.currentPeriodNumber + 1))."
            }
            return "This will finish the match and stop live logging."
        case .finishRegulation:
            return "Regulation is complete. Finish the match now or continue into extra time."
        case .startExtraTime:
            return "Start Extra Time 1 and keep the match clock running."
        case .startPenaltyShootout:
            return "Start penalty kicks. Shootout goals stay separate from the match score."
        case .finishShootout:
            return "Finish penalty kicks and close the match."
        case .drawnMatchEnd:
            return "The match is level. End it as a draw or continue to penalty kicks."
        case .endMatch:
            return "This will finish the match now and stop live logging."
        }
    }
}

private struct CompactScorePill: View {
    let match: MatchRecord

    var body: some View {
        HStack(spacing: 10) {
            Text(currentClock)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()

            Text(match.currentHalfShortTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 16)

            Text(match.displayTeamName)
                .lineLimit(1)

            Text("\(match.homeScoreValue)-\(match.awayScoreValue)")
                .font(.headline.weight(.bold))
                .monospacedDigit()

            Text(match.displayOpponentName)
                .lineLimit(1)

            if match.hasPenaltyShootout {
                Text("(\(match.homePenaltyScoreValue)-\(match.awayPenaltyScoreValue) pens)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(match.accent.color.opacity(0.22))
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding(.horizontal, 16)
    }

    private var currentClock: String {
        MatchFormat.clockText(forElapsedSeconds: match.elapsedClockSeconds)
    }
}

private struct HeaderOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
