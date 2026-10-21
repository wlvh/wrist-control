import AppKit
import WristCore

final class DisplayGeometry {
    private(set) var layoutID = UInt64.random(in: 1...UInt64.max)
    func invalidate() { layoutID = UInt64.random(in: 1...UInt64.max) }
    func screen(at point: PointerPoint) -> PointerScreen? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(id.uint32Value)
            if bounds.contains(CGPoint(x: point.x, y: point.y)) {
                return PointerScreen(displayID: id.uint32Value, layoutID: layoutID,
                    origin: PointerPoint(x: bounds.minX, y: bounds.minY), width: bounds.width, height: bounds.height,
                    backingScale: screen.backingScaleFactor)
            }
        }
        return nil
    }
    func appKitFrame(for display: UInt32) -> NSRect? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }?.frame
    }
}
