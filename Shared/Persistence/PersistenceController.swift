import Foundation
import OSLog
import SQLite3
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer
    let launchIssueMessage: String?

    private static let logger = Logger(subsystem: "com.albaraa.Midline", category: "Persistence")

    init(inMemory: Bool = false) {
        let schema = Schema(versionedSchema: MidlineSchemaV6.self)
        let primaryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        var diagnostics = [String]()

        Self.log("Starting SwiftData container setup. inMemory=\(inMemory)", diagnostics: &diagnostics)

        if !inMemory,
           let recovered = Self.openRecoveredStoreIfAvailable(schema: schema, primaryURL: primaryConfiguration.url, diagnostics: &diagnostics) {
            container = recovered
            launchIssueMessage = nil
            return
        }

        if let primary = Self.openContainer(
            schema: schema,
            configuration: primaryConfiguration,
            migrationPlan: MidlineMigrationPlan.self,
            label: "primary",
            diagnostics: &diagnostics
        ) {
            container = primary
            launchIssueMessage = nil
            return
        }

        if !inMemory,
           let recovered = Self.recoverStore(
            schema: schema,
            sourceURL: primaryConfiguration.url,
            diagnostics: &diagnostics
           ) {
            container = recovered
            launchIssueMessage = "Midline recovered your saved data into a fresh store after a SwiftData migration failure."
            return
        }

        if let fresh = Self.openFreshFallbackStore(
            schema: schema,
            primaryURL: primaryConfiguration.url,
            diagnostics: &diagnostics
        ) {
            container = fresh
            launchIssueMessage = "Midline could not migrate the old local database. The old files were preserved, and a fresh store was opened."
            return
        }

        Self.log("Falling back to in-memory store after all disk stores failed.", diagnostics: &diagnostics, type: .fault)
        let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = (try? ModelContainer(for: schema, migrationPlan: MidlineMigrationPlan.self, configurations: [memoryConfiguration]))
            ?? (try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        launchIssueMessage = "Midline could not open local storage. Changes from this launch may not be saved."
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

    #if DEBUG
    static func recoverStoreForTesting(sourceURL: URL) -> ModelContainer? {
        var diagnostics = [String]()
        let schema = Schema(versionedSchema: MidlineSchemaV6.self)
        return recoverStore(schema: schema, sourceURL: sourceURL, diagnostics: &diagnostics)
    }
    #endif
}

private extension PersistenceController {
    struct RecoveryImport {
        var matches = [RecoveredMatch]()
        var players = [RecoveredPlayer]()
        var events = [RecoveredEvent]()
        var settings = [RecoveredSettings]()
    }

    struct RecoveredMatch {
        let primaryKey: Int64
        let id: UUID
        let title: String
        let teamName: String
        let opponentName: String
        let date: Date
        let durationMinutes: Int
        let numberOfHalves: Int
        let extraTimeEnabled: Bool?
        let extraTimeHalfDurationMinutes: Int?
        let shootoutStatusRawValue: String?
        let homePenaltyScore: Int?
        let awayPenaltyScore: Int?
        let substitutionLimitModeRawValue: String?
        let substitutionLimit: Int?
        let isQuickMatch: Bool
        let currentHalf: Int
        let homeScore: Int
        let awayScore: Int
        let elapsedSeconds: Int
        let isLive: Bool
        let isFinished: Bool
        let accentRawValue: String
        let trackedEventTypeRawValues: [String]?
    }

    struct RecoveredPlayer {
        let id: UUID
        let matchPrimaryKey: Int64?
        let name: String
        let jerseyNumber: Int?
        let positionRawValue: String
        let isFavorite: Bool
        let isPinned: Bool
        let isStarter: Bool
        let teamSideRawValue: String
    }

    struct RecoveredEvent {
        let id: UUID
        let matchPrimaryKey: Int64?
        let timestamp: Date
        let matchMinute: Int
        let periodRawValue: String
        let eventTypeRawValue: String
        let teamSideRawValue: String
        let playerID: UUID?
        let secondaryPlayerID: UUID?
        let linkedGroupID: UUID?
        let notes: String?
        let pitchX: Double?
        let pitchY: Double?
        let elapsedSeconds: Int?
        let sourceDeviceRawValue: String?
    }

    struct RecoveredSettings {
        let id: UUID
        let defaultDurationMinutes: Int
        let defaultNumberOfHalves: Int
        let defaultExtraTimeEnabled: Bool?
        let defaultExtraTimeHalfDurationMinutes: Int?
        let defaultSubstitutionLimitModeRawValue: String?
        let defaultSubstitutionLimit: Int?
        let themeAccentRawValue: String
        let quickActionsData: Data
    }

    static func openContainer(
        schema: Schema,
        configuration: ModelConfiguration,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        label: String,
        diagnostics: inout [String]
    ) -> ModelContainer? {
        do {
            log("Opening \(label) SwiftData store at \(configuration.url.path)", diagnostics: &diagnostics)
            let container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
            log("Opened \(label) SwiftData store.", diagnostics: &diagnostics)
            return container
        } catch {
            log("Failed to open \(label) SwiftData store: \(String(describing: error))", diagnostics: &diagnostics, type: .error)
            return nil
        }
    }

    static func openRecoveredStoreIfAvailable(
        schema: Schema,
        primaryURL: URL,
        diagnostics: inout [String]
    ) -> ModelContainer? {
        let recoveredURL = recoveredStoreURL(for: primaryURL)
        guard FileManager.default.fileExists(atPath: recoveredURL.path) else { return nil }

        let configuration = ModelConfiguration(schema: schema, url: recoveredURL)
        return openContainer(
            schema: schema,
            configuration: configuration,
            migrationPlan: MidlineMigrationPlan.self,
            label: "existing recovered",
            diagnostics: &diagnostics
        )
    }

    static func recoverStore(schema: Schema, sourceURL: URL, diagnostics: inout [String]) -> ModelContainer? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            log("No source store exists at \(sourceURL.path); skipping import recovery.", diagnostics: &diagnostics)
            return nil
        }

        do {
            log("Attempting direct SQLite import recovery from \(sourceURL.path)", diagnostics: &diagnostics)
            let imported = try SQLiteRecoveryReader.readStore(at: sourceURL)
            log(
                "Read legacy SQLite rows: matches=\(imported.matches.count), players=\(imported.players.count), events=\(imported.events.count), settings=\(imported.settings.count)",
                diagnostics: &diagnostics
            )

            let recoveredURL = recoveredStoreURL(for: sourceURL)
            try removeStoreFiles(at: recoveredURL)
            let recoveredConfiguration = ModelConfiguration(schema: schema, url: recoveredURL)
            let recoveredContainer = try ModelContainer(
                for: schema,
                migrationPlan: MidlineMigrationPlan.self,
                configurations: [recoveredConfiguration]
            )
            try importRecoveredRows(imported, into: recoveredContainer)
            log("Recovered SQLite store into \(recoveredURL.path)", diagnostics: &diagnostics)
            return recoveredContainer
        } catch {
            log("Direct SQLite import recovery failed: \(String(describing: error))", diagnostics: &diagnostics, type: .error)
            backupStoreFiles(at: sourceURL, diagnostics: &diagnostics)
            return nil
        }
    }

    static func openFreshFallbackStore(schema: Schema, primaryURL: URL, diagnostics: inout [String]) -> ModelContainer? {
        let fallbackURL = recoveredStoreURL(for: primaryURL)
        do {
            try removeStoreFiles(at: fallbackURL)
            let configuration = ModelConfiguration(schema: schema, url: fallbackURL)
            let container = try ModelContainer(for: schema, migrationPlan: MidlineMigrationPlan.self, configurations: [configuration])
            log("Opened fresh fallback store at \(fallbackURL.path)", diagnostics: &diagnostics)
            return container
        } catch {
            log("Failed to open fresh fallback store: \(String(describing: error))", diagnostics: &diagnostics, type: .fault)
            return nil
        }
    }

    static func importRecoveredRows(_ recovery: RecoveryImport, into container: ModelContainer) throws {
        let context = ModelContext(container)
        var matchesByPrimaryKey = [Int64: MatchRecord]()

        for recoveredMatch in recovery.matches {
            let match = MatchRecord(
                id: recoveredMatch.id,
                title: recoveredMatch.title,
                teamName: recoveredMatch.teamName,
                opponentName: recoveredMatch.opponentName,
                date: recoveredMatch.date,
                durationMinutes: recoveredMatch.durationMinutes,
                numberOfHalves: recoveredMatch.numberOfHalves,
                extraTimeEnabled: recoveredMatch.extraTimeEnabled ?? false,
                extraTimeHalfDurationMinutes: recoveredMatch.extraTimeHalfDurationMinutes ?? MatchFormat.defaultExtraTimeHalfDurationMinutes,
                shootoutStatus: recoveredMatch.shootoutStatusRawValue.flatMap(PenaltyShootoutStatus.init(rawValue:)) ?? .notStarted,
                homePenaltyScore: recoveredMatch.homePenaltyScore ?? 0,
                awayPenaltyScore: recoveredMatch.awayPenaltyScore ?? 0,
                substitutionLimitMode: recoveredMatch.substitutionLimitModeRawValue.flatMap(SubstitutionLimitMode.init(rawValue:)) ?? .unlimited,
                substitutionLimit: recoveredMatch.substitutionLimit ?? MatchFormat.defaultSubstitutionLimit,
                isQuickMatch: recoveredMatch.isQuickMatch,
                currentHalf: recoveredMatch.currentHalf,
                homeScore: recoveredMatch.homeScore,
                awayScore: recoveredMatch.awayScore,
                elapsedSeconds: recoveredMatch.elapsedSeconds,
                isLive: recoveredMatch.isLive,
                isFinished: recoveredMatch.isFinished,
                accent: AppThemeAccent(rawValue: recoveredMatch.accentRawValue) ?? .stadiumGreen,
                trackedEventTypes: recoveredMatch.trackedEventTypeRawValues.map(MatchEventType.sanitizedTrackedEvents(fromRawValues:))
                    ?? MatchEventType.defaultQuickActions
            )
            if let rawTrackedEvents = recoveredMatch.trackedEventTypeRawValues {
                match.trackedEventTypeRawValues = rawTrackedEvents
            }
            match.normalizePersistedValues()
            context.insert(match)
            matchesByPrimaryKey[recoveredMatch.primaryKey] = match
        }

        for recoveredPlayer in recovery.players {
            let match = recoveredPlayer.matchPrimaryKey.flatMap { matchesByPrimaryKey[$0] }
            let player = PlayerRecord(
                id: recoveredPlayer.id,
                name: recoveredPlayer.name,
                jerseyNumber: recoveredPlayer.jerseyNumber,
                position: PlayerPosition(rawValue: recoveredPlayer.positionRawValue) ?? .utility,
                isFavorite: recoveredPlayer.isFavorite,
                isPinned: recoveredPlayer.isPinned,
                isStarter: recoveredPlayer.isStarter,
                teamSide: TeamSide(rawValue: recoveredPlayer.teamSideRawValue) ?? .home,
                match: match
            )
            player.positionRawValue = recoveredPlayer.positionRawValue
            player.teamSideRawValue = recoveredPlayer.teamSideRawValue
            match?.players.append(player)
            context.insert(player)
        }

        for recoveredEvent in recovery.events {
            let match = recoveredEvent.matchPrimaryKey.flatMap { matchesByPrimaryKey[$0] }
            let event = MatchEventRecord(
                id: recoveredEvent.id,
                timestamp: recoveredEvent.timestamp,
                matchMinute: recoveredEvent.matchMinute,
                elapsedSeconds: recoveredEvent.elapsedSeconds,
                period: MatchPeriod(rawValue: recoveredEvent.periodRawValue) ?? .firstHalf,
                eventType: MatchEventType(rawValue: recoveredEvent.eventTypeRawValue) ?? .goal,
                teamSide: TeamSide(rawValue: recoveredEvent.teamSideRawValue) ?? .home,
                playerID: recoveredEvent.playerID,
                secondaryPlayerID: recoveredEvent.secondaryPlayerID,
                linkedGroupID: recoveredEvent.linkedGroupID,
                notes: recoveredEvent.notes,
                pitchX: recoveredEvent.pitchX,
                pitchY: recoveredEvent.pitchY,
                sourceDevice: recoveredEvent.sourceDeviceRawValue.flatMap(SourceDevice.init(rawValue:)) ?? .iPhone,
                match: match
            )
            event.periodRawValue = recoveredEvent.periodRawValue
            event.eventTypeRawValue = recoveredEvent.eventTypeRawValue
            event.teamSideRawValue = recoveredEvent.teamSideRawValue
            event.sourceDeviceRawValue = recoveredEvent.sourceDeviceRawValue
            event.normalizePersistedValues()
            match?.events.append(event)
            context.insert(event)
        }

        if recovery.settings.isEmpty {
            context.insert(AppSettingsRecord())
        } else {
            for recoveredSettings in recovery.settings {
                let settings = AppSettingsRecord(
                    id: recoveredSettings.id,
                    defaultDurationMinutes: recoveredSettings.defaultDurationMinutes,
                    defaultNumberOfHalves: recoveredSettings.defaultNumberOfHalves,
                    defaultExtraTimeEnabled: recoveredSettings.defaultExtraTimeEnabled ?? false,
                    defaultExtraTimeHalfDurationMinutes: recoveredSettings.defaultExtraTimeHalfDurationMinutes
                        ?? MatchFormat.defaultExtraTimeHalfDurationMinutes,
                    defaultSubstitutionLimitMode: recoveredSettings.defaultSubstitutionLimitModeRawValue
                        .flatMap(SubstitutionLimitMode.init(rawValue:)) ?? .unlimited,
                    defaultSubstitutionLimit: recoveredSettings.defaultSubstitutionLimit ?? MatchFormat.defaultSubstitutionLimit,
                    themeAccent: AppThemeAccent(rawValue: recoveredSettings.themeAccentRawValue) ?? .stadiumGreen
                )
                settings.quickActionsData = recoveredSettings.quickActionsData
                settings.defaultSubstitutionLimitModeRawValue = recoveredSettings.defaultSubstitutionLimitModeRawValue
                    ?? SubstitutionLimitMode.unlimited.rawValue
                settings.normalizePersistedValues()
                context.insert(settings)
            }
        }

        try context.save()
    }

    static func recoveredStoreURL(for primaryURL: URL) -> URL {
        primaryURL
            .deletingLastPathComponent()
            .appendingPathComponent("MidlineRecovered.store")
    }

    static func removeStoreFiles(at url: URL) throws {
        for fileURL in storeFileURLs(for: url) where FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static func backupStoreFiles(at url: URL, diagnostics: inout [String]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let suffix = ".migration-failed-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))"

        for fileURL in storeFileURLs(for: url) where FileManager.default.fileExists(atPath: fileURL.path) {
            let backupURL = fileURL.appendingPathExtension(suffix)
            do {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try FileManager.default.removeItem(at: backupURL)
                }
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
                log("Backed up failed store file to \(backupURL.path)", diagnostics: &diagnostics)
            } catch {
                log("Could not back up \(fileURL.path): \(String(describing: error))", diagnostics: &diagnostics, type: .error)
            }
        }
    }

    static func storeFileURLs(for url: URL) -> [URL] {
        [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal")
        ]
    }

    static func log(_ message: String, diagnostics: inout [String], type: OSLogType = .info) {
        diagnostics.append(message)
        logger.log(level: type, "\(message, privacy: .public)")
        print("[MidlinePersistence] \(message)")
    }
}

