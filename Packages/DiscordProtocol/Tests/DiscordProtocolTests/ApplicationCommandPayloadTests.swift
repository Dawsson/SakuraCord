import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

private func fixtureCommand(
    options: [ApplicationCommandOption], guildID: GuildID? = GuildID("300")!
) -> ApplicationCommand {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    return ApplicationCommand(
        id: "200:admin/run",
        rootCommandID: "200",
        applicationID: application.id,
        guildID: guildID,
        version: "201",
        name: "admin",
        application: application,
        options: options,
        subcommandPath: [
            ApplicationCommandPathComponent(name: "run", type: .subcommand)
        ],
        rootCommandJSON: Data(
            #"{"id":"200","application_id":"100","name":"admin","future":true}"#.utf8
        )
    )
}

@Test("global command invoked in a guild does not claim guild registration")
func globalCommandInvocationScopeContract() throws {
    let command = fixtureCommand(options: [], guildID: nil)
    let invocation = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [],
        nonce: "600"
    )

    let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["guild_id"] == nil)
}

@Test("execution payload nests subcommands and indexes staged attachments")
func executionPayloadContract() throws {
    let options = [
        ApplicationCommandOption(name: "text", type: .string, isRequired: true),
        ApplicationCommandOption(name: "user", type: .user),
        ApplicationCommandOption(name: "channel", type: .channel),
        ApplicationCommandOption(name: "role", type: .role),
        ApplicationCommandOption(name: "mentionable", type: .mentionable),
        ApplicationCommandOption(name: "count", type: .integer, minimumValue: 1, maximumValue: 5),
        ApplicationCommandOption(name: "enabled", type: .boolean),
        ApplicationCommandOption(name: "ratio", type: .number),
        ApplicationCommandOption(name: "file", type: .attachment)
    ].map { option in
        var option = option
        option.id = "200/\(option.name)"
        return option
    }
    let file = URL(fileURLWithPath: "/tmp/sanitized-command.txt")
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: options),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: "200/text", name: "text", type: .string, argument: .string("hello")),
            .init(optionID: "200/user", name: "user", type: .user, argument: .user(UserID("500")!)),
            .init(
                optionID: "200/channel", name: "channel", type: .channel,
                argument: .channel(ChannelID("501")!)
            ),
            .init(
                optionID: "200/role", name: "role", type: .role,
                argument: .role(RoleID("502")!)
            ),
            .init(
                optionID: "200/mentionable", name: "mentionable", type: .mentionable,
                argument: .mentionable("503")
            ),
            .init(optionID: "200/count", name: "count", type: .integer, argument: .integer(3)),
            .init(optionID: "200/enabled", name: "enabled", type: .boolean, argument: .boolean(true)),
            .init(optionID: "200/ratio", name: "ratio", type: .number, argument: .number(1.5)),
            .init(optionID: "200/file", name: "file", type: .attachment, argument: .attachment(file))
        ],
        nonce: "600"
    )

    let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
    #expect(payload.attachmentURLs == [file])
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["id"] as? String == "200")
    #expect(object["name"] as? String == "admin")
    #expect(object["version"] as? String == "201")
    #expect(object["guild_id"] as? String == "300")
    let root = try #require(object["application_command"] as? [String: Any])
    #expect(root["future"] as? Bool == true)
    let outer = try #require(object["options"] as? [[String: Any]])
    #expect(outer.count == 1)
    #expect(outer[0]["name"] as? String == "run")
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.map { $0["name"] as? String } == [
        "text", "user", "channel", "role", "mentionable", "count", "enabled", "ratio", "file"
    ])
    #expect(leaves[1]["value"] as? String == "500")
    #expect(leaves[2]["value"] as? String == "501")
    #expect(leaves[3]["value"] as? String == "502")
    #expect(leaves[4]["value"] as? String == "503")
    #expect((leaves.last?["value"] as? NSNumber)?.intValue == 0)
}

