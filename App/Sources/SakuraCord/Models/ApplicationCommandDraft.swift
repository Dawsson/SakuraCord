import Foundation
import SakuraCordModels

/// One option the person is filling in for the active command.
struct ApplicationCommandDraftField: Identifiable, Equatable {
    let option: ApplicationCommandOption
    /// What the editor shows and the person edits.
    var text: String
    /// A value chosen from a suggestion, entity search or the file picker.
    /// Typing into the field clears it, so the text becomes a query again.
    var resolved: ApplicationCommandArgument?

    var id: String { option.id }

    /// Entities and files behave like mentions: one deletion removes them.
    var isAtomic: Bool {
        guard resolved != nil else { return false }
        switch option.type {
        case .user, .channel, .role, .mentionable, .attachment: return true
        default: return false
        }
    }

    var isEmpty: Bool { resolved == nil && textForParsing.isEmpty }

    /// Whitespace is data in free text; other option types parse trimmed input.
    var textForParsing: String {
        option.type == .string && option.choices.isEmpty
            ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ApplicationCommandDraftFocus: Hashable {
    case command
    case field(String)
    /// Between chips: before `fields[index]`, or after the last one. Typing an
    /// option name here adds it at this position, as in Discord.
    case gap(Int)
}

/// The structured command the person is composing. Pure value logic so the
/// editor, suggestions and submission all agree on one state.
struct ApplicationCommandDraft: Equatable {
    var command: ApplicationCommand
    /// Required options first in definition order, then optional ones in the
    /// order the person added them.
    private(set) var fields: [ApplicationCommandDraftField]
    /// Keep text in each gap when the caret visits another field or gap.
    private(set) var gapTexts: [String]
    private(set) var gapIndex: Int
    var gapText: String {
        get { gapTexts[gapIndex] }
        set { gapTexts[gapIndex] = newValue }
    }

    var focus: ApplicationCommandDraftFocus {
        didSet {
            if case let .gap(index) = focus { gapIndex = min(max(0, index), fields.count) }
        }
    }

    mutating func setGapText(_ text: String, at index: Int) {
        guard gapTexts.indices.contains(index) else { return }
        gapTexts[index] = text
    }

    init(command: ApplicationCommand) {
        self.command = command
        let required = command.options.filter(\.isRequired).map {
            ApplicationCommandDraftField(option: $0, text: "", resolved: nil)
        }
        fields = required
        gapTexts = Array(repeating: "", count: required.count + 1)
        gapIndex = required.count
        focus = required.first.map { .field($0.id) } ?? .gap(required.count)
    }

    var endGap: ApplicationCommandDraftFocus { .gap(fields.count) }

    var focusedField: ApplicationCommandDraftField? {
        guard case let .field(id) = focus else { return nil }
        return field(id)
    }

    func field(_ id: String) -> ApplicationCommandDraftField? {
        fields.first { $0.id == id }
    }

    func index(of id: String) -> Int? {
        fields.firstIndex { $0.id == id }
    }

    /// Options not currently present, including removed required fields, in definition order.
    var availableOptions: [ApplicationCommandOption] {
        let present = Set(fields.map(\.id))
        return command.options.filter { !present.contains($0.id) }
    }

    /// The gap after a field, where Discord leaves the caret once a value is chosen.
    func gap(after id: String) -> ApplicationCommandDraftFocus {
        .gap((index(of: id) ?? fields.count - 1) + 1)
    }

    func matchingOptions(matching query: String) -> [ApplicationCommandOption] {
        let normalized = query.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !normalized.isEmpty else { return availableOptions }
        return availableOptions.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
                || $0.name.localizedCaseInsensitiveContains(normalized)
        }.sorted {
            let left = $0.displayName.lowercased().hasPrefix(normalized.lowercased())
            let right = $1.displayName.lowercased().hasPrefix(normalized.lowercased())
            return left && !right
        }
    }

    // MARK: Editing

    mutating func setText(_ text: String, for id: String) {
        guard let index = index(of: id) else { return }
        fields[index].text = text
        fields[index].resolved = nil
    }

    mutating func resolve(_ id: String, to value: ApplicationCommandArgument, display: String) {
        guard let index = index(of: id) else { return }
        fields[index].text = display
        fields[index].resolved = value
    }

    @discardableResult
    mutating func addOption(_ option: ApplicationCommandOption, preservingGapText: Bool = false) -> Bool {
        guard command.options.contains(where: { $0.id == option.id }),
              index(of: option.id) == nil
        else { return false }
        // A name typed in a gap inserts the option at that gap.
        let position: Int = if case let .gap(index) = focus { min(index, fields.count) } else { fields.count }
        fields.insert(ApplicationCommandDraftField(option: option, text: "", resolved: nil), at: position)
        if preservingGapText {
            gapTexts.insert("", at: position + 1)
        } else {
            // Choosing an option rebuilds Discord's command and consumes gap queries.
            gapTexts = Array(repeating: "", count: fields.count + 1)
        }
        gapIndex = fields.count
        focus = .field(option.id)
        return true
    }

    /// Required fields can be removed while editing; submission still requires them.
    mutating func removeField(_ id: String) {
        guard let index = index(of: id) else { return }
        fields.remove(at: index)
        let trailingText = gapTexts.remove(at: index + 1)
        gapTexts[index] += trailingText
        if gapIndex > index { gapIndex -= 1 }
        gapIndex = min(gapIndex, fields.count)
        if focus == .field(id) {
            focus = .gap(index)
        } else if case let .gap(gap) = focus, gap > index {
            focus = .gap(gap - 1)
        }
    }

    /// Discord's Backspace at the gap after a chip: enter it and delete its
    /// last character, or the whole token for a chosen entity or file.
    mutating func deleteBackward(intoFieldBefore gap: Int) -> ApplicationCommandDraftFocus? {
        guard gap > 0, fields.indices.contains(gap - 1) else { return nil }
        let field = fields[gap - 1]
        if field.isEmpty {
            removeField(field.id)
            focus = .gap(gap - 1)
            return focus
        }
        if field.isAtomic {
            setText("", for: field.id)
        } else if !field.text.isEmpty {
            setText(String(field.text.dropLast()), for: field.id)
        }
        focus = .field(field.id)
        return focus
    }

    /// Discord implicitly opens a sole optional value, including entity options.
    /// One remaining option on a multi-option command does not qualify.
    mutating func acceptImplicitOptionValue() -> Bool {
        guard case .gap = focus, fields.isEmpty, command.options.count == 1,
              let option = command.options.first, !option.isRequired,
              option.type != .attachment, !gapText.isEmpty else { return false }
        let value = gapText
        guard addOption(option) else { return false }
        setText(value, for: option.id)
        return true
    }

    /// Accepts a typed `name:` in a gap as that optional field.
    mutating func acceptTypedOptionName() -> Bool {
        let typed = gapText.trimmingCharacters(in: .whitespaces)
        guard typed.hasSuffix(":") else { return false }
        let name = String(typed.dropLast()).lowercased()
        guard let option = availableOptions.first(where: {
            $0.displayName.lowercased() == name || $0.name.lowercased() == name
        }) else { return false }
        return addOption(option)
    }

    /// Tab skips inter-field gaps; Shift-Tab can return to the command name.
    mutating func moveFocus(by delta: Int) {
        let stops: [ApplicationCommandDraftFocus] = [.command] + fields.map { .field($0.id) } + [endGap]
        let current: Int = switch focus {
        case .command: 0
        case let .field(id): (index(of: id) ?? 0) + 1
        case let .gap(gap): delta > 0 ? gap : gap + 1
        }
        focus = stops[min(max(0, current + delta), stops.count - 1)]
    }

    // MARK: Values and validation

    /// The typed value a field currently represents, if any.
    func argument(for field: ApplicationCommandDraftField) -> ApplicationCommandArgument? {
        if let resolved = field.resolved { return resolved }
        let text = field.textForParsing
        guard !text.isEmpty else { return nil }
        let option = field.option
        if !option.choices.isEmpty {
            return option.choices.first {
                $0.displayName.caseInsensitiveCompare(text) == .orderedSame
                    || $0.name.caseInsensitiveCompare(text) == .orderedSame
            }.map { Self.argument(for: $0.value) }
        }
        switch option.type {
        case .string:
            return .string(field.text)
        case .integer:
            return Int64(text).map(ApplicationCommandArgument.integer)
        case .number:
            let normalized = text.replacingOccurrences(
                of: Locale.current.decimalSeparator ?? ".", with: "."
            )
            return Double(normalized).flatMap { $0.isFinite ? .number($0) : nil }
        case .boolean:
            return switch text.lowercased() {
            case "true", "yes": .boolean(true)
            case "false", "no": .boolean(false)
            default: nil
            }
        case .user:
            return Self.snowflake(in: text, prefixes: ["<@!", "<@"]).flatMap(UserID.init).map(ApplicationCommandArgument.user)
        case .channel:
            return Self.snowflake(in: text, prefixes: ["<#"]).flatMap(ChannelID.init).map(ApplicationCommandArgument.channel)
        case .role:
            return Self.snowflake(in: text, prefixes: ["<@&"]).flatMap(RoleID.init).map(ApplicationCommandArgument.role)
        case .mentionable:
            return Self.snowflake(in: text, prefixes: ["<@&", "<@!", "<@"]).map(ApplicationCommandArgument.mentionable)
        default:
            return nil
        }
    }

    /// Discord-style feedback for a field, or nil when it can be sent.
    func validationError(for field: ApplicationCommandDraftField) -> String? {
        guard let value = argument(for: field) else { return unparsedValueError(for: field) }
        return valueError(value, option: field.option)
    }

    /// Feedback for a field that holds no usable value.
    private func unparsedValueError(for field: ApplicationCommandDraftField) -> String? {
        let option = field.option
        if field.isEmpty { return option.isRequired ? "This option is required." : nil }
        if !option.choices.isEmpty { return "Choose one of the options." }
        return switch option.type {
        case .integer: "Enter a whole number."
        case .number: "Enter a number."
        case .boolean: "Choose True or False."
        case .user: "Choose a member."
        case .channel: "Choose a channel."
        case .role: "Choose a role."
        case .mentionable: "Choose a member or role."
        case .attachment: "Attach a file."
        default: "This value isn’t valid."
        }
    }

    private func valueError(_ value: ApplicationCommandArgument, option: ApplicationCommandOption) -> String? {
        switch value {
        case let .string(text):
            lengthError(text, option: option)
        case let .integer(number):
            (-9_007_199_254_740_991 ... 9_007_199_254_740_991).contains(number)
                ? boundsError(Double(number), option: option) : "This number is too large."
        case let .number(number):
            boundsError(number, option: option)
        case let .attachment(url):
            FileManager.default.fileExists(atPath: url.path) ? nil : "The selected file is no longer available."
        default:
            nil
        }
    }

    private func lengthError(_ text: String, option: ApplicationCommandOption) -> String? {
        // Discord's server counts Unicode scalars.
        let count = text.unicodeScalars.count
        let tooShort = option.minimumLength.map { count < $0 } ?? false
        let tooLong = option.maximumLength.map { count > $0 } ?? false
        guard tooShort || tooLong else { return nil }
        return switch (option.minimumLength, option.maximumLength) {
        case let (minimum?, maximum?): "Enter between \(minimum) and \(maximum) characters."
        case let (minimum?, nil): "Enter at least \(minimum) characters."
        case let (nil, maximum?): "Enter at most \(maximum) characters."
        default: nil
        }
    }

    private func boundsError(_ number: Double, option: ApplicationCommandOption) -> String? {
        let below = option.minimumValue.map { number < $0 } ?? false
        let above = option.maximumValue.map { number > $0 } ?? false
        guard below || above else { return nil }
        let format: (Double) -> String = {
            Int64(exactly: $0).map(String.init) ?? $0.formatted(.number)
        }
        return switch (option.minimumValue, option.maximumValue) {
        case let (minimum?, maximum?): "Enter a number between \(format(minimum)) and \(format(maximum))."
        case let (minimum?, nil): "Enter a number of at least \(format(minimum))."
        case let (nil, maximum?): "Enter a number of at most \(format(maximum))."
        default: nil
        }
    }

    var firstInvalidField: (field: ApplicationCommandDraftField, message: String)? {
        if let missing = command.options.first(where: { $0.isRequired && field($0.id) == nil }) {
            return (ApplicationCommandDraftField(option: missing, text: "", resolved: nil), "This option is required.")
        }
        for field in fields {
            if let message = validationError(for: field) { return (field, message) }
        }
        return nil
    }

    /// Option values in registered definition order, as the official client sends them.
    func optionValues() -> [ApplicationCommandOptionValue] {
        command.options.compactMap { option in
            guard let field = field(option.id), let value = argument(for: field) else { return nil }
            return ApplicationCommandOptionValue(
                optionID: option.id, name: option.name, type: option.type, argument: value
            )
        }
    }

    /// Values sent alongside a focused autocomplete query: every other field
    /// that already holds a usable value.
    func siblingValues(excluding id: String) -> [ApplicationCommandOptionValue] {
        optionValues().filter { $0.optionID != id }
    }

    var attachmentURLs: [URL] {
        fields.compactMap {
            guard case let .attachment(url)? = $0.resolved else { return nil }
            return url
        }
    }

    /// Plain text Discord would show when copied: `/name option:value`.
    var plainText: String { plainText(commandName: "/\(command.displayName)") }

    func plainText(commandName: String) -> String {
        var text = commandName + gapTexts[0]
        for (index, field) in fields.enumerated() {
            text += " \(field.option.displayName):\(field.text)" + gapTexts[index + 1]
        }
        return text
    }

    static func argument(for value: ApplicationCommandChoiceValue) -> ApplicationCommandArgument {
        switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .number(value): .number(value)
        }
    }

    private static func snowflake(in text: String, prefixes: [String]) -> String? {
        var value = text
        if value.hasSuffix(">"),
           let prefix = prefixes.first(where: { value.hasPrefix($0) })
        {
            value = String(value.dropFirst(prefix.count).dropLast())
        }
        return value.allSatisfy(\.isASCIIDigit) && (17 ... 20).contains(value.count) ? value : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
