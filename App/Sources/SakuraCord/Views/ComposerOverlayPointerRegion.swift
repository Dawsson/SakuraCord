import AppKit
import SwiftUI

/// Composer suggestions extend outside the composer's AppKit bounds. Track
/// their actual window rectangles so only the covered timeline loses hover.
struct ComposerOverlayPointerRegion: NSViewRepresentable {
    static let changed = Notification.Name("ComposerOverlayPointerRegionChanged")
    private static let regions = NSHashTable<Region>.weakObjects()

    static func containsPointer(in window: NSWindow?, at location: NSPoint? = nil) -> Bool {
        guard let window else { return false }
        let point = location ?? window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return regions.allObjects.contains { region in
            region.window === window && !region.isHiddenOrHasHiddenAncestor
                && WindowModalCoordinator.allowsInput(for: region)
                && region.bounds.contains(region.convert(point, from: nil))
        }
    }

    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {}
    static func dismantleNSView(_ view: Region, coordinator: ()) { view.stop() }

    final class Region: NSView {
        private weak var registeredWindow: NSWindow?
        private var windowFrame: CGRect?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            registeredWindow = window
            if window != nil { regions.add(self) }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let frame = convert(bounds, to: nil)
            guard frame != windowFrame else { return }
            windowFrame = frame
            notify(registeredWindow)
        }

        func stop() {
            let oldWindow = registeredWindow
            regions.remove(self)
            registeredWindow = nil
            windowFrame = nil
            notify(oldWindow)
        }

        private func notify(_ window: NSWindow?) {
            guard let window else { return }
            // Reconcile after the SwiftUI/AppKit layout transaction has settled.
            Task { @MainActor [weak window] in
                guard let window else { return }
                NotificationCenter.default.post(name: ComposerOverlayPointerRegion.changed, object: window)
            }
        }
    }
}