@Test("autocomplete marks only the focused option and preserves earlier values")
func autocompletePayloadContract() throws {
    var scope = ApplicationCommandOption(name: "scope", type: .string)
    scope.id = "200/scope"
    var query = ApplicationCommandOption(
        name: "query", type: .string, minimumLength: 1, maximumLength: 20,
        usesAutocomplete: true
    )
    query.id = "200/query"
    var requiredLater = ApplicationCommandOption(
        name: "destination", type: .channel, isRequired: true
    )
    requiredLater.id = "200/destination"
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: [scope, query, requiredLater]),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: scope.id, name: scope.name, type: scope.type, argument: .string("all"))
        ],
        nonce: "600"
    )
    let request = ApplicationCommandAutocompleteRequest(
        invocation: invocation, focusedOptionID: query.id, query: "sa", nonce: "601"
    )

    let payload = try ApplicationCommandPayloadBuilder.autocomplete(request)
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let outer = try #require(object["options"] as? [[String: Any]])
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.count == 2)
    #expect(leaves[0]["focused"] == nil)
    #expect(leaves[1]["focused"] as? Bool == true)
    #expect(leaves[1]["value"] as? String == "sa")
    #expect(leaves.contains { $0["name"] as? String == "destination" } == false)
}

@Test("invalid and missing command values fail before transmission")
func commandPayloadValidation() throws {
    var required = ApplicationCommandOption(
        name: "count", type: .integer, isRequired: true, minimumValue: 1, maximumValue: 5
    )
    required.id = "200/count"
    let command = fixtureCommand(options: [required])
    let missing = ApplicationCommandInvocation(
        command: command, channelID: ChannelID("400")!, guildID: GuildID("300")!, values: []
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(missing)
    }

    let tooLarge = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(optionID: required.id, name: required.name, type: .integer, argument: .integer(9))
        ]
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(tooLarge)
    }

    let minimumInteger = ApplicationCommandInvocation(
        command: command,
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: [
            .init(
                optionID: required.id, name: required.name, type: .integer,
                argument: .integer(.min)
            )
        ]
    )
    #expect(throws: ChatProviderError.self) {
        try ApplicationCommandPayloadBuilder.execution(minimumInteger)
    }
}

@Test("autocomplete accepts a partial value below the final minimum length")
func autocompletePartialValueIgnoresFinalMinimumLength() throws {
    var option = ApplicationCommandOption(
        name: "query", type: .string, isRequired: true,
        minimumLength: 3, maximumLength: 20, usesAutocomplete: true
    )
    option.id = "200/query"
    let invocation = ApplicationCommandInvocation(
        command: fixtureCommand(options: [option]),
        channelID: ChannelID("400")!,
        guildID: GuildID("300")!,
        values: []
    )

    let payload = try ApplicationCommandPayloadBuilder.autocomplete(
        ApplicationCommandAutocompleteRequest(
            invocation: invocation,
            focusedOptionID: option.id,
            query: "a"
        )
    )
    let encoded = try JSONEncoder().encode(JSONValue.object(payload.data))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let outer = try #require(object["options"] as? [[String: Any]])
    let leaves = try #require(outer[0]["options"] as? [[String: Any]])
    #expect(leaves.first?["value"] as? String == "a")
    #expect(leaves.first?["focused"] as? Bool == true)
}

