import Foundation

/// How focus switching behaves, for users to tune in the advanced settings. The defaults are what
/// worked best so far.
public struct FocusTuning: Codable, Equatable, Sendable {
    // What the window trigger does.
    /// Looking at the window that already has focus brings back what's hidden behind it there.
    /// Off, that does nothing.
    public var revealsHidden = true
    /// While holding, outline the windows buried directly behind the focused one.
    public var outlinesBuried = true
    /// Name tags on those outlines.
    public var labelsBuried = true

    // Picking a window from the gaze.
    /// The gaze blur's width, relative to the measured tracking error.
    public var blurScale = 1.0
    /// Share of the blur a window needs to be picked.
    public var minimumShare = 0.3
    /// How far ahead of the runner-up the picked window must be.
    public var minimumLead = 1.25
    /// How far another window must lead to take over the outline while holding.
    public var switchLead = 1.5
    /// How much of the gaze before the key went down is averaged (seconds).
    public var averagingTime = 0.33
    /// Holding the key this long shows the outline (seconds).
    public var previewDelay = 0.15

    // Overview.
    /// ⇧ held this long with the trigger opens the overview (a tap opens it at once). Seconds.
    public var overviewDelay = 0.25

    // Pointer jump.
    /// The gaze must be at least this far from the pointer to jump (mm on screen).
    public var jumpMinimumDistance = 80.0
    /// The mouse must head within this angle of the gaze (degrees).
    public var jumpMaximumAngle = 50.0
    /// Mouse travel before deciding whether to jump (points).
    public var jumpDecisionDistance = 12.0

    // Switching displays by looking, without a key.
    /// Looking at another display for a moment moves focus there.
    public var switchesDisplays = false
    /// How long the gaze rests on the other display before focus moves (seconds).
    public var displayDwell = 0.35
    /// After a keystroke, focus stays on its display this long (seconds).
    public var typingPause = 2.0
    /// After using the mouse or trackpad, focus stays this long (seconds).
    public var mousePause = 1.5

    public init() {}

    public var thresholds: WindowTargeting.Thresholds {
        WindowTargeting.Thresholds(minimumShare: minimumShare, minimumLead: minimumLead, switchLead: switchLead)
    }

    /// Settings saved by an older version lack newer fields: those take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusTuning()
        revealsHidden = try c.decodeIfPresent(Bool.self, forKey: .revealsHidden) ?? d.revealsHidden
        outlinesBuried = try c.decodeIfPresent(Bool.self, forKey: .outlinesBuried) ?? d.outlinesBuried
        labelsBuried = try c.decodeIfPresent(Bool.self, forKey: .labelsBuried) ?? d.labelsBuried
        blurScale = try c.decodeIfPresent(Double.self, forKey: .blurScale) ?? d.blurScale
        minimumShare = try c.decodeIfPresent(Double.self, forKey: .minimumShare) ?? d.minimumShare
        minimumLead = try c.decodeIfPresent(Double.self, forKey: .minimumLead) ?? d.minimumLead
        switchLead = try c.decodeIfPresent(Double.self, forKey: .switchLead) ?? d.switchLead
        averagingTime = try c.decodeIfPresent(Double.self, forKey: .averagingTime) ?? d.averagingTime
        previewDelay = try c.decodeIfPresent(Double.self, forKey: .previewDelay) ?? d.previewDelay
        overviewDelay = try c.decodeIfPresent(Double.self, forKey: .overviewDelay) ?? d.overviewDelay
        jumpMinimumDistance = try c.decodeIfPresent(Double.self, forKey: .jumpMinimumDistance) ?? d.jumpMinimumDistance
        jumpMaximumAngle = try c.decodeIfPresent(Double.self, forKey: .jumpMaximumAngle) ?? d.jumpMaximumAngle
        jumpDecisionDistance = try c.decodeIfPresent(Double.self, forKey: .jumpDecisionDistance) ?? d.jumpDecisionDistance
        switchesDisplays = try c.decodeIfPresent(Bool.self, forKey: .switchesDisplays) ?? d.switchesDisplays
        displayDwell = try c.decodeIfPresent(Double.self, forKey: .displayDwell) ?? d.displayDwell
        typingPause = try c.decodeIfPresent(Double.self, forKey: .typingPause) ?? d.typingPause
        mousePause = try c.decodeIfPresent(Double.self, forKey: .mousePause) ?? d.mousePause
    }
}
