import Foundation
import SakuraCordModels

/// One application's commands in the picker, in index order.
struct ApplicationCommandPickerSource: Equatable {
    var application: ApplicationCommandApplication
    var commands: [ApplicationCommand]

    /// Discord names a section after the application's bot, falling back to
    /// the application name.
    var name: String { application.bot?.username ?? application.name }
}

/// Discord's slash-command picker rules (desktop build of 2026-10-04): the
/// browse list shown for a bare `/`, Frequently Used, and typed search.
/// Pure so it can be verified against the official client's output.
struct ApplicationCommandPickerEngine {
    struct BrowseSection {
        var application: ApplicationCommandApplication
        var name: String
        var commands: [ApplicationCommand]
    }

    struct Browse {
        var frequentlyUsed: [ApplicationCommand]
        var sections: [BrowseSection]
    }

    static let frequentlyUsedLimit = 5
    static let searchResultLimit = 20
    /// Discord reads at most this many words of a query.
    static let maximumQueryWords = 3

    /// Application sections in index order: the conversation's index first,
    /// then applications only the user index has.
    let sources: [ApplicationCommandPickerSource]
    /// Built-ins available here; Discord lists them after every application.
    let builtIns: [ApplicationCommand]
    let locale: Locale
    /// Discord's frecency score for a command in this conversation.
    var frecencyScore: (ApplicationCommand) -> Double
    /// Command IDs (`root\0sub`) among the 100 most frecent, already scoped
    /// to this conversation.
    var frequentCommandIDs: [String]

    private struct SearchCommand {
        let command: ApplicationCommand
        let name: String
        let display: String
        let tail: String
        let displayTail: String
        let description: String
        let displayDescription: String
        let hasLocalizedName: Bool
        let hasLocalizedDescription: Bool
    }

    private struct SearchSection {
        let name: String
        let description: String?
        let commands: [SearchCommand]
    }

    private var commandSortRanks: [String: Int] = [:]
    private var searchSections: [SearchSection] = []
    private var browseSections: [BrowseSection] = []

    init(sources: [ApplicationCommandPickerSource], builtIns: [ApplicationCommand], locale: Locale,
         frecencyScore: @escaping (ApplicationCommand) -> Double, frequentCommandIDs: [String]) {
        self.sources = sources
        self.builtIns = builtIns
        self.locale = locale
        self.frecencyScore = frecencyScore
        self.frequentCommandIDs = frequentCommandIDs
        var sections = sortedSections(sources.map {
            BrowseSection(application: $0.application, name: $0.name, commands: $0.commands)
        })
        if !builtIns.isEmpty {
            sections.append(BrowseSection(application: DiscordBuiltInCommands.application,
                name: DiscordBuiltInCommands.application.name, commands: builtIns))
        }
        let allCommands = sections.flatMap(\.commands)
        let names = Set(allCommands.map(\.displayName)).sorted { collate($0, $1) == .orderedAscending }
        var ranks: [String: Int] = [:]
        var rank = 0
        for (index, name) in names.enumerated() {
            if index > 0, collate(names[index - 1], name) != .orderedSame { rank += 1 }
            ranks[name] = rank
        }
        commandSortRanks = Dictionary(allCommands.map { ($0.id, ranks[$0.displayName] ?? 0) }, uniquingKeysWith: { first, _ in first })
        // Localized and canonical strings often coincide, and command names
        // repeat across applications. Normalize each distinct string only once.
        var normalized: [String: String] = [:]
        func lower(_ value: String) -> String {
            if let cached = normalized[value] { return cached }
            let result = value.lowercased(with: locale)
            normalized[value] = result
            return result
        }
        func tail(_ value: String) -> String {
            guard let space = value.firstIndex(of: " ") else { return "" }
            return String(value[value.index(after: space)...])
        }
        searchSections = sections.map { section in
            SearchSection(name: lower(section.name),
                description: section.application.id == DiscordBuiltInCommands.application.id ? nil : lower(section.application.description),
                commands: section.commands.map { command in
                    let name = lower(Self.untranslatedName(of: command))
                    let display = lower(command.displayName)
                    let description = lower(command.description)
                    let displayDescription = lower(command.displayDescription)
                    return SearchCommand(command: command, name: name, display: display,
                        tail: tail(name),
                        displayTail: tail(display),
                        description: description,
                        displayDescription: displayDescription,
                        hasLocalizedName: !name.utf16.elementsEqual(display.utf16),
                        hasLocalizedDescription: !description.utf16.elementsEqual(displayDescription.utf16))
                })
        }
        browseSections = sections.compactMap { section in
            guard !section.commands.isEmpty else { return nil }
            return BrowseSection(application: section.application, name: section.name,
                commands: stableSorted(section.commands) { commandSortRanks[$0.id, default: 0] < commandSortRanks[$1.id, default: 0] })
        }
    }

    // MARK: Browse

    func browse() -> Browse {
        let frequent = Set(frequentCommandIDs)
        let candidates = browseSections.flatMap(\.commands).filter { frequent.contains(Self.discordID(of: $0)) }
        let frequentlyUsed = stableSorted(candidates) { frecencyScore($0) > frecencyScore($1) }
        return Browse(frequentlyUsed: Array(frequentlyUsed.prefix(Self.frequentlyUsedLimit)), sections: browseSections)
    }

