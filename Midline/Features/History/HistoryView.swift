import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MatchRecord.date, order: .reverse) private var matches: [MatchRecord]
    @State private var searchText = ""
    @State private var duplicateDraft: MatchSetupDraft?
    @State private var pendingDeletion: MatchDeletionRequest?
    @State private var saveErrorMessage: String?
    @Bindable var engine: MatchEngine

    var body: some View {
        List {
            if filteredMatches.isEmpty {
                ContentUnavailableView(
                    matches.isEmpty ? "No Matches" : "No Results",
                    systemImage: matches.isEmpty ? "clock.badge.questionmark" : "magnifyingglass",
                    description: Text(matches.isEmpty ? "Completed and active matches will appear here." : "Try a different team, opponent, or date.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredMatches) { match in
                    NavigationLink {
                        destination(for: match)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(match.displayTitle)
                                .font(.headline)
                            Text(match.compactScoreLine)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(statusText(for: match))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(statusTint(for: match))
                                Text(match.formatSummaryText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(match.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            requestDelete([match])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            prepareDuplicate(from: match)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            prepareDuplicate(from: match)
                        } label: {
                            Label("Duplicate Setup", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            requestDelete([match])
                        } label: {
                            Label("Delete Match", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteMatches)
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Team, opponent, date")
        .sheet(item: $duplicateDraft) { draft in
            NavigationStack {
                MatchSetupView(engine: engine, setupDraft: draft)
            }
        }
        .confirmationDialog(
            "Delete Match",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            Button(deleteActionTitle(for: request), role: .destructive) {
                delete(request.matches)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { request in
            Text(deleteMessage(for: request))
        }
        .alert("Couldn’t Update History", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Try again.")
        }
    }

    private var filteredMatches: [MatchRecord] {
        if searchText.isEmpty { return matches }
        return matches.filter { $0.matchesSearchQuery(searchText) }
    }

    @ViewBuilder
    private func destination(for match: MatchRecord) -> some View {
        if match.isFinished {
            SummaryView(match: match)
        } else {
            LiveMatchView(match: match, engine: engine)
        }
    }

    private func deleteMatches(at offsets: IndexSet) {
        requestDelete(offsets.map { filteredMatches[$0] })
    }

    private func requestDelete(_ matchesToDelete: [MatchRecord]) {
        guard !matchesToDelete.isEmpty else { return }
        pendingDeletion = MatchDeletionRequest(matches: matchesToDelete)
    }

    private func delete(_ matchesToDelete: [MatchRecord]) {
        guard !matchesToDelete.isEmpty else { return }
        let preferredActiveMatchID = matches.preferredActiveMatch(currentActiveMatch: engine.activeMatch)?.id
        let engineActiveMatchID = engine.activeMatch?.id
        let matchIDsToDelete = matchesToDelete.map(\.id)
        let remainingMatches = matches.filter { match in
            !matchIDsToDelete.contains(match.id)
        }
        for match in matchesToDelete {
            context.delete(match)
        }
        do {
            try context.save()
            let deletedPreferredActiveMatch = matchIDsToDelete.contains { $0 == preferredActiveMatchID }
            let deletedEngineActiveMatch = matchIDsToDelete.contains { $0 == engineActiveMatchID }
            if deletedPreferredActiveMatch || deletedEngineActiveMatch {
                if let replacementActiveMatch = engine.restorePreferredActiveMatch(afterDeletingIDs: matchIDsToDelete, from: remainingMatches) {
                    try context.save()
                    MatchSyncService.shared.broadcastMatchState(replacementActiveMatch)
                } else {
                    MatchSyncService.shared.broadcastClearedMatchState()
                }
            }
        } catch {
            context.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }

    private func prepareDuplicate(from match: MatchRecord) {
        duplicateDraft = MatchSetupDraft.duplicate(from: match)
    }

    private func deleteActionTitle(for request: MatchDeletionRequest) -> String {
        request.matches.count == 1 ? "Delete Match" : "Delete Matches"
    }

    private func deleteMessage(for request: MatchDeletionRequest) -> String {
        if request.matches.count == 1 {
            return "This removes this match, its players, and its timeline events."
        }
        return "This removes \(request.matches.count) matches, including their players and timeline events."
    }

    private func statusText(for match: MatchRecord) -> String {
        if match.isFinished { return "Finished" }
        return match.isLive ? "Live" : "Paused"
    }

    private func statusTint(for match: MatchRecord) -> Color {
        if match.isFinished { return .secondary }
        return match.isLive ? .green : .orange
    }
}

private struct MatchDeletionRequest: Identifiable {
    let id = UUID()
    let matches: [MatchRecord]
}
