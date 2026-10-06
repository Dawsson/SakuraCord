import Foundation
import MediaPipeline

extension AppModel {
    func routeOversizedAttachment(_ prompt: OversizedAttachmentPrompt) {
        guard attachmentComposerContext(for: prompt.destination) == prompt.context,
              isComposerDropEligible(prompt.destination)
        else {
            presentNextOversizedAttachmentPrompt()
            return
        }
        switch prompt.stage {
        case .compaction:
            switch attachmentSettings.compactionPolicy {
            case .ask: oversizedAttachmentPrompt = prompt
            case .always:
                oversizedAttachmentPrompt = prompt
                compactOversizedAttachment(prompt)
            case .never: routeOversizedAttachment(prompt.externalUpload())
            }
        case .externalUpload:
            switch attachmentSettings.externalUploadPolicy {
            case .ask: oversizedAttachmentPrompt = prompt
            case .always:
                let service = attachmentSettings.externalProvider
                if prompt.availableServices.contains(service) {
                    oversizedAttachmentPrompt = prompt
                    uploadOversizedAttachment(prompt, using: service)
                } else {
                    errorMessage = "This file cannot be uploaded to \(service.displayName)."
                    presentNextOversizedAttachmentPrompt()
                }
            case .never:
                errorMessage = "\(prompt.fileURL.lastPathComponent) exceeds your Discord upload limit and was not attached."
                presentNextOversizedAttachmentPrompt()
            }
        }
    }

    func skipAttachmentCompaction(_ prompt: OversizedAttachmentPrompt) {
        guard oversizedAttachmentPrompt?.id == prompt.id else { return }
        oversizedAttachmentPrompt = nil
        routeOversizedAttachment(prompt.externalUpload())
        pruneOwnedPromisedAttachmentFiles()
    }

    func compactOversizedAttachment(_ prompt: OversizedAttachmentPrompt) {
        guard oversizedAttachmentPrompt?.id == prompt.id,
              prompt.stage == .compaction,
              attachmentComposerContext(for: prompt.destination) == prompt.context,
              isComposerDropEligible(prompt.destination)
        else { return }
        oversizedAttachmentPrompt = nil
        attachmentCompactionPresentation = prompt
        attachmentCompactionGeneration &+= 1
        let generation = attachmentCompactionGeneration
        let accountGeneration = accountSessionGeneration
        let options = attachmentSettings.compaction
        beginUsingOwnedPromisedFiles([prompt.fileURL])
        attachmentCompactionTask = Task { [weak self] in
            guard let self else { return }
            var outputDirectory: URL?
            var adopted = false
            let accessed = prompt.fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { prompt.fileURL.stopAccessingSecurityScopedResource() }
                if !adopted, let outputDirectory {
                    ComposerPromisedFileStorage.removeDirectory(outputDirectory)
                }
                endUsingOwnedPromisedFiles([prompt.fileURL])
            }
            var fallback: OversizedAttachmentPrompt?
            do {
                let directory = try ComposerPromisedFileStorage.makeReceivingDirectory()
                outputDirectory = directory
                let output = try await attachmentCompactor.compact(prompt.fileURL, in: directory, options: options)
                try Task.checkCancellation()
                guard generation == attachmentCompactionGeneration,
                      accountGeneration == accountSessionGeneration,
                      attachmentComposerContext(for: prompt.destination) == prompt.context,
                      isComposerDropEligible(prompt.destination)
                else { return finishAttachmentCompaction(generation: generation) }
                guard let approved = ComposerPromisedFileStorage.approvedRegularFile(output, in: directory) else { throw CocoaError(.fileReadUnknown) }
                let checked = try await uploadPrivacyPreparation.checkFile(approved)
                guard generation == attachmentCompactionGeneration,
                      accountGeneration == accountSessionGeneration,
                      attachmentComposerContext(for: prompt.destination) == prompt.context,
                      isComposerDropEligible(prompt.destination)
                else { return finishAttachmentCompaction(generation: generation) }
                guard let size = checked.uploadSize else { throw CocoaError(.fileReadUnknown) }
                if size <= discordAttachmentLimit {
                    let urls = adoptPromisedFileBatch(ComposerPromisedFileBatch(directory: directory, urls: [approved]))
                    adopted = appendCheckedComposerAttachments(urls, to: prompt.destination)
                } else {
                    fallback = prompt.externalUpload(after: "The compressed file still exceeds your upload limit.")
                }
            } catch AttachmentCompactionError.unsupportedType {
                fallback = prompt.externalUpload(after: "Compression isn’t available for this file type.")
            } catch is CancellationError {
                // Cancellation skips this file entirely.
            } catch {
                fallback = prompt.externalUpload(after: "This file could not be compressed.")
            }
            guard generation == attachmentCompactionGeneration,
                  accountGeneration == accountSessionGeneration else { return }
            attachmentCompactionTask = nil
            attachmentCompactionPresentation = nil
            if !Task.isCancelled, let fallback { routeOversizedAttachment(fallback) }
            presentNextOversizedAttachmentPrompt()
        }
    }

    func cancelAttachmentCompaction() {
        // Keep the source and presentation alive until the worker stops using it.
        attachmentCompactionTask?.cancel()
    }

    private func finishAttachmentCompaction(generation: UInt64) {
        guard generation == attachmentCompactionGeneration else { return }
        attachmentCompactionTask = nil
        attachmentCompactionPresentation = nil
        presentNextOversizedAttachmentPrompt()
    }
}
