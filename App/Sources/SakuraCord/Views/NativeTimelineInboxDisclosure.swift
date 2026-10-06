import AppKit
import SakuraCordModels

/// An Inbox group opening or closing in place.
///
/// Rows stay real canvas content throughout: the group's rows are clipped to
/// `revealedHeight`, and every later row is displayed `fullHeight -
/// revealedHeight` higher. A collapsing group keeps its rows (`heldItems`)
/// until the motion ends, so the model can collapse immediately.
struct NativeTimelineInboxDisclosure {
    static let duration: TimeInterval = 0.3

    let channelID: ChannelID
    let isCollapsing: Bool
    let requestedUptime: TimeInterval
    var heldItems: [NativeMessageTimelineItem]
    var startHeight: CGFloat
    var startUptime: TimeInterval?
    var revealedHeight: CGFloat
    var isFinished = false

    /// Ease-out with a soft landing, close to AppKit's disclosure motion.
    static func progress(at elapsed: TimeInterval) -> CGFloat {
        let fraction = min(1, max(0, elapsed / duration))
        return 1 - pow(1 - fraction, 4)
    }
}

extension NativeTimelineCanvasView {
    func toggleInboxGroup(_ channelID: ChannelID) {
        guard let model, let group = model.inbox.groups.first(where: { $0.id == channelID }) else { return }
        let previous = inboxDisclosure?.channelID == channelID ? inboxDisclosure : nil
        // Reversing the same group continues from where it is; another group snaps to its end.
        if previous == nil { finishInboxDisclosure() }
        guard !group.isAgeRestricted,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let headerIndex = inboxHeaderIndex(for: channelID),
              displayedRowOrigin(at: headerIndex) < visibleRect.maxY,
              displayedRowOrigin(at: headerIndex) + layouts[headerIndex].height > visibleRect.minY
        else {
            clearInboxDisclosure()
            model.toggleInboxGroup(channelID)
            return
        }
        let range = inboxGroupContentRange(afterHeaderAt: headerIndex)
        let now = ProcessInfo.processInfo.systemUptime
        if group.isCollapsed {
            inboxDisclosure = NativeTimelineInboxDisclosure(
                channelID: channelID, isCollapsing: false, requestedUptime: now, heldItems: [],
                startHeight: previous?.revealedHeight ?? 0, revealedHeight: previous?.revealedHeight ?? 0
            )
        } else {
            guard !range.isEmpty else {
                clearInboxDisclosure()
                model.toggleInboxGroup(channelID)
                return
            }
            // Only the part inside the viewport needs to move.
            let visibleHeight = max(0, visibleRect.maxY - displayedRowOrigin(at: range.lowerBound))
            let height = min(previous?.revealedHeight ?? contentHeight(of: range), visibleHeight)
            inboxDisclosure = NativeTimelineInboxDisclosure(
                channelID: channelID, isCollapsing: true, requestedUptime: now,
                heldItems: Array(items[range]), startHeight: height, revealedHeight: height
            )
        }
        // Hover chrome belongs to a row position that is about to move.
        removeActionCapsule()
        model.toggleInboxGroup(channelID)
        refreshInboxDisclosureGeometry()
        inboxDisclosureTicker.start(on: self) { [weak self] in self?.stepInboxDisclosure() }
    }

    /// Rows the coordinator keeps for a group that is still visibly closing.
    func heldInboxItems(for channelID: ChannelID) -> [NativeMessageTimelineItem] {
        guard let inboxDisclosure, inboxDisclosure.isCollapsing, !inboxDisclosure.isFinished,
              inboxDisclosure.channelID == channelID else { return [] }
        return inboxDisclosure.heldItems
    }

    /// Recomputes the cached geometry read by `displayedRowOrigin(at:)`.
    func refreshInboxDisclosureGeometry() {
        guard let disclosure = inboxDisclosure, let headerIndex = inboxHeaderIndex(for: disclosure.channelID) else {
            clearInboxDisclosure()
            return
        }
        let range = inboxGroupContentRange(afterHeaderAt: headerIndex)
        guard !range.isEmpty else {
            if disclosure.isCollapsing { clearInboxDisclosure() } else { resetInboxDisclosureGeometry() }
            return
        }
        // Rows are measured before applying the shift, which only affects later rows.
        inboxDisclosureRange = range
        let top = contentOriginY + rowOrigins[range.lowerBound]
        let fullHeight = contentHeight(of: range)
        inboxDisclosureShift = min(0, disclosure.revealedHeight - fullHeight)
        inboxDisclosureClipMaxY = top + disclosure.revealedHeight
    }

    func finishInboxDisclosure() {
        guard let disclosure = inboxDisclosure else { return }
        let collapsing = disclosure.isCollapsing && !disclosure.isFinished
        clearInboxDisclosure()
        // Drops the held rows from the next published item list.
        if collapsing { model?.publishInbox() }
    }

