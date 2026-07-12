# 08 — Consumers & Summarizer

**Output is not part of the core.** Kairos's responsibility ends at producing accurate, attributed segments; turning them into a timesheet — per-client formatting, PDF/CSV/Markdown, posting to an invoicing or time-tracking API — is an open-ended integration space that lives in **external consumers**. The core exposes a stable read API and stays out of the formatting business.

## The contract consumers depend on

- `GET /segments?from=&to=` over the Unix socket, **or** `kairos export --from --to --format json`.
- Response = computed segments + the `activities` they reference, with `client`/`billable` already **resolved** via the project→client mapping (plus `external_id`, `project`, `metadata.transcript_path`).

That is everything a consumer needs. Consumers may be written in any language; they shell out to `kairos export` or hit the socket, then format and deliver however a given client requires. Per-client templates, API delivery, and LLM summarization all live here — not in the daemon.

## Reference summarizer (one consumer, not privileged)

Kairos ships a reference consumer as an example — a starting point to copy and specialize per client, not a mandated format.

### Pipeline

```
kairos export ──▶ group (by day / project / client — client resolved by the daemon)
              │
              │  for each cc segment block:
              │     1. locate transcript via activity.metadata.transcript_path
              │        (or ~/.claude/projects/*/<external_id>.jsonl)
              │     2. slice transcript entries within [block.start, block.end]
              │     3. extract user prompts + assistant tool-use/file deltas
              │     4. LLM summarize → one line
              ▼
           timesheet.md / .csv / …  (or POST to an external API)
```

### Transcript slicing

- Map an activity's `external_id` (CC session_id) to its transcript file (the metadata carries `transcript_path`; fallback is `~/.claude/projects/*/<session_id>.jsonl`, whose directory name encodes the cwd).
- For each block, read transcript entries whose `timestamp` ∈ `[block.start, block.end]`.
- Feed the slices (prompt text + which files were read/edited) to an LLM: *"In one ≤120-char sentence, summarize what the user worked on in this block."*

### LLM provider (consumer-side, optional)

- Summarization is a **consumer** concern, so the model choice lives in the consumer's own config (`~/.kairos/consumer.toml` or the tool's own): `provider`, `model`, `base_url`, `api_key`. Provider-agnostic (OpenAI-compatible endpoint covers Haiku/Haku/local models).
- With no provider configured, blocks are emitted as pure time totals without descriptions.

## Reproducible deliverables

When a consumer finalizes a timesheet for submission, it (or the operator) creates a **snapshot** first — `kairos snapshot create --from --to --label …` — recording the recipe (params + a watermark per append-only source + digest). The exact same segments *and* the project→client mapping in effect at that moment can be re-derived later for audit, even after the attribution heuristic or the mapping is changed. Client display names resolve live (mutable by design). See [03-data-model.md](./03-data-model.md).

## Output example (from the reference summarizer)

```markdown
# Timesheet — 2026-07-12

## daemonclaw — Client: Acme  (3h 12m)
- 09:00–10:15 (1h 15m, cc) — Built the auth middleware; added JWT refresh endpoint.
- 10:30–11:00 (0h 30m, cc) — Debugged flaky test in the payments service.
- 14:00–14:45 (0h 45m, meeting) — Sync with Acme eng lead on API contract.
- 15:00–16:42 (1h 42m, cc) — Reworked error handling per review feedback.

## swiftcapital — Client: Vault  (1h 05m)
- 11:10–12:15 (1h 05m, cc) — Implemented risk-score aggregation query.
```

## Clocks

All timestamps in the DB and the API are epoch seconds. Transcripts use ISO-8601 (UTC). Consumers convert to the local timezone for display only — the core keeps everything epoch-internal to avoid timezone-display traps.
