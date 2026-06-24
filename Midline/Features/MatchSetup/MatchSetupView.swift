import SwiftUI
import SwiftData

struct MatchSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var settings: [AppSettingsRecord]

    @Bindable var engine: MatchEngine
    var quickMode: Bool
    private let setupDraft: MatchSetupDraft?

    @State private var title = ""
    @State private var teamName = "Midline FC"
    @State private var opponentName = ""
    @State private var date = Date()
    @State private var duration = 90
    @State private var extraTimeEnabled = false
    @State private var extraTimeHalfDuration = MatchFormat.defaultExtraTimeHalfDurationMinutes
    @State private var substitutionLimitMode = SubstitutionLimitMode.unlimited
    @State private var substitutionLimit = MatchFormat.defaultSubstitutionLimit
    @State private var accent = AppThemeAccent.stadiumGreen
    @State private var includePlayers = false
    @State private var homePlayers: [SetupPlayerDraft]
    @State private var opponentPlayers: [SetupPlayerDraft]
    @State private var trackedEvents = Set(MatchEventType.defaultQuickActions)
    @State private var saveErrorMessage: String?
    @State private var didApplySettingsDefaults = false

    private var canStart: Bool {
        MatchFormat.sanitizedNameText(teamName) != nil
        && MatchFormat.sanitizedNameText(opponentName) != nil
    }

    private var setupTeamDisplayName: String {
        MatchFormat.nameDisplayText(teamName, fallback: "Team")
    }

    private var setupOpponentDisplayName: String {
        MatchFormat.nameDisplayText(opponentName, fallback: "Opponent")
    }

    init(engine: MatchEngine, quickMode: Bool = false, setupDraft: MatchSetupDraft? = nil) {
        self.engine = engine
        self.quickMode = setupDraft?.isQuickMatch ?? quickMode
        self.setupDraft = setupDraft
        _title = State(initialValue: setupDraft?.title ?? "")
        _teamName = State(initialValue: setupDraft?.teamName ?? "Midline FC")
        _opponentName = State(initialValue: setupDraft?.opponentName ?? "")
        _date = State(initialValue: setupDraft?.date ?? Date())
        _duration = State(initialValue: MatchFormat.clampedDurationMinutes(setupDraft?.durationMinutes ?? 90))
        let draftExtraTimeEnabled = setupDraft?.extraTimeEnabled
            ?? (setupDraft.map { MatchFormat.clampedNumberOfPeriods($0.numberOfHalves) > MatchFormat.regulationPeriodCount } ?? false)
        _extraTimeEnabled = State(initialValue: draftExtraTimeEnabled)
        _extraTimeHalfDuration = State(initialValue: MatchFormat.clampedExtraTimeHalfDurationMinutes(
            setupDraft?.extraTimeHalfDurationMinutes ?? MatchFormat.defaultExtraTimeHalfDurationMinutes
        ))
        _substitutionLimitMode = State(initialValue: setupDraft?.substitutionLimitMode ?? .unlimited)
        _substitutionLimit = State(initialValue: MatchFormat.clampedSubstitutionLimit(
            setupDraft?.substitutionLimit ?? MatchFormat.defaultSubstitutionLimit
        ))
        _accent = State(initialValue: setupDraft?.accent ?? .stadiumGreen)
        _includePlayers = State(initialValue: setupDraft?.hasPlayers ?? false)
        _homePlayers = State(initialValue: Self.playerDrafts(from: setupDraft, teamSide: .home))
        _opponentPlayers = State(initialValue: Self.playerDrafts(from: setupDraft, teamSide: .opponent))
        _trackedEvents = State(initialValue: Set(setupDraft?.trackedEventTypes ?? MatchEventType.defaultQuickActions))
    }

    var body: some View {
        Form {
            Section("Match") {
                TextField("Match title", text: $title)
                TextField("Team name", text: $teamName)
                TextField("Opponent name", text: $opponentName)
                DatePicker("Date", selection: $date)
                if !canStart {
                    Text("Team and opponent are required to start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !quickMode {
                Section("Format") {
                    Stepper("Regulation: \(duration) min", value: $duration, in: MatchFormat.durationRange)
                    Toggle("Extra Time", isOn: $extraTimeEnabled)
                    if extraTimeEnabled {
                        Stepper(
                            "Extra-time half: \(extraTimeHalfDuration) min",
                            value: $extraTimeHalfDuration,
                            in: MatchFormat.extraTimeHalfDurationRange
                        )
                    }

                    Picker("Substitutions", selection: $substitutionLimitMode) {
                        ForEach(SubstitutionLimitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if substitutionLimitMode == .limited {
                        Stepper(
                            "Substitution limit: \(substitutionLimit)",
                            value: $substitutionLimit,
                            in: MatchFormat.substitutionLimitRange
                        )
                    }
                }

                Section("Players") {
                    Toggle("Add player list", isOn: includePlayersBinding)
                    if includePlayers {
                        VStack(alignment: .leading, spacing: 16) {
                            rosterSection(
                                title: setupTeamDisplayName,
                                accent: .blue,
                                players: $homePlayers,
                                defaultTeamSide: .home
                            )

                            rosterSection(
                                title: setupOpponentDisplayName,
                                accent: .orange,
                                players: $opponentPlayers,
                                defaultTeamSide: .opponent
                            )
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Tracked Events") {
                    if trackedEvents.isEmpty {
                        Text("This match will start with no quick actions enabled.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(MatchEventType.configurableQuickActions) { event in
                        Toggle(event.title, isOn: binding(for: event))
                    }
                }
            } else if trackedEvents.isEmpty {
                Section("Quick Actions") {
                    Text("This quick match will start with no quick actions enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(setupDraft == nil ? (quickMode ? "Quick Match" : "New Match") : "Duplicate Match")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Start") { createMatch() }
                    .disabled(!canStart)
            }
        }
        .alert("Couldn’t Start Match", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Try again.")
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            applySettingsDefaultsIfNeeded()
        }
        .onChange(of: settings.preferredSettingsRecord?.id) { _, _ in
            applySettingsDefaultsIfNeeded()
        }
    }

    private func binding(for event: MatchEventType) -> Binding<Bool> {
        .init(
            get: { trackedEvents.contains(event) },
            set: { isEnabled in
                if isEnabled {
                    trackedEvents.insert(event)
                } else {
                    trackedEvents.remove(event)
                }
            }
        )
    }

    private var includePlayersBinding: Binding<Bool> {
        .init(
            get: { includePlayers },
            set: { isIncluded in
                includePlayers = isIncluded
                if isIncluded {
                    seedRosterRowsIfNeeded()
                }
            }
        )
    }

    private func applySettingsDefaultsIfNeeded() {
        guard setupDraft == nil, !didApplySettingsDefaults, let settings = settings.preferredSettingsRecord else { return }
        duration = settings.defaultDurationMinuteValue
        extraTimeEnabled = settings.defaultUsesExtraTime
        extraTimeHalfDuration = settings.defaultExtraTimeHalfDurationMinuteValue
        substitutionLimitMode = settings.defaultSubstitutionLimitMode
        substitutionLimit = settings.defaultSubstitutionLimitValue
        accent = settings.themeAccent
        trackedEvents = Set(MatchEventType.sanitizedTrackedEvents(from: settings.quickActions.enabledActions))
        didApplySettingsDefaults = true
    }

    private func createMatch() {
        let cleanTeamName = MatchFormat.nameDisplayText(teamName, fallback: "")
        let cleanOpponentName = MatchFormat.nameDisplayText(opponentName, fallback: "")
        let cleanTitle = MatchFormat.sanitizedNameText(title)
        let previousActiveMatch = engine.activeMatch
        let previousActiveWasLive = previousActiveMatch?.isLive
        let match = MatchRecord(
            title: cleanTitle ?? "\(cleanTeamName) vs \(cleanOpponentName)",
            teamName: cleanTeamName,
            opponentName: cleanOpponentName,
            date: date,
            durationMinutes: MatchFormat.clampedDurationMinutes(duration),
            numberOfHalves: extraTimeEnabled ? MatchFormat.extraTimePeriodCount : MatchFormat.regulationPeriodCount,
            extraTimeEnabled: extraTimeEnabled,
            extraTimeHalfDurationMinutes: MatchFormat.clampedExtraTimeHalfDurationMinutes(extraTimeHalfDuration),
            substitutionLimitMode: substitutionLimitMode,
            substitutionLimit: MatchFormat.clampedSubstitutionLimit(substitutionLimit),
            isQuickMatch: quickMode,
            accent: accent,
            trackedEventTypes: MatchEventType.sanitizedTrackedEvents(from: trackedEvents)
        )

        if includePlayers {
            match.players = playerRecords(from: homePlayers + opponentPlayers, match: match)
        }

        context.insert(match)
        engine.start(match: match)
        do {
            try context.save()
            MatchSyncService.shared.broadcastMatchState(match)
            dismiss()
        } catch {
            context.rollback()
            engine.restoreActiveMatchAfterFailedStart(
                failedMatchID: match.id,
                previousActiveMatch: previousActiveMatch,
                previousActiveWasLive: previousActiveWasLive
            )
            saveErrorMessage = error.localizedDescription
        }
    }

    private func seedRosterRowsIfNeeded() {
        if homePlayers.isEmpty {
            homePlayers.append(SetupPlayerDraft(teamSide: .home))
        }
        if opponentPlayers.isEmpty {
            opponentPlayers.append(SetupPlayerDraft(teamSide: .opponent))
        }
    }

    private func playerRecords(from drafts: [SetupPlayerDraft], match: MatchRecord) -> [PlayerRecord] {
        drafts.compactMap { draft in
            guard let name = MatchFormat.sanitizedNameText(draft.name) else { return nil }
            return PlayerRecord(
                name: name,
                jerseyNumber: MatchFormat.jerseyNumber(fromText: draft.jerseyNumberText),
                position: draft.position,
                isStarter: draft.isStarter,
                teamSide: draft.teamSide,
                match: match
            )
        }
    }

    private static func playerDrafts(from setupDraft: MatchSetupDraft?, teamSide: TeamSide) -> [SetupPlayerDraft] {
        guard let setupDraft else { return [] }
        switch teamSide {
        case .home:
            return playerDrafts(
                startersText: setupDraft.homeStartingPlayersText,
                benchText: setupDraft.homeBenchPlayersText,
                teamSide: .home
            )
        case .opponent:
            return playerDrafts(
                startersText: setupDraft.opponentStartingPlayersText,
                benchText: setupDraft.opponentBenchPlayersText,
                teamSide: .opponent
            )
        }
    }

    private static func playerDrafts(startersText: String, benchText: String, teamSide: TeamSide) -> [SetupPlayerDraft] {
        parsePlayerDrafts(from: startersText, teamSide: teamSide, isStarter: true)
        + parsePlayerDrafts(from: benchText, teamSide: teamSide, isStarter: false)
    }

    private static func parsePlayerDrafts(from text: String, teamSide: TeamSide, isStarter: Bool) -> [SetupPlayerDraft] {
        MatchSetupPlayerLineParser.parseLines(in: text)
            .map { playerLine in
                SetupPlayerDraft(
                    name: playerLine.name,
                    jerseyNumberText: playerLine.jerseyNumberText,
                    position: playerLine.position,
                    isStarter: isStarter,
                    teamSide: teamSide
                )
            }
    }

    private func rosterSection(
        title: String,
        accent: Color,
        players: Binding<[SetupPlayerDraft]>,
        defaultTeamSide: TeamSide
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: "person.3.fill")
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
                Button {
                    players.wrappedValue.append(SetupPlayerDraft(teamSide: defaultTeamSide))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(.caption.weight(.semibold))
            }

            if players.wrappedValue.isEmpty {
                Text("No players yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(players) { $player in
                    PlayerDraftRow(player: $player) {
                        players.wrappedValue.removeAll { $0.id == player.id }
                    }
                }
            }
        }
        .padding(14)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SetupPlayerDraft: Identifiable, Hashable {
    let id: UUID
    var name: String
    var jerseyNumberText: String
    var position: PlayerPosition
    var isStarter: Bool
    var teamSide: TeamSide

    init(
        id: UUID = UUID(),
        name: String = "",
        jerseyNumberText: String = "",
        position: PlayerPosition = .utility,
        isStarter: Bool = true,
        teamSide: TeamSide
    ) {
        self.id = id
        self.name = name
        self.jerseyNumberText = jerseyNumberText
        self.position = position
        self.isStarter = isStarter
        self.teamSide = teamSide
    }
}

private struct PlayerDraftRow: View {
    @Binding var player: SetupPlayerDraft
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Player name", text: $player.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                TextField("#", text: $player.jerseyNumberText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 48)
                    .onChange(of: player.jerseyNumberText) { _, newValue in
                        player.jerseyNumberText = sanitizedJersey(from: newValue)
                    }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Picker("Position", selection: $player.position) {
                    ForEach(PlayerPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .labelsHidden()

                Toggle("Starter", isOn: $player.isStarter)
                    .toggleStyle(.switch)
                    .font(.subheadline)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sanitizedJersey(from value: String) -> String {
        MatchFormat.sanitizedJerseyNumberText(value)
    }
}
