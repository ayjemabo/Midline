import Foundation

nonisolated enum PlayerTrackingMode: String, Codable, CaseIterable, Identifiable {
    case off
    case optional
    case required

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .optional:
            "Optional"
        case .required:
            "Required"
        }
    }
}

nonisolated struct QuickActionConfiguration: Codable, Hashable {
    var enabledActions: [MatchEventType] = MatchEventType.defaultQuickActions
    var smartDetailEnabled = true
    var watchHapticsEnabled = true
    var playerTrackingMode: PlayerTrackingMode = .optional
    var favoritePlayerIDs: [UUID] = []

    init(
        enabledActions: [MatchEventType] = MatchEventType.defaultQuickActions,
        smartDetailEnabled: Bool = true,
        watchHapticsEnabled: Bool = true,
        playerTrackingMode: PlayerTrackingMode = .optional,
        favoritePlayerIDs: [UUID] = []
    ) {
        self.enabledActions = MatchEventType.sanitizedTrackedEvents(from: enabledActions)
        self.smartDetailEnabled = smartDetailEnabled
        self.watchHapticsEnabled = watchHapticsEnabled
        self.playerTrackingMode = playerTrackingMode
        self.favoritePlayerIDs = Self.sanitizedFavoritePlayerIDs(favoritePlayerIDs)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabledActions: Self.decodeEnabledActions(from: container),
            smartDetailEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .smartDetailEnabled)) ?? true,
            watchHapticsEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .watchHapticsEnabled)) ?? true,
            playerTrackingMode: Self.decodePlayerTrackingMode(from: container),
            favoritePlayerIDs: Self.decodeFavoritePlayerIDs(from: container)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(MatchEventType.sanitizedTrackedEvents(from: enabledActions), forKey: .enabledActions)
        try container.encode(smartDetailEnabled, forKey: .smartDetailEnabled)
        try container.encode(watchHapticsEnabled, forKey: .watchHapticsEnabled)
        try container.encode(playerTrackingMode, forKey: .playerTrackingMode)
        try container.encode(Self.sanitizedFavoritePlayerIDs(favoritePlayerIDs), forKey: .favoritePlayerIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case enabledActions
        case smartDetailEnabled
        case watchHapticsEnabled
        case playerTrackingMode
        case favoritePlayerIDs
    }

    private struct SavedActionValue: Decodable {
        let rawValue: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try? container.decode(String.self)
        }
    }

    private struct FavoritePlayerIDValue: Decodable {
        let id: UUID?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            guard let rawValue = try? container.decode(String.self) else {
                id = nil
                return
            }
            id = UUID(uuidString: MatchFormat.sanitizedRawValue(rawValue))
        }
    }

    private static func decodeEnabledActions(from container: KeyedDecodingContainer<CodingKeys>) -> [MatchEventType] {
        guard let values = try? container.decodeIfPresent([SavedActionValue].self, forKey: .enabledActions) else {
            return MatchEventType.defaultQuickActions
        }
        let rawValues = values.compactMap(\.rawValue)
        if values.isEmpty {
            return []
        }
        guard !rawValues.isEmpty else {
            return MatchEventType.defaultQuickActions
        }
        return MatchEventType.sanitizedTrackedEvents(fromRawValues: rawValues)
    }

    private static func decodePlayerTrackingMode(from container: KeyedDecodingContainer<CodingKeys>) -> PlayerTrackingMode {
        guard
            let rawValue = try? container.decodeIfPresent(String.self, forKey: .playerTrackingMode),
            let mode = PlayerTrackingMode(rawValue: MatchFormat.sanitizedRawValue(rawValue))
        else {
            return .optional
        }
        return mode
    }

    private static func decodeFavoritePlayerIDs(from container: KeyedDecodingContainer<CodingKeys>) -> [UUID] {
        if let values = try? container.decodeIfPresent([FavoritePlayerIDValue].self, forKey: .favoritePlayerIDs) {
            return sanitizedFavoritePlayerIDs(values.compactMap(\.id))
        }

        return []
    }

    private static func sanitizedFavoritePlayerIDs(_ ids: [UUID]) -> [UUID] {
        var seenIDs = Set<UUID>()
        return ids.filter { seenIDs.insert($0).inserted }
    }
}
