# 05 — Protocol

The daemon exposes one interface for **both** ingestion (clients) and reads (consumers): **HTTP/JSON over a Unix domain socket**. This is language-agnostic on purpose — the ecosystem goal is that anyone can write a client or a consumer in any language. XPC is explicitly rejected (it would tie the ecosystem to Swift).

- **Socket:** `~/.kairos/daemon.sock` (Unix domain; no TCP port).
- **Access control:** filesystem permissions — same user only.
- **Encoding:** JSON request/response bodies.
- **Ergonomic layer:** the `kairos` CLI wraps the socket so clients can shell out; it also provides a **spool fallback** when the daemon is down.

The daemon has **no source-specific knowledge** — endpoints speak in generic activities and events.

## Endpoints

### Ingest (clients)

```
POST /activities
  body: { source, external_id?, project?, title?, client_override?, metadata? }
  → 200 { activity_id }                       # idempotent on (source, external_id)

POST /events
  body: { activity: {source, external_id} | null, kind, ts, payload? }
  → 202 {}                                    # appended; fire-and-forget

POST /activities/close
  body: { source, external_id?, ts }
  → 202 {}
```

`ts` is epoch seconds, **client-supplied**, so events are correct even if delivery is delayed. The daemon rejects absurdly future-dated events.

### Control (any client; used by the config UI / menu bar)

```
POST /control/pause   body: { paused: bool, ts }              # → pause_on / pause_off
POST /control/owner   body: { source, external_id?, ts }      # → force_owner
```

### Config: clients & project→client mapping

```
GET   /clients                         → { clients: [ {id, name}, ... ] }
POST  /clients        { name }         → { id }                 # create
PATCH /clients/{id}   { name }          → {}                     # rename (mutable)

GET   /mapping                          → { map: [ {project, client_id, billable}, ... ] }  # current resolved
POST  /mapping        { project, client_id|null, billable }     → {}   # APPENDS a new rule row
```

`POST /mapping` never mutates — it appends to the append-only `project_client_map`; the resolver takes the latest row per project. `client_id: null` appends a tombstone (unmaps the project).

### Read (consumers)

```
GET /segments?from=<epoch>&to=<epoch>[&project=<name>][&client=<id>]
  → { segments: [ {activity_id, start, end, seconds, rule}, ... ],
      activities: { "<id>": {source, external_id, project, title, client, billable, metadata} } }
  # segments COMPUTED on request; client/billable resolved via the mapping at read time.

GET /owner       → { activity: {source, external_id, project, title} | null }

POST /snapshots  { label?, from, to, params? }
  → { id, watermarks: {events, project_client_map}, segments_digest, generated_at }
GET  /snapshots/<id>/segments   → { ... }     # re-derive from the frozen recipe

# Reserved read endpoints for a future viewer UI:
GET /events?from=&to=      GET /activities?from=&to=      GET /snapshots
```

## The `kairos` CLI (stable public contract)

```
# client side
kairos activity open  --source cc --id <session_id> --project daemonclaw \
                      --meta transcript_path=<path> --meta cwd=<cwd>
kairos event  --source cc --id <session_id> --kind cc_submit [--ts <epoch>]
kairos event  --source cc --id <session_id> --kind cc_stop
kairos activity close --source cc --id <session_id>

# config
kairos client add "Acme"                 # → prints id
kairos client rename <id> "Acme Corp"
kairos map set --project daemonclaw --client <id> [--no-billable]   # appends a rule
kairos map unset --project daemonclaw                               # tombstone

# control
kairos pause on
kairos owner --source cc --id <session_id>

# consumer side
kairos export --from <epoch> --to <epoch> [--client <id>] [--project <name>] --format json
kairos snapshot create --from <epoch> --to <epoch> --label "Acme wk28"
kairos snapshot show <id>
```

`kairos export` is the primary language-agnostic read API for third-party timesheet tools.

## Resilience: spool fallback

If the daemon socket is unavailable, `kairos event` / `kairos activity` append the JSON line to `~/.kairos/spool/<uuid>.jsonl` and exit 0. On startup and periodically the daemon **drains the spool** into `events` (ordered by each event's own `ts`), then removes the files. Fire-and-forget stays reliable across restarts with no client-side retry logic.

## Guarantees & conventions

- **Idempotency:** `POST /activities` is idempotent on `(source, external_id)`.
- **Append-only config:** `POST /mapping` only ever appends; there is no update/delete of a mapping row.
- **No callbacks to clients:** the daemon never initiates connections; the config UI is in-process.
- **Best-effort ingest:** a failed POST is dropped by the caller (or spooled); ingestion never blocks the host.
- **Reads are pure:** `GET /segments` has no side effects.

## Example: the CC client sending a submit (raw socket, any language)

```bash
curl --unix-socket ~/.kairos/daemon.sock -s -X POST http://localhost/events \
  -H 'Content-Type: application/json' \
  -d '{"activity":{"source":"cc","external_id":"cdb8e518-..."},
       "kind":"cc_submit","ts":1783739062.0}'
```

Or simply: `kairos event --source cc --id cdb8e518-... --kind cc_submit`.