@Test("execution carries the definition the official client displayed")
func executionDefinitionNormalizationContract() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let chat = ApplicationCommand(
        id: "200", rootCommandID: "200", applicationID: "100", version: "201",
        name: "pick", application: application,
        options: [ApplicationCommandOption(id: "200/kind", name: "kind", type: .string, isRequired: true)],
        rootCommandJSON: Data(#"""
        {"id":"200","name":"pick","description":"Pick","name_localized":"choisir","options":[
          {"type":3,"name":"kind","description":"Kind","choices":[{"name":"A","value":"a"}]}]}
        """#.utf8)
    )
    let chatPayload = try ApplicationCommandPayloadBuilder.execution(ApplicationCommandInvocation(
        command: chat, channelID: ChannelID("400")!, guildID: nil,
        values: [.init(optionID: "200/kind", name: "kind", type: .string, argument: .string("a"))]
    ))
    let definition = try #require(chatPayload.data["application_command"]?.objectValue)
    // An index-provided localization is kept; missing ones repeat the shown text.
    #expect(definition["name_localized"] == .string("choisir"))
    #expect(definition["description_localized"] == .string("Pick"))
    let option = try #require(definition["options"]?.arrayValue?.first?.objectValue)
    #expect(option["name_localized"] == .string("kind"))
    #expect(option["description_localized"] == .string("Kind"))
    let choice = try #require(option["choices"]?.arrayValue?.first?.objectValue)
    #expect(choice["name_localized"] == .string("A"))
    #expect(choice["description_localized"] == nil)

    let context = ApplicationCommand(
        id: "300", rootCommandID: "300", applicationID: "100", version: "301", type: .message,
        name: "Inspect", application: application,
        rootCommandJSON: Data(#"{"id":"300","type":3,"name":"Inspect"}"#.utf8)
    )
    let contextPayload = try ApplicationCommandPayloadBuilder.execution(ApplicationCommandInvocation(
        command: context, channelID: ChannelID("400")!, guildID: nil, values: [], targetID: "500"
    ))
    #expect(contextPayload.data["target_id"] == .string("500"))
    #expect(contextPayload.data["type"] == .number(3))
    let contextDefinition = try #require(contextPayload.data["application_command"]?.objectValue)
    #expect(contextDefinition["description"] == .string(""))
    #expect(contextDefinition["options"] == .array([]))
    #expect(contextDefinition["name_localized"] == .string("Inspect"))
    #expect(contextDefinition["description_localized"] == nil)
}

@Test("modal submissions keep wrappers and distinguish untouched from cleared")
func modalSubmissionPlanContract() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let text = { (id: String) in
        ModalControl(id: id, customID: id, kind: .textInput(
            style: .short, placeholder: nil, minLength: nil, maxLength: nil, initialValue: nil
        ), isRequired: false)
    }
    let select = ModalControl(id: "s", customID: "strings", kind: .select(
        kind: .string, placeholder: nil, options: [], minValues: 0, maxValues: 1,
        channelTypes: [], defaultValues: []
    ), isRequired: false)
    let files = ModalControl(id: "f", customID: "files", kind: .fileUpload(
        minValues: 0, maxValues: 2, fileTypes: []
    ), isRequired: false)
    let modal = InteractionModal(
        interactionID: "777", openingNonce: "1", application: application,
        channelID: ChannelID("400")!, guildID: nil, customID: "form", title: "Form",
        nodes: [
            .textDisplay(id: "0", content: "Read me"),
            .actionRow(id: "1", children: [.control(text("legacy"))]),
            .label(id: "2", label: "Untouched", description: nil, child: .control(text("untouched"))),
            .label(id: "3", label: "Cleared", description: nil, child: .control(text("cleared"))),
            .label(id: "4", label: "Select", description: nil, child: .control(select)),
            .label(id: "5", label: "Files", description: nil, child: .control(files))
        ]
    )
    let urls = [URL(fileURLWithPath: "/a.txt"), URL(fileURLWithPath: "/b.txt")]
    let plan = ModalSubmissionPayloadBuilder.plan(ModalSubmission(modal: modal, values: [
        "legacy": .text("kept"),
        "untouched": .text(nil),
        "cleared": .text(""),
        "strings": .values(nil),
        "files": .files(urls)
    ]))

    let encoded = try JSONEncoder().encode(JSONValue.array(plan.components))
    let json = try #require(String(data: encoded, encoding: .utf8))
    let expected = try JSONEncoder().encode(JSONValue.array([
        .object(["type": .number(10)]),
        .object(["type": .number(1), "components": .array([
            .object(["type": .number(4), "custom_id": .string("legacy"), "value": .string("kept")])
        ])]),
        .object(["type": .number(18), "component": .object([
            "type": .number(4), "custom_id": .string("untouched"), "value": .null
        ])]),
        .object(["type": .number(18), "component": .object([
            "type": .number(4), "custom_id": .string("cleared"), "value": .string("")
        ])]),
        .object(["type": .number(18), "component": .object([
            "type": .number(3), "custom_id": .string("strings"), "values": .null
        ])]),
        .object(["type": .number(18), "component": .object([
            "type": .number(19), "custom_id": .string("files"), "values": .array([.number(0), .number(1)])
        ])])
    ]))
    #expect(
        try JSONSerialization.jsonObject(with: encoded) as? NSArray
            == JSONSerialization.jsonObject(with: expected) as? NSArray,
        "\(json)"
    )
    #expect(plan.fileURLs == urls)
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}
