import CoreGraphics
import Foundation

/// An on-screen window of another app, in global AppKit coordinates (lower-left origin).
public struct ScreenWindow: Sendable, Hashable {
    public var id: UInt32
    public var pid: Int32
    public var frame: CGRect
    public var appName: String

    public init(id: UInt32, pid: Int32, frame: CGRect, appName: String) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.appName = appName
    }
}

/// Which window the user is looking at, given that the gaze point is a blur rather than a pixel.
public enum WindowTarget: Sendable, Equatable {
    /// One window clearly holds most of the gaze.
    case window(ScreenWindow)
    /// Two windows share the gaze about equally (say, it rests on their border).
    case ambiguous(ScreenWindow, ScreenWindow)
    /// The gaze is mostly on the desktop.
    case none

    public var window: ScreenWindow? {
        if case .window(let window) = self { return window }
        return nil
    }
}

public enum WindowTargeting {
    /// When a window counts as picked.
    public struct Thresholds: Sendable, Equatable {
        /// Share of the gaze a window needs to be picked, and how far ahead of the runner-up: by
        /// default little more than being under the gaze point, so only gaze right on a border
        /// is refused.
        public var minimumShare = 0.3
        public var minimumLead = 1.25
        /// How far another window must lead to take over from the one already outlined.
        public var switchLead = 1.5

        public init(minimumShare: Double = 0.3, minimumLead: Double = 1.25, switchLead: Double = 1.5) {
            self.minimumShare = minimumShare
            self.minimumLead = minimumLead
            self.switchLead = switchLead
        }
    }
    /// Below this share for every window, the gaze is on the desktop.
    static let desktopShare = 0.25

    /// Like `target(gazes:sigma:windows:displays:keeping:)`, except that looking at the window that
    /// already has focus picks what's hidden behind it at that spot: raising a big window buries
    /// the small one that was in front of it, and this is how to get it back (tap again where it
    /// was). Repeated taps toggle between the two.
    public static func target(gazes: [CGPoint], sigma: Double, windows: [ScreenWindow], displays: [CGRect], focused: UInt32?, keeping current: UInt32? = nil, thresholds: Thresholds = Thresholds()) -> WindowTarget {
        let direct = target(gazes: gazes, sigma: sigma, windows: windows, displays: displays, keeping: current, thresholds: thresholds)
        guard let focused, let window = direct.window, window.id == focused else { return direct }
        let behind = target(gazes: gazes, sigma: sigma, windows: windows.filter { $0.id != focused }, displays: displays, keeping: current, thresholds: thresholds)
        return behind == .none ? direct : behind
    }

    public static func target(gaze: CGPoint, sigma: Double, windows: [ScreenWindow], displays: [CGRect], focused: UInt32?) -> WindowTarget {
        target(gazes: [gaze], sigma: sigma, windows: windows, displays: displays, focused: focused)
    }

    public static func target(gaze: CGPoint, sigma: Double, windows: [ScreenWindow], displays: [CGRect]) -> WindowTarget {
        target(gazes: [gaze], sigma: sigma, windows: windows, displays: displays)
    }

    /// Spreads each gaze point over a Gaussian of `sigma` points and scores each window by how
    /// much of it lands on the window's visible part, averaged over the points (the last moments
    /// of gaze, steadier than one). A window needs a clear majority to be picked; otherwise (gaze
    /// on a border) the two leaders are ambiguous. `current`, the window already outlined, stays
    /// picked until another one clearly holds more, so the outline doesn't flicker at a border.
    public static func target(gazes: [CGPoint], sigma: Double, windows: [ScreenWindow], displays: [CGRect], keeping current: UInt32? = nil, thresholds: Thresholds = Thresholds()) -> WindowTarget {
        let shares = shares(gazes: gazes, sigma: sigma, windows: windows, displays: displays)
        let ranked = shares.sorted { $0.share > $1.share }
        guard let best = ranked.first, best.share >= desktopShare else { return .none }
        if let current, current != best.window.id, let kept = shares.first(where: { $0.window.id == current }),
           kept.share >= desktopShare, best.share < thresholds.switchLead * kept.share {
            return .window(kept.window)
        }
        let second = ranked.dropFirst().first
        if best.share >= thresholds.minimumShare, best.share >= thresholds.minimumLead * (second?.share ?? 0) {
            return .window(best.window)
        }
        return second.map { .ambiguous(best.window, $0.window) } ?? .none
    }