    // MARK: Search

    enum SearchMode { case composer, contextMenu }

    /// Composer completion is capped and parses option boundaries. The Apps
    /// menu searches literal text and retains every result in its scrollable list.
    func search(_ rawQuery: String, mode: SearchMode = .composer) -> [ApplicationCommand] {
        let parsed = mode == .composer ? Self.parse(rawQuery) : (text: rawQuery, hasSpaceTerminator: false)
        let query = parsed.text.lowercased(with: locale)
        let words = query.components(separatedBy: " ")
        let firstWord = words.first ?? ""
        let rest = words.dropFirst().joined(separator: " ")

        var scored: [(command: ApplicationCommand, score: Int)] = []
        for section in searchSections {
            let applicationScore = applicationMatchScore(
                query, name: section.name, description: section.description
            )
            for command in section.commands {
                var score = commandMatchScore(command, query: query, firstWord: firstWord, rest: rest)
                if score == nil {
                    score = applicationScore
                } else if let applicationScore, let current = score, applicationScore < current {
                    score = applicationScore
                }
                if let score { scored.append((command.command, score)) }
            }
        }

        // Only twenty rows can be shown. Keep that prefix in order instead of
        // sorting thousands of matches, retaining source order for exact ties.
        let exact = parsed.text.trimmingCharacters(in: .whitespaces)
        struct Match {
            let command: ApplicationCommand
            let score: Int
            let frecency: Double
            let nameRank: Int
        }
        var best: [Match] = []
        best.reserveCapacity(Self.searchResultLimit + 1)
        func precedes(_ lhs: Match, _ rhs: Match) -> Bool {
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
            return lhs.nameRank < rhs.nameRank
        }
        if mode == .contextMenu {
            return scored.enumerated().map { index, match in
                (index, Match(command: match.command, score: match.score, frecency: frecencyScore(match.command), nameRank: commandSortRanks[match.command.id] ?? 0))
            }.sorted { lhs, rhs in
                if precedes(lhs.1, rhs.1) { return true }
                if precedes(rhs.1, lhs.1) { return false }
                return lhs.0 < rhs.0
            }.map { $0.1.command }
        }
        for match in scored {
            if parsed.hasSpaceTerminator,
               match.command.displayName != exact, !match.command.displayName.hasPrefix(exact + " ") { continue }
            let candidate = Match(command: match.command, score: match.score, frecency: frecencyScore(match.command), nameRank: commandSortRanks[match.command.id] ?? 0)
            if best.count == Self.searchResultLimit, let last = best.last, !precedes(candidate, last) { continue }
            var low = 0
            var high = best.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(candidate, best[middle]) { high = middle } else { low = middle + 1 }
            }
            best.insert(candidate, at: low)
            if best.count > Self.searchResultLimit { best.removeLast() }
        }
        return best.map(\.command)
    }

    /// Discord's query reading: text before an option (`name:`) or the fourth
    /// word, and whether the command name was already terminated.
    static func parse(_ query: String) -> (text: String, hasSpaceTerminator: Bool) {
        var text = query
        var terminated = false
        if let colon = text.firstIndex(of: ":") {
            if let space = text[..<colon].lastIndex(of: " ") {
                text = String(text[..<space])
                terminated = true
            } else {
                text = String(text[..<colon])
            }
        }
        var parts = text.components(separatedBy: " ")
        if parts.count > maximumQueryWords {
            parts = Array(parts.prefix(maximumQueryWords + 1))
            terminated = true
            parts.removeLast()
        }
        text = parts.joined(separator: " ")
        if query.utf16.count > text.utf16.count || text.hasSuffix(" ") {
            terminated = true
            while text.hasSuffix(" ") || text.last?.isWhitespace == true { text.removeLast() }
        }
        return (text, terminated)
    }

    // MARK: Discord's match scores

    private func applicationMatchScore(_ query: String, name: String, description: String?) -> Int? {
        if Self.hasPrefix(name, query) { return 5 }
        if Self.contains(name, query) { return 6 }
        if let description, Self.contains(description, query) { return 8 }
        return Self.fuzzyMatches(query, name) ? 11 : nil
    }

    private func commandMatchScore(
        _ prepared: SearchCommand, query: String, firstWord: String, rest: String
    ) -> Int? {
        let command = prepared.command
        let untranslated = prepared.name
        let display = prepared.display
        if Self.hasPrefix(untranslated, query) || (prepared.hasLocalizedName && Self.hasPrefix(display, query)) { return 0 }
        if (Self.hasPrefix(untranslated, firstWord) && Self.hasPrefix(prepared.tail, rest))
            || (prepared.hasLocalizedName && Self.hasPrefix(display, firstWord) && Self.hasPrefix(prepared.displayTail, rest)) { return 1 }
        if Self.contains(untranslated, query) || (prepared.hasLocalizedName && Self.contains(display, query)) { return 2 }
        // A qualified option can only match once the query has passed the
        // command name. Read its suffix once, rather than build two qualified
        // strings for every option on every keystroke.
        func optionQuery(after name: String) -> String? {
            let prefix = name + " "
            guard Self.hasPrefix(query, prefix) else { return nil }
            return String(decoding: query.utf16.dropFirst(prefix.utf16.count), as: UTF16.self)
        }
        let canonicalOptionQuery = optionQuery(after: untranslated)
        let localizedOptionQuery = prepared.hasLocalizedName ? optionQuery(after: display) : nil
        func optionHasPrefix(_ name: String) -> Bool {
            Self.hasPrefix(name, query)
                || canonicalOptionQuery.map { Self.hasPrefix(name, $0) } == true
                || localizedOptionQuery.map { Self.hasPrefix(name, $0) } == true
        }
        var optionContains = false
        for option in command.options {
            let name = option.name, localized = option.localizedName
            if optionHasPrefix(name)
            {
                return 3
            }
            if let localized, optionHasPrefix(localized)
            {
                return 3
            }
            if Self.contains(name, query) || localized.map({ Self.contains($0, query) }) == true {
                optionContains = true
            }
        }
        if optionContains { return 4 }
        let untranslatedDescription = prepared.description
        let displayDescription = prepared.displayDescription
        if Self.contains(untranslatedDescription, query) || (prepared.hasLocalizedDescription && Self.contains(displayDescription, query)) { return 7 }
        if Self.fuzzyMatches(query, untranslated) || (prepared.hasLocalizedName && Self.fuzzyMatches(query, display)) { return 9 }
        for option in command.options
            where Self.fuzzyMatches(query, option.name) || option.localizedName.map({ Self.fuzzyMatches(query, $0) }) == true
        {
            _ = option
            return 10
        }
        if Self.fuzzyMatches(query, untranslatedDescription) || (prepared.hasLocalizedDescription && Self.fuzzyMatches(query, displayDescription)) {
            return 12
        }
        return nil
    }

    // MARK: Identity

    /// Discord's flattened command ID: the root ID, then each subcommand
    /// group and subcommand name, separated by NUL.
    static func discordID(of command: ApplicationCommand) -> String {
        guard !DiscordBuiltInCommands.isBuiltIn(command),
              command.applicationID != SakuraCordBuiltInCommands.application.id
        else { return command.id }
        guard !command.subcommandPath.isEmpty else { return command.rootCommandID }
        return ([command.rootCommandID] + command.subcommandPath.map(\.name)).joined(separator: "\u{0}")
    }

    /// Discord's frecency key: built-ins by their negative ID, guild-registered
    /// commands suffixed with the guild they are used in.
    static func frecencyKey(of command: ApplicationCommand, guildID: GuildID?) -> String {
        let id = discordID(of: command)
        if let number = Int(id), number < 0 { return id }
        if let guildID, command.guildID != nil { return "\(id):\(guildID)" }
        return id
    }

    /// Discord's scoping of frecency keys to a conversation: guild-suffixed
    /// keys only count in that guild, and lose their suffix.
    static func scopedCommandIDs(_ keys: [String], guildID: GuildID?) -> [String] {
        keys.compactMap { key in
            guard let separator = key.firstIndex(of: ":") else { return key }
            let suffix = key[key.index(after: separator)...].split(separator: ":", omittingEmptySubsequences: false).first
            guard let guildID, suffix.map(String.init) == guildID.description else { return nil }
            return String(key[..<separator])
        }
    }

    static func untranslatedName(of command: ApplicationCommand) -> String {
        guard !command.subcommandPath.isEmpty else { return command.name }
        return ([command.name] + command.subcommandPath.map(\.name)).joined(separator: " ")
    }

    // MARK: Ordering

    private func sortedSections(_ sections: [BrowseSection]) -> [BrowseSection] {
        stableSorted(sections) { collate($0.name, $1.name) == .orderedAscending }
    }

    /// Discord sorts with `Intl.Collator(locale, {sensitivity: "accent", numeric: true})`.
    func collate(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric], range: nil, locale: locale)
    }

    private func stableSorted<Element>(_ values: [Element], by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        values.enumerated().sorted { left, right in
            if areInIncreasingOrder(left.element, right.element) { return true }
            if areInIncreasingOrder(right.element, left.element) { return false }
            return left.offset < right.offset
        }.map(\.element)
    }

    // MARK: JavaScript string semantics

    static func hasPrefix(_ value: String, _ prefix: String) -> Bool {
        value.utf16.starts(with: prefix.utf16)
    }

    static func contains(_ value: String, _ needle: String) -> Bool {
        needle.isEmpty || value.range(of: needle, options: .literal) != nil
    }

    /// The `fuzzysearch` package: every needle code unit in order.
    static func fuzzyMatches(_ needle: String, _ haystack: String) -> Bool {
        // Walk code units without allocating two arrays for every candidate.
        // UTF-16 preserves the official client's matching, including surrogates.
        var candidate = haystack.utf16.makeIterator()
        for unit in needle.utf16 {
            var found = false
            while let next = candidate.next() {
                if next == unit { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
