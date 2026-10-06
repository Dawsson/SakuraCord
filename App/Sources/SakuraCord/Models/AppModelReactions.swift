import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func edit(_ message: Message, content: String) async {
        guard !message.hasPoll else { return }
        let session = accountSession()
        do {
            let updated = try await session.provider.edit(
                messageID: message.id, channelID: message.channelID, content: content
            )
            guard isCurrentAccountSession(session) else { return }
            let reconciled = reconcileVisibleOrCached(updated)
            recordAuthoritativeMessageUpsert(reconciled)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ message: Message) async {
        let session = accountSession()
        do {
            try await session.provider.delete(
                messageID: message.id,
                channelID: message.channelID
            )
            guard isCurrentAccountSession(session) else { return }
            consumeMessageDeleted(
                channelID: message.channelID,
                messageID: message.id
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func dismissEphemeralMessage(_ message: Message) {
        guard message.flags.contains(.ephemeral) else { return }
        if message.channelID == selectedChannelID {
            mutateSelectedMessages {
                $0.removeAll { $0.id == message.id }
            }
        }
        messageCache[message.channelID]?.removeAll { $0.id == message.id }
    }

    func toggleReaction(_ emoji: String, on message: Message) async {
        let guildID = message.guildID ?? selectedGuildID
        let currentGuildEmojis = guildID.flatMap { emojisByGuild[$0] } ?? []
        guard
            DiscordEmojiPermissionPolicy.canToggleReaction(
                emoji,
                existingReactions: message.reactions,
                currentGuildEmojis: currentGuildEmojis,
                premiumType: snapshot?.currentUser.premiumType ?? 0
            )
        else {
            errorMessage = "Nitro is required for animated and other-server emoji reactions."
            return
        }
        guard snapshot?.currentUser.id != nil else {
            errorMessage = ChatProviderError.unauthenticated.localizedDescription
            return
        }

        let key = ReactionMutationKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: Reaction(emoji: emoji, count: 0).id
        )
        let latestMessage = reactionMessage(for: key) ?? message
        let latestReacted =
            latestMessage.reactions.first(where: { $0.id == key.reactionID })?
                .didCurrentUserReact ?? false
        var state =
            reactionMutations[key]
            ?? ReactionMutationState(
                emoji: emoji,
                confirmedReacted: latestReacted,
                desiredReacted: latestReacted,
                generation: 0,
                isSending: false
            )
        state.emoji = emoji
        state.desiredReacted.toggle()
        state.generation &+= 1
        reactionMutations[key] = state
        applyCurrentUserReactionState(state.desiredReacted, for: key, emoji: emoji)

        if !state.isSending {
            scheduleReactionMutation(for: key)
        }
    }

    func scheduleReactionMutation(for key: ReactionMutationKey) {
        guard let state = reactionMutations[key], !state.isSending else { return }
        let generation = state.generation
        let debounce = reactionMutationTiming.debounce
        reactionMutationTasks[key]?.cancel()
        reactionMutationTasks[key] = Task { @MainActor [weak self] in
            if debounce > .zero {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.sendReactionMutation(for: key, generation: generation)
        }
    }

    func sendReactionMutation(
        for key: ReactionMutationKey,
        generation: UInt64
    ) async {
        let session = accountSession()
        guard var state = reactionMutations[key],
              state.generation == generation,
              !state.isSending
        else { return }
        reactionMutationTasks[key] = nil
        guard state.desiredReacted != state.confirmedReacted else {
            reactionMutations[key] = nil
            return
        }

        let sentState = state.desiredReacted
        state.isSending = true
        reactionMutations[key] = state
        do {
            try await session.provider.setReaction(
                state.emoji,
                reacted: sentState,
                messageID: key.messageID,
                channelID: key.channelID
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            guard let latest = reactionMutations[key] else { return }
            applyCurrentUserReactionState(
                latest.confirmedReacted,
                for: key,
                emoji: latest.emoji
            )
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            errorMessage = error.localizedDescription
            return
        }

        guard isCurrentAccountSession(session) else { return }
        guard var latest = reactionMutations[key] else { return }
        latest.confirmedReacted = sentState
        latest.isSending = false
        applyCurrentUserReactionState(
            latest.desiredReacted,
            for: key,
            emoji: latest.emoji
        )
        if latest.desiredReacted == latest.confirmedReacted {
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            if let message = reactionMessage(for: key) {
                recordAuthoritativeMessageUpsert(message)
            }
        } else {
            reactionMutations[key] = latest
            if let message = reactionMessage(for: key) {
                recordAuthoritativeMessageUpsert(message)
            }
            scheduleReactionMutation(for: key)
        }
    }

    func reactionMessage(for key: ReactionMutationKey) -> Message? {
        messageInWorkspace(channelID: key.channelID, messageID: key.messageID)
            ?? presentedGuideResource?.messages.first { $0.id == key.messageID && $0.channelID == key.channelID }
            ?? inbox.retainedMessages.first { $0.id == key.messageID }
    }

    func knownReactionReactor(for userID: UserID) -> ReactionReactor? {
        if let member = membersByID[userID] {
            return ReactionReactor(
                id: userID,
                displayName: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL
            )
        }
        guard snapshot?.currentUser.id == userID, let user = snapshot?.currentUser else {
            return nil
        }
        return ReactionReactor(user: user)
    }

    func applyCurrentUserReactionState(
        _ reacted: Bool,
        for key: ReactionMutationKey,
        emoji: String
    ) {
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let update: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        applyReactionUpdate(update, persistsResult: false)
    }

    func loadReactionReactors(_ reaction: Reaction, on message: Message) async {
        guard reaction.count > 0, reaction.reactors.isEmpty else { return }
        guard await waitForTimelineScrollingToEnd() else { return }
        let session = accountSession()
        let key = ReactionReactorLoadKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: reaction.id
        )
        if let failedAt = failedReactionReactorLoads[key],
           Date.now.timeIntervalSince(failedAt) < 30
        {
            return
        }
        guard loadingReactionReactors.insert(key).inserted else { return }
        defer {
            if isCurrentAccountSession(session) {
                loadingReactionReactors.remove(key)
            }
        }

        do {
            let reactors = try await reactionReactorLoadLimiter.withPermit {
                try await session.provider.reactionReactors(
                    for: reaction.emoji,
                    messageID: message.id,
                    channelID: message.channelID,
                    reactionCount: reaction.count
                )
            }
            guard await waitForTimelineScrollingToEnd(),
                  isCurrentAccountSession(session)
            else { return }
            failedReactionReactorLoads[key] = nil
            applyReactionReactors(reactors, for: key)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(session) else { return }
            if failedReactionReactorLoads.count >= 256,
               let oldest = failedReactionReactorLoads.min(by: { $0.value < $1.value })?.key
            {
                failedReactionReactorLoads[oldest] = nil
            }
            failedReactionReactorLoads[key] = .now
        }
    }

    func applyReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorLoadKey
    ) {
        var seen: Set<UserID> = []
        let normalized = reactors.filter { seen.insert($0.id).inserted }.prefix(5)

        func updating(_ values: [Message]) -> [Message] {
            guard let messageIndex = values.firstIndex(where: { $0.id == key.messageID }) else {
                return values
            }
            var result = values
            result[messageIndex] = updating(result[messageIndex])
            return result
        }

        func updating(_ message: Message) -> Message {
            guard
                let reactionIndex = message.reactions.firstIndex(where: {
                    $0.id == key.reactionID && $0.count > 0
                })
            else { return message }
            var result = message
            var seen = Set<UserID>()
            let merged =
                normalized + result.reactions[reactionIndex].reactors
            result.reactions[reactionIndex].reactors = Array(
                merged
                    .filter { seen.insert($0.id).inserted }
                    .prefix(min(5, max(0, result.reactions[reactionIndex].count)))
            )
            return result
        }

        if key.channelID == selectedChannelID {
            replaceSelectedMessages(with: updating(messages))
        } else if var cached = messageCache[key.channelID] {
            cached = updating(cached)
            messageCache[key.channelID] = cached
        }
        if key.channelID == openThread?.id {
            threadMessages = updating(threadMessages)
        }
        if let resource = presentedGuideResource, resource.channelID == key.channelID,
           let message = resource.messages.first(where: { $0.id == key.messageID }) {
            receiveGuideResourceEvent(.messageUpdated(updating(message)))
        }
        if let message = inbox.retainedMessages.first(where: { $0.id == key.messageID }) {
            reconcileInboxMessage(updating(message))
        }

        guard let forumIndex = forumCatalogueIndexByID[key.channelID] else { return }
        var forumPost = forumCataloguePosts[forumIndex]
        if let firstMessage = forumPost.firstMessage {
            forumPost.firstMessage = updating(firstMessage)
        }
        if let mostRecentMessage = forumPost.mostRecentMessage {
            forumPost.mostRecentMessage = updating(mostRecentMessage)
        }
        guard forumPost != forumCataloguePosts[forumIndex] else { return }
        forumCataloguePosts[forumIndex] = forumPost
        updateForumPresentation(with: forumPost)
    }

    func clearReactionReactorLoadState(
        channelID: ChannelID,
        messageID: MessageID
    ) {
        loadingReactionReactors = Set(
            loadingReactionReactors.filter {
                $0.channelID != channelID || $0.messageID != messageID
            })
        failedReactionReactorLoads = failedReactionReactorLoads.filter {
            $0.key.channelID != channelID || $0.key.messageID != messageID
        }
    }

    func clearReactionMutationState(
        channelID: ChannelID? = nil,
        messageID: MessageID? = nil
    ) {
        let keys = reactionMutations.keys.filter { key in
            (channelID == nil || key.channelID == channelID)
                && (messageID == nil || key.messageID == messageID)
        }
        for key in keys {
            reactionMutationTasks[key]?.cancel()
            reactionMutationTasks[key] = nil
            reactionMutations[key] = nil
        }
    }

    private func applyInboxReactionUpdate(_ update: MessageReactionUpdate, currentUserID: UserID?, reactor: ReactionReactor?) {
        if let message = inbox.retainedMessages.first(where: { $0.id == update.messageID }) {
            var updated = message
            if updated.applyReactionUpdate(update, currentUserID: currentUserID, reactor: reactor) {
                reconcileInboxMessage(updated)
            }
        }

    }

    func applyReactionUpdate(
        _ update: MessageReactionUpdate,
        persistsResult: Bool = true
    ) {
        let currentUserID = snapshot?.currentUser.id
        let reactor: ReactionReactor? =
            switch update {
            case .add(_, _, let userID, _, _):
                knownReactionReactor(for: userID)
            case .remove, .removeAll, .removeEmoji:
                nil
            }
        var messageToPersist: Message?

        func applying(to values: inout [Message]) {
            guard
                let index = values.firstIndex(where: {
                    $0.id == update.messageID && $0.channelID == update.channelID
                })
            else {
                return
            }
            var message = values[index]
            if message.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: reactor
            ) {
                values[index] = message
            }
            messageToPersist = message
        }

        if update.channelID == selectedChannelID {
            var updated = messages
            applying(to: &updated)
            if updated != messages {
                replaceSelectedMessages(with: updated)
            }
        }
        if var cached = messageCache[update.channelID] {
            applying(to: &cached)
            messageCache[update.channelID] = cached
        }
        if update.channelID == openThread?.id {
            applying(to: &threadMessages)
        }

        applyInboxReactionUpdate(update, currentUserID: currentUserID, reactor: reactor)

        if var resourceMessages = presentedGuideResource?.messages {
            applying(to: &resourceMessages)
            if let message = resourceMessages.first(where: { $0.id == update.messageID && $0.channelID == update.channelID }) {
                receiveGuideResourceEvent(.messageUpdated(message))
            }
        }

        if let forumIndex = forumCatalogueIndexByID[update.channelID] {
            var post = forumCataloguePosts[forumIndex]
            if var firstMessage = post.firstMessage, firstMessage.id == update.messageID {
                _ = firstMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                )
                post.firstMessage = firstMessage
                messageToPersist = firstMessage
            }
            if var mostRecentMessage = post.mostRecentMessage,
               mostRecentMessage.id == update.messageID
            {
                _ = mostRecentMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                )
                post.mostRecentMessage = mostRecentMessage
                messageToPersist = mostRecentMessage
            }
            if post != forumCataloguePosts[forumIndex] {
                forumCataloguePosts[forumIndex] = post
                updateForumPresentation(with: post)
            }
        }

        if persistsResult {
            for (key, mutation) in reactionMutations
            where key.channelID == update.channelID && key.messageID == update.messageID {
                applyCurrentUserReactionState(
                    mutation.desiredReacted,
                    for: key,
                    emoji: mutation.emoji
                )
            }
            let lookupKey = ReactionMutationKey(
                channelID: update.channelID,
                messageID: update.messageID,
                reactionID: ""
            )
            messageToPersist = reactionMessage(for: lookupKey) ?? messageToPersist
        }

        if persistsResult, let messageToPersist {
            recordAuthoritativeMessageUpsert(messageToPersist)
        }
    }

}
