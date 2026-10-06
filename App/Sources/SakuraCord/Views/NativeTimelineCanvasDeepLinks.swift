import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    @discardableResult
    func activateSakuraCordDeepLink(
        _ action: SakuraCordDeepLinkAction,
        message: Message
    ) -> Bool {
        guard let actions else { return false }
        switch action {
        case .checkForUpdates, .updateToApplyTheme:
            actions.checkForUpdates()
        case let .applyTheme(theme):
            actions.applyTheme(theme)
        case let .openSettings(destination):
            actions.openSettings(destination)
        case let .startIssueReport(kind):
            guard let model else { return false }
            model.presentIssueReport(kind)
        case .sendDiagnostics:
            guard let model, let window else { return false }
            let channelID = message.channelID
            let session = model.accountSession()
            Task { @MainActor [weak window] in
                guard model.isCurrentAccountSession(session) else { return }
                await model.shareDiagnostics(in: channelID) { name in
                    await Task.yield()
                    guard let window, window.isVisible, window.attachedSheet == nil else { return false }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Send Diagnostics?"
                    alert.informativeText = "Send sanitised local diagnostics to “\(name)”?"
                    alert.addButton(withTitle: "Send")
                    alert.addButton(withTitle: "Cancel")
                    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
                }
            }
        }
        return true
    }
}
