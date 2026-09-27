APP := build/Build/Products/Debug/keybro.app
BUNDLE_ID := dev.chetan.keybro
# Sign with the local "keybro Dev" certificate when it exists (scripts/make-dev-cert.sh),
# so permissions survive rebuilds. Otherwise ad-hoc.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "keybro Dev" && echo 'CODE_SIGN_IDENTITY=keybro Dev' || echo 'CODE_SIGN_IDENTITY=-')

MCP_DIR := $(HOME)/Library/Application Support/keybro/bin

.PHONY: gen build run test smoke reset-perms clean dev-cert mcp

dev-cert:
	./scripts/make-dev-cert.sh

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project keybro.xcodeproj -scheme keybro -configuration Debug -derivedDataPath build -quiet "$(SIGN)" build

# MCP server for Claude Code, installed at a fixed path: claude mcp add keybro -- "$(MCP_DIR)/keybro-mcp"
mcp:
	cd KeybroKit && swift build -c release --product keybro-mcp
	mkdir -p "$(MCP_DIR)"
	cp "$$(cd KeybroKit && swift build -c release --show-bin-path)/keybro-mcp" "$(MCP_DIR)/keybro-mcp"
	@echo "Installed. Connect with: claude mcp add keybro -- \"$(MCP_DIR)/keybro-mcp\""

run: build mcp
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
