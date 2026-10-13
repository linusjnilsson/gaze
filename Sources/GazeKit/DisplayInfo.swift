import AppKit
import CoreGraphics
import Foundation

/// A connected display and the identity used to recognize a desk setup (home, office, …).
public struct DisplayInfo: Sendable, Codable, Hashable {
    public var displayID: UInt32
    /// Frame in global AppKit coordinates (points, lower-left origin of the primary display).
    public var frame: CGRect
    public var millimetersPerPoint: Double
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String
    /// The laptop's own display, which has the camera above it.
    public var isBuiltin: Bool

    public init(displayID: UInt32, frame: CGRect, millimetersPerPoint: Double, vendor: UInt32, model: UInt32, serial: UInt32, name: String, isBuiltin: Bool = false) {
        self.displayID = displayID
        self.frame = frame
        self.millimetersPerPoint = millimetersPerPoint
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
        self.isBuiltin = isBuiltin
    }

    @MainActor
    public static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let physical = CGDisplayScreenSize(id)
            return DisplayInfo(
                displayID: id,
                frame: screen.frame,
                millimetersPerPoint: physical.width > 0 ? physical.width / screen.frame.width : 0.25,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    /// A stable identifier for a set of displays in a given arrangement. Changing monitors,
    /// resolution, or arrangement yields a different signature, and needs a different calibration.
    public static func signature(of displays: [DisplayInfo]) -> String {
        let canonical = displays
            .map { d in
                "\(d.vendor)-\(d.model)-\(d.serial)@\(Int(d.frame.minX)),\(Int(d.frame.minY)),\(Int(d.frame.width))x\(Int(d.frame.height))"
            }
            .sorted()
            .joined(separator: "|")
        // FNV-1a: short, filename-safe, and stable across launches (unlike `hashValue`).
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

extension [DisplayInfo] {
    /// Moves `point` onto the nearest display, so gaze slightly past a screen edge still lands on it.
    public func clamp(_ point: CGPoint) -> CGPoint {
        guard !isEmpty else { return point }
        if contains(where: { $0.frame.contains(point) }) { return point }
        let candidates = map { display in
            let f = display.frame
            return CGPoint(x: Swift.min(Swift.max(point.x, f.minX), f.maxX - 1), y: Swift.min(Swift.max(point.y, f.minY), f.maxY - 1))
        }
        return candidates.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }!
    }

    public func display(containing point: CGPoint) -> DisplayInfo? {
        first { $0.frame.contains(point) }
    }
}
