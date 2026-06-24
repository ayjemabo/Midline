import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        let schema = Schema(versionedSchema: MidlineSchemaV4.self)

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: MidlineMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    func prepareRequiredRecords(context: ModelContext) throws {
        let matchRecords = try context.fetch(FetchDescriptor<MatchRecord>())
        for matchRecord in matchRecords {
            matchRecord.normalizePersistedValues()
        }

        let eventRecords = try context.fetch(FetchDescriptor<MatchEventRecord>())
        for eventRecord in eventRecords {
            eventRecord.normalizePersistedValues()
        }

        let settingsRecords = try context.fetch(FetchDescriptor<AppSettingsRecord>())
        if settingsRecords.isEmpty {
            context.insert(AppSettingsRecord())
        } else if let settingsRecord = settingsRecords.preferredSettingsRecord {
            settingsRecord.normalizePersistedValues()
            for duplicateSettings in settingsRecords where duplicateSettings.id != settingsRecord.id {
                context.delete(duplicateSettings)
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum MidlineMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            MidlineSchemaV1.self,
            MidlineSchemaV4.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MidlineSchemaV1.self, toVersion: MidlineSchemaV4.self)
        ]
    }
}

enum MidlineSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            MatchRecord.self,
            PlayerRecord.self,
            MatchEventRecord.self,
            AppSettingsRecord.self
        ]
    }
}

enum MidlineSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            MatchRecord.self,
            PlayerRecord.self,
            MatchEventRecord.self,
            AppSettingsRecord.self
        ]
    }

    @Model
    final class MatchRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var teamName: String
        var opponentName: String
        var date: Date
        var durationMinutes: Int
        var numberOfHalves: Int
        var isQuickMatch: Bool
        var currentHalf: Int
        var homeScore: Int
        var awayScore: Int
        var elapsedSeconds: Int
        var isLive: Bool
        var isFinished: Bool
        var accentRawValue: String
        @Relationship(deleteRule: .cascade, inverse: \PlayerRecord.match) var players: [PlayerRecord] = []
        @Relationship(deleteRule: .cascade, inverse: \MatchEventRecord.match) var events: [MatchEventRecord] = []

        init(
            id: UUID = UUID(),
            title: String,
            teamName: String,
            opponentName: String,
            date: Date = .now,
            durationMinutes: Int = 90,
            numberOfHalves: Int = 2,
            isQuickMatch: Bool = false,
            currentHalf: Int = 1,
            homeScore: Int = 0,
            awayScore: Int = 0,
            elapsedSeconds: Int = 0,
            isLive: Bool = true,
            isFinished: Bool = false,
            accentRawValue: String = AppThemeAccent.stadiumGreen.rawValue
        ) {
            self.id = id
            self.title = title
            self.teamName = teamName
            self.opponentName = opponentName
            self.date = date
            self.durationMinutes = durationMinutes
            self.numberOfHalves = numberOfHalves
            self.isQuickMatch = isQuickMatch
            self.currentHalf = currentHalf
            self.homeScore = homeScore
            self.awayScore = awayScore
            self.elapsedSeconds = elapsedSeconds
            self.isLive = isLive
            self.isFinished = isFinished
            self.accentRawValue = accentRawValue
        }
    }

    @Model
    final class PlayerRecord {
        @Attribute(.unique) var id: UUID
        var name: String
        var jerseyNumber: Int?
        var positionRawValue: String
        var isFavorite: Bool
        var isPinned: Bool
        var isStarter: Bool
        var teamSideRawValue: String
        var match: MatchRecord?

        init(
            id: UUID = UUID(),
            name: String,
            jerseyNumber: Int? = nil,
            positionRawValue: String = PlayerPosition.utility.rawValue,
            isFavorite: Bool = false,
            isPinned: Bool = false,
            isStarter: Bool = true,
            teamSideRawValue: String = TeamSide.home.rawValue,
            match: MatchRecord? = nil
        ) {
            self.id = id
            self.name = name
            self.jerseyNumber = jerseyNumber
            self.positionRawValue = positionRawValue
            self.isFavorite = isFavorite
            self.isPinned = isPinned
            self.isStarter = isStarter
            self.teamSideRawValue = teamSideRawValue
            self.match = match
        }
    }

    @Model
    final class MatchEventRecord {
        @Attribute(.unique) var id: UUID
        var timestamp: Date
        var matchMinute: Int
        var periodRawValue: String
        var eventTypeRawValue: String
        var teamSideRawValue: String
        var playerID: UUID?
        var secondaryPlayerID: UUID?
        var linkedGroupID: UUID?
        var notes: String?
        var pitchX: Double?
        var pitchY: Double?
        var match: MatchRecord?

        init(
            id: UUID = UUID(),
            timestamp: Date = .now,
            matchMinute: Int,
            periodRawValue: String = MatchPeriod.firstHalf.rawValue,
            eventTypeRawValue: String = MatchEventType.goal.rawValue,
            teamSideRawValue: String = TeamSide.home.rawValue,
            playerID: UUID? = nil,
            secondaryPlayerID: UUID? = nil,
            linkedGroupID: UUID? = nil,
            notes: String? = nil,
            pitchX: Double? = nil,
            pitchY: Double? = nil,
            match: MatchRecord? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.matchMinute = matchMinute
            self.periodRawValue = periodRawValue
            self.eventTypeRawValue = eventTypeRawValue
            self.teamSideRawValue = teamSideRawValue
            self.playerID = playerID
            self.secondaryPlayerID = secondaryPlayerID
            self.linkedGroupID = linkedGroupID
            self.notes = notes
            self.pitchX = pitchX
            self.pitchY = pitchY
            self.match = match
        }
    }

    @Model
    final class AppSettingsRecord {
        @Attribute(.unique) var id: UUID
        var defaultDurationMinutes: Int
        var defaultNumberOfHalves: Int
        var themeAccentRawValue: String
        var quickActionsData: Data

        init(
            id: UUID = UUID(),
            defaultDurationMinutes: Int = 90,
            defaultNumberOfHalves: Int = 2,
            themeAccentRawValue: String = AppThemeAccent.stadiumGreen.rawValue,
            quickActionsData: Data = Data()
        ) {
            self.id = id
            self.defaultDurationMinutes = defaultDurationMinutes
            self.defaultNumberOfHalves = defaultNumberOfHalves
            self.themeAccentRawValue = themeAccentRawValue
            self.quickActionsData = quickActionsData
        }
    }
}
