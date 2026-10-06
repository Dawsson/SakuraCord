import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

struct ApplicationCommandFrecencyCodecTests {
    @Test func `command frecency patch encodes field 7 the way Discord's client writes it`() {
        let history = ApplicationCommandFrecencyHistory(entries: [
            ApplicationCommandFrecencyEntry(key: "-7", totalUses: 3, recentUses: [1, 300], frecency: 2, score: 1),
            ApplicationCommandFrecencyEntry(key: "9\u{0}sub:8", totalUses: 1, recentUses: [5], frecency: -1, score: 0),
        ])

        let patch = DiscordSettingsProto.applicationCommandFrecencyPatch(history)

        // value: total_uses, packed recent_uses, frecency, score; zero fields omitted.
        let first: [UInt8] = [0x08, 3, 0x12, 3, 1, 0xAC, 0x02, 0x18, 2, 0x20, 1]
        let negativeOne: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        let second: [UInt8] = [0x08, 1, 0x12, 1, 5, 0x18] + negativeOne
        func mapEntry(_ key: String, _ value: [UInt8]) -> [UInt8] {
            let body = [0x0A, UInt8(key.utf8.count)] + Array(key.utf8) + [0x12, UInt8(value.count)] + value
            return [0x0A, UInt8(body.count)] + body
        }
        let map = mapEntry("-7", first) + mapEntry("9\u{0}sub:8", second)
        #expect(Array(patch) == [0x3A, UInt8(map.count)] + map)
        #expect(DiscordSettingsProto.applicationCommandFrecency(from: patch) == history)
    }

    @Test func `command frecency save keeps the 500 most recently used entries`() {
        let entries = (0 ..< 502).map {
            ApplicationCommandFrecencyEntry(
                key: "\($0)", totalUses: 1, recentUses: [UInt64(1_000 + ($0 == 0 ? 5_000 : $0))], frecency: 1, score: 1
            )
        }

        let patch = DiscordSettingsProto.applicationCommandFrecencyPatch(ApplicationCommandFrecencyHistory(entries: entries))
        let saved = DiscordSettingsProto.applicationCommandFrecency(from: patch)?.entries.map(\.key) ?? []

        #expect(saved.count == 500)
        #expect(saved.first == "0")
        #expect(!saved.contains("1") && !saved.contains("2"))
    }

    @Test func `settings without command frecency are not treated as an empty history`() {
        #expect(DiscordSettingsProto.applicationCommandFrecency(from: Data([0x08, 0x01])) == nil)
        #expect(DiscordSettingsProto.applicationCommandFrecency(from: Data([0x3A, 0x00]))?.entries.isEmpty == true)
    }
}
