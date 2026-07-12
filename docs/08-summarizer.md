# 08 — Consumers & Summarizer

**Output is not part of the core.** Kairos's responsibility ends at producing accurate, attributed segments; turning them into a timesheet — per-client formatting, PDF/CSV/Markdown, posting to an invoicing or time-tracking API — is an open-ended integration space that lives in **external consumers**. The core exposes a stable read API and stays out of the formatting business.

## The contract consumers depend on

- The **Python/Node SDK** (primary) — a thin, pure-language wrapper over the line-JSON socket (see [05](./05-protocol.md)). `core.segments(from, to, client=...)` returns computed segments + the `activities` they reference, with `client`/`billable` already **resolved** via the project→client mapping (plus `external_id`, `project`, `metadata.transcript_path`).
- Or `kairos export --format json` (a shell convenience over the same `segments.get`) for quick one-shot dumps.

That is everything a consumer needs from the core: **segment data**. The Swift attribution library is daemon-internal and is **not** exposed via FFI — consumers do not call Swift; they receive JSON segments through the SDK. Transcript slicing, LLM calls, per-client templates, and API delivery all live in the consumer — not in the daemon.

## Reference summarizer (one consumer, not privileged)

Kairos ships a reference consumer as an example — a starting point to copy and specialize per client, not a mandated format.

### Pipeline

```
core.segments(from, to) ──▶ group (by day / project / client — client resolved by the daemon)
              │
              │  for each ai segment block:
              │     1. locate transcript via activity.metadata.transcript_path
              │        (or ~/.claude/projects/*/<external_id>.jsonl)
              │     2. slice transcript entries within [block.start, block.end]   ← app-side file I/O
              │     3. extract user prompts + assistant tool-use/file deltas
              │     4. LLM summarize → one line                                     ← app-side LLM
              ▼
           timesheet.md / .csv / …  (or POST to an external API)
```

### Transcript slicing

- Map an activity's `external_id` (the Claude Code session_id) to its transcript file (the metadata carries `transcript_path`; fallback is `~/.claude/projects/*/<session_id>.jsonl`, whose directory name encodes the cwd).
- For each block, read transcript entries whose `timestamp` ∈ `[block.start, block.end]`.
- Feed the slices (prompt text + which files were read/edited) to an LLM: *"In one ≤120-char sentence, summarize what the user worked on in this block."*

### LLM provider (consumer-side, optional)

- Summarization is a **consumer** concern, so the model choice lives in the consumer's own config (`~/.kairos/consumer.toml` or the tool's own): `provider`, `model`, `base_url`, `api_key`. Provider-agnostic (OpenAI-compatible endpoint covers Haiku/Haku/local models).
- With no provider configured, blocks are emitted as pure time totals without descriptions.

## Reproducible deliverables

When a consumer finalizes a timesheet for submission, it (or the operator) creates a **snapshot** first — `core.snapshots.create(...)` / `kairos snapshot create --from --to --label …` — recording the recipe (params + a watermark per append-only source + digest). It drains the spool first. The exact same segments *and* the project→client mapping in effect at that moment can be re-derived later for audit, even after the attribution heuristic or the mapping is changed. Client display names resolve live (mutable by design). See [03-data-model.md](./03-data-model.md).

## Output example (from the reference summarizer)

```markdown
# Timesheet — 2026-07-12

## daemonclaw — Client: Acme  (3h 12m)
- 09:00–10:15 (1h 15m, ai) — Built the auth middleware; added JWT refresh endpoint.
- 10:30–11:00 (0h 30m, ai) — Debugged flaky test in the payments service.
- 14:00–14:45 (0h 45m, meeting) — Sync with Acme eng lead on API contract.
- 15:00–16:42 (1h 42m, ai) — Reworked error handling per review feedback.

## swiftcapital — Client: Vault  (1h 05m)
- 11:10–12:15 (1h 05m, ai) — Implemented risk-score aggregation query.
```

## Clocks

All timestamps in the DB and the API are epoch seconds. Transcripts use ISO-8601 (UTC). Consumers convert to the local timezone for display only — the core keeps everything epoch-internal to avoid timezone-display traps.
