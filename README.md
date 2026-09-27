# keybro

Mac menu bar app: Claude Code in any text field, plus a local long-running memory that your Claude Code sessions can use. See `PLAN.md` and `docs/keybro-overview.html`.

## What it does
- **Generate** (`⌘⇧K`): screenshot of the app you're in + your instruction + memory → three versions (casual, safe, bold) → `↵` inserts. Type to refine. `/standup`-style saved commands. Start with `?` to ask about the screen (answer is copied, not typed). Type `/sorry to rahul` in the field itself and press the hotkey. Mic button (`⌘D`) for on-device dictation.
- **Fix** (`⌘⇧L`): fixes grammar in your voice, in place, with undo. Follows the per-app writing mode.
- **Memory**: saves what you type (draft after a 2s pause, sent when the field clears), fixes and generated replies. Knows who you're talking to (window titles, the browser extension, chat headers, and what Generate reads on screen).
- **Nightly update** (after 9 PM, or "Update memory now"): facts with dates (old ones are replaced, never deleted), promises with due dates that close themselves when you follow through, person profiles, a daily digest, Markdown export for Obsidian.
- **Claude Code**: `keybro-mcp` lets any Claude Code session search your memory, look up people, and see open promises.

## 100% local
- Memory lives in `~/keybro-memory/memory.db` (SQLite), readable only by you.
- Search by meaning uses Apple's on-device embeddings.
- The nightly update uses a local model by default: Apple's on-device model (needs Apple Intelligence) or Ollama (`qwen3:4b`). Settings, Engine can switch it to Claude Code.
- Voice uses on-device speech recognition only.
- The browser extension only talks to the keybro helper on this Mac.
- The only thing that leaves your Mac: what you send to Claude when you use Generate or Fix (and the nightly update, if you pick Claude for it).

Never read: password fields, password managers, terminals, System Settings, blocked apps, anything while paused. Never saved: API keys, tokens, card numbers, OTPs, sexual content.

## Requirements
- macOS 26+, Apple Silicon, Xcode 26, `brew install xcodegen`
- Claude Code installed and logged in (`claude`)
- For a local nightly update: Apple Intelligence on, or `ollama pull qwen3:4b`

## Setup
```bash
make dev-cert     # once: local signing cert so permissions survive rebuilds (asks for your password)
make run          # build, install the MCP server, launch
claude mcp add keybro -- "$HOME/Library/Application Support/keybro/bin/keybro-mcp"   # connect Claude Code
make extension    # optional: browser helper; then load extension/chrome unpacked in chrome://extensions
```

## Commands
```bash
make test         # unit tests (no network)
make smoke        # one real Claude call
make mcp          # build + install the MCP server
make extension    # build + register the browser helper
make reset-perms  # clear Accessibility / Screen Recording grants
cd KeybroKit && swift run -c release keybro-eval --demo          # memory retrieval benchmark
cd KeybroKit && swift run -c release keybro-eval longmemeval_s.json 100
cd KeybroKit && swift run keybro-axprobe                         # Fix end to end in a scratch TextEdit doc (hands off the keyboard)
KEYBRO_MEMORY_DIR=/tmp/kb swift run keybro-smoke --seed-and-consolidate   # nightly update on sample data (Ollama)
```

## Layout
- `App/`: SwiftUI app (menu bar, command bar, Fix pill, Memory window, Settings, voice)
- `KeybroKit/Sources/KeybroKit/`: `Engine/` (Claude Code runner, local models), `Capture/` (Accessibility, screenshots, typing watcher), `Insert/`, `Fix/`, `Generate/`, `Memory/` (store, search, nightly job, export, MCP query), `MCP/`, `Web/`, `Text/`, `System/`
- `KeybroKit/Sources/keybro-mcp`, `keybro-nmh`, `keybro-eval`, `keybro-smoke`, `keybro-axprobe`: tools
- `extension/chrome`: browser extension
- `project.yml`: XcodeGen spec (`keybro.xcodeproj` is generated)

## Claude Code scope
`~/keybro-memory/mcp.json` (also in Settings, Claude Code): how many days back it can see, which apps to hide (hidden apps also hide facts and promises learned from them), and whether it can save notes. Every request is logged to `~/keybro-memory/mcp-access.log`.

## Dev notes
- Without `make dev-cert`, builds are ad-hoc signed and macOS may drop permissions after a rebuild: `make reset-perms`, then grant again.
- `KEYBRO_MEMORY_DIR` points all tools at another memory folder.
