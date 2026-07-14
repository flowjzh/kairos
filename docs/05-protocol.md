# 05 — Protocol

The daemon exposes one interface for **both** ingestion (clients) and reads (consumers): a **custom line-delimited JSON RPC** over a Unix domain socket. HTTP is explicitly rejected — Swift has no built-in HTTP server, and a custom protocol is fully native (`Network.framework` + `JSONDecoder`/`JSONEncoder`), needs no `swift-nio`, and is trivially consumable in any language. XPC is also rejected (it would tie the ecosystem to Swift).

- **Socket:** `~/.kairos/daemon.sock` (Unix domain; no TCP port).
- **Access control:** filesystem permissions — same user only (the daemon `chmod 0600`s the socket).
- **Framing:** one JSON object per line (newline-delimited). `JSONEncoder` produces compact JSON (no raw newlines), so newline framing is safe.
- **Model:** **one request per connection.** A client opens the socket, writes one request line, reads one response line, closes. No keep-alive, no request `id`, no multiplexing — fire-and-forget clients and one-shot reads don't need it.
- **Payload:** JSON only (never Swift binary Codable) — so non-Swift SDKs are trivial and the protocol is language-neutral.
- **Identifiers:** `source` and `project` are sent as **slugs** (human-readable, e.g. `claude-code`, `daemonclaw`); the daemon resolves them to internal integer ids. `client` is sent as its integer `id` (clients have no slug). `external_id` is the agent's session id (opaque string).

The daemon has **no source-specific knowledge** — methods speak in generic activities and events.

## Request / response shape

```
→ {"method":"events.post","params":{"activity":{"source":"claude-code","external_id":"…"},"kind":"ai_submit","ts":1783739062.0}}
← {"result":{"activity_id":42}}
   or
← {"error":{"code":"bad_request","message":"ts in the future"}}
```

`ts` is epoch seconds, **client-supplied**, so events are correct even if delivery is delayed. The daemon rejects absurdly future-dated events.

## Methods

### Ingest (clients)

```
activities.start   { source, external_id?, project?, title?, metadata?, kairos_session_id?, afk_immune? }
                   → { activity_id }                  # create-or-RESUME; sets state=active; NO event
activities.stop    { source, external_id?, kairos_session_id? }
                   → {}                               # sets state=stopped; NO event
activities.ensure  { kairos_session_id, source, project?, title?, ts }
                   → { activity_id }                  # idempotent: create only if the kid is unclaimed (wrapper's 5s call)
events.post        { activity: {source, external_id}, kind, ts, payload?, kairos_session_id? }
                   → {}                               # appended; fire-and-forget (ai_submit/ai_stop/activity_override)
focus.report       { kairos_session_id, focused: bool, ts }
                   → {}                               # → focus / blur (M4; the timing base since M4p3)
```

`source` and `project` are slugs — the daemon auto-registers them (upsert into `sources`/`projects`) on first sight. **Since M4p3** `activities.start`/`stop` are pure identity + lifecycle declarations that write **no event**: `start` creates-or-resumes the row and sets `state=active` (resume = a `stopped` row with the same `(source, external_id)` flips back to `active`); `stop` sets `state=stopped`. Timing comes only from `focus`/`blur` (via `focus.report`). `activities.ensure` is the PTY wrapper's post-launch call (after ~5 s): the daemon creates a `source=pty` activity **only if** the `kairos_session_id` is still unclaimed by a hook — so a wrapped `vim`/`ssh` gets an activity while `kairos claude` (whose `SessionStart` already claimed the kid) is a no-op. A meeting/manual with a direct client follows `activities.start` with `events.post` `kind=activity_override`.

