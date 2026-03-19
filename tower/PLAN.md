# tower — Ground Control UI for graunde

## Architecture

```
graunde/tower/
├── backend/           # OCaml + Dream
│   ├── bin/
│   │   └── main.ml   # Entry point: Dream server, UDP listener, SSE hub
│   ├── lib/
│   │   ├── db.ml     # SQLite queries (attestations, session_project)
│   │   ├── loom.ml   # UDP listener on 19470, bridges to SSE
│   │   ├── controls.ml  # Parse controls.d + hooks.d into structured data
│   │   ├── scopes.ml # Scope tree builder from parsed controls
│   │   ├── build.ml  # Version/staleness checks (git describe, CONTROLS_HASH)
│   │   └── api.ml    # REST endpoints + SSE stream
│   ├── dune-project
│   └── tower.opam
├── frontend/          # SvelteKit
│   ├── src/
│   │   ├── routes/
│   │   │   ├── +layout.svelte    # Sidebar + top bar shell
│   │   │   ├── +page.svelte      # Dashboard (status cards)
│   │   │   ├── controls/+page.svelte
│   │   │   ├── scopes/+page.svelte
│   │   │   ├── trail/+page.svelte
│   │   │   ├── stream/+page.svelte
│   │   │   └── build/+page.svelte
│   │   ├── lib/
│   │   │   ├── api.ts            # Fetch helpers
│   │   │   ├── sse.ts            # EventSource wrapper
│   │   │   └── types.ts          # Shared types
│   │   └── app.html
│   ├── static/
│   ├── svelte.config.js
│   ├── package.json
│   └── vite.config.ts
├── Makefile           # Build both, dev mode, install
└── PLAN.md            # This file
```

## Backend (OCaml + Dream)

### Dependencies
- `dream` — HTTP server, WebSocket, SSE
- `caqti` + `caqti-driver-sqlite3` — SQLite access (type-safe queries)
- `yojson` — JSON parsing/generation
- `lwt` — async (Dream uses it internally)
- `re` — regex for parsing D source files

### API Endpoints

```
GET  /api/controls          → list all controls with scope info
GET  /api/scopes            → scope tree (nested JSON)
GET  /api/trail             → attestation list (paginated, filterable)
GET  /api/trail/stats       → aggregate counts by event type, decision
GET  /api/build             → version, staleness, upstream tag
GET  /api/stream            → SSE endpoint (bridges UDP loom feed)
POST /api/build/recompile   → trigger `make install` in graunde root
```

### Key Design Decisions

1. **UDP bridge**: OCaml process binds UDP socket on a *different* port (19471) or
   shares 19470 with SO_REUSEPORT. Simpler: just query SQLite on a timer + SSE push.
   Best: listen on 19470 alongside graunde's fire-and-forget sends (graunde sends,
   tower receives — no conflict since graunde only sends, never listens).

   Actually: graunde *sends* to 19470. Tower *binds* 19470 to receive. This is the
   standard UDP pattern — sender doesn't bind, receiver does. No port conflict.

2. **Control parsing**: Rather than parsing D source directly (fragile), we can:
   - Option A: Parse the D source with regex (good enough for the structured DSL)
   - Option B: Add a `--dump-controls` flag to graunde that outputs JSON
   - Going with Option A for now — the DSL is regular enough.

3. **Static files**: Dream serves the built Svelte app from `frontend/build/`.
   In dev mode, Vite dev server proxies API calls to Dream.

## Frontend (SvelteKit)

### Views

1. **Dashboard** (`/`) — Status cards: build health, control count, event count today,
   active sessions. Mini sparkline of events over last 24h.

2. **Controls** (`/controls`) — Table: name, type (cmd/stop/userprompt/sessionstart),
   command pattern, action (arg/omit/msg-only), scope path, decision. Filterable by
   type, scope, decision. Click to expand shows full details.

3. **Scopes** (`/scopes`) — Tree view. Root "" expands to show controls. Each scope
   node shows path, decision, control count. Negation scopes (!) shown distinctly.
   Selecting a scope filters the controls view.

4. **Trail** (`/trail`) — Reverse-chronological attestation list. Columns: timestamp,
   event type, subject (branch), predicate, source. Expandable rows show full
   attributes JSON. Filters: event type, subject, date range, text search.

5. **Stream** (`/stream`) — Live SSE-powered event tail. Events appear as they fire.
   Color-coded: green=allow, yellow=ask, red=deny/block. Pause/resume button.
   Optional sound on deny events.

6. **Build** (`/build`) — Current version, source hash vs compiled hash, upstream tag.
   Recompile button. Build log output.

### Styling
- Tailwind CSS — utility-first, no build complexity beyond what Vite already does
- Dark theme by default (dev tool)
- Monospace for code/commands, proportional for labels

## Implementation Order

### Phase 1: Skeleton
- [ ] OCaml project with Dream serving "hello world"
- [ ] SvelteKit project with sidebar layout shell
- [ ] Makefile for building both
- [ ] Dream serves Svelte static build

### Phase 2: Data Layer
- [ ] SQLite connection + attestation queries (caqti)
- [ ] D source parser for controls
- [ ] Scope tree builder
- [ ] Build/version checks

### Phase 3: API + Views
- [ ] /api/trail + Trail view
- [ ] /api/controls + Controls view
- [ ] /api/scopes + Scopes view
- [ ] /api/build + Build view
- [ ] Dashboard with stats

### Phase 4: Live Stream
- [ ] UDP listener on 19470
- [ ] SSE endpoint bridging UDP to browser
- [ ] Stream view with live tail

### Phase 5: Polish
- [ ] Filtering, pagination, search
- [ ] Keyboard navigation
- [ ] Error states
- [ ] `make install` integration
