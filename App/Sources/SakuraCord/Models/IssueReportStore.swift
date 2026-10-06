import Foundation
import Observation

/// In-memory state for the native report flow. Drafts survive closing the
/// modal and are discarded once filed or when the account changes.
@MainActor
@Observable
final class IssueReportStore {
    struct Presentation: Identifiable, Equatable {
        let id = UUID()
    }

    enum Step: Int, CaseIterable, Comparable {
        case describe, details, review, done

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum FormState: Equatable {
        case loading
        case ready(IssueReportForm)
        case failed(String)
    }

    enum Phase: Equatable {
        case preparing
        case signingIn
        case sending
    }

    enum JoinState: Equatable {
        case idle
        case joining
        case failed(String)
    }

    struct Draft: Equatable {
        let id = UUID()
        var values: [String: String] = [:]
        var attachments: [IssueReportAttachment] = []
        var includesSystemInfo = true
        var includesAPILog = false
        var includesPanicSave = false
    }

    struct Outcome: Equatable {
        let filed: IssueReportFiled
        let followedExisting: Bool
    }

    var presentation: Presentation?
    private(set) var kind: IssueReportKind = .bug
    private(set) var step: Step = .describe
    private(set) var formState: FormState = .loading
    private var drafts: [IssueReportKind: Draft] = [:]
    private(set) var similar: [IssueReportSimilar] = []
    private(set) var phase: Phase?
    private(set) var pendingAttachmentLoads = 0
    var error: String?
    private(set) var outcome: Outcome?
    var joinState: JoinState = .idle
    let systemInfo = IssueReportSystemInfo.current()

    @ObservationIgnored let client = IssueReportHubClient()
    @ObservationIgnored var hubSession: IssueReportHubSession?
    @ObservationIgnored var submissionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var formTask: Task<Void, Never>?
    @ObservationIgnored private var formLoadedAt = Date.distantPast
    @ObservationIgnored private var similarTask: Task<Void, Never>?
    @ObservationIgnored private var similarQuery = ""

    var draft: Draft {
        get { drafts[kind] ?? Draft() }
        set {
            drafts[kind] = newValue
            error = nil
        }
    }

    var form: IssueReportForm? {
        if case let .ready(form) = formState { form } else { nil }
    }

    var definition: IssueReportForm.Definition? { form?.kinds[kind] }

    var isSubmitting: Bool { phase != nil }

    /// The page-one paragraph that describes the report; it drives duplicate search.
    var primaryField: IssueReportField? {
        definition?.fields.first { $0.page == 1 && $0.kind == .paragraph && $0.required }
    }

    func fields(on page: Int) -> [IssueReportField] {
        definition?.fields.filter { $0.page == page && $0.diagnostic != true && $0.kind != .unsupported } ?? []
    }

    func field(ofKind fieldKind: IssueReportField.Kind) -> IssueReportField? {
        definition?.fields.first { $0.kind == fieldKind }
    }

    func hasDiagnosticField(_ id: String) -> Bool {
        definition?.fields.contains { $0.id == id && $0.diagnostic == true } == true
    }

    // MARK: Presentation

    func present(_ kind: IssueReportKind?) {
        guard !isSubmitting else {
            presentation = presentation ?? Presentation()
            return
        }
        if outcome != nil {
            outcome = nil
            joinState = .idle
            step = .describe
        }
        if let kind, kind != self.kind {
            self.kind = kind
            step = .describe
            similar = []
            similarQuery = ""
            refreshSimilar()
        }
        error = nil
        presentation = Presentation()
        loadForm()
    }

    func dismiss() {
        guard !isSubmitting else { return }
        presentation = nil
        if outcome != nil {
            outcome = nil
            joinState = .idle
            step = .describe
        }
    }

    func switchKind(to kind: IssueReportKind) {
        guard kind != self.kind, !isSubmitting, outcome == nil else { return }
        self.kind = kind
        step = .describe
        similar = []
        similarQuery = ""
        error = nil
        refreshSimilar()
    }

    func reset() {
        generation = UUID()
        submissionTask?.cancel()
        formTask?.cancel()
        similarTask?.cancel()
        submissionTask = nil
        formTask = nil
        similarTask = nil
        similarQuery = ""
        presentation = nil
        drafts = [:]
        similar = []
        phase = nil
        pendingAttachmentLoads = 0
        error = nil
        outcome = nil
        joinState = .idle
        step = .describe
        hubSession = nil
    }

    // MARK: Schema

