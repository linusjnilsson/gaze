.PHONY: app run test model clean release

app:
	./scripts/build-app.sh

run: app
	-pkill -x Gaze
	@# open fails while the old instance is still quitting.
	@while pgrep -x Gaze >/dev/null; do sleep 0.1; done
	open build/Gaze.app

test:
	swift test

# A notarized DMG and Sparkle appcast for sharing (see scripts/release.sh for the one-time setup).
release:
	./scripts/release.sh $(VERSION)

# Downloads the pretrained gaze network and converts it to Core ML (needs uv).
model:
	uv run scripts/convert-gaze-model.py

clean:
	rm -rf .build build
