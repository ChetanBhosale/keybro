# keybro

Mac menu bar app: Claude Code in any text field, plus a local long-running memory. See `PLAN.md` and `docs/keybro-overview.html`.

## Requirements
- macOS 26+, Apple Silicon, Xcode 26
- `brew install xcodegen`
- Claude Code installed and logged in (`claude`)

## Commands
```bash
make test         # KeybroKit unit tests (no network)
make smoke        # one real Claude call through ClaudeRunner
cd KeybroKit && swift run keybro-axprobe  # Fix end to end in a scratch TextEdit doc (hands off the keyboard)
make run          # generate Xcode project, build, launch
make reset-perms  # clear Accessibility / Screen Recording grants
```

## Layout
- `App/`: SwiftUI app target (menu bar, setup window)
- `KeybroKit/`: all logic as a Swift package (`Engine/`, `System/`), tested with `swift test`
- `project.yml`: XcodeGen spec. `keybro.xcodeproj` is generated, not committed

## Dev note: permissions
Builds are ad-hoc signed until there's a Developer ID. macOS ties Accessibility grants to the signature, so after a rebuild the toggle can look on but not work. Run `make reset-perms` and grant again.
