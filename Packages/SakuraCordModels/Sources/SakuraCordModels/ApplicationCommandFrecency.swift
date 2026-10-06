import Foundation

/// One command's synced usage, as stored in Discord's frecency settings
/// (`application_command_frecency`). Keys follow Discord's client: the
/// flattened command ID (`root\0group\0sub`), suffixed `:guildID` for
/// guild-registered commands, or a negative ID for built-ins.
public struct ApplicationCommandFrecencyEntry: Codable, Hashable, Sendable {
    public var key: String
    public var totalUses: Int
    /// Millisecond timestamps, oldest first, at most ten.
    public var recentUses: [UInt64]
    /// Discord stores -1 when the value must be recomputed.
    public var frecency: Int32
    public var score: Int32

    public init(key: String, totalUses: Int, recentUses: [UInt64], frecency: Int32 = -1, score: Int32 = 0) {
        self.key = key
        self.totalUses = totalUses
        self.recentUses = recentUses
        self.frecency = frecency
        self.score = score
    }
}

/// The synced map in stored order. Order matters: Discord breaks frecency
/// ties by insertion order.
public struct ApplicationCommandFrecencyHistory: Codable, Hashable, Sendable {
    public var entries: [ApplicationCommandFrecencyEntry]

    public init(entries: [ApplicationCommandFrecencyEntry] = []) {
        self.entries = entries
    }
}
