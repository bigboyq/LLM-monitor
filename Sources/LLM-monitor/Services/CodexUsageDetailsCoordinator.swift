import Foundation

/// AppState delegate for the delayed Codex local-usage enrichment task.
@MainActor
protocol CodexUsageDetailsCoordinatorDelegate: AnyObject {
    func setScanningState(_ isScanning: Bool, for providerID: String)
    func applyCodexUsageDetails(
        _ details: CodexUsageDetails?,
        providerID: String,
        fetchedAt: Date,
        configurationGeneration: Int
    )
}

/// Owns Codex detail task cancellation, token freshness, and scanning state.
///
/// The quota refresh itself stays in `ProviderRefreshScheduler`; this coordinator
/// only handles the slower local session-file enrichment that follows a successful
/// Codex quota response. Keeping the task state here prevents AppState from owning
/// another pair of dictionaries and another stale-result protocol.
@MainActor
final class CodexUsageDetailsCoordinator {
    private weak var delegate: (any CodexUsageDetailsCoordinatorDelegate)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var taskTokens: [String: UUID] = [:]

    init(delegate: any CodexUsageDetailsCoordinatorDelegate) {
        self.delegate = delegate
    }

    func schedule(
        providerID: String,
        authPath: String?,
        model: ModelQuota?,
        fetchedAt: Date,
        configurationGeneration: Int
    ) {
        cancel(providerID: providerID)
        guard let model else { return }

        let taskToken = UUID()
        taskTokens[providerID] = taskToken
        delegate?.setScanningState(true, for: providerID)

        let task = Task { [weak self] in
            let details = await CodexFetcher.loadUsageDetailsAsync(
                authPath: authPath,
                model: model
            )
            guard !Task.isCancelled else {
                self?.finishIfCurrent(providerID: providerID, taskToken: taskToken)
                return
            }
            self?.applyIfCurrent(
                details,
                providerID: providerID,
                fetchedAt: fetchedAt,
                configurationGeneration: configurationGeneration,
                taskToken: taskToken
            )
        }
        tasks[providerID] = task
    }

    func cancel(providerID: String) {
        tasks[providerID]?.cancel()
        tasks.removeValue(forKey: providerID)
        taskTokens.removeValue(forKey: providerID)
        delegate?.setScanningState(false, for: providerID)
    }

    func cancelAll() {
        let providerIDs = Set(tasks.keys).union(taskTokens.keys)
        for providerID in providerIDs {
            cancel(providerID: providerID)
        }
    }

    private func finishIfCurrent(providerID: String, taskToken: UUID) {
        guard taskTokens[providerID] == taskToken else { return }
        tasks.removeValue(forKey: providerID)
        taskTokens.removeValue(forKey: providerID)
        delegate?.setScanningState(false, for: providerID)
    }

    private func applyIfCurrent(
        _ details: CodexUsageDetails?,
        providerID: String,
        fetchedAt: Date,
        configurationGeneration: Int,
        taskToken: UUID
    ) {
        guard taskTokens[providerID] == taskToken else {
            logDebug("[codex/detail] apply aborted: stale task token")
            return
        }
        tasks.removeValue(forKey: providerID)
        taskTokens.removeValue(forKey: providerID)
        delegate?.setScanningState(false, for: providerID)
        delegate?.applyCodexUsageDetails(
            details,
            providerID: providerID,
            fetchedAt: fetchedAt,
            configurationGeneration: configurationGeneration
        )
    }
}
