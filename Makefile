APP := build/Build/Products/Debug/keybro.app
BUNDLE_ID := dev.chetan.keybro

.PHONY: gen build run test smoke reset-perms clean

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project keybro.xcodeproj -scheme keybro -configuration Debug -derivedDataPath build -quiet build

run: build
	-pkill -x keybro
	open $(APP)

test:
	cd KeybroKit && swift test

# One real Claude call through ClaudeRunner: make smoke PROMPT="..."
smoke:
	cd KeybroKit && swift run -q keybro-smoke "$(or $(PROMPT),Reply with exactly: keybro is alive)"

# Ad-hoc builds change signature every build, so macOS may silently drop the grants.
reset-perms:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset ScreenCapture $(BUNDLE_ID)

clean:
	rm -rf build keybro.xcodeproj
