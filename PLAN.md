# keybro: Plan

A native macOS app that turns any text field into a Claude Code powered writing assistant, with a long-running local memory of your world.

- **Cmd+Shift+K (Generate):** screenshot the current window, type an instruction ("sorry to rahul, can't come"), Claude Code drafts a context-aware reply, Enter inserts it into the field.
- **Cmd+Shift+L (Fix):** fix grammar and English of the current text in your own voice, replaced in place.
- **Memory:** everything you send or fix builds a local memory (people, facts, promises, style) that powers better replies and is shared with your Claude Code sessions via MCP.
- **Engine:** Claude Code (`claude -p`) on your existing login. No external LLM API keys.

> Hotkeys are defaults only and must be remappable. Cmd+Shift+K clashes with Slack, VS Code, Xcode. Cmd+Shift+L clashes with Safari, Bitwarden, VS Code/Cursor.

---

## 1. Why this, why now

### Pain points (research, Sept 2026, mostly Hacker News; Reddit blocked direct fetches)
1. Copy-pasting context between apps and ChatGPT/Claude. "It feels like we're working for the AI."
2. AI tools forget you between sessions and don't share memory. "Claude Code simply forgets everything between sessions."
3. Fear of always-on screen recording (Recall, Screenpipe threads). Grammarly is called a keylogger.
4. Demand for fully local, bring-your-own-model setups.
5. Rewind/Limitless shut down after Meta acquisition (Dec 2025). Users orphaned and wary of vendors.
6. Subscription fatigue. "I don't want to pay twice for same LLM tokens. I already use Claude Code."
7. AI rewrites sound too formal or obviously AI.
8. Hidden capture scandals (Wispr Flow screenshots) destroyed trust.

### Competitor gap
| Space | Players | Missing |
|---|---|---|
| Inline AI writing | BoltAI, Elephas, Raycast AI, Grammarly, Apple Writing Tools (macOS 27) | Screen-aware drafting in any field, own voice, memory |
| Memory + MCP | Screenpipe, minimi, Omi, OpenMemory, Supermemory | Writing UX, capture-on-intent only |

**Wedge:** nobody combines both. One local memory that powers inline writing AND is served to Claude Code. Plain grammar fix alone is not defensible (Apple ships it free).

### Principles
- Capture only on hotkey. Never record in the background.
- Local only. No cloud, no account.
- Runs on Claude Code the user already has.
- Sounds like the user, not like AI.

---

## 2. Feature list

### 2.1 Inline Generate (Cmd+Shift+K)
- Works in any text field: WhatsApp, Slack, Gmail, iMessage, LinkedIn, X, Discord, Notion, Terminal.
- Floating command bar at the cursor. Type the instruction.
- Auto screenshot of the frontmost window for chat context.
- Streaming draft preview.
- Keys: `Enter` insert, `Tab` continue chatting, `Esc` cancel, `↑/↓` switch variant.
- Follow-ups: "shorter", "more flirty", "add a joke", "reply in Hindi".
- Variants: safe, casual, bold.
- Tone presets: friendly, professional, flirty, apologetic, firm, funny.
- Selected text becomes a rewrite instead of new text.
- Ask about the screen: "what did he ask earlier?"

### 2.2 Instant Fix (Cmd+Shift+L)
- Fix grammar in place (selection, or whole field if nothing selected).
- Keeps the user's voice. No em dashes, no AI phrasing.
- Undo pill and `Cmd+Z` restore.
- Modifier modes: short, professional.
- Hinglish/Hindi to clean English and back.

### 2.3 Screen context
- Screenshot only on hotkey.
- Knows the app and the person (e.g. WhatsApp, Rahul).
- Region select option.
- Redact OTPs, card numbers, passwords before sending.
- Later: on-device OCR (Vision) instead of image for speed and fewer tokens.

### 2.4 Memory
- Built from approved actions only (inserted replies, accepted fixes, chats). No raw keystroke logging.
- People memory: who, relationship, tone, recent context, inside jokes.
- Voice profile per person and per app.
- Open loops: promises detected and reminded.
- Daily digest.
- Built-in memory graph (Obsidian optional).
- Markdown export to an Obsidian vault.
- Memory inspector: search, edit, delete, pin.
- Forget: by entity, tag, or time range.
- Time travel: "what did I know about Rahul in March".
- Provenance: every fact links to its source message or screenshot.

### 2.5 Claude Code integration
- Engine: `claude -p` headless, user's Claude login.
- Model per action (haiku for Fix, sonnet for Generate).
- MCP server `keybro-memory` so any Claude Code session can use the memory.
- Scoped access (time window, app, tag, work vs personal) plus access log.

### 2.6 Per-app modes and skills
- WhatsApp casual, Slack concise, Gmail professional, LinkedIn thoughtful, X witty, Terminal explain-error.
- Custom prompt per app.
- Saved commands: `/standup`, `/followup`, `/decline-politely`.

