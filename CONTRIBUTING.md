# Contributing to Gaze

Thanks for wanting to help. Gaze is a small project with a clear goal: make looking at a window
enough to work in it. Contributions of every size are welcome, from a typo to a better gaze model.

## Where help matters most

- **Accuracy at the screen edges.** Estimates are 10–15 mm off in the bottom corners and about
  10 mm at the left and right edges, pulled toward the middle. `gaze-eval -regions` maps it.
- **Turning the head.** The head-motion calibration step makes tracking about 1.5 mm better with a
  turned head but about 0.9 mm worse with a still head. Weighting those frames less in the fit
  might keep the gain without the cost.
- **Other Macs and cameras.** Gaze has mostly been tuned on a 16" MacBook Pro. Calibration results
  from other models, external webcams, glasses and different lighting all teach us something.
- **Onboarding and settings polish.** First launch, permissions and picking a trigger can be
  smoother.
- **Apps whose panes Gaze can't focus.** JetBrains editors, tmux and others draw panes that
  Accessibility doesn't expose.

Ideas outside this list are welcome too: open an issue to talk it through first if it's big.

## Getting started

```sh
make model   # the pretrained gaze network, converted to Core ML (needs uv)
make run     # build and launch build/Gaze.app
make test    # unit tests
```

You need a Mac with Apple Silicon, macOS 15 and Xcode. Builds are signed with your first "Apple
Development" identity so macOS keeps the camera permission between rebuilds (set
`GAZE_SIGN_IDENTITY` to choose another). [docs/how-it-works.md](docs/how-it-works.md) explains the
pipeline and why it's built the way it is: read the part you're changing first.

## Changing the tracking: measure it

Tracking changes are judged on numbers, not on how the dot feels. Turn on *Save calibration
recordings* in the menu bar menu, calibrate, and replay the recording offline:

```sh
swift run -c release GazeEval [-v] [recording]   # held-out error per target (default: newest recording)
swift run -c release GazeEval -headpose          # error while the head is turned
swift run -c release GazeEval -regions           # error across the screen
```

Put the before and after numbers in your pull request, ideally from more than one recording. A
change that helps one recording and hurts another is worth knowing about too.

Recordings contain JPEG crops of your face. They stay on your Mac. Never commit them, and only
share one if you're comfortable with that.

## Pull requests

- Keep each pull request to one change, and say what it does and why.
- Match the style around you: plain Swift, comments that explain *why*, and short functions.
- Add or update tests in `Tests/GazeKitTests/` for logic in `GazeKit`.
- Run `make test` before opening the pull request.
- If you change what users see or do, update the README or `docs/how-it-works.md`.

## Non-commercial

Gaze includes the ETH-XGaze network weights, licensed CC BY-NC-SA 4.0, so Gaze may only be used
and shared non-commercially. Please keep that in mind with anything you build on it.
