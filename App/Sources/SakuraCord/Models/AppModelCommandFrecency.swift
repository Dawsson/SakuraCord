import DiscordProtocol
import Foundation
import SakuraCordModels

/// Slash-command usage synced through Discord's frecency settings. Uses stay
/// pending locally and are saved on Discord's own schedule: shortly after the
/// Gateway becomes ready, every two hours, and when the connection closes.
/// Desktop window focus/minimization is not Discord's mobile APP_STATE_UPDATE.
extension AppModel {
    static let commandFrecencyFlushInterval: Duration = .seconds(2 * 60 * 60)

    /// Discord loads synced usage when the picker first needs it.
    func loadCommandFrecencyIfNeeded() {
        guard !commandComposer.frecencyStore.hasLoadedRemoteHistory, commandFrecencyLoadTask == nil,
              commandFrecencySaveTask == nil else { return }
        let session = accountSession()
        commandFrecencyLoadTask = Task { [weak self] in
            defer {
                if let self, isCurrentAccountSession(session) { commandFrecencyLoadTask = nil }
            }
            guard let history = try? await session.provider.applicationCommandFrecency(),
                  let self, !Task.isCancelled, isCurrentAccountSession(session)
            else { return }
            applyRemoteCommandFrecency(history)
        }
    }

    func applyRemoteCommandFrecency(_ history: ApplicationCommandFrecencyHistory) {
        // A Gateway echo can arrive before the PATCH returns. Keep it from
        // replaying the already included prefix while that save is in flight.
        guard commandFrecencySaveTask == nil else {
            deferredCommandFrecency = history
            return
        }
        updateCommandFrecency(history)
    }

    /// Discord waits up to ten seconds after (re)connecting, then repeats about
    /// every two hours.
    func scheduleCommandFrecencyFlushAfterConnecting() {
        scheduleCommandFrecencyFlush(after: .milliseconds(10 + Int.random(in: 0 ..< 10_000)))
    }

    func flushCommandFrecencyNow() {
        scheduleCommandFrecencyFlush(after: .zero)
    }

    private func scheduleCommandFrecencyFlush(after delay: Duration) {
        let session = accountSession()
        commandFrecencyFlushTask?.cancel()
        commandFrecencyFlushTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, isCurrentAccountSession(session) else { return }
            await flushCommandFrecencyIfNeeded()
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            scheduleCommandFrecencyFlush(
                after: Self.commandFrecencyFlushInterval + .milliseconds(Int.random(in: 0 ..< 600_000))
            )
        }
    }

    /// Saves pending uses on top of the latest synced history, then adopts
    /// what Discord stored.
    func flushCommandFrecencyIfNeeded() async {
        if let saving = commandFrecencySaveTask {
            await saving.value
            return
        }
        let session = accountSession()
        let saving = startAccountChildTask(account: session) { model, session in
            defer {
                if model.isCurrentAccountSession(session) {
                    model.commandFrecencySaveTask = nil
                    if let history = model.deferredCommandFrecency {
                        model.deferredCommandFrecency = nil
                        model.updateCommandFrecency(history)
                    }
                }
            }
            await model.saveCommandFrecencyIfNeeded(session: session)
        }
        commandFrecencySaveTask = saving
        await saving.value
    }

    private func saveCommandFrecencyIfNeeded(session: AppModelAccountSession) async {
        // Join the initial read before writing, so its stale response cannot
        // later overwrite the history returned by this save.
        if let loading = commandFrecencyLoadTask { await loading.value }
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
        if let history = deferredCommandFrecency {
            deferredCommandFrecency = nil
            updateCommandFrecency(history)
        }
        let store = commandComposer.frecencyStore
        guard store.hasPendingUsage, supportedCapabilities.contains(.slashCommands) else { return }
        if !store.hasLoadedRemoteHistory {
            guard let history = try? await session.provider.applicationCommandFrecency(),
                  !Task.isCancelled, isCurrentAccountSession(session)
            else { return }
            updateCommandFrecency(history)
        }
        let saving = store.pendingUsages
        do {
            let stored = try await session.provider.saveApplicationCommandFrecency(store.historyForSave())
            guard isCurrentAccountSession(session) else { return }
            store.acknowledge(saving)
            deferredCommandFrecency = nil
            updateCommandFrecency(stored)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            if let history = deferredCommandFrecency {
                deferredCommandFrecency = nil
                updateCommandFrecency(history)
            }
            if !(error is CancellationError) { DiscordAPIDiagnosticStore.shared.recordClientFailure(error) }
        }
    }
}
