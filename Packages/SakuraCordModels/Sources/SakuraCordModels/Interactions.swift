import Foundation

/// A message component the user activated. Each case owns the component type
/// Discord expects in `data.component_type`.
public enum ComponentInteractionKind: String, Codable, Hashable, Sendable {
    case button, stringSelect, userSelect, roleSelect, mentionableSelect, channelSelect

    public init(selectKind: ComponentSelectKind) {
        self = switch selectKind {
        case .string: .stringSelect
        case .user: .userSelect
        case .role: .roleSelect
        case .mentionable: .mentionableSelect
        case .channel: .channelSelect
        }
    }

    public var componentType: Int {
        switch self {
        case .button: 2
        case .stringSelect: 3
        case .userSelect: 5
        case .roleSelect: 6
        case .mentionableSelect: 7
        case .channelSelect: 8
        }
    }
}

public struct ComponentInteractionSubmission: Codable, Hashable, Sendable {
    public var messageID: MessageID
    public var messageFlags: MessageFlags
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var applicationID: ApplicationID
    public var customID: String
    public var kind: ComponentInteractionKind
    /// Selected values in the order the person chose them. Buttons send none.
    public var values: [String]
    public var nonce: String

    public init(
        messageID: MessageID, messageFlags: MessageFlags = [], channelID: ChannelID,
        guildID: GuildID? = nil, applicationID: ApplicationID, customID: String,
        kind: ComponentInteractionKind, values: [String] = [], nonce: String = ClientNonce.make()
    ) {
        self.messageID = messageID
        self.messageFlags = messageFlags
        self.channelID = channelID
        self.guildID = guildID
        self.applicationID = applicationID
        self.customID = customID
        self.kind = kind
        self.values = values
        self.nonce = nonce
    }
}

public enum ComponentDefaultValueKind: String, Codable, Hashable, Sendable {
    case user, role, channel
}

/// An entity a select starts with. Discord sends these as `default_values`.
public struct ComponentDefaultValue: Codable, Hashable, Sendable {
    public var id: String
    public var kind: ComponentDefaultValueKind

    public init(id: String, kind: ComponentDefaultValueKind) {
        self.id = id
        self.kind = kind
    }
}

public enum ModalTextInputStyle: Int, Codable, Hashable, Sendable {
    case short = 1
    case paragraph = 2
}

/// One interactive control inside a returned modal.
public struct ModalControl: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case textInput(
            style: ModalTextInputStyle, placeholder: String?, minLength: Int?, maxLength: Int?,
            initialValue: String?
        )
        case select(
            kind: ComponentSelectKind, placeholder: String?, options: [ComponentSelectOption],
            minValues: Int, maxValues: Int, channelTypes: [Int], defaultValues: [ComponentDefaultValue]
        )
        /// `fileTypes` holds extensions (".txt") or broad kinds ("image").
        case fileUpload(minValues: Int, maxValues: Int, fileTypes: [String])
        case radioGroup(options: [ComponentSelectOption])
        case checkboxGroup(options: [ComponentSelectOption], minValues: Int, maxValues: Int)
        case checkbox(isInitiallyChecked: Bool)
    }

    /// Discord's numeric component ID when present, otherwise the tree path.
    public var id: String
    /// Opaque app-defined identity. Preserve exactly; never interpret it.
    public var customID: String
    public var kind: Kind
    public var isRequired: Bool
    public var isDisabled: Bool
    /// Legacy text inputs carry their own label instead of a label wrapper.
    public var label: String?

    public init(
        id: String, customID: String, kind: Kind, isRequired: Bool, isDisabled: Bool = false,
        label: String? = nil
    ) {
        self.id = id
        self.customID = customID
        self.kind = kind
        self.isRequired = isRequired
        self.isDisabled = isDisabled
        self.label = label
    }

    public var componentType: Int {
        switch kind {
        case .textInput: 4
        case let .select(kind, _, _, _, _, _, _): kind.rawValue
        case .fileUpload: 19
        case .radioGroup: 21
        case .checkboxGroup: 22
        case .checkbox: 23
        }
    }
}

/// The incoming modal layout. Submission mirrors these wrappers, so legacy
/// action rows and modern labels must survive even though both render as fields.
public indirect enum ModalNode: Identifiable, Codable, Hashable, Sendable {
    /// Legacy action row (`type: 1`) holding a text input.
    case actionRow(id: String, children: [ModalNode])
    /// Modern label (`type: 18`) wrapping exactly one control.
    case label(id: String, label: String, description: String?, child: ModalNode)
    /// Explanatory Markdown (`type: 10`). Submitted as `{type: 10}`.
    case textDisplay(id: String, content: String)
    case control(ModalControl)
    case unsupported(id: String, type: Int)

    public var id: String {
        switch self {
        case let .actionRow(id, _), let .label(id, _, _, _), let .textDisplay(id, _),
             let .unsupported(id, _):
            id
        case let .control(control):
            control.id
        }
    }

    /// Controls in render order.
    public var controls: [ModalControl] {
        switch self {
        case let .actionRow(_, children): children.flatMap(\.controls)
        case let .label(_, _, _, child): child.controls
        case .textDisplay, .unsupported: []
        case let .control(control): [control]
        }
    }

    /// Whether the node contains a type SakuraCord cannot submit faithfully.
    public var containsUnsupportedInput: Bool {
        switch self {
        case let .actionRow(_, children): children.contains(where: \.containsUnsupportedInput)
        case let .label(_, _, _, child): child.containsUnsupportedInput
        case .textDisplay, .control: false
        case .unsupported: true
        }
    }
}

