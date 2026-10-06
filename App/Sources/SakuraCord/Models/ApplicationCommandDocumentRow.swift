import Foundation
import SakuraCordModels

/// Prepared once per result set; scrolling and keyboard movement never flatten
/// the catalog or inspect command options again.
struct ApplicationCommandDocumentRow: Identifiable {
    let id: String
    let sectionID: String
    let title: String
    let subtitle: String
    let detail: String
    let application: ApplicationCommandApplication?
    let command: ApplicationCommand?
    let showsIcon: Bool
    let isFrequent: Bool

    var height: CGFloat { command == nil ? 30 : 46 }

    init(section: ApplicationCommandSection, command: ApplicationCommand? = nil) {
        sectionID = section.id
        self.command = command
        isFrequent = section.kind == .frequentlyUsed
        application = command?.application ?? section.application
        if let command {
            id = ApplicationCommandComposerModel.pickerRowID(section: section, command: command)
            title = "/\(command.displayName)"
            subtitle = command.displayDescription
            let required = command.options.filter(\.isRequired)
            let optionalCount = command.options.count - required.count
            detail = (required.prefix(4).map(\.displayName) + (optionalCount > 0 ? ["+\(optionalCount) optional"] : [])).joined(separator: "  ")
            showsIcon = section.kind != .application(command.application.id)
        } else {
            id = "command-header:\(section.id)"
            title = section.title
            subtitle = ""
            detail = ""
            showsIcon = section.kind != .searchResults
        }
    }
}
