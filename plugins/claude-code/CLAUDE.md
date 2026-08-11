# CLAUDE.md — claude-code plugin

The Claude Code hook binary (`kairos-claude-code`). It reads the hook JSON on
stdin, maps it to a Kairos RPC, and sends it over the daemon socket. The socket
is resolved from `$KAIROS_RUNTIME_DIR` (else `~/.kairos`), so the hook routes to
whichever daemon the session's env points at — this is how a dev session reaches
the dev daemon (see CONTRIBUTING "Dev vs release isolation").

This directory is **self-contained**: `.claude-plugin/marketplace.json` names one
plugin with `source: "."`, so the dir is both the marketplace and the plugin.
`hooks/hooks.json` calls the binary directly (`${CLAUDE_PLUGIN_ROOT}/bin/…`), no
shell shim. `make app`/`make app-dev` bundle this tree (with the freshly built
binary) into the app under `Contents/Resources/plugins/claude-code/`. The release
app registers it as the `kairos` marketplace; the dev app stamps it to `kairos-dev`
so the two never collide in `~/.claude/settings.json`.

The binary has two modes, dispatched by argv[1]: the hook forwarder (no arg, as
`hooks.json` invokes it) and `kairos-claude-code statusline` — the CC status line
command, which reads `session_id` from stdin, queries `activities.status`, and
renders one colored line via the shared `kairos-statusline` crate. `hooks.json`
registers only the hook mode; the statusline mode is wired by the user's
`statusLine.command` setting (see docs/07-clients.md).

## Dev loop: rebuild the app AND refresh Claude's cache

Claude runs a **copy** of the binary from its own plugin cache
(`~/.claude/plugins/cache/kairos-dev/kairos-claude-code/<version>/bin/`), not the
one in the app bundle. `/reload-plugins` reloads hook wiring but does **not**
re-copy the binary — so a stale cached copy keeps running old code (e.g. ignoring
`KAIROS_RUNTIME_DIR` and routing to the wrong daemon).

First-time dev setup:

```sh
make install-dev                                       # build the dev app (bundles the fresh hook)
claude plugin marketplace add "/Applications/Kairos Dev.app/Contents/Resources/plugins/claude-code"
claude plugin install kairos-claude-code@kairos-dev --scope local
```

After editing the Rust source, rebuild and re-copy into the cache:

```sh
make install-dev                                        # rebuild + reinstall the dev app
claude plugin install kairos-claude-code@kairos-dev     # re-copies the fresh binary into the cache
```

`make install-dev` alone is not enough — it only updates the bundled app; skipping
the re-install leaves Claude's cached copy stale.
