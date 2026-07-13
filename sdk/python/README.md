# kairos-sdk (Python)

A thin, dependency-free Python client for the Kairos daemon. It speaks the
line-JSON RPC over the Unix domain socket (`~/.kairos/daemon.sock`): open the
socket, write one request line, read one response line, close. A single
`segments.get` round-trip returns every segment in the range — there is no
pagination.

## Install

```bash
uv sync                      # from sdk/python/, sets up a dev env with the package
# or, into another project:
uv add --editable /path/to/kairos/sdk/python
```

## Use

```python
from kairos_sdk import Kairos

kairos = Kairos()                                  # ~/.kairos/daemon.sock
segments = kairos.segments(from_ts, to_ts,         # epoch seconds
                           project='kairos',        # optional slug filter
                           client=1)                # optional client id filter
for s in segments:
    a = s.activity                                 # joined; client/billable resolved
    print(s.seconds, a.project, a.transcript_path)
```

`segments(start, end, project=None, client=None)` returns `list[Segment]`,
ordered by `start`. Each `Segment` carries the afk/pause-subtracted human time
in `seconds` (the effort measure — do not recompute it from `end - start`) and a
joined `Activity` with `source`, `project`, `title`, resolved `client`,
`billable`, and `metadata` (including `transcript_path` for AI sessions).

A daemon-returned error or an unreachable socket raises `KairosError`.

## Test

```bash
uv run pytest
```

`parse_segments_result` is pure (no socket) and tested directly; the client's
socket framing is tested against a one-shot in-process Unix server.
