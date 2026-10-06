import AppKit
import SakuraCordModels
import SwiftUI
import Testing
@testable import SakuraCord

@MainActor @Test("IME commits once across command values and optional-field boundaries")
func commandNativeComposition() throws {
    let model = ApplicationCommandComposerModel()
    let option = ApplicationCommandOption(id: "100/text", name: "text", type: .string, isRequired: true)
    let note = ApplicationCommandOption(id: "100/note", name: "note", type: .string)
    let app = ApplicationCommandApplication(id: "10", name: "Test")
    model.activate(ApplicationCommand(id: "100", rootCommandID: "100", applicationID: app.id, version: "1", name: "test", description: "", application: app, options: [option, note]))
    var cancelled: String?
    let parent = ApplicationCommandEditorView(composer: model, draft: try #require(model.draft), caretRequestRevision: 0,
        fieldIssue: nil, roles: [], onKeyboardCommand: { _ in false }, onSubmit: {}, onCancel: {
            cancelled = $0
            model.cancelActiveCommand()
        },
        canReceiveAttachment: { false }, receiveAttachment: { _ in }, isFocused: .constant(false))
    let coordinator = parent.makeCoordinator()
    let text = ApplicationCommandTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
    text.coordinator = coordinator
    text.delegate = coordinator
    text.allowsUndo = false
    coordinator.render(in: text, caret: .field(option.id, offset: 0))
    coordinator.appliedCaretRevision = model.caretRequestRevision
    let unspecified = NSRange(location: NSNotFound, length: 0)
    text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    #expect(text.hasMarkedText())
    text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
    text.insertText("日本語🌸", replacementRange: unspecified)
    #expect(!text.hasMarkedText())
    #expect(model.draft?.field(option.id)?.text == "日本語🌸")
    #expect(text.string == ApplicationCommandEditorDocument(draft: try #require(model.draft)).string)
    model.setFocus(.gap(1))
    coordinator.render(in: text, caret: .gap(1, offset: 0))
    text.setMarkedText("note:", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
    #expect(text.hasMarkedText())
    text.insertText("note:", replacementRange: unspecified)
    #expect(model.draft?.fields.map(\.id) == [option.id, note.id])
    #expect(text.string == ApplicationCommandEditorDocument(draft: try #require(model.draft)).string)
    #expect(model.draft?.focus == .field(note.id))
    text.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
    text.unmarkText()
    #expect(model.draft?.field(note.id)?.text == "かな")
    text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
    text.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    text.insertText("普通のメッセージ", replacementRange: unspecified)
    #expect(cancelled == "普通のメッセージ")
    text.insertText("🌸", replacementRange: unspecified)
    text.insertText("続き", replacementRange: unspecified)
    #expect(cancelled == "普通のメッセージ🌸続き")

    // A sole optional value opens only after IME commitment. Removing its
    // empty chip must not recreate it or leak the leftover separator on re-entry.
    var optional = option
    optional.isRequired = false
    model.activate(ApplicationCommand(id: "101", rootCommandID: "101", applicationID: app.id, version: "1", name: "optional", description: "", application: app, options: [optional]))
    let optionalParent = ApplicationCommandEditorView(composer: model, draft: try #require(model.draft), caretRequestRevision: 0,
        fieldIssue: nil, roles: [], onKeyboardCommand: { _ in false }, onSubmit: {}, onCancel: { _ in },
        canReceiveAttachment: { false }, receiveAttachment: { _ in }, isFocused: .constant(false))
    let optionalCoordinator = optionalParent.makeCoordinator()
    let optionalText = ApplicationCommandTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
    optionalText.allowsUndo = false
    optionalText.coordinator = optionalCoordinator
    optionalText.delegate = optionalCoordinator
    optionalCoordinator.render(in: optionalText, caret: .gap(0, offset: 0))
    optionalCoordinator.appliedCaretRevision = model.caretRequestRevision
    optionalText.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    #expect(model.draft?.fields.isEmpty == true)
    optionalText.insertText("🌸", replacementRange: unspecified)
    #expect(model.draft?.field(optional.id)?.text == "🌸")
    optionalText.deleteBackward(nil)
    optionalText.deleteBackward(nil)
    #expect(model.draft?.fields.isEmpty == true)
    optionalText.insertText("x", replacementRange: unspecified)
    #expect(model.draft?.field(optional.id)?.text == "x")
    optionalText.deleteBackward(nil)
    optionalText.deleteBackward(nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    optionalText.commandPasteboard = pasteboard
    pasteboard.setString("one\ntwo", forType: .string)
    optionalText.paste(nil)
    #expect(model.draft?.field(optional.id)?.text == "one two")
    optionalText.paste(nil)
    #expect(model.draft?.field(optional.id)?.text == "one twoone\ntwo")
}

@MainActor @Test("command keyboard selection, multiline values and empty-chip deletion preserve the draft")
func commandNativeKeyboardEditing() throws {
    let model = ApplicationCommandComposerModel()
    let option = ApplicationCommandOption(id: "100/text", name: "text", type: .string, isRequired: true)
    let app = ApplicationCommandApplication(id: "10", name: "Test")
    model.activate(ApplicationCommand(id: "100", rootCommandID: "100", applicationID: app.id, version: "1", name: "test", description: "", application: app, options: [option]))
    var cancelled: String?
    let parent = ApplicationCommandEditorView(composer: model, draft: try #require(model.draft), caretRequestRevision: 0,
        fieldIssue: nil, roles: [], onKeyboardCommand: { command in
            switch command {
            case .advance: model.moveFocus(by: 1)
            case .previousField: model.moveFocus(by: -1)
            default: return false
            }
            return true
        }, onSubmit: {}, onCancel: {
            cancelled = $0
            model.cancelActiveCommand()
        }, canReceiveAttachment: { false }, receiveAttachment: { _ in }, isFocused: .constant(false))
    let coordinator = parent.makeCoordinator()
    let text = ApplicationCommandTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    text.coordinator = coordinator
    text.delegate = coordinator
    text.allowsUndo = false
    coordinator.render(in: text, caret: .field(option.id, offset: 0))
    coordinator.appliedCaretRevision = model.caretRequestRevision
    text.insertText("alpha\nbeta", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(model.draft?.field(option.id)?.text == "alpha\nbeta")
    let draft = try #require(model.draft)
    let document = ApplicationCommandEditorDocument(draft: draft)
    let value = try #require(document.span(option.id)).value
    text.setSelectedRange(NSRange(location: NSMaxRange(value), length: 0))
    text.deleteForward(nil)
    #expect(text.selectedRange() == NSRange(location: NSMaxRange(value), length: 0))
    #expect(model.draft?.field(option.id)?.text == "alpha\nbeta")
    #expect(coordinator.moveVertically(forward: false, in: text))
    #expect(text.selectedRange().location >= value.location)
    #expect(text.selectedRange().location <= value.location + 5)
    #expect(model.draft?.focus == .field(option.id))
    #expect(coordinator.moveVertically(forward: true, in: text))
    #expect(text.selectedRange().location >= value.location + 6)
    #expect(text.selectedRange().location <= NSMaxRange(value))
    text.setSelectedRange(NSRange(location: value.location, length: 0))
    text.moveLeft(nil)
    #expect(text.selectedRange() == NSRange(location: document.command.length, length: 0))
    #expect(model.draft?.focus == .command)
    text.moveLeft(nil)
    #expect(text.selectedRange().location == document.command.length - 1)
    text.insertTab(nil)
    #expect(text.selectedRange() == value)
    text.insertTab(nil)
    text.insertBacktab(nil)
    #expect(text.selectedRange() == value)
    text.deleteBackward(nil)
    #expect(model.draft?.field(option.id)?.text == "")
    text.deleteBackward(nil)
    #expect(model.draft?.fields.isEmpty == true)
    #expect(model.draft?.gapText == " ")
    #expect(!model.canSubmit)
    text.deleteBackward(nil)
    #expect(cancelled == "/test")
    #expect(model.draft == nil)

    // A selection crossing only the label trims the value without editing the root.
    let partial = document.edit(replacing: NSRange(location: document.command.length,
        length: value.location + 1 - document.command.length), with: "", draft: draft)
    guard case let .replace(updated, caret) = partial else {
        Issue.record("Expected a structured cross-label deletion")
        return
    }
    #expect(updated.field(option.id)?.text == "lpha\nbeta")
    #expect(caret == .command(offset: document.command.length))
    var spaced = draft
    spaced.setGapText(" ", at: 0)
    spaced.focus = .gap(1)
    #expect(spaced.gapTexts[0] == " ")
    let spacedDocument = ApplicationCommandEditorDocument(draft: spaced)
    #expect(spacedDocument.snap(spacedDocument.gaps[0].location, direction: .backward) == spacedDocument.command.length)
    #expect(spacedDocument.snap(spacedDocument.gaps[0].location, direction: .forward) == NSMaxRange(spacedDocument.gaps[0]))
    #expect(spacedDocument.edit(replacing: NSRange(location: spacedDocument.command.length - 1, length: 1), with: "", draft: spaced)
        == .cancel(restoringText: "/tes  text:alpha\nbeta"))
    #expect(document.edit(replacing: NSRange(location: document.command.length - 1, length: 1), with: "x", draft: draft)
        == .cancel(restoringText: "/tesx text:alpha\nbeta"))
}