/// Display metadata Discord supplies for a modal's default entity values.
public struct ModalResolvedEntities: Codable, Hashable, Sendable {
    public var users: [String: User]
    public var roles: [String: GuildRole]
    public var channels: [String: ModalResolvedChannel]

    public init(
        users: [String: User] = [:], roles: [String: GuildRole] = [:],
        channels: [String: ModalResolvedChannel] = [:]
    ) {
        self.users = users
        self.roles = roles
        self.channels = channels
    }
}

public struct ModalResolvedChannel: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: Int

    public init(id: String, name: String, type: Int) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// A modal an application returned for one interaction. Its identity is the
/// opening interaction, so reopening an identical form is a different modal.
public struct InteractionModal: Identifiable, Codable, Hashable, Sendable {
    public var id: String { interactionID }

    /// The interaction that opened the form; it becomes the submission's `data.id`.
    public var interactionID: String
    public var openingNonce: String
    public var application: ApplicationCommandApplication
    public var channelID: ChannelID
    /// Taken from the opening invocation; the modal event omits it.
    public var guildID: GuildID?
    public var customID: String
    public var title: String
    public var nodes: [ModalNode]
    public var resolved: ModalResolvedEntities

    public init(
        interactionID: String, openingNonce: String, application: ApplicationCommandApplication,
        channelID: ChannelID, guildID: GuildID?, customID: String, title: String,
        nodes: [ModalNode], resolved: ModalResolvedEntities = ModalResolvedEntities()
    ) {
        self.interactionID = interactionID
        self.openingNonce = openingNonce
        self.application = application
        self.channelID = channelID
        self.guildID = guildID
        self.customID = customID
        self.title = title
        self.nodes = nodes
        self.resolved = resolved
    }

    public var controls: [ModalControl] {
        nodes.flatMap(\.controls)
    }

    /// An unknown control could be required, so a partial submission is refused.
    public var isSubmittable: Bool {
        !nodes.contains(where: \.containsUnsupportedInput)
    }
}

/// The submitted state of one control. `nil` payloads mean the person never
/// touched a control without a default; Discord's client sends those as null,
/// which differs from an explicitly cleared empty string or array.
public enum ModalFieldValue: Codable, Hashable, Sendable {
    case text(String?)
    case values([String]?)
    case radio(String?)
    case checkbox(Bool)
    case files([URL]?)
}

public struct ModalSubmission: Codable, Hashable, Sendable {
    public var modal: InteractionModal
    /// Keyed by control custom ID.
    public var values: [String: ModalFieldValue]
    /// Every submission attempt, including a corrected retry, gets a fresh nonce.
    public var nonce: String

    public init(
        modal: InteractionModal, values: [String: ModalFieldValue],
        nonce: String = ClientNonce.make()
    ) {
        self.modal = modal
        self.values = values
        self.nonce = nonce
    }
}

/// Discord's `INTERACTION_FAILURE`. Code 2 means the application did not
/// acknowledge in time; presentation chooses wording per surface.
public struct InteractionFailure: Codable, Hashable, Sendable {
    public var reasonCode: Int?
    public var message: String?

    public init(reasonCode: Int? = nil, message: String? = nil) {
        self.reasonCode = reasonCode
        self.message = message
    }

    public static let applicationDidNotRespond = 2

    public var isMissingAcknowledgement: Bool {
        reasonCode == Self.applicationDidNotRespond
    }
}

/// Gateway lifecycle for one outbound interaction, correlated by nonce. Events
/// can arrive before the HTTP response and in any relative order.
public enum InteractionEvent: Equatable, Sendable {
    case created(nonce: String, interactionID: String)
    case succeeded(nonce: String, interactionID: String?)
    case failed(nonce: String, failure: InteractionFailure)
    /// Opening success may follow; it must not dismiss the modal.
    case presentModal(InteractionModal)
}

/// Rejection details for a submitted form, keyed by control custom ID when
/// Discord identified the field.
public struct ModalSubmissionRejection: Error, Hashable, Sendable {
    public var message: String
    public var fieldMessages: [String: String]

    public init(message: String, fieldMessages: [String: String] = [:]) {
        self.message = message
        self.fieldMessages = fieldMessages
    }
}

extension ModalSubmissionRejection: LocalizedError {
    public var errorDescription: String? { message }
}