**`kairos_session_id` + `focus.report` (M4 / M4p3).** When a command is launched under `kairos` (the PTY fallback), the wrapper injects a `kairos_session_id` (kid) and every agent hook RPC carries it; the daemon keeps an ephemeral in-memory map `kid → activity`, refreshed on each hook (last-write-wins), so it survives a daemon restart via the next hook. The wrapper reports focus transitions with `focus.report` (best-effort — dropped if the socket is down); the daemon resolves the map to the activity and appends `focus`/`blur`. A report that arrives before the mapping exists is buffered (latest wins) and flushed on registration. Since **M4p3** `focus`/`blur` are the timing base and the daemon owns two derived behaviours: on a foreground `blur` with no successor it **auto-catches** to an active manual backdrop by materialising a `focus` event (0→none, 1→auto, >1→most-recent + a menu notification); and the wrapper's launch `focus.report` + `activities.ensure` make it the first axis for activity creation (Design B — the hook enriches, it does not open a competing activity). The wire format is defined canonically in Rust `libs/codec`; the daemon's `KairosRPC` is its Swift hand-mirror (M4p2).

### Notifications (plugin → user)

```
notify.user   { source, kind, title, subtitle?, message, cooldown_seconds? }
              → {}    # daemon posts a native macOS notification; throttled only if cooldown_seconds is set
```

A plugin asks the daemon to nudge the user — e.g. the agent started **without** `kairos`, so focus/blur timing is missing, and the user should relaunch via `kairos`. The **plugin** owns *whether* to notify, the *wording* (`title`/`subtitle`/`message`), and *how often* (`cooldown_seconds`, optional): if present, the daemon delivers at most once per that many seconds per `(source, kind)` (in-memory — resets on daemon restart); if omitted, every call is delivered. `subtitle`, if set, is a smaller line under the title — a way to set a command apart on its own line, since native notifications have no inline code/monospace style. The daemon never decides this on its own: a future plugin that reports its own focus needs no PTY wrap and must not be nagged for lacking a `kairos_session_id`, so the orphan check stays in the plugin. (claude-code omits `cooldown_seconds` — it wants a nudge on every unwrapped start, since relaunching frequently and forgetting the `kairos` prefix is exactly the case to catch.) `notify.user` is **never spooled** — a stale nudge replayed after a daemon outage is noise (the activity RPC beside it is spooled as usual).

### Control (config UI / menu bar / CLI)

```
control.pause   { paused: bool, ts }              # → pause_on / pause_off
focus.set       { source, external_id?, ts }       # → focus (source=manual); the manual switch / override
```

`focus.set` is the menu's manual switch (and the replacement for the removed `force_owner`): it materialises a `focus` event for the chosen activity, which the latest-wins reducer makes the current holder.

### Config: clients & project→client mapping

```
clients.list                          → { clients: [ {id, name}, ... ] }
clients.add     { name }              → { id }
clients.rename  { id, name }          → {}                    # mutable

mapping.list                          → { map: [ {project, client_id, billable}, ... ] }   # project as slug; current resolved
mapping.set     { project, client_id|null, billable }  → {}   # APPENDS a rule row (never mutates)
```

`mapping.set` only ever appends to the append-only `project_client_map`; the resolver takes the latest row per project. `client_id: null` appends a tombstone (unmaps the project).

### Read (consumers)

```
segments.get   { from, to, project?, client? }
  → { segments: [ {activity_id, start, end, seconds, rule}, ... ],
      activities: { "<id>": {source, external_id, project, title, client, billable, metadata} } }
  # segments COMPUTED on request; client/billable resolved via the mapping at read time.
  # source/project returned as slugs; client as {id, name}.

focused.get    → { activity: {source, external_id, project, title} | null }   # the single focused activity (M4p3)

snapshots.create  { label?, from, to, params? }
  → { id, watermarks: {events, project_client_map}, segments_digest, generated_at }
  # drains the spool first; warns if spool non-empty after drain.
snapshots.get     { id }   → re-derived segments from the frozen recipe

# Reserved for a future viewer UI / rich consumers:
events.list { from, to }   activities.list { from, to }   snapshots.list
```

## The `kairos` CLI (thin socket client)