private enum SQLiteRecoveryError: Error {
    case openFailed(String)
    case prepareFailed(String)
}

private final class SQLiteRecoveryReader {
    private let db: OpaquePointer?

    private init(db: OpaquePointer?) {
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }

    static func readStore(at url: URL) throws -> PersistenceController.RecoveryImport {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite open error"
            sqlite3_close(db)
            throw SQLiteRecoveryError.openFailed(message)
        }

        return try SQLiteRecoveryReader(db: db).read()
    }

    private func read() throws -> PersistenceController.RecoveryImport {
        var recovery = PersistenceController.RecoveryImport()

        if tableExists("ZMATCHRECORD") {
            let columns = try columns(in: "ZMATCHRECORD")
            recovery.matches = try rows(in: "ZMATCHRECORD").compactMap { row in
                guard let primaryKey = row.int64("Z_PK") else { return nil }
                return PersistenceController.RecoveredMatch(
                    primaryKey: primaryKey,
                    id: row.uuid("ZID") ?? UUID(),
                    title: row.string("ZTITLE") ?? "Recovered Match",
                    teamName: row.string("ZTEAMNAME") ?? "Home",
                    opponentName: row.string("ZOPPONENTNAME") ?? "Opponent",
                    date: row.date("ZDATE") ?? .now,
                    durationMinutes: row.int("ZDURATIONMINUTES") ?? 90,
                    numberOfHalves: row.int("ZNUMBEROFHALVES") ?? 2,
                    extraTimeEnabled: columns.contains("ZEXTRATIMEENABLED") ? row.bool("ZEXTRATIMEENABLED") : nil,
                    extraTimeHalfDurationMinutes: columns.contains("ZEXTRATIMEHALFDURATIONMINUTES")
                        ? row.int("ZEXTRATIMEHALFDURATIONMINUTES") : nil,
                    shootoutStatusRawValue: columns.contains("ZSHOOTOUTSTATUSRAWVALUE")
                        ? row.string("ZSHOOTOUTSTATUSRAWVALUE") : nil,
                    homePenaltyScore: columns.contains("ZHOMEPENALTYSCORE") ? row.int("ZHOMEPENALTYSCORE") : nil,
                    awayPenaltyScore: columns.contains("ZAWAYPENALTYSCORE") ? row.int("ZAWAYPENALTYSCORE") : nil,
                    substitutionLimitModeRawValue: columns.contains("ZSUBSTITUTIONLIMITMODERAWVALUE")
                        ? row.string("ZSUBSTITUTIONLIMITMODERAWVALUE") : nil,
                    substitutionLimit: columns.contains("ZSUBSTITUTIONLIMIT") ? row.int("ZSUBSTITUTIONLIMIT") : nil,
                    isQuickMatch: row.bool("ZISQUICKMATCH") ?? false,
                    currentHalf: row.int("ZCURRENTHALF") ?? 1,
                    homeScore: row.int("ZHOMESCORE") ?? 0,
                    awayScore: row.int("ZAWAYSCORE") ?? 0,
                    elapsedSeconds: row.int("ZELAPSEDSECONDS") ?? 0,
                    isLive: row.bool("ZISLIVE") ?? false,
                    isFinished: row.bool("ZISFINISHED") ?? false,
                    accentRawValue: row.string("ZACCENTRAWVALUE") ?? AppThemeAccent.stadiumGreen.rawValue,
                    trackedEventTypeRawValues: columns.contains("ZTRACKEDEVENTTYPERAWVALUES")
                        ? row.stringArray("ZTRACKEDEVENTTYPERAWVALUES") : nil
                )
            }
        }

        if tableExists("ZPLAYERRECORD") {
            recovery.players = try rows(in: "ZPLAYERRECORD").map { row in
                PersistenceController.RecoveredPlayer(
                    id: row.uuid("ZID") ?? UUID(),
                    matchPrimaryKey: row.int64("ZMATCH"),
                    name: row.string("ZNAME") ?? "Recovered Player",
                    jerseyNumber: row.int("ZJERSEYNUMBER"),
                    positionRawValue: row.string("ZPOSITIONRAWVALUE") ?? PlayerPosition.utility.rawValue,
                    isFavorite: row.bool("ZISFAVORITE") ?? false,
                    isPinned: row.bool("ZISPINNED") ?? false,
                    isStarter: row.bool("ZISSTARTER") ?? true,
                    teamSideRawValue: row.string("ZTEAMSIDERAWVALUE") ?? TeamSide.home.rawValue
                )
            }
        }

        if tableExists("ZMATCHEVENTRECORD") {
            let columns = try columns(in: "ZMATCHEVENTRECORD")
            recovery.events = try rows(in: "ZMATCHEVENTRECORD").map { row in
                PersistenceController.RecoveredEvent(
                    id: row.uuid("ZID") ?? UUID(),
                    matchPrimaryKey: row.int64("ZMATCH"),
                    timestamp: row.date("ZTIMESTAMP") ?? .now,
                    matchMinute: row.int("ZMATCHMINUTE") ?? 1,
                    periodRawValue: row.string("ZPERIODRAWVALUE") ?? MatchPeriod.firstHalf.rawValue,
                    eventTypeRawValue: row.string("ZEVENTTYPERAWVALUE") ?? MatchEventType.goal.rawValue,
                    teamSideRawValue: row.string("ZTEAMSIDERAWVALUE") ?? TeamSide.home.rawValue,
                    playerID: row.uuid("ZPLAYERID"),
                    secondaryPlayerID: row.uuid("ZSECONDARYPLAYERID"),
                    linkedGroupID: row.uuid("ZLINKEDGROUPID"),
                    notes: row.string("ZNOTES"),
                    pitchX: row.double("ZPITCHX"),
                    pitchY: row.double("ZPITCHY"),
                    elapsedSeconds: columns.contains("ZELAPSEDSECONDS")
                        ? row.int("ZELAPSEDSECONDS") : nil,
                    sourceDeviceRawValue: columns.contains("ZSOURCEDEVICERAWVALUE")
                        ? row.string("ZSOURCEDEVICERAWVALUE") : nil
                )
            }
        }

        if tableExists("ZAPPSETTINGSRECORD") {
            let columns = try columns(in: "ZAPPSETTINGSRECORD")
            recovery.settings = try rows(in: "ZAPPSETTINGSRECORD").map { row in
                PersistenceController.RecoveredSettings(
                    id: row.uuid("ZID") ?? UUID(),
                    defaultDurationMinutes: row.int("ZDEFAULTDURATIONMINUTES") ?? 90,
                    defaultNumberOfHalves: row.int("ZDEFAULTNUMBEROFHALVES") ?? 2,
                    defaultExtraTimeEnabled: columns.contains("ZDEFAULTEXTRATIMEENABLED")
                        ? row.bool("ZDEFAULTEXTRATIMEENABLED") : nil,
                    defaultExtraTimeHalfDurationMinutes: columns.contains("ZDEFAULTEXTRATIMEHALFDURATIONMINUTES")
                        ? row.int("ZDEFAULTEXTRATIMEHALFDURATIONMINUTES") : nil,
                    defaultSubstitutionLimitModeRawValue: columns.contains("ZDEFAULTSUBSTITUTIONLIMITMODERAWVALUE")
                        ? row.string("ZDEFAULTSUBSTITUTIONLIMITMODERAWVALUE") : nil,
                    defaultSubstitutionLimit: columns.contains("ZDEFAULTSUBSTITUTIONLIMIT")
                        ? row.int("ZDEFAULTSUBSTITUTIONLIMIT") : nil,
                    themeAccentRawValue: row.string("ZTHEMEACCENTRAWVALUE") ?? AppThemeAccent.stadiumGreen.rawValue,
                    quickActionsData: row.data("ZQUICKACTIONSDATA") ?? Data()
                )
            }
        }

        return recovery
    }

    private func tableExists(_ table: String) -> Bool {
        (try? rows(sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", bindings: [table]))?.isEmpty == false
    }

    private func columns(in table: String) throws -> Set<String> {
        Set(try rows(sql: "PRAGMA table_info(\(table))").compactMap { $0.string("name")?.uppercased() })
    }

    private func rows(in table: String) throws -> [SQLiteRow] {
        try rows(sql: "SELECT * FROM \(table)")
    }

    private func rows(sql: String, bindings: [String] = []) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRecoveryError.prepareFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? sql)
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1, SQLITE_TRANSIENT)
        }

        var result = [SQLiteRow]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(SQLiteRow(statement: statement))
        }
        return result
    }
}

private struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(statement: OpaquePointer?) {
        var values = [String: SQLiteValue]()
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index)).uppercased()
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                values[name] = .string(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                let byteCount = Int(sqlite3_column_bytes(statement, index))
                if let bytes = sqlite3_column_blob(statement, index), byteCount > 0 {
                    values[name] = .data(Data(bytes: bytes, count: byteCount))
                } else {
                    values[name] = .data(Data())
                }
            default:
                values[name] = .null
            }
        }
        self.values = values
    }

    func string(_ column: String) -> String? {
        if case let .string(value)? = values[column.uppercased()] { return value }
        return nil
    }

    func int(_ column: String) -> Int? {
        int64(column).map(Int.init)
    }

    func int64(_ column: String) -> Int64? {
        if case let .int(value)? = values[column.uppercased()] { return value }
        return nil
    }

    func bool(_ column: String) -> Bool? {
        int(column).map { $0 != 0 }
    }

    func double(_ column: String) -> Double? {
        switch values[column.uppercased()] {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        default:
            return nil
        }
    }

    func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    func data(_ column: String) -> Data? {
        if case let .data(value)? = values[column.uppercased()] { return value }
        return nil
    }

    func uuid(_ column: String) -> UUID? {
        guard let data = data(column), data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func stringArray(_ column: String) -> [String]? {
        guard let data = data(column) else { return nil }
        if let values = try? JSONDecoder().decode([String].self, from: data) {
            return values
        }
        if let values = try? PropertyListDecoder().decode([String].self, from: data) {
            return values
        }
        return nil
    }
}

private enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MidlineMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            MidlineSchemaV1.self,
            MidlineSchemaV5.self,
            MidlineSchemaV6.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MidlineSchemaV1.self, toVersion: MidlineSchemaV5.self),
            .lightweight(fromVersion: MidlineSchemaV5.self, toVersion: MidlineSchemaV6.self)
        ]
    }
}

enum MidlineSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            MatchRecord.self,
            PlayerRecord.self,
            MatchEventRecord.self,
            AppSettingsRecord.self
        ]
    }
}

enum MidlineSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

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
        var extraTimeEnabled: Bool?
        var extraTimeHalfDurationMinutes: Int?
        var shootoutStatusRawValue: String?
        var homePenaltyScore: Int?
        var awayPenaltyScore: Int?
        var substitutionLimitModeRawValue: String?
        var substitutionLimit: Int?
        var isQuickMatch: Bool
        var currentHalf: Int
        var homeScore: Int
        var awayScore: Int
        var elapsedSeconds: Int
        var isLive: Bool
        var isFinished: Bool
        var accentRawValue: String
        var trackedEventTypeRawValues: [String]?
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
            extraTimeEnabled: Bool? = false,
            extraTimeHalfDurationMinutes: Int? = MatchFormat.defaultExtraTimeHalfDurationMinutes,
            shootoutStatusRawValue: String? = PenaltyShootoutStatus.notStarted.rawValue,
            homePenaltyScore: Int? = 0,
            awayPenaltyScore: Int? = 0,
            substitutionLimitModeRawValue: String? = SubstitutionLimitMode.unlimited.rawValue,
            substitutionLimit: Int? = MatchFormat.defaultSubstitutionLimit,
            isQuickMatch: Bool = false,
            currentHalf: Int = 1,
            homeScore: Int = 0,
            awayScore: Int = 0,
            elapsedSeconds: Int = 0,
            isLive: Bool = true,
            isFinished: Bool = false,
            accentRawValue: String = AppThemeAccent.stadiumGreen.rawValue,
            trackedEventTypeRawValues: [String]? = MatchEventType.defaultQuickActions.map(\.rawValue)
        ) {
            self.id = id
            self.title = title
            self.teamName = teamName
            self.opponentName = opponentName
            self.date = date
            self.durationMinutes = durationMinutes
            self.numberOfHalves = numberOfHalves
            self.extraTimeEnabled = extraTimeEnabled
            self.extraTimeHalfDurationMinutes = extraTimeHalfDurationMinutes
            self.shootoutStatusRawValue = shootoutStatusRawValue
            self.homePenaltyScore = homePenaltyScore
            self.awayPenaltyScore = awayPenaltyScore
            self.substitutionLimitModeRawValue = substitutionLimitModeRawValue
            self.substitutionLimit = substitutionLimit
            self.isQuickMatch = isQuickMatch
            self.currentHalf = currentHalf
            self.homeScore = homeScore
            self.awayScore = awayScore
            self.elapsedSeconds = elapsedSeconds
            self.isLive = isLive
            self.isFinished = isFinished
            self.accentRawValue = accentRawValue
            self.trackedEventTypeRawValues = trackedEventTypeRawValues
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
        var sourceDeviceRawValue: String?
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
            sourceDeviceRawValue: String? = SourceDevice.iPhone.rawValue,
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
            self.sourceDeviceRawValue = sourceDeviceRawValue
            self.match = match
        }
    }

    @Model
    final class AppSettingsRecord {
        @Attribute(.unique) var id: UUID
        var defaultDurationMinutes: Int
        var defaultNumberOfHalves: Int
        var defaultExtraTimeEnabled: Bool?
        var defaultExtraTimeHalfDurationMinutes: Int?
        var defaultSubstitutionLimitModeRawValue: String?
        var defaultSubstitutionLimit: Int?
        var themeAccentRawValue: String
        var quickActionsData: Data

        init(
            id: UUID = UUID(),
            defaultDurationMinutes: Int = 90,
            defaultNumberOfHalves: Int = 2,
            defaultExtraTimeEnabled: Bool? = false,
            defaultExtraTimeHalfDurationMinutes: Int? = MatchFormat.defaultExtraTimeHalfDurationMinutes,
            defaultSubstitutionLimitModeRawValue: String? = SubstitutionLimitMode.unlimited.rawValue,
            defaultSubstitutionLimit: Int? = MatchFormat.defaultSubstitutionLimit,
            themeAccentRawValue: String = AppThemeAccent.stadiumGreen.rawValue,
            quickActionsData: Data = Data()
        ) {
            self.id = id
            self.defaultDurationMinutes = defaultDurationMinutes
            self.defaultNumberOfHalves = defaultNumberOfHalves
            self.defaultExtraTimeEnabled = defaultExtraTimeEnabled
            self.defaultExtraTimeHalfDurationMinutes = defaultExtraTimeHalfDurationMinutes
            self.defaultSubstitutionLimitModeRawValue = defaultSubstitutionLimitModeRawValue
            self.defaultSubstitutionLimit = defaultSubstitutionLimit
            self.themeAccentRawValue = themeAccentRawValue
            self.quickActionsData = quickActionsData
        }
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
