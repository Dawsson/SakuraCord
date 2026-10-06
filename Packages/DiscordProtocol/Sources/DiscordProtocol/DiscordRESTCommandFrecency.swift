import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func applicationCommandFrecency() async throws -> ApplicationCommandFrecencyHistory {
        let data = try await frecencySettingsProto()
        return DiscordSettingsProto.applicationCommandFrecency(from: data) ?? ApplicationCommandFrecencyHistory()
    }

    /// One PATCH carrying only field 7, matching Discord's flush of pending
    /// command uses. The Gateway then echoes the stored proto to every session.
    func saveApplicationCommandFrecency(_ history: ApplicationCommandFrecencyHistory) async throws
        -> ApplicationCommandFrecencyHistory
    {
        let patch = DiscordSettingsProto.applicationCommandFrecencyPatch(history)
        let response: UserSettingsProtoDTO = try await request(
            "/users/@me/settings-proto/2",
            method: "PATCH",
            body: ["settings": .string(patch.base64EncodedString())]
        )
        let stored = Data(base64Encoded: response.settings)
            ?? DiscordSettingsProto.mergingPartialFrecencySettings(
                patch, into: cachedFrecencySettingsProto ?? Data()
            )
        cachedFrecencySettingsProto = stored
        return DiscordSettingsProto.applicationCommandFrecency(from: stored) ?? history
    }
}
