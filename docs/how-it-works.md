# How Gaze works

The details behind the [README](../README.md): every control, the tracking pipeline, calibration, the
experiments that shaped it, and how it keeps learning.

## Using Gaze in detail

1. Grant camera access on first launch.
2. **Calibrate** (about 2½ minutes per display). An intro lists the five steps and checks that the
   camera sees your face; press Space to start. Each step opens with a card saying what to do,
   with a countdown: look at a dozen dots; follow a gliding dot for 18 s; lean back or shift to one
   side and follow it again for 15 s; keep your eyes on a dot at five spots while moving your head
   in a circle with the arrow circling it; then 7 dots per display held out to measure accuracy,
   reported separately for a still head and a moving head. The background is white and
   translucent, so the screen lights your face and your eyes look as they do over everyday apps.
3. Toggle **Show gaze dot** to see the live estimate (optionally with the raw per-frame estimate in
   gray). **Steadiness** trades responsiveness for a calmer dot.
4. The main window shows detected landmarks, the iris inside each eye, head position and rotation,
   and eye angles.

**Switching focus.** Look at a window and double-tap **left ⌘** (the right ⌘ doesn't count, so
it stays free for shortcuts). Other triggers to try, in the picker: any right-hand modifier, left
⌘ or ⌥, or 🌐/fn tapped alone; Caps Lock (remapped to F18 with `hidutil` while selected, undone on
quit or when another trigger is picked); a double-tap of ⌥, ⌃ or either ⌘; or the middle, back or forward mouse button (taken from apps by an event tap while selected). The
window comes to the front with keyboard focus, and the pointer moves into it if it was elsewhere.
Hold the key (for a double-tap, the second tap) to see an outline of the window it will pick;
pressing any other key or clicking cancels, so ⌘-shortcuts never switch. A small window buried by raising a big one comes back the same way: look where it was and tap. Looking at
the window that already has focus means "what's behind here", so repeated taps toggle between the
two. While you hold the key, the windows buried directly behind the focused one show as dashed outlines
with a small name tag (only that first layer: windows stacked deeper can't be told apart by eye, and
the ⇧ overview reaches them), so you can see what's there to bring back; the one your gaze picks shows as a
tinted outline labeled with its app icon, name and window title (read through Accessibility). Tap **⇧** while holding (left ⇧ when the trigger
is right ⇧) to see every window as a tile, a grid per display; look at one and let go of the
trigger to focus it. Tiles come in a fixed order, by app name and then each app's windows as
they were opened, so an app is in the same place every time and the eyes learn where to go
(ordering by where windows sit reshuffled it: big windows overlap, so their positions barely
differ). The mouse works too: once it moves, the tile under the pointer is highlighted instead,
and a click focuses it at once (the overlay takes the click, so it doesn't reach the app below). The tile nearest the gaze is
highlighted, so looking beside a tile or just past its edge counts too, and it moves on only once
another tile is clearly nearer. Big, separate tiles are easy to hit
with a gaze that's a couple of centimeters off, and buried windows get a tile like any other. The grid opens when ⇧ goes up (or after holding it
a quarter second), so ⌘⇧ shortcuts typed with the trigger's modifier, whose key comes before ⇧ is let go, don't
flash it. Looking alone never switches: you read
other windows all the time without wanting to type into them.