    func loadForm(force: Bool = false) {
        guard formTask == nil else { return }
        if !force, form != nil, Date.now.timeIntervalSince(formLoadedAt) < 300 { return }
        if form == nil { formState = .loading }
        formTask = Task { [weak self, client] in
            let result: Result<IssueReportForm, any Error>
            do { result = .success(try await client.form()) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            formTask = nil
            switch result {
            case let .success(form):
                formState = .ready(form)
                formLoadedAt = .now
            case let .failure(error):
                // Keep a recent schema rather than interrupting a draft.
                if form == nil { formState = .failed(error.localizedDescription) }
            }
        }
    }

#if DEBUG
    func installFormForTesting(_ form: IssueReportForm, kind: IssueReportKind) {
        formState = .ready(form)
        formLoadedAt = .now
        self.kind = kind
    }
#endif

    // MARK: Values

    /// Keep asynchronous file reads with their original account and draft.
    func addAttachments(_ urls: [URL], using privacy: UploadPrivacyPreparation) async {
        let generation = generation
        let kind = kind
        let originalDraft = draft
        drafts[kind] = originalDraft
        let slots = IssueReportHubClient.maximumFileCount - uploadCount
        guard slots > 0 else {
            error = "Attach at most 5 files, including diagnostics."
            return
        }
        let accepted = Array(urls.prefix(slots))
        pendingAttachmentLoads += 1
        defer {
            if self.generation == generation { pendingAttachmentLoads -= 1 }
        }
        var results: [Result<IssueReportAttachment, any Error>] = []
        for url in accepted {
            guard !Task.isCancelled, self.generation == generation else { return }
            do {
                let prepared = try await privacy.prepare(url)
                defer { prepared.discard() }
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try IssueReportAttachment.load(prepared.url)
                }.value
                results.append(.success(attachment))
            } catch is CancellationError {
                continue
            } catch {
                results.append(.failure(error))
            }
        }
        guard !Task.isCancelled, self.generation == generation,
              var target = drafts[kind], target.id == originalDraft.id, !isSubmitting
        else { return }
        let diagnostics = kind == .bug
            ? (target.includesAPILog ? 1 : 0) + (target.includesPanicSave ? 1 : 0) : 0
        let remaining = max(0, IssueReportHubClient.maximumFileCount - target.attachments.count - diagnostics)
        let added = results.compactMap { try? $0.get() }
        target.attachments += added.prefix(remaining)
        drafts[kind] = target
        guard self.kind == kind else { return }
        if let failure = results.compactMap({ result -> (any Error)? in
            if case let .failure(error) = result { error } else { nil }
        }).first {
            error = failure.localizedDescription
        } else if urls.count > slots || added.count > remaining {
            error = "Attach at most 5 files, including diagnostics."
        }
    }

    func value(_ id: String) -> String {
        draft.values[id] ?? ""
    }

    func setValue(_ value: String, for id: String) {
        guard draft.values[id, default: ""] != value else { return }
        draft.values[id] = value.isEmpty ? nil : value
        if id == "title" || id == primaryField?.id { refreshSimilar() }
    }

    /// The installed release when it is supported; otherwise the person's choice.
    var installedVersion: String? { form?.supportedVersion(matching: systemInfo.appVersion) }

    var selectedVersion: String? {
        installedVersion ?? draft.values["version"].flatMap { form?.supportedVersion(matching: $0) }
    }

    func missingRequirement(before target: Step) -> String? {
        guard pendingAttachmentLoads == 0 else { return "Wait for your attachments to finish preparing." }
        guard let definition else { return "The report form hasn’t loaded yet." }
        let title = value("title").trimmingCharacters(in: .whitespacesAndNewlines)
        if !IssueReportForm.titleLengthRange.contains(title.count) {
            return title.count < IssueReportForm.titleLengthRange.lowerBound
                ? "Add a short title." : "Shorten the title to 100 characters."
        }
        let pages = target > .details ? [1, 2] : [1]
        for field in definition.fields
            where pages.contains(field.page) && field.diagnostic != true && field.kind != .unsupported
        {
            let text = value(field.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required, text.isEmpty {
                return field.kind == .choice ? "Choose an answer for “\(field.label)”." : "Fill in “\(field.label)”."
            }
            if let maxLength = field.maxLength, text.count > maxLength {
                return "Shorten “\(field.label)” to \(maxLength) characters."
            }
        }
        if target > .details, selectedVersion == nil {
            return "Update SakuraCord to a supported release first."
        }
        if target > .details, uploadCount > IssueReportHubClient.maximumFileCount {
            return "Attach at most \(IssueReportHubClient.maximumFileCount) files, including diagnostics."
        }
        return nil
    }

    var uploadCount: Int {
        draft.attachments.count
            + (kind == .bug && draft.includesAPILog ? 1 : 0)
            + (kind == .bug && draft.includesPanicSave ? 1 : 0)
    }

    /// Exactly the schema's fields, with SakuraCord's diagnostics filled in.
    func submissionValues() -> [String: String] {
        guard let definition else { return [:] }
        var values = ["title": value("title").trimmingCharacters(in: .whitespacesAndNewlines)]
        for field in definition.fields where field.kind != .files && field.diagnostic != true {
            let text = value(field.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values[field.id] = text }
        }
        if let version = selectedVersion { values["version"] = version }
        if kind == .bug, draft.includesSystemInfo {
            if hasDiagnosticField("macos") { values["macos"] = systemInfo.macOS }
            if hasDiagnosticField("mac"), let mac = systemInfo.mac { values["mac"] = mac }
        }
        return values
    }

    // MARK: Navigation

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1), next < .done else { return }
        if let missing = missingRequirement(before: next) {
            error = missing
            return
        }
        error = nil
        step = next
    }

    func goBack() {
        guard !isSubmitting, let previous = Step(rawValue: step.rawValue - 1), step != .done else { return }
        error = nil
        step = previous
    }

    func go(to target: Step) {
        guard target < step, step != .done, !isSubmitting else { return }
        error = nil
        step = target
    }

    // MARK: Submission state, driven by AppModel

    func begin(_ phase: Phase) {
        error = nil
        self.phase = phase
    }

    func finish(_ filed: IssueReportFiled, followedExisting: Bool) {
        phase = nil
        drafts[kind] = nil
        similar = []
        outcome = Outcome(filed: filed, followedExisting: followedExisting)
        step = .done
    }

    func fail(_ message: String) {
        phase = nil
        error = message
    }

    // MARK: Duplicate search

    private func refreshSimilar() {
        let text = [value("title"), primaryField.map { value($0.id) } ?? ""]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != similarQuery else { return }
        similarQuery = text
        similarTask?.cancel()
        guard text.count >= 12 else {
            similar = []
            return
        }
        similarTask = Task { [weak self, client] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled,
                  let results = try? await client.similar(to: text),
                  !Task.isCancelled,
                  let self, similarQuery == text
            else { return }
            similar = results
        }
    }
}