### 2.7 Privacy and trust
- Everything local (SQLite + Markdown).
- App blocklist (banking, password managers).
- Skip secure / password fields automatically.
- Pause and incognito from the menu bar.
- Privacy dashboard: what was captured and when.
- Open source capture layer (later).

### 2.8 Later
- Voice: hold hotkey to speak instruction, dictation, local Whisper.
- `/` trigger typed directly in the field.
- Smart reply chips on unread chats, unreplied reminders.
- Calendar and email awareness.
- Team memory over MCP.
- iPhone companion with keyboard extension.

---

## 3. Architecture

```
┌──────────────────── keybro.app (Swift, menu bar) ────────────────────┐
│ HotkeyManager → FocusReader (AX) → ScreenCapture (ScreenCaptureKit)  │
│        ↓                                                             │
│ CommandBar (floating NSPanel at cursor)                              │
│        ↓                                                             │
│ ContextBuilder (memory retrieval, token budget)                      │
│        ↓                                                             │
│ ClaudeRunner → `claude -p … --output-format stream-json`             │
│        ↓                                                             │
│ Inserter (AX write → clipboard paste fallback → restore clipboard)   │
│        ↓                                                             │
│ MemoryWriter (episode log → background fact extraction)              │
└──────────────────────────────────────────────────────────────────────┘
        │                                   │
   ~/keybro-memory/memory.db          ~/keybro-memory/*.md
   (SQLite, source of truth)          (generated view, Obsidian/graph)
        │
   keybro-memory MCP server  ←  Claude Code / Cursor sessions
```

### Modules
| Module | Job | Tech |
|---|---|---|
| `HotkeyManager` | Global remappable hotkeys | `KeyboardShortcuts` (sindresorhus) |
| `FocusReader` | Frontmost app, focused field, value, selection, caret rect | AX: `kAXFocusedUIElementAttribute`, `kAXValueAttribute`, `kAXSelectedTextAttribute`, `kAXBoundsForRangeParameterizedAttribute` |
| `ScreenCapture` | Frontmost window to `/tmp/keybro/shot.png` | ScreenCaptureKit `SCScreenshotManager` |
| `CommandBar` | Input, streaming draft, keys | Non-activating `NSPanel` + SwiftUI |
| `ContextBuilder` | Pick memory for the prompt | SQLite FTS5 (+ sqlite-vec later) |
| `ClaudeRunner` | Spawn `claude -p`, stream, keep `session_id` for `--resume` | `Process` |
| `Inserter` | Write text into the field | AX set, fallback `NSPasteboard` + `CGEvent` Cmd+V |
| `MemoryWriter` | Log episode, run background extraction | SQLite, background `claude -p` |
| `MemoryMCP` | Stdio MCP binary for Claude Code | Talks to the app DB over a Unix socket or reads SQLite directly |
| `Settings` | Hotkeys, claude path, models, blocklist | SwiftUI `Settings` scene |

### App surfaces
- Menu bar icon: status, pause, open memory, settings.
- Floating command bar.
- Main window: Memory Graph, People, Timeline, Open Loops, Settings.
- Onboarding: Accessibility, Screen Recording, Claude Code check.

---

## 4. Claude Code engine

### Generate
```bash
claude -p "<prompt>" \
  --model sonnet \
  --add-dir ~/keybro-memory \
  --allowedTools "Read" \
  --output-format stream-json --verbose
```
Prompt contains: app name, screenshot path, instruction, retrieved memory context, style rules, "output only the message text".

### Follow-up
Same call plus `--resume <session_id>`.

### Fix
`--model haiku`, no screenshot, only `me/style.md` as context.

### Memory extraction (background, after insert)
Scoped to the memory folder, returns JSON facts that the app reconciles into SQLite.

### Gotchas
- GUI apps don't inherit shell `PATH`. Resolve `claude` once via `zsh -lc 'which claude'` and store it.
- Cold start per call. Show "thinking…" instantly and stream tokens.
- Counts against the user's Claude plan limits.
- Personal use is fine. A public product running on users' Claude subscriptions needs a check of Anthropic's terms, probably with an API-key option.

---

## 5. Long-running memory design

### Why hybrid
| Approach | Fails when |
|---|---|
| Markdown only | 1000s of files, Claude grepping is slow and token heavy |
| Embeddings only | Old and new facts clash, no time, no structure, duplicates |
| Hybrid | Scales for years |

### Layers
```
L0 Episodes   raw events, append-only (message sent, fix done, screen text)
L1 Facts      atomic, timestamped, sourced: "Rahul moved to Bangalore" (valid_from Aug 2026)
L2 Entities   people, projects, places, auto summarised profiles
L3 Core       small, always in prompt: style, top people, active loops
```

### Storage
- `~/keybro-memory/memory.db` (SQLite) is the source of truth.
  - Tables: `episodes`, `facts` (with `valid_from`, `valid_to`, `source_episode_id`, `importance`), `entities`, `edges`, `loops`.
  - FTS5 for keyword search.
  - `sqlite-vec` for embeddings (v2).
