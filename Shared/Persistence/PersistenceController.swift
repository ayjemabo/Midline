import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        let schema = Schema([
            MatchRecord.self,
            PlayerRecord.self,
            MatchEventRecord.self,
            AppSettingsRecord.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
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
