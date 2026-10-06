import Foundation

/// A link to sakuracord.app/report with this Mac's diagnostics filled in, for
/// reporting without a signed-in account. Nothing is sent until the person
/// reviews the form and submits it.
nonisolated struct IssueReportLink: Equatable, Sendable {
    static let trackerURL = URL(string: "https://sakuracord.app/tracker")!

    let kind: IssueReportKind
    let system: IssueReportSystemInfo

    var url: URL {
        var components = URLComponents(string: "https://sakuracord.app/report")!
        var items = [URLQueryItem(name: "type", value: kind.rawValue)]
        if let appVersion = system.appVersion {
            items.append(URLQueryItem(name: "version", value: appVersion))
        }
        if kind == .bug {
            items.append(URLQueryItem(name: "macos", value: system.macOS))
            if let mac = system.mac {
                items.append(URLQueryItem(name: "mac", value: mac))
            }
        }
        components.queryItems = items
        return components.url!
    }

    @MainActor
    static func current(_ kind: IssueReportKind) -> Self {
        Self(kind: kind, system: .current())
    }
}
