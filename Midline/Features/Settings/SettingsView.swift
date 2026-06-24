import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var settings: [AppSettingsRecord]
    @Bindable var engine: MatchEngine
    @State private var saveErrorMessage: String?

    var body: some View {
        Form {
            if let settings = settings.preferredSettingsRecord {
                defaultsSection(settings)
                quickActionsSection(settings)
                appearanceSection(settings)
            }
        }
        .navigationTitle("Settings")
        .alert("Couldn’t Save Settings", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Try again.")
        }
        .task {
            prepareSettings()
        }
    }

    private func defaultsSection(_ settings: AppSettingsRecord) -> some View {
        Section("Defaults") {
            Stepper("Match duration: \(settings.defaultDurationMinuteValue) min", value: durationBinding(settings), in: MatchFormat.durationRange)
            Toggle("Extra Time", isOn: extraTimeEnabledBinding(settings))
            if settings.defaultUsesExtraTime {
                Stepper(
                    "Extra-time half: \(settings.defaultExtraTimeHalfDurationMinuteValue) min",
                    value: extraTimeHalfDurationBinding(settings),
                    in: MatchFormat.extraTimeHalfDurationRange
                )
            }
            Picker("Substitutions", selection: substitutionLimitModeBinding(settings)) {
                ForEach(SubstitutionLimitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if settings.defaultSubstitutionLimitMode == .limited {
                Stepper(
                    "Substitution limit: \(settings.defaultSubstitutionLimitValue)",
                    value: substitutionLimitBinding(settings),
                    in: MatchFormat.substitutionLimitRange
                )
            }

            Picker("Player Tracking", selection: quickActionsBinding(settings, \.playerTrackingMode)) {
                ForEach(PlayerTrackingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    private func quickActionsSection(_ settings: AppSettingsRecord) -> some View {
        Section("Quick Actions") {
            Toggle("Smart detail after tap", isOn: quickActionsBinding(settings, \.smartDetailEnabled))
            Toggle("Watch haptics", isOn: quickActionsBinding(settings, \.watchHapticsEnabled))

            if settings.quickActions.enabledActions.isEmpty {
                Text("New matches will start with no quick actions enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(MatchEventType.configurableQuickActions) { event in
                Toggle(event.title, isOn: Binding(
                    get: { settings.quickActions.enabledActions.contains(event) },
                    set: { enabled in
                        var config = settings.quickActions
                        if enabled {
                            config.enabledActions.append(event)
                        } else {
                            config.enabledActions.removeAll { $0 == event }
                        }
                        config.enabledActions = MatchEventType.sanitizedTrackedEvents(from: config.enabledActions)
                        settings.quickActions = config
                        save()
                    }
                ))
            }
        }
    }

    private func appearanceSection(_ settings: AppSettingsRecord) -> some View {
        Section("Appearance") {
            Picker("Accent", selection: bindTheme(settings)) {
                ForEach(AppThemeAccent.allCases) { accent in
                    Text(accent.title).tag(accent)
                }
            }
        }
    }

    private func bindTheme(_ settings: AppSettingsRecord) -> Binding<AppThemeAccent> {
        Binding(
            get: { settings.themeAccent },
            set: { settings.themeAccent = $0; save() }
        )
    }

    private func quickActionsBinding<T>(_ settings: AppSettingsRecord, _ keyPath: WritableKeyPath<QuickActionConfiguration, T>) -> Binding<T> {
        Binding(
            get: { settings.quickActions[keyPath: keyPath] },
            set: {
                var config = settings.quickActions
                config[keyPath: keyPath] = $0
                settings.quickActions = config
                save()
            }
        )
    }

    private func save() {
        do {
            try context.save()
            if let activeMatch = engine.activeMatch {
                MatchSyncService.shared.broadcastMatchState(activeMatch)
            }
        } catch {
            context.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }

    private func prepareSettings() {
        do {
            try PersistenceController.shared.prepareRequiredRecords(context: context)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func durationBinding(_ settings: AppSettingsRecord) -> Binding<Int> {
        Binding(
            get: { settings.defaultDurationMinuteValue },
            set: {
                settings.defaultDurationMinutes = MatchFormat.clampedDurationMinutes($0)
                save()
            }
        )
    }

    private func extraTimeEnabledBinding(_ settings: AppSettingsRecord) -> Binding<Bool> {
        Binding(
            get: { settings.defaultUsesExtraTime },
            set: {
                settings.defaultExtraTimeEnabled = $0
                settings.defaultNumberOfHalves = $0 ? MatchFormat.extraTimePeriodCount : MatchFormat.regulationPeriodCount
                settings.defaultExtraTimeHalfDurationMinutes = settings.defaultExtraTimeHalfDurationMinuteValue
                save()
            }
        )
    }

    private func extraTimeHalfDurationBinding(_ settings: AppSettingsRecord) -> Binding<Int> {
        Binding(
            get: { settings.defaultExtraTimeHalfDurationMinuteValue },
            set: {
                settings.defaultExtraTimeHalfDurationMinutes = MatchFormat.clampedExtraTimeHalfDurationMinutes($0)
                save()
            }
        )
    }

    private func substitutionLimitModeBinding(_ settings: AppSettingsRecord) -> Binding<SubstitutionLimitMode> {
        Binding(
            get: { settings.defaultSubstitutionLimitMode },
            set: {
                settings.defaultSubstitutionLimitMode = $0
                settings.defaultSubstitutionLimit = settings.defaultSubstitutionLimitValue
                save()
            }
        )
    }

    private func substitutionLimitBinding(_ settings: AppSettingsRecord) -> Binding<Int> {
        Binding(
            get: { settings.defaultSubstitutionLimitValue },
            set: {
                settings.defaultSubstitutionLimit = MatchFormat.clampedSubstitutionLimit($0)
                save()
            }
        )
    }
}