    private func stepInboxDisclosure() {
        guard var disclosure = inboxDisclosure else {
            inboxDisclosureTicker.stop()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let headerIndex = inboxHeaderIndex(for: disclosure.channelID) else {
            clearInboxDisclosure()
            return
        }
        let range = inboxGroupContentRange(afterHeaderAt: headerIndex)
        if range.isEmpty {
            // An expanding group may still be loading; its header shows progress.
            if disclosure.isCollapsing || now - disclosure.requestedUptime > 4 { clearInboxDisclosure() }
            return
        }
        let start = disclosure.startUptime ?? now
        disclosure.startUptime = start
        let visibleHeight = max(0, visibleRect.maxY - (contentOriginY + rowOrigins[range.lowerBound]))
        let target = disclosure.isCollapsing ? 0 : min(contentHeight(of: range), visibleHeight)
        let progress = NativeTimelineInboxDisclosure.progress(at: now - start)
        disclosure.revealedHeight = disclosure.startHeight + (target - disclosure.startHeight) * progress
        if progress >= 1 {
            if disclosure.isCollapsing {
                disclosure.isFinished = true
                inboxDisclosure = disclosure
                inboxDisclosureTicker.stop()
                refreshInboxDisclosureGeometry()
                redrawForInboxDisclosure()
                model?.publishInbox()
            } else {
                clearInboxDisclosure()
            }
            return
        }
        inboxDisclosure = disclosure
        refreshInboxDisclosureGeometry()
        redrawForInboxDisclosure()
    }

    func clearInboxDisclosure() {
        let wasActive = inboxDisclosure != nil
        inboxDisclosure = nil
        inboxDisclosureTicker.stop()
        resetInboxDisclosureGeometry()
        if wasActive { redrawForInboxDisclosure() }
    }

    private func resetInboxDisclosureGeometry() {
        inboxDisclosureRange = 0 ..< 0
        inboxDisclosureShift = 0
        inboxDisclosureClipMaxY = .greatestFiniteMagnitude
    }

    private func redrawForInboxDisclosure() {
        invalidateVisibleContent()
        reconcileInboxHeaders()
        positionAnimatedMediaOverlays()
        positionInlineVideoOverlays()
        positionLottieStickerOverlays()
        reconcileActivityIndicators()
        positionSpoilerOverlays()
        maskInboxDisclosureSubviews()
    }

    /// Hosted views inside the group follow the same clip as its drawn rows.
    private func maskInboxDisclosureSubviews() {
        for view in inboxDisclosureMaskedViews { view.layer?.mask = nil }
        inboxDisclosureMaskedViews = []
        guard inboxDisclosure != nil, !inboxDisclosureRange.isEmpty else { return }
        let rows = items[inboxDisclosureRange]
        let identifiers = Set(rows.map(\.identifier))
        let messageIDs = Set(rows.compactMap(\.messageID))
        var views: [NSView] = []
        for item in rows {
            switch item {
            case let .inboxForumPost(post): if let host = inboxForumPostHosts[post.id] { views.append(host) }
            case let .inboxEvent(event): if let host = inboxEventHosts[event.id] { views.append(host) }
            default: break
            }
        }
        views += animatedMediaOverlays.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += inlineVideoOverlays.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += lottieStickerOverlays.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += activityIndicators.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += spoilerOverlays.filter { messageIDs.contains($0.key.messageID) }.map(\.value)
        for view in views {
            view.wantsLayer = true
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            let visible = CGRect(x: view.frame.minX, y: view.frame.minY, width: view.frame.width,
                                 height: max(0, min(view.frame.height, inboxDisclosureClipMaxY - view.frame.minY)))
            mask.frame = view.convert(visible, from: self)
            view.layer?.mask = mask
            inboxDisclosureMaskedViews.append(view)
        }
    }

    /// Visits displayed rows intersecting `rect` in index order. Rows hidden
    /// below an animating group's clip do not end the walk early.
    func forEachDisplayedRow(in rect: CGRect, _ body: (Int) -> Void) {
        guard !items.isEmpty, var index = rowIndex(at: max(0, rect.minY)) else { return }
        while items.indices.contains(index) {
            if displayedRowOrigin(at: index) >= rect.maxY {
                guard inboxDisclosureRange.contains(index) else { return }
                index = inboxDisclosureRange.upperBound
                continue
            }
            body(index)
            index += 1
        }
    }

    func inboxHeaderIndex(for channelID: ChannelID) -> Int? {
        items.firstIndex {
            if case let .inboxGroup(header) = $0 { header.channelID == channelID } else { false }
        }
    }

    private func inboxGroupContentRange(afterHeaderAt headerIndex: Int) -> Range<Int> {
        var end = headerIndex + 1
        while items.indices.contains(end) {
            if case .inboxGroup = items[end] { break }
            end += 1
        }
        return headerIndex + 1 ..< end
    }

    private func contentHeight(of range: Range<Int>) -> CGFloat {
        range.reduce(0) { $0 + layouts[$1].height }
    }
}
