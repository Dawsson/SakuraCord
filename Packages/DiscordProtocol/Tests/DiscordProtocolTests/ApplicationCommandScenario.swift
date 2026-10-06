@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

struct ApplicationCommandScenario {
    var run: Void {
        get async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("command-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([])
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket)
        )
        let events = await provider.eventStream()

        _ = try await provider.bootstrap()
        #expect(await eventually { await socket.sentCount == 1 })
        let target = ApplicationCommandIndexTarget.guild(GuildID(rawValue: 100))
        let first = try await provider.applicationCommandCatalog(for: target)
        let second = try await provider.applicationCommandCatalog(for: target)
        let userCatalog = try await provider.applicationCommandCatalog(for: .user)
        let channelTarget = ApplicationCommandIndexTarget.channel(ChannelID(rawValue: 200))
        _ = try await provider.applicationCommandCatalog(for: channelTarget)
        #expect(first == second)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 1)
        #expect(RateLimitURLProtocol.userCommandIndexRequests == 1)
        #expect(RateLimitURLProtocol.channelCommandIndexRequests == 1)

        let versionInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["guild_id": .string("100"), "version": .string("904")]),
            sequence: 2,
            eventName: "GUILD_APPLICATION_COMMAND_INDEX_UPDATE"
        ))
        #expect(await versionInvalidation.value == target)
        _ = try await provider.applicationCommandCatalog(for: target)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 2)

        let userInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["application_id": .string("900")]),
            sequence: 3,
            eventName: "USER_APPLICATION_UPDATE"
        ))
        #expect(await userInvalidation.value == .user)
        _ = try await provider.applicationCommandCatalog(for: .user)
        #expect(RateLimitURLProtocol.userCommandIndexRequests == 2)

        let guildInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["id": .string("100"), "unavailable": .bool(true)]),
            sequence: 4,
            eventName: "GUILD_DELETE"
        ))
        #expect(await guildInvalidation.value == target)
        _ = try await provider.applicationCommandCatalog(for: target)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 3)

        let channelInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["id": .string("200"), "guild_id": .string("100")]),
            sequence: 5,
            eventName: "CHANNEL_DELETE"
        ))
        #expect(await channelInvalidation.value == channelTarget)
        _ = try await provider.applicationCommandCatalog(for: channelTarget)
        #expect(RateLimitURLProtocol.channelCommandIndexRequests == 2)

        let command = try #require(first.commands.first)
        let option = try #require(command.options.first)
        let invocation = ApplicationCommandInvocation(
            command: command,
            channelID: ChannelID(rawValue: 200),
            guildID: GuildID(rawValue: 100),
            values: [
                .init(
                    optionID: option.id,
                    name: option.name,
                    type: option.type,
                    argument: .string("sakura")
                )
            ],
            nonce: "command-nonce"
        )
        try await provider.executeApplicationCommand(invocation) { _ in }
        #expect(RateLimitURLProtocol.interactionRequestCount == 1)
        let execution = try #require(RateLimitURLProtocol.interactionBodies.first)
        #expect((execution["type"] as? NSNumber)?.intValue == 2)
        #expect(execution["application_id"] as? String == "900")
        #expect(execution["channel_id"] as? String == "200")
        #expect(execution["guild_id"] as? String == "100")
        #expect(execution["session_id"] as? String == "command-session")
        #expect(execution["nonce"] as? String == "command-nonce")
        #expect(execution["analytics_location"] as? String == "slash_ui")
        let executionData = try #require(execution["data"] as? [String: Any])
        #expect(executionData["id"] as? String == "901")
        #expect(executionData["version"] as? String == "902")
        #expect(executionData["guild_id"] as? String == "100")

        let globalCommand = try #require(userCatalog.commands.first)
        let globalOption = try #require(globalCommand.options.first)
        let globalInvocation = ApplicationCommandInvocation(
            command: globalCommand,
            channelID: ChannelID(rawValue: 200),
            guildID: GuildID(rawValue: 100),
            values: [
                .init(
                    optionID: globalOption.id,
                    name: globalOption.name,
                    type: globalOption.type,
                    argument: .string("sakura")
                )
            ],
            nonce: "global-command-nonce"
        )
        try await provider.executeApplicationCommand(globalInvocation) { _ in }
        #expect(RateLimitURLProtocol.interactionRequestCount == 2)
        let globalExecution = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect(globalExecution["guild_id"] as? String == "100")
        let globalExecutionData = try #require(globalExecution["data"] as? [String: Any])
        #expect(globalExecutionData["guild_id"] == nil)

        try await provider.requestApplicationCommandAutocomplete(
            ApplicationCommandAutocompleteRequest(
                invocation: invocation,
                focusedOptionID: option.id,
                query: "sa",
                nonce: "autocomplete-nonce"
            )
        )
        #expect(RateLimitURLProtocol.interactionRequestCount == 3)
        let autocomplete = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect((autocomplete["type"] as? NSNumber)?.intValue == 4)
        #expect(autocomplete["nonce"] as? String == "autocomplete-nonce")
        #expect(autocomplete["analytics_location"] == nil)

        let modalTask = Task { () -> InteractionModal? in
            for await event in events {
                if case let .interaction(.presentModal(modal)) = event,
                   modal.openingNonce == "command-nonce"
                {
                    return modal
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "id": .string("777"),
                "nonce": .string("command-nonce"),
                "application_id": .string("900"),
                "channel_id": .string("200"),
                "guild_id": .string("100"),
                "custom_id": .string("feedback"),
                "title": .string("Feedback"),
                "components": .array([
                    .object([
                        "type": .number(18), "id": .number(1),
                        "label": .string("Comment"),
                        "component": .object([
                            "type": .number(4), "id": .number(2),
                            "custom_id": .string("comment"), "style": .number(2),
                            "required": .bool(true), "min_length": .number(3)
                        ])
                    ]),
                    .object([
                        "type": .number(18), "id": .number(3),
                        "label": .string("Follow up"),
                        "component": .object([
                            "type": .number(23), "id": .number(4),
                            "custom_id": .string("follow-up"), "default": .bool(false)
                        ])
                    ])
                ])
            ]),
            sequence: 6,
            eventName: "INTERACTION_MODAL_CREATE"
        ))
        let modal = try #require(await modalTask.value)
        #expect(modal.customID == "feedback")
        #expect(modal.controls.count == 2)
        try await provider.submitModal(
            ModalSubmission(
                modal: modal,
                values: ["comment": .text("Looks good"), "follow-up": .checkbox(true)],
                nonce: "modal-nonce"
            )
        )
        #expect(RateLimitURLProtocol.interactionRequestCount == 4)
        let modalBody = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect((modalBody["type"] as? NSNumber)?.intValue == 5)
        // A submission is a new interaction; data.id names the one that opened it.
        #expect(modalBody["nonce"] as? String == "modal-nonce")
        let modalData = try #require(modalBody["data"] as? [String: Any])
        #expect(modalData["id"] as? String == "777")
        #expect(modalData["custom_id"] as? String == "feedback")
        let modalComponents = try #require(modalData["components"] as? [[String: Any]])
        #expect((modalComponents[0]["type"] as? NSNumber)?.intValue == 18)
        let textInput = try #require(modalComponents[0]["component"] as? [String: Any])
        #expect(textInput["value"] as? String == "Looks good")
        let checkbox = try #require(modalComponents[1]["component"] as? [String: Any])
        #expect(checkbox["value"] as? Bool == true)

        let acknowledgementEvent = Task { () -> ChannelReadState? in
            for await event in events {
                if case let .readStateChanged(state) = event { return state }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "channel_id": .string("200"),
                "message_id": .string("333"),
                "mention_count": .number(2),
                "manual": .bool(true),
                "flags": .number(3),
                "last_viewed": .number(4_222),
                "version": .number(73)
            ]),
            sequence: 7,
            eventName: "MESSAGE_ACK"
        ))
        #expect(
            await acknowledgementEvent.value
                == ChannelReadState(
                    channelID: ChannelID(rawValue: 200),
                    lastAcknowledgedMessageID: MessageID(rawValue: 333),
                    mentionCount: 2,
                    isManual: true,
                    flags: 3,
                    lastViewed: 4_222,
                    version: 73
                )
        )
        let notificationSettingsEvent = Task { () -> GuildNotificationSettings? in
            for await event in events {
                if case let .notificationSettingsChanged(settings) = event { return settings }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "message_notifications": .number(1),
                "muted": .bool(false),
                "suppress_everyone": .bool(true),
                "suppress_roles": .bool(false),
                "notify_highlights": .number(1),
                "mute_scheduled_events": .bool(true),
                "mobile_push": .bool(false),
                "channel_overrides": .array([
                    .object([
                        "channel_id": .string("200"),
                        "message_notifications": .number(0),
                        "muted": .bool(true),
                    ])
                ]),
            ]),
            sequence: 8,
            eventName: "USER_GUILD_SETTINGS_UPDATE"
        ))
        let decodedSettings = try #require(await notificationSettingsEvent.value)
        #expect(decodedSettings.guildID == GuildID(rawValue: 100))
        #expect(decodedSettings.messageNotifications == .onlyMentions)
        #expect(decodedSettings.suppressEveryone)
        #expect(decodedSettings.notifyHighlights == .disabled)
        #expect(decodedSettings.muteScheduledEvents)
        #expect(!decodedSettings.mobilePush)
        #expect(decodedSettings.channelOverrides.first?.messageNotifications == .allMessages)
        #expect(decodedSettings.channelOverrides.first?.isMuted == true)
        let partialSettingsEvent = Task { () -> GuildNotificationSettings? in
            for await event in events {
                if case let .notificationSettingsChanged(settings) = event { return settings }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "suppress_roles": .bool(true),
            ]),
            sequence: 9,
            eventName: "USER_GUILD_SETTINGS_UPDATE"
        ))
        let mergedSettings = try #require(await partialSettingsEvent.value)
        #expect(mergedSettings.suppressEveryone)
        #expect(mergedSettings.suppressRoles)
        #expect(mergedSettings.notifyHighlights == .disabled)
        #expect(mergedSettings.muteScheduledEvents)
        #expect(!mergedSettings.mobilePush)
        #expect(mergedSettings.channelOverrides.first?.isMuted == true)
        await provider.disconnect()
        }
    }
}
