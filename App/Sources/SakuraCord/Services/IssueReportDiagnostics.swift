import AppKit
import DiscordProtocol
import Foundation
import UniformTypeIdentifiers

/// Values SakuraCord fills in for the report's diagnostic fields.
nonisolated struct IssueReportSystemInfo: Equatable, Sendable {
    let appVersion: String?
    let macOS: String
    let mac: String?

    @MainActor
    static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        let system = DiagnosticsSupportSummary.currentSystemSnapshot
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(system.memoryBytes), countStyle: .memory
        )
        let mac = CurrentMacHardware.modelIdentifier.map { model in
            ([model, system.chip].compactMap(\.self) + [memory]).joined(separator: " · ")
        }
        return Self(
            appVersion: AboutVersionInformation().displayVersion,
            macOS: "macOS " + processInfo.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: ""),
            mac: mac
        )
    }
}

/// A file the person attached, read when attached so it survives the modal.
nonisolated struct IssueReportAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let contentType: UTType
    let data: Data

    var isImage: Bool { contentType.conforms(to: .image) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    static func load(_ url: URL) throws -> Self {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw IssueReportAttachmentError.notAFile(url.lastPathComponent) }
        guard (values.fileSize ?? 0) <= IssueReportHubClient.maximumFileBytes else {
            throw IssueReportAttachmentError.tooLarge(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= IssueReportHubClient.maximumFileBytes else {
            throw IssueReportAttachmentError.tooLarge(url.lastPathComponent)
        }
        return Self(
            name: url.lastPathComponent,
            contentType: values.contentType ?? .data,
            data: data
        )
    }

    var upload: IssueReportUpload {
        IssueReportUpload(
            name: name,
            contentType: contentType.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }
}

nonisolated enum IssueReportAttachmentError: LocalizedError {
    case notAFile(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .notAFile(name): "“\(name)” isn’t a file SakuraCord can attach."
        case let .tooLarge(name): "“\(name)” is larger than 10 MB."
        }
    }
}

/// Sanitised diagnostics SakuraCord can attach without the person exporting them.
nonisolated enum IssueReportDiagnostics {
    struct PanicSave: Equatable, Sendable {
        let url: URL
        let savedAt: Date
    }

    static var retainedAPILogEntryCount: Int {
        DiscordAPIDiagnosticStore.shared.retainedEntryCount
    }

    static var panicSaveIsEnabled: Bool {
        DiscordAPIDiagnosticStore.shared.enablesPanicSave
    }

    static func latestPanicSave(fileManager: FileManager = .default) -> PanicSave? {
        let url = DiscordAPIDiagnosticStore.shared.panicSaveURL
        guard let date = try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return nil }
        return PanicSave(url: url, savedAt: date)
    }

    static func apiLogUpload(now: Date = .now) throws -> IssueReportUpload {
        let data = try DiscordAPIDiagnosticStore.shared.exportData()
        return IssueReportUpload(
            name: "SakuraCord-API-Log-\(timestamp(now)).jsonl",
            contentType: "application/jsonl",
            data: newestJSONLines(data, limit: IssueReportHubClient.maximumFileBytes)
        )
    }

    static func panicSaveUpload(_ save: PanicSave) throws -> IssueReportUpload {
        IssueReportUpload(
            name: "SakuraCord-Panic-Save-\(timestamp(save.savedAt)).jsonl",
            contentType: "application/jsonl",
            data: newestJSONLines(try Data(contentsOf: save.url), limit: IssueReportHubClient.maximumFileBytes)
        )
    }

    /// Keeps the metadata line and the newest entries that fit the upload limit.
    static func newestJSONLines(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let header = lines.first else { return Data() }
        var kept: [Data.SubSequence] = []
        var size = header.count + 1
        for line in lines.dropFirst().reversed() {
            guard size + line.count + 1 <= limit else { break }
            kept.append(line)
            size += line.count + 1
        }
        var result = Data(header)
        result.append(UInt8(ascii: "\n"))
        for line in kept.reversed() {
            result.append(contentsOf: line)
            result.append(UInt8(ascii: "\n"))
        }
        return result
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}
