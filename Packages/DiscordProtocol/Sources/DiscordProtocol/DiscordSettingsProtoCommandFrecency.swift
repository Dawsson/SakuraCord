import Foundation
import SakuraCordModels

/// `FrecencyUserSettings.application_command_frecency` (field 7): a map of
/// command keys to usage items, encoded the way Discord's client writes it.
extension DiscordSettingsProto {
    static let applicationCommandFrecencyField = 7
    /// Discord keeps at most this many command entries when saving.
    static let maximumApplicationCommandFrecencyEntries = 500

    static func applicationCommandFrecency(from data: Data) -> ApplicationCommandFrecencyHistory? {
        var reader = ProtoReader(data: data)
        var payload: Data?
        var found = false
        while let field = reader.readRawField() {
            if field.field == applicationCommandFrecencyField, field.wireType == 2 {
                payload = field.payload
                found = true
            }
        }
        guard found else { return nil }
        return applicationCommandFrecency(mapPayload: payload ?? Data())
    }

    static func applicationCommandFrecency(mapPayload data: Data) -> ApplicationCommandFrecencyHistory {
        var reader = ProtoReader(data: data)
        var entries: [ApplicationCommandFrecencyEntry] = []
        var indexByKey: [String: Int] = [:]
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2, let entryData = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            var entryReader = ProtoReader(data: entryData)
            var key: String?
            var item = ApplicationCommandFrecencyEntry(key: "", totalUses: 0, recentUses: [], frecency: 0, score: 0)
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 2, let bytes = entryReader.readLengthDelimited() {
                    key = String(bytes: bytes, encoding: .utf8)
                } else if entryTag.field == 2, entryTag.wireType == 2, let bytes = entryReader.readLengthDelimited() {
                    item = frecencyItem(from: bytes)
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            guard let key else { continue }
            item.key = key
            // A repeated map key replaces the earlier value in place, as in JavaScript objects.
            if let index = indexByKey[key] {
                entries[index] = item
            } else {
                indexByKey[key] = entries.count
                entries.append(item)
            }
        }
        return ApplicationCommandFrecencyHistory(entries: entries)
    }

    private static func frecencyItem(from data: Data) -> ApplicationCommandFrecencyEntry {
        var reader = ProtoReader(data: data)
        var item = ApplicationCommandFrecencyEntry(key: "", totalUses: 0, recentUses: [], frecency: 0, score: 0)
        while let tag = reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 0):
                item.totalUses = Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: reader.readVarint() ?? 0))
            case (2, 0):
                if let value = reader.readVarint() { item.recentUses.append(value) }
            case (2, 2):
                if let packed = reader.readLengthDelimited() {
                    var packedReader = ProtoReader(data: packed)
                    while let value = packedReader.readVarint() { item.recentUses.append(value) }
                }
            case (3, 0):
                item.frecency = Int32(truncatingIfNeeded: reader.readVarint() ?? 0)
            case (4, 0):
                item.score = Int32(truncatingIfNeeded: reader.readVarint() ?? 0)
            default:
                if !reader.skip(wireType: tag.wireType) { return item }
            }
        }
        return item
    }

    /// The partial settings proto carrying only field 7, as Discord's client
    /// sends it. Entries beyond the limit drop the least recently used, which
    /// also reorders by recency like Discord's serializer.
    static func applicationCommandFrecencyPatch(_ history: ApplicationCommandFrecencyHistory) -> Data {
        var entries = history.entries
        if entries.count > maximumApplicationCommandFrecencyEntries {
            entries = stableSorted(entries) { ($0.recentUses.last ?? 0) < ($1.recentUses.last ?? 0) }
            entries.reverse()
            entries.removeLast(entries.count - maximumApplicationCommandFrecencyEntries)
        }
        var map = Data()
        for entry in entries {
            var value = Data()
            if entry.totalUses != 0 { value.append(frecencyVarintField(1, UInt64(UInt32(truncatingIfNeeded: entry.totalUses)))) }
            let recent = entry.recentUses.filter { $0 > 0 }
            if !recent.isEmpty {
                var packed = Data()
                recent.forEach { packed.append(frecencyVarint($0)) }
                value.append(frecencyLengthDelimitedField(2, packed))
            }
            if entry.frecency != 0 { value.append(frecencyVarintField(3, UInt64(bitPattern: Int64(entry.frecency)))) }
            if entry.score != 0 { value.append(frecencyVarintField(4, UInt64(bitPattern: Int64(entry.score)))) }
            var mapEntry = frecencyLengthDelimitedField(1, Data(entry.key.utf8))
            mapEntry.append(frecencyLengthDelimitedField(2, value))
            map.append(frecencyLengthDelimitedField(1, mapEntry))
        }
        return frecencyLengthDelimitedField(applicationCommandFrecencyField, map)
    }

    private static func stableSorted(
        _ entries: [ApplicationCommandFrecencyEntry],
        by areInIncreasingOrder: (ApplicationCommandFrecencyEntry, ApplicationCommandFrecencyEntry) -> Bool
    ) -> [ApplicationCommandFrecencyEntry] {
        entries.enumerated().sorted { left, right in
            if areInIncreasingOrder(left.element, right.element) { return true }
            if areInIncreasingOrder(right.element, left.element) { return false }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func frecencyLengthDelimitedField(_ field: Int, _ value: Data) -> Data {
        var data = frecencyVarint(UInt64(field << 3 | 2))
        data.append(frecencyVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func frecencyVarintField(_ field: Int, _ value: UInt64) -> Data {
        var data = frecencyVarint(UInt64(field << 3))
        data.append(frecencyVarint(value))
        return data
    }

    private static func frecencyVarint(_ source: UInt64) -> Data {
        var value = source
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }
}
