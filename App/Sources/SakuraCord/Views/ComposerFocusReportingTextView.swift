import AppKit

/// Composer editors report real first-responder changes. AppKit's text
/// editing notifications only bracket edits, so clicking into or away from an
/// editor without typing would otherwise leave composer focus stale.
class ComposerFocusReportingTextView: NSTextView {
    var onFirstResponderChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFirstResponderChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFirstResponderChange?(false) }
        return resigned
    }
}