The CLI is a **pure socket client** — it links **no** attribution library and **no** SQLite (the core lives only in the daemon). Every subcommand is one line-JSON RPC:

```
# client side
kairos activity start --source claude-code --id <session_id> --project daemonclaw \
                      --meta transcript_path=<path> --meta cwd=<cwd>
kairos event  --source claude-code --id <session_id> --kind ai_submit [--ts <epoch>]
kairos event  --source claude-code --id <session_id> --kind ai_stop
kairos activity stop  --source claude-code --id <session_id>

# config
kairos client add "Acme"                  # → prints id
kairos client rename <id> "Acme Corp"
kairos map set --project daemonclaw --client <id> [--no-billable]
kairos map unset --project daemonclaw

# control
kairos pause on
kairos focus --source claude-code --id <session_id>    # manual switch (→ focus.set)

# consumer side (daemon computes; CLI just prints)
kairos export --from <epoch> --to <epoch> [--client <id>] [--project <name>] --format json
kairos snapshot create --from <epoch> --to <epoch> --label "Acme wk28"
kairos snapshot show <id>
```

`kairos export` is a **shell convenience** over `segments.get` — handy for debugging and quick pipes, but **not** the primary consumer interface. The primary interface for a real timesheet app is the SDK (below).

## SDKs (the primary consumer surface)

Because the protocol is line-JSON, an SDK is a thin wrapper (open socket, write a JSON line, read a JSON line) — pure Python/Node, **no native dylib, no FFI**. The SDK exposes typed methods, not a raw dump:

```python
core = Kairos()                                             # connects to ~/.kairos/daemon.sock
segs = core.segments(_from, to, client="acme")              # → segments.get
for s in segs:
    path = s.activity.metadata["transcript_path"]
    slice = read_transcript(path, s.start, s.end)           # app-side file I/O
    summary = llm.summarize(slice)                          # app-side LLM
```

The Swift core (attribution + SQLite) is **daemon-internal** and is **not** exposed via FFI — the cost of a Swift→C façade (unstable ABI, manual memory/type translation, shipping a macOS dylib coupled to the OS Swift runtime) is not justified: the daemon is always running, and consumers need *segment data* (JSON-able), not Swift computation. Transcript slicing, LLM calls, and per-client formatting all live in the consumer.

Reference SDKs ship in Swift (bundled with the daemon repo) and Python (for the reference summarizer, [08](./08-summarizer.md)).

## Resilience: spool fallback

If the daemon socket is unavailable, `kairos event` / `kairos activity` append the JSON line to `~/.kairos/spool/<uuid>.jsonl` and exit 0. On startup and periodically the daemon **drains the spool** into `events` (appended in each event's own `ts` order), then removes the files. Fire-and-forget stays reliable across restarts with no client-side retry logic. (`snapshots.create` and `kairos export` drain first when the daemon is up.)

## Guarantees & conventions

- **Idempotency:** `activities.start` is idempotent on `(source, external_id)` (create-or-resume); `activities.ensure` no-ops if the kid is already claimed.
- **Append-only config:** `mapping.set` only ever appends; there is no update/delete of a mapping row.
- **No callbacks to clients:** the daemon never initiates connections; the config UI is in-process.
- **Best-effort ingest:** a failed method call is dropped by the caller (or spooled); ingestion never blocks the host.
- **Reads are pure:** `segments.get` has no side effects.
- **Debugging:** `echo '{"method":"segments.get","params":{"from":0,"to":9999999999}}' | nc -U ~/.kairos/daemon.sock` (or the CLI) — not curl, but equally direct.

## Example: the client sending a submit (raw socket, any language)

```bash
echo '{"method":"events.post","params":{"activity":{"source":"claude-code","external_id":"cdb8e518-..."},"kind":"ai_submit","ts":1783739062.0}}' \
  | nc -U ~/.kairos/daemon.sock
```

Or simply: `kairos event --source claude-code --id cdb8e518-... --kind ai_submit`.