    /// The windows buried behind `focused`: behind it, at least a quarter of each under it, and
    /// less than half of each still visible (counting every window in front). Front to back.
    /// Only the first layer: windows that would mostly show if `focused` were gone. Deeper ones
    /// sit under these, where the eyes can't tell them apart (the overview reaches them). These
    /// are what looking at the focused window brings back.
    public static func buried(behind focused: UInt32, windows: [ScreenWindow], limit: Int = 8) -> [ScreenWindow] {
        guard let index = windows.firstIndex(where: { $0.id == focused }) else { return [] }
        let top = windows[index].frame
        var result: [ScreenWindow] = []
        for i in windows.indices where i > index {
            let window = windows[i]
            let overlap = window.frame.intersection(top)
            guard !overlap.isNull, overlap.width * overlap.height >= 0.25 * window.frame.width * window.frame.height else { continue }
            let inFront = windows[..<i]
            if visibleFraction(of: window.frame, under: inFront.map(\.frame)) < 0.5,
               visibleFraction(of: window.frame, under: inFront.filter { $0.id != focused }.map(\.frame)) >= 0.5 {
                result.append(window)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// The share of `frame` not covered by any of `covers`, sampled on a grid.
    static func visibleFraction(of frame: CGRect, under covers: [CGRect]) -> Double {
        let steps = 16
        var visible = 0
        for i in 0..<steps {
            for j in 0..<steps {
                let p = CGPoint(x: frame.minX + (Double(i) + 0.5) / Double(steps) * frame.width, y: frame.minY + (Double(j) + 0.5) / Double(steps) * frame.height)
                if !covers.contains(where: { $0.contains(p) }) { visible += 1 }
            }
        }
        return Double(visible) / Double(steps * steps)
    }

    /// Each window's share of the on-screen gaze, averaged over the gaze points.
    public static func shares(gazes: [CGPoint], sigma: Double, windows: [ScreenWindow], displays: [CGRect]) -> [(window: ScreenWindow, share: Double)] {
        guard !gazes.isEmpty else { return [] }
        var total = [Double](repeating: 0, count: windows.count)
        for gaze in gazes {
            for (window, share) in shares(gaze: gaze, sigma: sigma, windows: windows, displays: displays) {
                total[windows.firstIndex(of: window)!] += share
            }
        }
        return zip(windows, total).filter { $0.1 > 0 }.map { ($0.0, $0.1 / Double(gazes.count)) }
    }

    /// Spreads the gaze over a Gaussian of `sigma` points around `gaze` and scores each window by
    /// how much of it lands on the window's visible part. `windows` is ordered front to back, so
    /// a window only gets what isn't covered by the ones in front. Only the part of the blur on a
    /// display counts: gaze near a screen edge isn't diluted by the space beyond it.
    public static func shares(gaze: CGPoint, sigma: Double, windows: [ScreenWindow], displays: [CGRect]) -> [(window: ScreenWindow, share: Double)] {
        let steps = 12
        let reach = 2.5 * max(sigma, 1)
        var mass = [Double](repeating: 0, count: windows.count)
        var total = 0.0
        for i in -steps...steps {
            for j in -steps...steps {
                let dx = Double(i) / Double(steps) * reach
                let dy = Double(j) / Double(steps) * reach
                let p = CGPoint(x: gaze.x + dx, y: gaze.y + dy)
                guard displays.isEmpty || displays.contains(where: { $0.contains(p) }) else { continue }
                let weight = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                total += weight
                if let front = windows.firstIndex(where: { $0.frame.contains(p) }) {
                    mass[front] += weight
                }
            }
        }
        guard total > 0 else { return [] }
        return zip(windows, mass).filter { $0.1 > 0 }.map { ($0.0, $0.1 / total) }
    }
}
