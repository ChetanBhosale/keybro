# keybro: Build Plan

A native macOS menu bar app. Any text field gets Claude Code, and everything you type builds a local, long-running memory that your Claude Code sessions can also use.

Visual overview of every feature: `docs/keybro-overview.html` (published at https://claude.ai/artifact/2yV85Ya9dhmgFXfQUEsX8Z).

---

## 1. What we are building

| Feature | Trigger | What happens |
|---|---|---|
| **Generate** | `⌘⇧K` (remappable) | Window screenshot + your instruction + memory → `claude -p` drafts a reply → `↵` insert, `⇥` refine, `esc` cancel |
| **Fix** | `⌘⇧L` (remappable) | Current text → fixed grammar in your voice → replaced in place, undo pill |
| **Typing capture** | Automatic | AX text after a 2s pause → draft; field clears after send → sent episode with app + contact |
| **Memory** | Automatic + nightly | Raw episodes by day, facts / people / loops / reflections by night |
| **Memory window** | `⌘M` | Graph, People, Timeline, Open Loops, Privacy, Settings |
| **MCP server** | Claude Code / Cursor | `search_memory`, `get_entity`, `timeline`, `open_loops`, `today_context`, `remember` |

Principles:
- Read, don't record. Accessibility text, not keystrokes. Screenshot only on the Generate hotkey.
- Local first. SQLite on disk, on-device model for light work, Claude Code (your login, no API keys) for heavy work.
- No LLM call per keystroke. Store raw text for free, understand it in batches.
- Sound like the user, never like AI.

---

## 2. Final tech decisions

| Area | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, SwiftUI + AppKit | Native, AX and ScreenCaptureKit are Swift-first |
| Min OS | macOS 26 (Tahoe), Apple Silicon | Needed for Apple Foundation Models (on-device LLM). Ollama fallback for anything missing |
| Distribution | Developer ID + notarized `.dmg`, Sparkle later | Mac App Store sandbox blocks the Accessibility API |
| Hotkeys | `KeyboardShortcuts` (sindresorhus) | Remappable, no extra permission |
| Database | SQLite via `GRDB.swift` | Migrations, FTS5, observation for live UI |
| Vectors | `sqlite-vec` (static, via `jkrukowski/SQLiteVec` or GRDB custom SQLite build) | System SQLite blocks loadable extensions, so it must be compiled in |
| Embeddings | Apple `NLContextualEmbedding`, fallback small ONNX / MLX model | Free, local |
| Light LLM | Apple Foundation Models, fallback Ollama (Qwen / Gemma) | Contact / topic / promise extraction on chat switch |
| Heavy LLM | Claude Code `claude -p` | Generate, Fix, nightly consolidation |
| OCR fallback | Vision `VNRecognizeTextRequest` | On-device, fast |
| MCP | `modelcontextprotocol/swift-sdk`, stdio | Claude Code launches it directly |
| Graph render | d3-force in `WKWebView` | Fastest path to a good interactive graph |

Memory design borrows: MemPalace (verbatim episodes, retrieval without LLM), Hindsight (retain / recall / reflect nightly loop), Graphiti (supersede facts with `valid_to` instead of deleting).

---

## 3. Repo layout

```
keybro/
  keybro.xcodeproj            # macOS app target (thin: entry point, Info.plist, entitlements)
  Package.swift               # KeybroKit: all logic, testable with `swift test`
  Sources/
    KeybroApp/                # @main, AppDelegate, menu bar, window routing
    Capture/
      HotkeyManager.swift
      FocusReader.swift       # focused element, value, selection, caret rect, secure-field check
      TypingWatcher.swift     # AXObserver kAXValueChangedNotification, debounce, sent detection
      ContactResolver.swift   # extension → AX header walk → OCR header strip → cache per window
      ScreenCapture.swift     # SCScreenshotManager, frontmost window only
      OCR.swift
      AppPolicy.swift         # blocklist, pause state, per-app rules
    Engine/
      ClaudeRunner.swift      # Process, stream-json parsing, session resume, timeouts
      ClaudeLocator.swift     # resolve `claude` path via login shell
      LocalModel.swift        # FoundationModels / Ollama behind one protocol
      Prompts/                # generate.md, fix.md, extract.md, nightly.md, style rules
    Insert/
      Inserter.swift          # AX set selected text → clipboard paste fallback → restore clipboard
    Memory/
      Database.swift          # GRDB pool, migrations
      Schema.swift
      EpisodeStore.swift
      FactStore.swift         # reconcile: add / update / supersede / ignore
      EntityStore.swift       # people, projects, handles, merge
      LoopStore.swift
      Search.swift            # FTS5 + vector + entity, scoring, token budget
      ContextBuilder.swift    # what goes into a Generate prompt
      Nightly.swift           # consolidate, reflect, merge, decay, close loops
      MarkdownExport.swift    # ~/keybro-memory/*.md with [[links]]
    UI/
      CommandBar/             # NSPanel + SwiftUI, variants, refine thread
      FixPill/
      MemoryWindow/           # Graph (WKWebView), People, Timeline, Loops, Privacy
      Settings/
      Onboarding/
  keybro-mcp/                 # separate executable target, opens the DB read-mostly
  extension/                  # browser extension for contact names on web apps (M7)
  Tests/
    CaptureTests/             # debounce, sent detection, secure-field skip
    MemoryTests/              # reconcile, supersede, merge, scoring, search
    EngineTests/              # stream-json parsing, prompt building
  docs/
    keybro-overview.html
```

---

## 4. Data model (SQLite)

```sql
-- L0: raw, verbatim, append-only
CREATE TABLE episodes (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,            -- sent | draft | fix | generate | screen_text
  app TEXT NOT NULL,             -- bundle id, e.g. net.whatsapp.WhatsApp, com.google.Chrome
  surface TEXT,                  -- whatsapp_web, slack, gmail ...
  entity_id INTEGER REFERENCES entities(id),  -- resolved contact, nullable
  contact_raw TEXT,              -- name as seen on screen
  text TEXT NOT NULL,
  context TEXT,                  -- visible chat text around it (trimmed)
  created_at INTEGER NOT NULL,
  processed_at INTEGER           -- set by nightly job
);
CREATE VIRTUAL TABLE episodes_fts USING fts5(text, context, content='episodes', content_rowid='id');

-- L2: people, projects, places, events
CREATE TABLE entities (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL,            -- person | project | place | event | org
  name TEXT NOT NULL,
  summary TEXT,                  -- regenerated nightly
  importance REAL DEFAULT 0.5,
  merged_into INTEGER REFERENCES entities(id),
  updated_at INTEGER
);
CREATE TABLE handles (           -- same person across apps
  entity_id INTEGER NOT NULL REFERENCES entities(id),
  surface TEXT NOT NULL,         -- whatsapp | slack | gmail | phone
  value TEXT NOT NULL,           -- "Rahul", "@rahul", "rahul.s@gmail.com", "+91..."
  UNIQUE(surface, value)
);

-- L1: atomic facts, bi-temporal
CREATE TABLE facts (
  id INTEGER PRIMARY KEY,
  subject_id INTEGER NOT NULL REFERENCES entities(id),
  predicate TEXT NOT NULL,       -- lives_in, relation, prefers_tone, works_on ...
  object TEXT NOT NULL,
  object_entity_id INTEGER REFERENCES entities(id),
  valid_from INTEGER,
  valid_to INTEGER,              -- NULL = still true; set when superseded
  recorded_at INTEGER NOT NULL,
  superseded_by INTEGER REFERENCES facts(id),
  source_episode_id INTEGER REFERENCES episodes(id),
  confidence REAL DEFAULT 0.7,
  importance REAL DEFAULT 0.5,
  last_used_at INTEGER
);
CREATE TABLE edges (             -- graph view
  src INTEGER NOT NULL REFERENCES entities(id),
  dst INTEGER NOT NULL REFERENCES entities(id),
  kind TEXT NOT NULL,
  weight REAL DEFAULT 1,
  UNIQUE(src, dst, kind)
);
CREATE TABLE loops (             -- promises
  id INTEGER PRIMARY KEY,
  entity_id INTEGER REFERENCES entities(id),
  text TEXT NOT NULL,
  due_at INTEGER,
  status TEXT NOT NULL DEFAULT 'open',  -- open | done | dropped
  source_episode_id INTEGER REFERENCES episodes(id),
  closed_by_episode_id INTEGER REFERENCES episodes(id)
);
CREATE TABLE reflections (       -- patterns from the nightly job
  id INTEGER PRIMARY KEY,
  entity_id INTEGER REFERENCES entities(id),
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE core_memory (       -- L3, always in prompt, small
  key TEXT PRIMARY KEY,          -- style, top_people, active_loops
  value TEXT NOT NULL
);
-- vectors (M5): vec0 virtual table keyed by episode / fact id
```

Files on disk:
```
~/keybro-memory/
  memory.db
  me/style.md            # seeded from ~/.claude/writing-style.md
  export/                # generated Markdown, Obsidian-ready (optional)
```

---

## 5. Core flows

### Fix (`⌘⇧L`)
1. `FocusReader` gets the focused element. If secure field or blocked app, stop.
2. Read selection, else full value. If AX read fails, send `⌘C` and read the clipboard (restore it after).
3. `ClaudeRunner`: `claude -p --model haiku` with `Prompts/fix.md` + `me/style.md`. Output only the fixed text.
4. `Inserter` replaces the same range. Show undo pill with the original.
5. Log a `fix` episode (before and after) for style learning.

### Generate (`⌘⇧K`)
1. Remember the target app and element. Capture the frontmost window to `/tmp/keybro/shot.png`.
2. `ContactResolver` returns the contact (cached per window). `ContextBuilder` pulls core memory, the person profile, top facts, open loops (about 1.5k tokens).
3. Show `CommandBar` at the caret. User types the instruction.
4. `claude -p --model sonnet --allowedTools Read --output-format stream-json` with prompt = app + contact + screenshot path + memory + instruction. Ask for JSON `{contact, variants:[casual, safe, bold]}`.
5. Stream into the bar. `⇥` sends follow-ups with `--resume <session_id>`.
6. `↵`: reactivate the target app, `Inserter` writes the draft. Log a `generate` episode.

### Typing capture (always on unless paused)
1. On focus change, `TypingWatcher` attaches an `AXObserver` for `kAXValueChangedNotification` to the focused field (skip secure / blocked).
2. Each change resets a 2s timer. On fire, upsert one `draft` row per (app, element, contact).
3. When the value drops to empty (or near empty) within a short window after the last draft and Enter / Send, promote the last draft to `sent`.
4. On chat switch, `ContactResolver` updates the contact and `LocalModel` extracts topic and promises from visible text (cheap, on-device).

### Contact resolution (per window, cached)
1. Browser extension message, if installed (web apps).
2. AX tree walk from the focused field up to the conversation header.
3. OCR of the header strip (needs screen recording).
4. On Generate, Claude also returns `contact` from the screenshot. Store it as a handle.

### Nightly job (idle + charging, or 2 AM)
1. Batch unprocessed episodes per contact into `claude -p` with `Prompts/nightly.md`. Output JSON facts, entities, handles, loops.
2. Reconcile facts: same subject + predicate with a different object → set old `valid_to`, `superseded_by`. Never delete.
3. Merge entities that share handles or strong name matches.
4. Close loops that later episodes fulfil.
5. Regenerate entity summaries, reflections, `core_memory`.
6. Decay: lower `importance` of facts not used in 60 days.
7. Rebuild Markdown export and graph edges.

### Retrieval score
`score = relevance (FTS5 / vector) × recency_decay(age) × importance`, then pack into the token budget: core → entity summary → top facts → recent episodes → open loops.

---

## 6. Milestones and tasks

### M0: Skeleton (days 1 to 2)
- [ ] Xcode app + `KeybroKit` package, `LSUIElement` menu bar only, Developer ID signing
- [ ] Onboarding: Accessibility (`AXIsProcessTrustedWithOptions`), Screen Recording check, explain monthly re-prompt
- [ ] `ClaudeLocator` via `zsh -lc 'which claude'`, store path, "Test Claude" button
- [ ] `ClaudeRunner` with stream-json parsing, timeout, cancel
- **Done when:** menu bar icon shows, permissions granted, test prompt streams back.

### M1: Fix (days 3 to 4)
- [ ] `HotkeyManager` with defaults and remap UI stub
- [ ] `FocusReader` (value, selection, secure check), clipboard read fallback
- [ ] `Inserter` (AX write, paste fallback, clipboard restore)
- [ ] Fix prompt + style file, undo pill
- **Done when:** Fix works in Notes, TextEdit, Safari, Chrome, Slack, WhatsApp. Record results in the test matrix.

### M2: Generate (days 5 to 8)
- [ ] `ScreenCapture` frontmost window
- [ ] `CommandBar` panel at caret (`kAXBoundsForRangeParameterizedAttribute`, fallback window center)
- [ ] Streaming draft, variants, refine thread with `--resume`
- [ ] Refocus target app before insert
- **Done when:** in a WhatsApp chat, "sorry to rahul, can't come" gives a context-aware reply that inserts correctly.

### M3: Memory v1 (days 9 to 12)
- [ ] GRDB database, migrations, schema above (no vectors)
- [ ] `TypingWatcher` with debounce and sent detection
- [ ] `ContactResolver` (AX header walk + OCR fallback)
- [ ] Episodes written from typing, Fix, Generate
- [ ] Memory window: Timeline + People list (raw), Graph from co-occurrence
- [ ] `ContextBuilder` with FTS5 + entity lookup feeding Generate
- **Done when:** after chatting with Rahul in WhatsApp Web and desktop, his episodes show under one person and Generate uses them.

### M4: Polish (days 13 to 14)
- [ ] Hotkey remap with clash warnings (Slack, VS Code, Safari, Bitwarden)
- [ ] Blocklist, pause / pause 1h, privacy view (what was captured)
- [ ] Errors: `claude` missing, not logged in, rate limited, insert failed (copy + toast)
- **Done when:** usable daily without surprises.

### M5: Memory v2 (week 3)
- [ ] `LocalModel` (Foundation Models, Ollama fallback) for on-chat-switch extraction
- [ ] Embeddings + `sqlite-vec`, hybrid scoring
- [ ] `keybro-mcp` stdio server with scoped tools + access log, `claude mcp add keybro` instructions
- **Done when:** a Claude Code session answers "what did Rahul say last week" through MCP.

### M6: Memory v3 (week 4)
- [ ] Nightly job (facts, reconcile, merge, loops, reflections, decay)
- [ ] Person profile with dated facts and superseded history
- [ ] Open loops UI, notifications, daily digest
- [ ] Markdown export with `[[links]]`
- **Done when:** loops auto close, superseded facts show history, digest arrives each evening.

### M7: Extras
- [ ] Browser extension for contact names (WhatsApp Web, Gmail, Slack web, LinkedIn, X)
- [ ] Voice input (local Whisper), per-app modes, saved commands, `/` trigger in field
- [ ] Memory benchmark: run LongMemEval-S retrieval (R@5) and QA to measure quality

---

## 7. Testing

| Layer | How |
|---|---|
| Debounce, sent detection, secure skip | Unit tests with a fake AX event stream |
| Reconcile / supersede / merge | Unit tests on an in-memory DB with fixture episodes |
| Scoring and token budget | Unit tests with fixed timestamps |
| stream-json parsing | Recorded `claude -p` outputs as fixtures |
| App compatibility | Manual matrix below, rerun each milestone |
| Memory quality | LongMemEval-S in M7 |

| App | Read text | AX insert | Paste fallback | Contact name |
|---|---|---|---|---|
| Notes / TextEdit | expect ✅ | expect ✅ | n/a | n/a |
| Safari (WhatsApp Web, Gmail) | test | test | needed | AX header / extension |
| Chrome (WhatsApp Web, Gmail, X) | needs `AXEnhancedUserInterface` | likely ❌ | needed | extension / OCR |
| Slack, Discord (Electron) | needs `AXManualAccessibility` | likely ❌ | needed | AX header |
| WhatsApp desktop | test | unknown | needed | AX header / OCR |
| iMessage | test | test | test | AX header |
| Terminal / iTerm | test | ❌ | paste | n/a |
| Password fields | must skip | must skip | must skip | n/a |

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| `claude -p` cold start makes Fix slow | Stream, instant "thinking" state, Haiku, move Fix to on-device model if needed |
| AX insert fails in Electron / Chrome | Clipboard paste fallback, always restore clipboard |
| Contact name missing on web apps | Extension first, AX header, OCR, Claude on Generate |
| Monthly Screen Recording re-prompt | Only Generate uses it; typing capture needs Accessibility only |
| Claude plan rate limits | Nightly batching, cheap models for background work |
| Apple Foundation Models too weak | Ollama with Qwen / Gemma |
| `sqlite-vec` build friction | Ship FTS5 first (M3), vectors in M5 |
| Public release terms | Personal use now; add API-key mode before sharing |

---

## 9. Open questions
- Does WhatsApp desktop expose the chat header and message list through AX?
- Is Fix through `claude -p` fast enough day to day?
- Foundation Models quality for contact / promise extraction vs Ollama.
