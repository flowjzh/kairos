import Foundation
import KairosClaudeCode
import KairosClient

/// Claude Code hook binary. Reads the hook JSON from stdin, maps it to a Kairos
/// RPC, and sends it over the socket (spooling if the daemon is down). Always
/// exits 0 — a time-tracking hook must never disrupt the editor.
//
// Wired for all four events in the plugin's hooks.json; the event is read from
// the stdin `hook_event_name`, so one command serves them all.

let home = FileManager.default.homeDirectoryForCurrentUser.path
let socketPath = "\(home)/.kairos/daemon.sock"
let spoolDir = "\(home)/.kairos/spool"

let data = FileHandle.standardInput.readDataToEndOfFile()
let kairosSessionId = ProcessInfo.processInfo.environment["KAIROS_SESSION_ID"]
guard let request = ClaudeCodeHook.request(fromJSON: data, kairosSessionId: kairosSessionId, now: Date().timeIntervalSince1970) else {
    exit(0)   // malformed or untracked event — ignore silently
}

let client = SocketClient(socketPath: socketPath, spoolDir: spoolDir)
// Fire-and-forget: spool on failure, swallow everything else.
_ = try? await client.send(request, spoolable: true)
exit(0)
