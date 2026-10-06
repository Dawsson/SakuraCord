import SakuraCordModels
import SwiftUI

struct PollVotersView: View {
    static let size = CGSize(width: 540, height: 420)

    let model: AppModel
    let message: Message
    @State private var selectedAnswerID: Int
    @State private var pages: [Int: VoterPage] = [:]
    @State private var errors: [Int: String] = [:]
    @State private var loadingAnswerIDs: Set<Int> = []
    @State private var pendingRefreshAnswerIDs: Set<Int> = []

    private struct VoterPage {
        var users: [User]
        var hasMore: Bool
        /// The tally the page was loaded for; a changed tally refreshes it.
        var count: Int?
    }

    private struct LoadIdentity: Equatable {
        let answerID: Int
        let count: Int?
    }

    init(model: AppModel, message: Message, initialAnswerID: Int) {
        self.model = model
        self.message = message
        _selectedAnswerID = State(initialValue: initialAnswerID)
    }

    private var poll: MessagePoll? {
        model.retainedMessage(channelID: message.channelID, messageID: message.id)?.poll ?? message.poll
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                answerList.frame(width: 220)
                Divider()
                voterList.frame(maxWidth: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task(id: LoadIdentity(answerID: selectedAnswerID, count: count(for: selectedAnswerID))) {
            await refresh(selectedAnswerID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(poll?.question ?? "Poll").font(.headline).lineLimit(2)
            if let poll {
                Text(summary(poll)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var answerList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                if let poll {
                    ForEach(poll.answers) { answer in
                        Button { selectedAnswerID = answer.id } label: {
                            PollVotersAnswerRow(answer: answer, poll: poll)
                        }
                        .buttonStyle(PopoverRowButtonStyle(isSelected: selectedAnswerID == answer.id))
                        .accessibilityAddTraits(selectedAnswerID == answer.id ? .isSelected : [])
                    }
                }
            }
            .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var voterList: some View {
        let answerID = selectedAnswerID
        let page = pages[answerID]
        let voters = displayedUsers(page?.users ?? [])
        let guildID = model.messagePresentationGuildID(for: message)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(voters) { user in
                    PollVoterRow(model: model, user: user, guildID: guildID)
                }
                if let page, let error = errors[answerID] {
                    VStack(spacing: 6) {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Try Again") {
                            load(answerID, after: page.count == count(for: answerID) ? page.users.last?.id : nil)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if let page, page.hasMore {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .id(page.users.last?.id)
                        .onAppear { load(answerID, after: page.users.last?.id) }
                }
            }
            .padding(8)
        }
        .id(answerID)
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            if page == nil, let error = errors[answerID] {
                ContentUnavailableView {
                    Label("Couldn't Load Voters", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { load(answerID, after: nil) }.buttonStyle(.glass)
                }
            } else if !voters.isEmpty {
                EmptyView()
            } else if page == nil, count(for: answerID) != 0 {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView("No Votes", systemImage: "chart.bar")
            }
        }
    }

    /// The current user's pending vote is shown before Discord lists it.
    private func displayedUsers(_ users: [User]) -> [User] {
        guard let poll, poll.results != nil, let me = model.snapshot?.currentUser else { return users }
        let others = users.filter { $0.id != me.id }
        return poll.selectedAnswerIDs.contains(selectedAnswerID) ? [me] + others : others
    }

    private func summary(_ poll: MessagePoll) -> String {
        let votes = poll.results == nil ? "Votes unavailable" : poll.totalVotes == 1 ? "1 vote" : "\(poll.totalVotes) votes"
        if poll.isClosed() { return "\(votes) · Final results" }
        guard let expiry = poll.expiry else { return votes }
        return "\(votes) · Ends \(expiry.formatted(.relative(presentation: .named)))"
    }

    private func count(for answerID: Int) -> Int? {
        guard let poll, poll.results != nil else { return nil }
        return poll.count(for: answerID)
    }

    private func refresh(_ answerID: Int) async {
        if let page = pages[answerID] {
            guard page.count != count(for: answerID) else { return }
            // Tallies change with every vote; keep the current list while they settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        load(answerID, after: nil)
    }

    /// Like Discord, an answer's voters load when it is selected. Loads outlive
    /// answer switches, so a page started for one answer still fills its cache.
    private func load(_ answerID: Int, after: UserID?) {
        guard loadingAnswerIDs.insert(answerID).inserted else {
            if after == nil { pendingRefreshAnswerIDs.insert(answerID) }
            return
        }
        errors[answerID] = nil
        let count = count(for: answerID)
        let session = model.accountSession()
        Task {
            defer {
                loadingAnswerIDs.remove(answerID)
                if pendingRefreshAnswerIDs.remove(answerID) != nil, model.isCurrentAccountSession(session) {
                    load(answerID, after: nil)
                }
            }
            if count == 0 {
                pages[answerID] = VoterPage(users: [], hasMore: false, count: 0)
                return
            }
            do {
                let page = try await session.provider.pollVoters(messageID: message.id, channelID: message.channelID,
                                                               answerID: answerID, after: after, limit: 100)
                guard model.isCurrentAccountSession(session) else { return }
                var seen = Set<UserID>()
                let existing = after == nil ? [] : pages[answerID]?.users ?? []
                pages[answerID] = VoterPage(users: (existing + page.users).filter { seen.insert($0.id).inserted },
                                            hasMore: page.hasMore, count: after == nil ? count : pages[answerID]?.count)
                errors[answerID] = nil
            } catch {
                guard model.isCurrentAccountSession(session) else { return }
                errors[answerID] = error.localizedDescription
            }
        }
    }
}

private struct PollVotersAnswerRow: View {
    let answer: PollAnswer
    let poll: MessagePoll

    var body: some View {
        let count = poll.count(for: answer.id)
        let fraction = poll.totalVotes > 0 ? Double(count) / Double(poll.totalVotes) : 0
        let voted = poll.selectedAnswerIDs.contains(answer.id)
        HStack(spacing: 10) {
            if let emoji = answer.emoji { PollAnswerEmoji(emoji: emoji, size: 20) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(answer.text).font(.callout.weight(.medium)).lineLimit(2)
                    if voted {
                        Image(systemName: "checkmark.circle.fill").font(.caption)
                            .foregroundStyle(SakuraCordAccentColor.color)
                            .accessibilityLabel("You voted")
                    }
                    Spacer(minLength: 4)
                    Text(poll.results == nil ? "—" : "\(count)").font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Capsule().fill(.quaternary).frame(height: 4).overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(voted ? SakuraCordAccentColor.color : .secondary)
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(ConcentricRectangle(cornerRadius: 16))
        .animation(.snappy, value: fraction)
        .accessibilityElement(children: .combine)
        .accessibilityValue(poll.results == nil ? "Votes unavailable" : count == 1 ? "1 vote" : "\(count) votes")
    }
}

private struct PollVoterRow: View {
    let model: AppModel
    let user: User
    let guildID: GuildID?

    var body: some View {
        let member = guildID.flatMap { guildID in
            model.membersByGuildID[guildID]?[user.id]
                ?? (guildID == model.selectedGuildID ? model.membersByID[user.id] : nil)
        }
        let isCurrentUser = model.snapshot?.currentUser.id == user.id
        HStack(spacing: 10) {
            AvatarView(name: user.displayName, url: member?.guildAvatarURL ?? user.avatarURL, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(member?.user.displayName ?? user.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(user.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrentUser {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A poll answer's custom or Unicode emoji.
struct PollAnswerEmoji: View {
    let emoji: EmojiReference
    let size: CGFloat

    var body: some View {
        Group {
            if let url = emoji.imageURL(size: 64) {
                AnimatedRemoteImage(url: url, animates: false, contentMode: .fit, usesSwiftUIRendering: true)
            } else {
                // Color emoji ink is about 1.15× the point size and sits slightly
                // above the line box's center; this matches image emoji (measured).
                Text(emoji.name).font(.system(size: size * 0.85)).fixedSize().offset(y: size / 80)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
