import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

private let frecencyNow = Date(timeIntervalSince1970: 1_790_000_000)

private func millisecondsAgo(days: Double) -> UInt64 {
    UInt64((frecencyNow.timeIntervalSince1970 - days * 86_400) * 1_000)
}

private func pickerCommand(
    _ id: String,
    _ name: String,
    application: ApplicationCommandApplication,
    guildID: GuildID? = nil,
    subcommand: String? = nil,
    description: String = ""
) -> ApplicationCommand {
    ApplicationCommand(
        id: subcommand.map { "\(id) \($0)" } ?? id, rootCommandID: id, applicationID: application.id,
        guildID: guildID, version: "1", name: name, description: description, application: application,
        subcommandPath: subcommand.map { [ApplicationCommandPathComponent(name: $0, type: .subcommand)] } ?? []
    )
}

@MainActor
@Test("command frecency scores recent uses with Discord's day weights")
func commandFrecencyScoring() {
    let store = ApplicationCommandFrecencyStore(now: { frecencyNow })
    store.overwrite(with: ApplicationCommandFrecencyHistory(entries: [
        ApplicationCommandFrecencyEntry(
            key: "1", totalUses: 20, recentUses: [millisecondsAgo(days: 20), millisecondsAgo(days: 1)]
        ),
        ApplicationCommandFrecencyEntry(key: "2", totalUses: 4, recentUses: [millisecondsAgo(days: 100)]),
        ApplicationCommandFrecencyEntry(key: "3", totalUses: 9, recentUses: []),
        ApplicationCommandFrecencyEntry(key: "4", totalUses: 1, recentUses: [millisecondsAgo(days: 2)]),
    ]))

    #expect(store.score(for: "1") == 1.5)
    #expect(store.score(for: "2") == 0.01)
    // An entry without recent uses scores zero and is dropped; equal frecency keeps stored order.
    #expect(store.frequently == ["1", "2", "4"])
    let saved = store.historyForSave().entries
    #expect(saved.map(\.key) == ["1", "2", "4"])
    #expect(saved[0].frecency == 15 && saved[0].score == 2)
    #expect(saved[1].frecency == 1 && saved[1].score == 0)
}

@MainActor
@Test("pending command uses replay over newer synced history until saved")
func commandFrecencyPendingReplay() {
    let store = ApplicationCommandFrecencyStore(now: { frecencyNow })
    store.recordUse("-7")
    store.overwrite(with: ApplicationCommandFrecencyHistory(entries: [
        ApplicationCommandFrecencyEntry(key: "-7", totalUses: 4, recentUses: [millisecondsAgo(days: 1)]),
    ]))

    #expect(store.hasPendingUsage)
    #expect(store.historyForSave().entries.first?.totalUses == 5)

    let saving = store.pendingUsages
    let response = store.historyForSave()
    // Another command is executed while the save is in flight.
    store.recordUse("-7")
    store.acknowledge(saving)
    store.overwrite(with: response)
    #expect(store.pendingUsages.count == 1)
    #expect(store.historyForSave().entries.first?.totalUses == 6)
    let finalResponse = store.historyForSave()
    store.acknowledge(store.pendingUsages)
    store.overwrite(with: finalResponse)
    #expect(!store.hasPendingUsage)
    #expect(store.historyForSave().entries.first?.totalUses == 6)
}

@MainActor
@Test("command frecency keys and scopes follow Discord's identity rules")
func commandFrecencyKeys() {
    let app = ApplicationCommandApplication(id: "10", name: "App")
    let guild = GuildID(rawValue: 77)
    let guildCommand = pickerCommand("20", "research", application: app, guildID: guild, subcommand: "modal")
    let globalCommand = pickerCommand("21", "ping", application: app)
    let builtIn = DiscordBuiltInCommands.all.first { $0.name == "nick" }!

    #expect(ApplicationCommandPickerEngine.frecencyKey(of: guildCommand, guildID: guild) == "20\u{0}modal:77")
    #expect(ApplicationCommandPickerEngine.frecencyKey(of: globalCommand, guildID: guild) == "21")
    #expect(ApplicationCommandPickerEngine.frecencyKey(of: builtIn, guildID: guild) == "-7")
    #expect(ApplicationCommandPickerEngine.scopedCommandIDs(["20:77", "20:78", "21", "-7"], guildID: guild) == ["20", "21", "-7"])
    #expect(ApplicationCommandPickerEngine.scopedCommandIDs(["20:77", "21"], guildID: nil) == ["21"])
}

@MainActor
@Test("command queries end at an option or the fourth word")
func commandQueryParsing() {
    #expect(ApplicationCommandPickerEngine.parse("sc") == ("sc", false))
    #expect(ApplicationCommandPickerEngine.parse("sc-research ") == ("sc-research", true))
    #expect(ApplicationCommandPickerEngine.parse("ban user:") == ("ban", true))
    #expect(ApplicationCommandPickerEngine.parse("a b c d e") == ("a b c", true))
}

@MainActor
@Test("command picker lists Frequently Used and search results in Discord's order")
func commandPickerOrdering() {
    let zoo = ApplicationCommandApplication(id: "1", name: "zoo")
    let alpha = ApplicationCommandApplication(id: "2", name: "Alpha")
    let commands = [
        pickerCommand("10", "ban", application: zoo),
        pickerCommand("11", "banner", application: zoo),
        pickerCommand("12", "urban", application: alpha),
        pickerCommand("13", "banana", application: alpha),
    ]
    let scores = ["11": 3.0, "12": 2.0, "-12": 1.0]
    let engine = ApplicationCommandPickerEngine(
        sources: [
            ApplicationCommandPickerSource(application: zoo, commands: Array(commands[0 ... 1])),
            ApplicationCommandPickerSource(application: alpha, commands: Array(commands[2 ... 3])),
        ],
        builtIns: DiscordBuiltInCommands.all.filter { $0.name == "ban" },
        locale: Locale(identifier: "en-GB"),
        frecencyScore: { scores[ApplicationCommandPickerEngine.discordID(of: $0)] ?? 0 },
        frequentCommandIDs: ["-12", "12", "11"]
    )

    let browse = engine.browse()
    #expect(browse.sections.map(\.name) == ["Alpha", "zoo", "Built-in"])
    #expect(browse.sections[0].commands.map(\.name) == ["banana", "urban"])
    #expect(browse.frequentlyUsed.map(\.id) == ["11", "12", "-12"])

    // Name prefixes first, frecency breaks ties before name order, then contains matches.
    #expect(engine.search("ban").map(\.id) == ["11", "-12", "10", "13", "12"])
    #expect(engine.search("ban ").map(\.id) == ["-12", "10"])
}