- `~/keybro-memory/*.md` is a generated view with `[[links]]`. File watcher re-indexes manual edits.
- Embeddings must be local (Claude Code can't produce them): Apple `NLContextualEmbedding`, or bundled `bge-small` / `nomic-embed` via MLX or Core ML.

### Folder
```
~/keybro-memory/
  memory.db
  CLAUDE.md            # how to use this folder, reply rules
  me/style.md          # user's voice
  people/rahul.md
  apps/whatsapp.md
  daily/2026-09-26.md
  loops.md
```

### Write path
1. Save episode (L0).
2. Claude extracts facts as JSON.
3. Reconcile: ADD, UPDATE, SUPERSEDE, IGNORE. Never delete, set `valid_to` instead.
4. Link facts to entities (graph edges).
5. Detect promises into `loops`.

### Read path
1. Detect entities on screen (Rahul) from screenshot and app.
2. Hybrid search: entity lookup + FTS5 (+ vector in v2).
3. Score = relevance × recency decay × importance.
4. Pack into ~1.5k token budget: core + entity profile + top facts + open loops.

### MCP tools
`search_memory(query, time_range)`, `get_entity(name)`, `timeline(name)`, `open_loops()`, `remember(fact)`.

### Nightly sleep job
- Consolidate daily episodes into weekly and monthly summaries.
- Regenerate entity profiles.
- Reflect: patterns ("Rahul usually cancels weekend plans").
- Decay: rarely used, low importance facts rank lower.
- Dedupe and merge entities ("Rahul S" = "rahul sharma").
- Auto close loops when fulfilled.

### Graph (no Obsidian needed)
Parse `[[links]]` / `edges` into nodes and edges, render with d3-force in a `WKWebView` (or SwiftUI `Canvas`). Click a node to open the note. "Open in Obsidian" is optional.

---

## 6. Milestones

| # | Name | Scope | Done when |
|---|---|---|---|
| M0 | Skeleton (day 1–2) | Xcode project, menu bar only (`LSUIElement`), onboarding for permissions, resolve `claude` path, "Test Claude" | Icon shows, permissions granted, test prompt returns |
| M1 | Fix (day 3–4) | Read selection or field, `claude -p` haiku, replace in place, undo pill | Works in Notes, TextEdit, Safari, Chrome, Slack, WhatsApp |
| M2 | Generate (day 5–8) | Window screenshot, command bar at caret, streaming, Enter/Tab/Esc, refocus target app before insert | WhatsApp "sorry to rahul can't come" gives a context-aware reply, inserted |
| M3 | Memory v1 (day 9–11) | SQLite episodes/facts/entities, FTS5, Markdown export, built-in graph, background extraction | After 3 chats, `people/rahul.md` has real context and replies use it |
| M4 | Polish (day 12–14) | Hotkey remap and conflict warnings, blocklist, secure field skip, pause, error states (not logged in, rate limit, insert failed → copy + toast) | Daily-drivable |
| M5 | Memory v2 | Local embeddings, sqlite-vec, hybrid scoring, MCP server | Claude Code session answers "what did Rahul say last week" via MCP |
| M6 | Memory v3 | Nightly job, time travel, provenance, open loops UI | Loops auto close, timeline view works |
| M7 | Extras | OCR instead of image, voice, `/` trigger, per-app modes, smart replies | |

---

## 7. Test matrix

| App | Read text | AX insert | Paste fallback |
|---|---|---|---|
| Notes / TextEdit | expect ✅ | expect ✅ | n/a |
| Safari, Chrome (Gmail, X) | test | likely ❌ | needed |
| Slack, Discord (Electron) | test | likely ❌ | needed |
| WhatsApp (Catalyst) | test | unknown | needed |
| iMessage | test | test | test |
| Terminal / iTerm | test | ❌ | paste |
| Password field | must skip | must skip | must skip |

Electron apps may need `AXManualAccessibility` set before their AX tree is readable.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| `claude -p` latency | Stream, show state instantly, haiku for Fix, local model for Fix later |
| AX insert fails in Electron/Chrome | Clipboard paste fallback, always restore clipboard |
| Monthly Screen Recording re-prompt (Sequoia/Tahoe) | Unavoidable, explain in onboarding, capture only on hotkey |
| Claude plan rate limits | Show clear error, cheaper model for background jobs |
| Keylogger perception | No keystroke capture, approved actions only, privacy dashboard, open source capture |
| Apple ships similar basics (macOS 27) | Differentiate on screen context in any app, own voice, memory, Claude Code |
| Distribution terms | Personal use first, add API-key mode before public release |

---

## 9. Stack
- Swift 6, SwiftUI + AppKit, macOS 14+.
- Packages: `KeyboardShortcuts`, SQLite (GRDB or raw), `sqlite-vec`, `Sparkle` (later).
- Distributed outside the Mac App Store (sandboxed apps can't use Accessibility): Developer ID signed, notarized `.dmg`.

---

## 10. Open questions
- Does Claude Code subscription mode work well enough for Fix latency, or does Fix need a local model?
- WhatsApp Catalyst AX support: needs a hands-on test in M1.
- Public release: API keys vs Claude Code only.