**Panes.** A second key, the **pane trigger** (double-tap ⌥ by default; off, or any modifier
key the window trigger doesn't use), focuses the pane you look at inside the focused window: a
terminal split, an editor, a sidebar list. It never switches windows, and the window trigger never
touches panes, so each key always means one thing. Holding it outlines the pane it will pick. Panes
are the window's scrollable areas as Accessibility lists them, read on a background thread when the
key goes down, with a 0.3 s limit for slow apps, and judged with the same gaze blur as windows. Most
apps take focus through Accessibility; iTerm doesn't, so its session is selected through its
scripting interface (the first time, macOS asks whether Gaze may control iTerm), with the script
compiled once and run inside Gaze: a few milliseconds per switch, where launching `osascript` took
about 150. The connection to iTerm is made while the key is held, since the first call is slow. Apps that don't
expose their panes, like the editor in JetBrains IDEs, have none to pick. tmux panes are drawn as
text and aren't visible this way.

**Settings.** *Settings…* in the menu holds the advanced knobs: whether the window trigger brings
back hidden windows at all, the outlines and their name tags, how sure a pick must be (blur width,
lead over the runner-up, minimum share, outline stickiness, gaze averaging), the outline and
overview delays, and the pointer jump's distance, direction tolerance and movement threshold. Each
explains itself, and *Restore Defaults* goes back to what's tuned here.

**Pointer jump.** When you start moving the mouse toward where you're looking, and that is at least
8 cm (and well beyond the tracking error) away, the pointer jumps to your gaze and your hand does the
last bit (MAGIC pointing, Zhai et al. 1999). Small moves, moves in another direction and drags are
left alone.

Both need Accessibility access (also used for learning from typing).

**Profiles.** Each calibration is a named profile for one display setup (monitors + arrangement),
saved with everything learned since in `~/Library/Application Support/Gaze/Profiles/`. When displays
change, the most recently used matching profile loads automatically, so switching between home and
office needs no recalibration. Several profiles can share the same displays (say "Home" and "Café"
for the laptop alone, where seating and lighting differ); pick one from the profile menu, which
also creates, renames and deletes profiles. Learned interactions are written a few seconds after
they happen, and on quit or when switching profiles.

**Recordings.** With *Save calibration recordings* on (off by default), each calibration also saves
its frames to `~/Library/Application Support/Gaze/Recordings/<date>/`: a JPEG crop around the face
per frame, and `session.json` with the landmarks, irises, network output, targets and displays. That
is real labeled data for comparing tracking methods offline. It never leaves the Mac.

## How it works

Gaze is modeled geometrically, so head movement is handled by the math instead of having to be
learned:

```
Camera (AVFoundation, 1080p)
  → Vision landmarks: eye corners, nose tip, mouth corners, eye contours
  → Head pose: fit the user's 3D face shape to the landmarks (perspective-n-point, Levenberg–Marquardt);
    a nose or mouth point Vision misplaces for a frame is detected and left out
  → Iris = weighted centroid of the darkest pixels inside each eye contour
  → Eyeball centers: placed at each eye's own corners in the image, set back by a calibrated depth
  → Eye rotation: intersect the camera ray through each iris with an eyeball sphere
  → Gaze ray = eyeball position + head rotation × calibrated eye-in-head direction
  → Intersect with each display's physical plane → global screen point
  → Blink rejection, clamp to displays
  → Fixation stabilizer: hold steady while the eyes rest on a spot, jump when the last few frames
    taken together clearly sit elsewhere (short runs catch big jumps in two frames, longer runs
    catch shifts smaller than the per-frame noise);
    head motion (measured precisely, unlike the iris) makes big jumps faster, and when the gaze
    is carried along by a head turn, the point follows the head smoothly instead of lagging
```

**Gaze network.** With `make model`, an appearance-based network runs next to the geometry: the
pretrained ETH-XGaze ResNet-18 (Core ML, Neural Engine) looking at the whole face rather than just the
iris. Each frame, the face is warped into the normalized view it was trained on (Zhang et al. 2018:
a virtual camera 60 cm from the face center with the head's roll removed, 224×224), and its pitch
and yaw are turned back into a camera-space direction. The network also looks at the mirror image
of the face (yaw flipped back) and the two answers are averaged: on three recorded calibrations that
was steadier on all three and more accurate on two, for about 2 ms more per frame. Profiles
calibrated before this keep the plain network until recalibrated, since their personalization was
fitted to it. From there it goes through the same
calibration as the iris (eye correction, display placement, learning, correction layer). Calibration
fits both, validates both on the same held-out targets, and uses the network unless it's clearly
worse there (a handful of targets can't separate close results, and replayed recordings show the
network well ahead); the result screen shows both. The chosen source is then refitted on every
target, validation included. The ETH-XGaze weights are licensed for non-commercial use only.

The network is then **personalized**: a generic network is off for each person in a consistent way
(eye shape, eyelids, glasses), and that shows in the 512 features its last layer reads. Calibration
fits ridge regression from those features to the network's error on the calibration dots (its
strength chosen by leaving out one dot at a time). On a real recording this cut the vertical error
by about a third. Blending the personalized network with the iris estimate didn't help on any axis
in held-out tests, so the network is used alone.

Leaning in close pushes the lower face out of the camera's view (it sits above the screen).
Landmarks at the image edge or in a cut-off part of the face are dropped, and head pose comes from
whatever remains: eyes and nose suffice, and the eyes alone carry tracking briefly from the previous
frame. If Vision's face detector loses a cropped face, landmark detection keeps following its last
region for up to a second. The status shows when the face is partly out of view.

Calibration fits only what geometry can't know:
- **Your face shape.** Faces differ by several millimeters from any generic model, and head pose
  fitted against the wrong shape misreads head turns by several degrees. The 3D landmark positions
  are learned from how they move as your head moves during calibration.
- **The eyeball lever.** Turning the head moves the iris relative to the eye corners, which has to
  be subtracted. From one camera, a deep face turning a little looks like a shallow face turning a
  lot, so this lever is fitted to the head-motion targets, where you look at a dot while moving.
- **A small eye correction.** The visual axis is offset a few degrees from the iris direction.
- **Where external displays sit** relative to the camera.

**Following a moving dot.** Twelve fixed dots label twelve spots, and the network's personalization
(512 features) overfits them: replayed recordings were about 10 mm worse on a dot left out of the
fit than on dots in it. So after the fixed dots, a dot glides along a Lissajous figure across each
display for 18 s, slow enough for smooth pursuit (about 10° a second). Each camera frame is labeled
with where the dot was 50 ms earlier (screen latency plus how far the eyes trail), the first second
is skipped while the eyes catch up, and frames are grouped into half-second stretches that stand in
for targets (outlier frames within a stretch, catch-up saccades, are dropped). That's about 30
extra targets and 500 frames across the whole screen, used by every part of the fit and kept as
calibration data for learning. Replaying recordings with part of the dot left out, the vertical
error kept falling as more was added (10 → 8 and 9 → 5 mm on held-out dots) but was leveling off,
and the horizontal error didn't change. So the second pass isn't more of the same: after asking
you to lean back or sit a bit to one side, the dot laps the screen along its edges and into the
corners (where estimates are least accurate, and where the sweep doesn't quite reach), then
spirals inward. Live tracking sees postures a single sitting doesn't, and the fit now sees two.
Recordings number the stretches from 10000 (sweep) and 20000 (loops); `gaze-eval -nopursuit`
replays a recording without them, `-firstpass` without the loops, and `-pursuit 0.5` with half of
them, to compare.

**Turning the head.** Estimates drift when the head turns away from how it was during calibration.
`gaze-eval -headpose` holds out each head-motion dot in turn and bins its frames by how far the head
is turned. On two recordings, still dots were 7–10 mm off per axis. Dots held while turning the
head were 12–19 mm off with the other two head-motion dots in the fit, 16–26 mm with one, and up to
50 mm sideways at 10° or more of yaw with none. Both the personalization and the geometry fit gained
from them, and the error was still falling steeply at two. Applying the eye correction in the
camera's frame instead of the head's made no difference. So calibration ends with a head-motion
pass: the dot rests at five spots (the middle and toward each corner) for 3.5 s each while you turn
your head left, right, up and down, and frames are grouped into half-second stretches like the
moving dot's, so each head pose counts as its own target. That's about 30 head-motion targets
where there were 3, numbered from 30000 in recordings; `gaze-eval -noheadpass` leaves them out.

**Accuracy near the edges.** On a recording with the moving dot, held-out error is a few millimeters
over most of the screen but 10–15 mm in the bottom corners and about 10 mm at the left and right
edges, always pulled toward the middle (`gaze-eval -regions` maps it). The plain network is 40 mm
short there, even on frames it was fitted on: looking down and sideways from a camera above the
screen, the eyelids cover much of the eye, and the network underestimates how far you look.
Personalization recovers most of it. With the moving dot, calibration also fits curvature in the
eye correction (horizontal and vertical eye angle multiplied together and squared), which helped
the left edge most (11 → 9 mm). Tried on the same recording and dropped, since each gained 1–2 mm
at most: a correction layer learned from calibration (rejected on held-out targets), fitting on
averaged frames, and weighting edge frames more in the personalization.

The built-in display's position relative to the camera is known. With no built-in display, the
camera is assumed to sit on top of the primary display. macOS doesn't report the camera's field of
view, and fitting it to gaze data runs away to absurd values that merely damp head-pose errors, so
it's fixed: a typical 70°, or the value entered under **Settings… → Camera**, used from the next
calibration on (a profile keeps the one it was calibrated with, since its face shape and
personalization were fitted to it). Apple doesn't publish it for recent Macs; `gaze-eval -fov`
replays a recording with several values and scores each on held-out dots.

**Focus switching.** The gaze point is treated as a blur as wide as the tracking error (live error
from clicks, else the last measured one, else the calibration's). Windows of other apps come from the window server, front to
back (ordinary windows only, no titles, so no Screen Recording access), and each window scores the
share of the blur landing on its visible part. Shares are averaged over the gaze since the key
went down (up to a third of a second). A window needs 30% of it and 1.25× the runner-up, little more
than being under the gaze point; otherwise (gaze right on a border) nothing happens and both are
outlined dashed. While holding, the outlined window stays until another one leads by 1.5×, so the outline doesn't flicker at a border. On the desktop of another
display, the trigger focuses the window last used on that display (Gaze notes the focused window per
display once a second), or brings the pointer there if it has none. The window is focused through Accessibility (set
main, app frontmost, raise), which macOS honors from a background app where a plain `activate()`
often isn't; window-server and Accessibility windows are matched by their exact frame.

**Switching displays by looking** (opt-in, with two or more displays: in the menu, or **Settings…
→ Displays**). Looking at another display moves focus there without a key, to the window last used
on it, and the pointer follows (so new windows, Spaces and Mission Control land there too). The gaze
has to rest on that display for 0.35 s, at least twice the tracking error clear of the bezel, so
glances across and gaze hovering at the border never switch; after a switch the next waits at least
a second. Nothing switches within 2 s of a keystroke or 1.5 s of moving the mouse, scrolling or
clicking, or while a trigger is held. All four are adjustable. Between displays, the gaze is
decided by large distances, so this is far more forgiving than picking windows on one screen.

**Resource use.** **Tracking: Light (15 fps)** in the menu halves the frames analyzed, and so
about half of the face detection and network work, with the gaze point a little slower to follow the
eyes; **Light on battery** switches by power source (checked every 30 s). Calibration always runs at
full speed. The camera otherwise runs at 30 fps while a face is in view, drops to 5 fps after 3 s
without one, and stops while the screen is locked or asleep. Views only redraw when what they
show changes: the gaze point is held still by the stabilizer, the frame rate updates once a
second, and the main window's live tracker view redraws at most 15 times a second and not at all
while the window is hidden or covered. Most of what remains is Vision's face and landmark
detection and the network on the Neural Engine.

| Path | Role |
| --- | --- |
| `Sources/GazeKit/` | Pipeline: camera, face analysis, head pose, eye model, gaze model + calibration fit, learning, stabilizer, profiles |
| `Sources/GazeApp/` | Main window, menu bar, calibration, overlays, focus switching, updates |
| `Sources/GazeEval/` | Offline replay of calibration recordings (`gaze-eval`) |
| `Tests/GazeKitTests/` | Unit tests |

## Learning from interactions

After calibrating, Gaze keeps refining itself from everyday use. Status and a per-reason breakdown
of skipped interactions are shown in the main window.

**When it learns.** Only at moments you were almost certainly looking at a known spot:

- **Aimed clicks:** the cursor traveled to the click (≥ 40 pt in the preceding 1.2 s). Clicks
  without cursor movement, double clicks, and repeated clicks on one spot are skipped, since people
  often click those without looking.
- **Start of typing:** the first keystroke after a ≥ 1 s pause, paired with the text cursor's
  position (Accessibility API; only positions and timing are used, never which keys).
- **Good tracking:** eyes open, both irises found, a low head-pose fit error, head in range.
- **Settled gaze:** the predicted gaze point stayed within 45 mm during the moment before.
- **Plausible:** predicted within a radius that scales with recent accuracy (60–180 mm for clicks),
  so a drifted model can still pick up the samples it needs to recover.

**How it learns.**

- Every frame of the settled gaze is kept, grouped as one event; calibration and validation frames
  are kept permanently as the most precise data.
- Each event is weighted by trust (calibration 2, click 1, typing 0.5), recency (7-day half-life,
  1 day while drifting; calibration ages 4× slower) and screen coverage (crowded regions count
  less).
- The geometric model (eye correction + external display placement) is refit robustly (Huber).
- With ≥ 60 everyday events on a display, a **correction layer** is learned on top: kernel ridge
  regression on eye-in-head and head angles, capped at ±60 mm, so it can learn errors that vary
  across the screen, which the geometric model can't represent. Its smoothness is chosen, and its
  use decided, on held-out recent events.
- **The network's personalization keeps learning.** Each learned event also stores what the network
  saw: its uncorrected angles per frame and its 512 features averaged over the event (about 2 KB).
  With ≥ 40 such everyday events, each refit also relearns the personalization (ridge regression as
  at calibration) from the calibration dots plus the newest 600 events, which span days, lighting
  and postures where calibration has 19 dots from one sitting. Stored frames are redone with
  whichever personalization is being fitted or judged. The refit tries it with and without
  relearning and keeps whichever does better on the held-out events.
- A refit is adopted only if it beats the current model on the newest 20% of events, held out from
  the fit.
- **Drift detection:** if the live error rises well above its level after the last adjustment,
  Gaze refits sooner, favors recent data, and suggests recalibrating.

## Roadmap

1. ~~Accuracy spike~~
2. ~~Head-motion robust 3D gaze model~~
3. ~~Continuous learning from clicks and typing, with a learned correction layer~~
4. ~~Focus switching with a trigger key~~ and ~~pointer jump~~
5. ~~Opt-in switching between displays by looking (typing and mouse guards, hysteresis)~~,
   ~~last window per display~~. Next: learn from confirmed switches, a frequency prior for windows you use
6. Settings polish, exclusions, onboarding
7. ~~Core ML appearance-based gaze model~~ (spike: pretrained, chosen per calibration)
8. ~~Personalize the network from calibration~~ ~~and keep refining it from clicks~~
