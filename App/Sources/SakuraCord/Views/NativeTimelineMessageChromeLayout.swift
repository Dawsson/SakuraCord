import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

@MainActor
enum NativeTimelineReactionFonts {
    private static var cachedCount: (pointSize: CGFloat, font: NSFont)?

    static var count: NSFont {
        let pointSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        if let cachedCount, cachedCount.pointSize == pointSize {
            return cachedCount.font
        }
        let font = AppPerformanceSignposts.measureSync(
            "TimelineReactionCountFontCacheMiss"
        ) {
            NSFont.monospacedDigitSystemFont(
                ofSize: pointSize,
                weight: .semibold
            )
        }
        cachedCount = (pointSize, font)
        return font
    }

    static let overflow = AppPerformanceSignposts.measureSync(
        "TimelineReactionOverflowFontCacheMiss"
    ) {
        NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    }
}

extension NativeTimelineRowLayout {
    static func commandInvocation(
        _ message: Message,
        origin: CGPoint,
        maximumWidth: CGFloat,
        cosmeticPolicy: ProfileCosmeticPolicy
    ) -> CommandInvocationRegion {
        let user = message.interactionMetadata?.user.map(cosmeticPolicy.user)
        let userLabel = user?.displayName ?? "Someone"
        let commandLabel = message.interactionMetadata?.displayName ?? "command"
        let userFont = ProfileNameFontLoader.shared.resolvedFont(for: user, fallback: .systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption2
            ).pointSize,
            weight: .semibold
        ))
        let captionFont = NSFont.preferredFont(
            forTextStyle: .caption1
        )
        let commandFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(
                forTextStyle: .caption1
            ).pointSize,
            weight: .semibold
        )
        let frame = CGRect(
            origin: origin,
            size: CGSize(
                width: maximumWidth,
                height: MessageRowLayoutMetrics.commandInvocationHeight
            )
        )
        let connectorFrame = CGRect(
            x: origin.x,
            y: origin.y,
            width: 30,
            height: MessageRowLayoutMetrics.commandInvocationHeight
        )
        var horizontalOffset = connectorFrame.maxX + 5
        let identityIconFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + MessageRowLayoutMetrics.commandInvocationContentInset,
            width: 14,
            height: 14
        )
        let avatarFrame = user == nil ? nil : identityIconFrame
        let fallbackAvatarFrame = user == nil ? identityIconFrame : nil
        horizontalOffset += 14 + 5
        let availableMaxX = frame.maxX - 48
        let userWidth = min(
            NativeTimelineRowLayout.measuredTextWidth(userLabel, font: userFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let userFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + 3,
            width: userWidth,
            height: 14
        )
        horizontalOffset = userFrame.maxX + 5
        let usedWidth = min(
            NativeTimelineRowLayout.measuredTextWidth("used", font: captionFont),
            max(0, availableMaxX - horizontalOffset)
        )
        let usedFrame = CGRect(
            x: horizontalOffset,
            y: origin.y + 2,
            width: usedWidth,
            height: 16
        )
        horizontalOffset = usedFrame.maxX + 5
        let pill = commandPill(
            label: commandLabel,
            font: commandFont,
            origin: CGPoint(x: horizontalOffset, y: origin.y + 2),
            maximumWidth: max(0, availableMaxX - horizontalOffset)
        )
        let profileFrame = identityIconFrame.union(userFrame)
        return CommandInvocationRegion(
            frame: frame,
            connectorFrame: connectorFrame,
            avatarFrame: avatarFrame,
            fallbackAvatarFrame: fallbackAvatarFrame,
            profileFrame: profileFrame,
            userFrame: userFrame,
            usedFrame: usedFrame,
            pillFrame: pill.frame,
            commandSymbolFrame: pill.symbol,
            commandFrame: pill.text
        )
    }

    private struct CommandPillRegion {
        let frame: CGRect
        let symbol: CGRect
        let text: CGRect
    }

    private static func commandPill(
        label: String,
        font: NSFont,
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> CommandPillRegion {
        let symbolWidth: CGFloat = 10
        let naturalCommandWidth = NativeTimelineRowLayout.measuredTextWidth(
            label,
            font: font
        )
        let pillWidth = min(
            6 + symbolWidth + 3 + naturalCommandWidth + 6,
            maximumWidth
        )
        let pillFrame = CGRect(
            x: origin.x,
            y: origin.y,
            width: pillWidth,
            height: 16
        )
        let commandSymbolFrame = CGRect(
            x: pillFrame.minX + 6,
            y: pillFrame.minY + 3,
            width: symbolWidth,
            height: 10
        )
        let commandFrame = CGRect(
            x: commandSymbolFrame.maxX + 3,
            y: pillFrame.minY,
            width: max(0, pillFrame.maxX - 6 - commandSymbolFrame.maxX - 3),
            height: 16
        )
        return CommandPillRegion(frame: pillFrame, symbol: commandSymbolFrame, text: commandFrame)
    }

    static func ephemeral(
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> EphemeralRegion {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let frame = CGRect(
            origin: origin,
            size: CGSize(width: maximumWidth, height: 15)
        )
        var horizontalOffset = origin.x
        let eyeFrame = CGRect(x: horizontalOffset, y: origin.y + 1, width: 13, height: 13)
        horizontalOffset = eyeFrame.maxX + 4
        let visibilityWidth = min(
            measuredTextWidth("Only you can see this", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let visibilityFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: visibilityWidth,
            height: 15
        )
        horizontalOffset = visibilityFrame.maxX + 4
        let bulletWidth = min(
            measuredTextWidth("•", font: font),
            max(0, frame.maxX - horizontalOffset)
        )
        let bulletFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: bulletWidth,
            height: 15
        )
        horizontalOffset = bulletFrame.maxX + 4
        let dismissFrame = CGRect(
            x: horizontalOffset,
            y: origin.y,
            width: min(
                measuredTextWidth("Dismiss message", font: font),
                max(0, frame.maxX - horizontalOffset)
            ),
            height: 15
        )
        return EphemeralRegion(
            frame: frame,
            eyeFrame: eyeFrame,
            visibilityFrame: visibilityFrame,
            bulletFrame: bulletFrame,
            dismissFrame: dismissFrame
        )
    }

    static func reactionSize(_ reaction: Reaction) -> CGSize {
        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var width: CGFloat = 12 + MessageReactionMetrics.emojiSize
        if reaction.count > 0 {
            width += 4 + measuredTextWidth(
                String(reaction.count),
                font: NativeTimelineReactionFonts.count
            )
        }
        if !plan.isEmpty {
            width += 4 + reactionPreviewWidth(plan)
        }
        return CGSize(
            width: ceil(width),
            height: MessageReactionMetrics.pillHeight
        )
    }

    private static func reactionPreviewWidth(
        _ plan: MessageReactionPreviewPlan
    ) -> CGFloat {
        let avatarsWidth = plan.reactors.isEmpty
            ? 0
            : MessageReactionMetrics.avatarSize
                + CGFloat(plan.reactors.count - 1) * 11
        guard plan.overflowCount > 0 else { return avatarsWidth }
        let overflowWidth = max(
            MessageReactionMetrics.avatarSize,
            measuredTextWidth(
                "+\(plan.overflowCount)",
                font: NativeTimelineReactionFonts.overflow
            )
        )
        return avatarsWidth
            + (plan.reactors.isEmpty ? 0 : 2)
            + overflowWidth
    }

    static func reactionRegion(
        _ reaction: Reaction,
        frame: CGRect
    ) -> ReactionRegion {
        var horizontalOffset = frame.minX + 6
        let emojiFrame = CGRect(
            x: horizontalOffset,
            y: frame.midY - MessageReactionMetrics.emojiSize / 2,
            width: MessageReactionMetrics.emojiSize,
            height: MessageReactionMetrics.emojiSize
        )
        horizontalOffset = emojiFrame.maxX

        var countFrame: CGRect?
        if reaction.count > 0 {
            horizontalOffset += 4
            let countWidth = measuredTextWidth(
                String(reaction.count),
                font: NativeTimelineReactionFonts.count
            )
            countFrame = CGRect(
                x: horizontalOffset,
                y: frame.minY,
                width: countWidth,
                height: frame.height
            )
            horizontalOffset += countWidth
        }

        let plan = MessageReactionPresentation.previewPlan(for: reaction)
        var avatars: [ReactionRegion.AvatarRegion] = []
        var overflowFrame: CGRect?
        if !plan.isEmpty {
            horizontalOffset += 4
            for (index, reactor) in plan.reactors.enumerated() {
                let avatarFrame = CGRect(
                    x: horizontalOffset + CGFloat(index) * 11,
                    y: frame.midY - MessageReactionMetrics.avatarSize / 2,
                    width: MessageReactionMetrics.avatarSize,
                    height: MessageReactionMetrics.avatarSize
                )
                avatars.append(.init(frame: avatarFrame, reactor: reactor))
            }
            if !plan.reactors.isEmpty {
                horizontalOffset += MessageReactionMetrics.avatarSize
                    + CGFloat(plan.reactors.count - 1) * 11
            }
            if plan.overflowCount > 0 {
                if !plan.reactors.isEmpty {
                    horizontalOffset += 2
                }
                overflowFrame = CGRect(
                    x: horizontalOffset,
                    y: frame.minY,
                    width: max(
                        MessageReactionMetrics.avatarSize,
                        frame.maxX - 6 - horizontalOffset
                    ),
                    height: frame.height
                )
            }
        }
        return ReactionRegion(
            frame: frame,
            reaction: reaction,
            emojiFrame: emojiFrame,
            countFrame: countFrame,
            avatarRegions: avatars,
            overflowFrame: overflowFrame
        )
    }

}
