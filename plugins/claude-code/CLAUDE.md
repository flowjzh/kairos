# CLAUDE.md — claude-code plugin

The Claude Code hook binary (`bin/kairos-claude-code`). It reads the hook JSON on
stdin, maps it to a Kairos RPC, and sends it over the daemon socket. The socket
is resolved from `$KAIROS_RUNTIME_DIR` (else `~/.kairos`), so the hook routes to
whichever daemon the session's env points at — this is how a dev session reaches
the dev daemon (see the repo README "Dev vs release").

## After changing plugin code: rebuild AND refresh Claude's cache

Claude runs a **copy** of the binary from its own plugin cache
(`~/.claude/plugins/cache/kairos/kairos-claude-code/<version>/bin/`), not the
binary in this repo. `/reload-plugins` reloads hook/agent wiring but does **not**
recompile or re-copy the binary — so a stale cached binary keeps running old code
(e.g. ignoring `KAIROS_RUNTIME_DIR` and routing to the wrong daemon).

After editing the Rust source, refresh both:

```sh
make plugin                                   # rebuild + stage bin/kairos-claude-code
```
then, inside Claude Code:
```
/plugin install kairos-claude-code@kairos     # re-copies the fresh binary into the cache
```

`make plugin` alone is not enough — it only updates this repo's `bin/`. Skipping
the `/plugin install` step leaves the cached copy stale.
