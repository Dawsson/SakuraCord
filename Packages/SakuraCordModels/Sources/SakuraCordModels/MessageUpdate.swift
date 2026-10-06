import Foundation

/// A sparse server update can reconcile any retained projection, even when the
/// provider has evicted the original message from its bounded working set.
public struct MessageUpdate: Equatable, Sendable {
    public let messageID: MessageID
    public let channelID: ChannelID
    public var pollUpdates: [MessagePollUpdate] = []
    public var content: String?
    public var editedTimestamp: Date??
    public var attachments: [Attachment]?
    public var embeds: [MessageEmbed]?
    public var components: [MessageComponent]?
    public var stickers: [MessageSticker]?
    public var thread: MessageThreadSummary??
    public var flags: MessageFlags?
    public var isPinned: Bool?
    public var type: DiscordMessageType?
    public var application: ApplicationCommandApplication?
    public var interactionMetadata: MessageInteractionMetadata?
    public var mentionedUsers: [User]?
    public var mentionedRoleIDs: [RoleID]?
    public var mentionsEveryone: Bool?
    public var updatedUsers: [UserID: User] = [:]
    public var webhookAuthor: User?

    public init(messageID: MessageID, channelID: ChannelID) {
        self.messageID = messageID
        self.channelID = channelID
    }

    public mutating func merge(_ newer: MessageUpdate) {
        guard messageID == newer.messageID, channelID == newer.channelID else { return }
        pollUpdates.append(contentsOf: newer.pollUpdates)
        content = newer.content ?? content
        if newer.editedTimestamp != nil { editedTimestamp = newer.editedTimestamp }
        attachments = newer.attachments ?? attachments
        embeds = newer.embeds ?? embeds
        components = newer.components ?? components
        stickers = newer.stickers ?? stickers
        if newer.thread != nil { thread = newer.thread }
        flags = newer.flags ?? flags
        isPinned = newer.isPinned ?? isPinned
        type = newer.type ?? type
        application = newer.application ?? application
        interactionMetadata = newer.interactionMetadata ?? interactionMetadata
        // Identity events affect older mention snapshots, while an explicit
        // newer mention list keeps its guild-specific names and avatars.
        mentionedUsers = newer.mentionedUsers ?? mentionedUsers?.map { newer.updatedUsers[$0.id] ?? $0 }
        mentionedRoleIDs = newer.mentionedRoleIDs ?? mentionedRoleIDs
        mentionsEveryone = newer.mentionsEveryone ?? mentionsEveryone
        updatedUsers.merge(newer.updatedUsers) { _, newer in newer }
        webhookAuthor = newer.webhookAuthor ?? webhookAuthor
    }

    public func apply(to message: inout Message) {
        guard message.id == messageID, message.channelID == channelID else { return }
        for user in updatedUsers.values { message.applyIdentityUpdate(user) }
        if let webhookAuthor, message.webhookID != nil, message.author.id == webhookAuthor.id {
            message.author = webhookAuthor
        }
        applyContent(to: &message)
        for update in pollUpdates { update.apply(to: &message) }
        if let thread { message.thread = thread }
        if let flags { message.flags = flags }
        if let isPinned { message.isPinned = isPinned }
        if let type { message.type = type }
        if let application {
            message.application = application
            message.applicationID = ApplicationID(application.id)
        }
        if var interactionMetadata {
            interactionMetadata.applicationID = interactionMetadata.applicationID ?? message.applicationID?.description
            message.interactionMetadata = interactionMetadata
        }
        if let mentionedUsers { message.mentionedUsers = mentionedUsers }
        if let mentionedRoleIDs { message.mentionedRoleIDs = mentionedRoleIDs }
        if let mentionsEveryone { message.mentionsEveryone = mentionsEveryone }
    }

    private func applyContent(to message: inout Message) {
        if let content { message.content = content }
        if let editedTimestamp { message.editedTimestamp = editedTimestamp }
        if let attachments { message.attachments = attachments }
        if let embeds { message.embeds = embeds }
        if let components { message.components = components }
        if let stickers { message.stickers = stickers }
    }

}

public extension Message {
    mutating func applyIdentityUpdate(_ user: User) {
        if author.id == user.id { author = user }
        for index in mentionedUsers.indices where mentionedUsers[index].id == user.id {
            mentionedUsers[index] = user
        }
    }
}
