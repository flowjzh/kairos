import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import KairosCore
import KairosRPC
import KairosServer
import KairosStore

/// The menu-bar icon as an `NSImage` — a symbol at an explicit point size, so the
/// bar renders it at that intrinsic size (MenuBarExtra ignores SwiftUI `.frame`).
private func menuBarIcon(afk: Bool) -> NSImage {
    let name = afk ? "moon.zzz.fill" : "clock.fill"
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "Kairos")?
        .withSymbolConfiguration(config) ?? NSImage()
    image.isTemplate = true
    return image
}

/// Floor an epoch-seconds timestamp to the whole minute (drops sub-minute
/// residue, e.g. the stale seconds a minute-granularity `DatePicker` carries).
private func floorToMinute(_ ts: Double) -> Double { floor(ts / 60) * 60 }

@main
struct KairosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model, onDashboard: { appDelegate.showDashboard() })
        } label: {
            Image(nsImage: menuBarIcon(afk: appDelegate.model.isAfk))
        }
        .menuBarExtraStyle(.window)
        Window("New Activity", id: "activity") {
            ActivityView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        Window("Configure", id: "configure") {
            ConfigView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: DaemonModel
    private let paths: KairosPaths
    private var socketServer: SocketServer?
    private var sampler: IdleSamplerController?
    private var checkpointTimer: Timer?
    private var notificationDelegate: NotificationDelegate?
    private var dashboard: DashboardWindowController?

    override init() {
        // One indirection point for socket/spool (runtime) + db (data). Runtime
        // is env-driven ($KAIROS_RUNTIME_DIR) so the non-bundle CLI/hook can
        // target the same socket; the data dir is baked into this app's bundle
        // (the KairosDataDir Info.plist key — the dev app sets it at build).
        // No dev/release branch in code.
        let paths = KairosPaths(
            env: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            dataDir: Bundle.main.object(forInfoDictionaryKey: "KairosDataDir") as? String
        )
        self.paths = paths
        try? FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true)
        let store: Store
        do {
            store = try Store(path: paths.dbPath)
            NSLog("kairos: opened disk store at \(paths.dbPath)")
        } catch {
            NSLog("kairos: failed to open store, falling back to in-memory: \(error)")
            store = try! Store(path: ":memory:")
        }
        self.model = DaemonModel(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance per bundle id: if a login-launched copy collides with a
        // manually-opened one (or two opens race), the newcomer exits before it
        // binds the socket. dev/release differ by bundle id, so they still coexist.
        let me = NSRunningApplication.current
        let twin = NSRunningApplication.runningApplications(withBundleIdentifier: me.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me.processIdentifier }
        if twin { NSApp.terminate(nil); return }

        // Register setting defaults before any read (refresh/sampler read
        // AppSettings): UserDefaults returns 0 for an unset key and grace 0 is a
        // valid "off", so the registered default is the only "not yet set" signal.
        AppSettings.register()
        NSApp.setActivationPolicy(.accessory)
        let socketPath = paths.socketPath
        let spoolDir = paths.spoolDir
        let store = model.store
        let dispatcher = model.dispatcher

        Task { @MainActor in
            Notifier.requestAuth()
            let nd = NotificationDelegate()
            UNUserNotificationCenter.current().delegate = nd
            self.notificationDelegate = nd
            _ = await Spooler(spoolDir: spoolDir).drain(dispatcher: dispatcher, store: store)
            self.socketServer = SocketServer(dispatcher: dispatcher, store: store)
            do {
                try self.socketServer?.start(at: socketPath)
            } catch {
                NSLog("kairos: socket server failed: \(error)")
            }
            await self.model.refresh()
            // Restart self-check: a focused manual activity lost its in-memory
            // afk_immune on relaunch. Prompt to re-confirm (re-establishing the
            // flag) or stop it BEFORE the idle sampler starts — so no afk is
            // logged during the prompt (no spurious holes, no over-count).
            if let rec = await self.model.focusedManualActivity() {
                let choice = self.promptResumeFocused(rec)
                if choice.continueTracking {
                    await self.model.setAfkImmune(rec.id, choice.afkOff)
                } else {
                    await self.model.stopActivity(rec.id)
                }
                await self.model.refresh()
            }
            self.sampler = IdleSamplerController(store: store, sessions: model.sessions)
            await self.sampler?.start()
            self.model.startRefresh()

            let mode = (try? await store.journalMode()) ?? "?"
            let wm = (try? await store.eventsWatermark()) ?? -1
            NSLog("kairos: store ready mode=\(mode) events=\(wm)")

            // Periodically fold the WAL into the main DB so writes survive an
            // abrupt daemon exit (launchd restart, reboot). Bounds worst-case
            // loss to one interval; graceful shutdown checkpoints immediately.
            let timer = Timer(timeInterval: 10, repeats: true) { _ in
                Task {
                    do { try await store.checkpoint() }
                    catch { NSLog("kairos: checkpoint failed: \(error)") }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.checkpointTimer = timer
        }
    }

    /// A menu-bar accessory app must keep running with no windows open. A raw
    /// NSWindow (the Dashboard) closing would otherwise terminate the app after
    /// the "last window" closes; SwiftUI Window scenes suppress this, raw ones
    /// don't, so say so explicitly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Kairos Dock icon (the app stays `.regular` while the Dashboard
    /// has been opened, so the icon persists) reopens the Dashboard — like
    /// cc-switch's main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampler?.stop()
        socketServer?.stop()
        checkpointTimer?.invalidate()
        // Best-effort final checkpoint on graceful shutdown (SIGTERM).
        let store = model.store
        let done = DispatchSemaphore(value: 0)
        Task.detached { try? await store.checkpoint(); done.signal() }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Show the Dashboard window (creating it on first open). It's a plain
    /// `NSWindow` that is destroyed on close (`isReleasedWhenClosed`) and rebuilt
    /// fresh on the next open — mirroring the Tauri/wry destroy+rebuild pattern
    /// (e.g. cc-switch's Lightweight Mode). That releases the WKWebView and its
    /// Web Content process on close, and a fresh webview renders cleanly on
    /// reopen (a SwiftUI `Window` keeps its scene alive, which neither releases
    /// the process nor reliably re-renders).
    func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        if dashboard == nil { dashboard = DashboardWindowController(model: model) }
        dashboard?.show()
    }

    /// Restart self-check prompt for a focused manual activity. The user re-decides
    /// whether to keep tracking it (afk_immune is in-memory and was lost on
    /// relaunch) and whether AFK detection stays off. Accessory app, so activate
    /// first or the sheet won't come to the front.
    @MainActor
    private func promptResumeFocused(_ record: ActivityRecord) -> (continueTracking: Bool, afkOff: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Manual activity still in focus", comment: "")
        let name = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.displayName
        alert.informativeText = String(
            format: NSLocalizedString("Kairos restarted. Continue tracking this activity: %@", comment: ""), name)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Stop", comment: ""))
        let afkOff = NSButton(checkboxWithTitle: NSLocalizedString("AFK detection off", comment: ""), target: nil, action: nil)
        alert.accessoryView = afkOff
        let continueTracking = alert.runModal() == .alertFirstButtonReturn
        return (continueTracking, afkOff.state == .on)
    }
}

@MainActor
@Observable
final class DaemonModel {
    let store: Store
    let sessions: SessionRegistry
    let dispatcher: Dispatcher
    /// In-process reducer for the Dashboard window (direct Store reads, memoized).
    let report: ReportBridge
    private(set) var menuLabel = "Kairos"
    private(set) var isPaused = false
    private(set) var isAfk = false
    private(set) var focusedId: Int64?
    /// An auto activity in its blur-grace window (light-green dot): a recent
    /// blur to void no focus has followed yet. Refocus within grace absorbs the
    /// blur; otherwise it stands once grace expires (ADR 39).
    private(set) var gracePending: Grace.Pending?
    private(set) var ongoingActivities: [ActivityRecord] = []
    private(set) var upcomingActivities: [ScheduledActivity] = []
    private(set) var manualTasks: [ActivityRecord] = []
    private(set) var clients: [Client] = []
    private(set) var mappings: [ProjectMapping] = []
    private(set) var projects: [String] = []
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// One-shot timer that re-renders exactly when an active grace expires —
    /// the light-green→gray flip is time-driven (no store write at expiry), so
    /// the event-driven refresh alone would leave a stale "refocus counts" cue.
    private var graceTimer: Timer?
    private var armedGraceExpiry: Double?
    /// Focus at the previous refresh — to detect a scheduled activity taking
    /// over the pointer as its start time arrives (issue 2).
    private var previousFocusedId: Int64?
    /// Max id of any `focus` event seen last refresh — if focus moved but no new
    /// focus event was written, the move is time-driven (a scheduled start
    /// crossing), not a user/click or auto-catch (both write a focus).
    private var lastFocusEventId: Int64 = 0
    private let notify: @Sendable (NotificationContent) -> Void

    init(store: Store, notify: @escaping @Sendable (NotificationContent) -> Void = Notifier.deliver) {
        self.store = store
        let sessions = SessionRegistry()
        self.sessions = sessions
        self.notify = notify
        self.dispatcher = Dispatcher(sessions: sessions, notify: Notifier.deliver)
        self.report = ReportBridge(store: store)
    }

    func startRefresh() {
        // Refresh on every store write (event-driven), replacing a full-table
        // poll. A short debounce coalesces the burst a single action emits
        // (e.g. open + override). A low-frequency safety tick still catches
        // spans that become "open past now" (afk/pause) with no fresh write.
        refreshTask = Task { @MainActor [weak self] in
            guard let stream = await self?.store.changes() else { return }
            for await _ in stream {
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms debounce
                await self?.refresh()
            }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Arm/cancel the one-shot grace-expiry timer. Re-armed only when the expiry
    /// changes, so the 30s safety tick doesn't churn it while a grace is steady.
    private func armGraceTimer(pending: Grace.Pending?, now: Double) {
        let expiry = pending.map { $0.blurTs + AppSettings.grace }
        guard expiry != armedGraceExpiry else { return }
        graceTimer?.invalidate()
        armedGraceExpiry = expiry
        guard let expiry else { return }
        let timer = Timer(timeInterval: max(0, expiry - now), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        graceTimer = timer
    }

    /// The menu dot color for an activity, via the shared `ActivityStatus`
    /// classifier (the same one `activities.status` uses). `now` is read live so
    /// a grace that elapses between refreshes still resolves correctly on the
    /// next render; the grace/expiry timers exist to force that render.
    func dotColor(_ id: Int64) -> Color {
        switch ActivityStatus.derive(focused: focusedId, pending: gracePending, id: id, now: Date().timeIntervalSince1970, grace: AppSettings.grace) {
        case .focused: return .green
        case .gracing: return .green.opacity(0.4)
        case .idle: return .gray
        }
    }

    func refresh() async {
        let now = Date().timeIntervalSince1970
        let events = (try? await store.loadGlobalEvents(since: now - Store.liveWindow)) ?? []
        let visible = (try? await store.visibleActivities()) ?? []
        // Manuals never get grace; the menu shows only visible activities, so the
        // visible-manual set is the right gate here (billing excludes all manuals).
        let manualIds = Set(visible.filter(\.manual).map(\.id))
        // One absorbed view feeds the pointer, placement, and the grace-pending
        // cue — so the menu can't drift from billing.
        let view = Grace.absorbedView(events: events, grace: AppSettings.grace, manualIds: manualIds)
        let state = GlobalState.reduce(events: view, to: now)
        let focused = state.focused
        let pending = Grace.pending(events: view, to: now, grace: AppSettings.grace, manualIds: manualIds)

        isPaused = state.isPaused
        isAfk = state.isAfk
        focusedId = focused
        gracePending = pending
        armGraceTimer(pending: pending, now: now)

        if isAfk {
            menuLabel = NSLocalizedString("Idle", comment: "")
        } else if isPaused {
            menuLabel = NSLocalizedString("Paused", comment: "")
        } else if let focused, let record = try? await store.loadActivity(id: focused) {
            menuLabel = record.title ?? record.project ?? record.source
        } else {
            menuLabel = "Kairos"
        }

        // Placement is fully derived from the focus/blur log (ADR 37): one visible
        // list split into Ongoing / Upcoming / Recent. `state` is just visibility.
        let (ongoing, upcoming, recent) = ActivityBuckets.partition(
            visible: visible,
            events: view,
            now: now
        )
        ongoingActivities = ongoing
        upcomingActivities = upcoming
        manualTasks = recent
        clients = (try? await store.listClients()) ?? []
        mappings = (try? await store.listMapping()) ?? []
        projects = (try? await store.listProjects()) ?? []

        // A scheduled activity's start crossing `now` makes the reducer hand it
        // the pointer with NO new event written. Detect that — focus moved to a
        // different activity, yet no focus event arrived since last refresh — and
        // tell the user we auto-switched to the planned task (issue 2).
        let maxFocusId = events.lazy.filter { $0.kind == .focus }.map(\.id).max() ?? 0
        if let focused, let prev = previousFocusedId, focused != prev, maxFocusId == lastFocusEventId {
            // The just-started activity is in `ongoing` by construction; fall back
            // to a generic label rather than a store round-trip.
            let title = ongoing.first { $0.id == focused }?.title ?? NSLocalizedString("an activity", comment: "")
            notify(NotificationContent(title: "Kairos", message: String(format: NSLocalizedString("Scheduled activity \"%@\" started — switched focus to it.", comment: ""), title)))
        }
        previousFocusedId = focused
        lastFocusEventId = maxFocusId
    }

    func togglePause() async {
        let now = Date().timeIntervalSince1970
        _ = try? await store.appendEvent(activityId: nil, kind: !isPaused ? .pauseOn : .pauseOff, ts: now)
        await refresh()
    }

    func addClient(_ name: String) async {
        guard !name.isEmpty else { return }
        _ = try? await store.addClient(name: name)
        await refresh()
    }

    func renameClient(_ id: Int64, _ name: String) async {
        try? await store.renameClient(id: id, name: name)
        await refresh()
    }

    func setMapping(project: String, client: Int64?, billable: Bool) async {
        guard !project.isEmpty else { return }
        try? await store.setMapping(project: project, clientId: client, billable: billable)
        await refresh()
    }

    /// Start (or reactivate) a manual activity: create-or-resume the row, write a
    /// `focus` at `start` (and a `blur` at `end` if timed). It is `visible`;
    /// placement (Upcoming/Ongoing/Recent) is derived from the events (ADR 37).
    func startManualActivity(source: String, externalId: String?, title: String, project: String?, clientId: Int64?, afkImmune: Bool, start: Double, end: Double?) async {
        guard let id = try? await store.startActivity(source: source, externalId: externalId, project: project, title: title.isEmpty ? nil : title, metadata: nil) else { return }
        await sessions.setAfkImmune(id, afkImmune)
        if let clientId {
            let payload = try? Wire.data(OverridePayload(clientId: clientId, billable: nil))
            try? await store.appendActivityEvent(activityId: id, kind: .activityOverride, ts: start, payload: payload)
        }
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: start)
        if let end { try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: end) }
        try? await store.setActivityState(activityId: id, .visible)
        await refresh()
    }

    /// Reactivate a Recent manual activity by its id: focus it now (it's already
    /// visible; placement becomes Ongoing). `afkImmune` is a launch-time option —
    /// afk_immune is in-memory, not persisted.
    func reactivate(_ id: Int64, afkImmune: Bool = false) async {
        try? await store.setActivityState(activityId: id, .visible)
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: Date().timeIntervalSince1970)
        await sessions.setAfkImmune(id, afkImmune)
        await refresh()
    }

    /// After a restart, a focused manual activity has lost its in-memory
    /// afk_immune. Returns it so the host can prompt to re-confirm or stop it;
    /// nil when no manual activity holds focus.
    func focusedManualActivity() async -> ActivityRecord? {
        guard let id = focusedId,
              let manuals = try? await store.manualActivityIds(),
              manuals.contains(id) else { return nil }
        if let rec = ongoingActivities.first(where: { $0.id == id }) { return rec }
        return try? await store.loadActivity(id: id)
    }

    func setAfkImmune(_ id: Int64, _ on: Bool) async {
        await sessions.setAfkImmune(id, on)
    }

    /// Manual focus switch (green-dot activity), a `focus` event.
    func focusActivity(_ id: Int64) async {
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: Date().timeIntervalSince1970)
        await refresh()
    }

    /// Stop (menu ✕): a `blur@now` ends it → derived Recent (still visible,
    /// resumable). No `state` change — visibility is unaffected.
    func stopActivity(_ id: Int64) async {
        try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: Date().timeIntervalSince1970)
        await sessions.setAfkImmune(id, false)
        await refresh()
    }

    /// Cancel an upcoming (not-yet-started) activity: neutralise its scheduled
    /// `focus` with a `blur` at the same instant (ordered after it, so it never
    /// lights up) and archive the row so it leaves every list.
    func cancelUpcoming(_ id: Int64, start: Double) async {
        try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: start)
        try? await store.setActivityState(activityId: id, .archived)
        await sessions.setAfkImmune(id, false)
        await refresh()
    }

    /// Archive a manual activity: `blur` (no-op if not focused) + state=archived
    /// — hidden from every list.
    func archiveActivity(_ id: Int64) async {
        try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: Date().timeIntervalSince1970)
        try? await store.setActivityState(activityId: id, .archived)
        await sessions.setAfkImmune(id, false)
        await refresh()
    }
}

/// A concrete `NSVisualEffectView` background so the main menu and the flyout
/// popover use the *same* material (SwiftUI's `Material` can't name the menu
/// material, so the two windows would otherwise blend differently).
private struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// A menu row with a native-feeling hover highlight (the `.window` MenuBarExtra
/// style doesn't highlight rows on its own).
private struct HoverRow<Content: View>: View {
    var onHover: ((Bool) -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { h in hovering = h; onHover?(h) }
            .padding(.horizontal, 5)
    }
}

private struct MenuContent: View {
    let model: DaemonModel
    let onDashboard: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var flyout: Int64?   // the Recent task whose submenu is open

    // Every row reserves this leading column so all text starts at the same x.
    private let iconColumn: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.ongoingActivities.isEmpty {
                sectionLabel("Ongoing Activities")
                ForEach(model.ongoingActivities, id: \.id) { a in
                    HoverRow(onHover: { if $0 { flyout = nil } }) {
                        HStack(spacing: 8) {
                            // Left dot: green = focused, light green = in blur
                            // grace (refocus to count the gap as focus), gray =
                            // not. Click to focus this activity — move the single
                            // pointer here. (No un-focus: the pointer moves by
                            // focusing another, or a manual one is removed with ✕.)
                            Button { Task { await model.focusActivity(a.id) } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(model.dotColor(a.id))
                                        .frame(width: iconColumn)
                                    Text(rowLabel(a)).lineLimit(1)
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Manual activities are stopped with ✕; auto ones
                            // (pty/claude) appear and leave on their own → "auto".
                            if a.manual {
                                Button { Task { await model.stopActivity(a.id) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop")
                            } else {
                                Text("auto").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 3)
            }

            if !model.upcomingActivities.isEmpty {
                sectionLabel("Upcoming Activities")
                ForEach(model.upcomingActivities) { u in
                    HoverRow(onHover: { if $0 { flyout = nil } }) {
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .frame(width: iconColumn)
                                Text(u.record.title ?? NSLocalizedString("Activity", comment: "")).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(scheduleLabel(u.start)).font(.caption).foregroundStyle(.tertiary)
                            }
                            Button { Task { await model.cancelUpcoming(u.id, start: u.start) } } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel")
                        }
                    }
                }
                Divider().padding(.vertical, 3)
            }

            if !model.manualTasks.isEmpty {
                sectionLabel("Recent Activities")
                ForEach(model.manualTasks, id: \.id) { t in
                    HoverRow(onHover: { if $0 { flyout = t.id } }) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: iconColumn)
                            Text(t.title ?? NSLocalizedString("Activity", comment: "")).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .popover(isPresented: flyoutBinding(t.id), arrowEdge: .trailing) {
                        flyoutMenu(t)
                    }
                }
                Divider().padding(.vertical, 3)
            }

            actionRow("New Activity…", "plus") { open("activity") }
            actionRow("Dashboard…", "chart.xyaxis.line") { onDashboard() }
            actionRow("Configure…", "gearshape") { open("configure") }
            actionRow(model.isPaused ? "Resume" : "Pause", model.isPaused ? "play.fill" : "pause.fill") {
                Task { await model.togglePause() }
            }
            Divider().padding(.vertical, 3)
            actionRow("Quit Kairos", "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
        .background(VisualEffect())
    }

    // The right-flyout submenu for a Recent task — a plain view (not a native
    // menu) so icons render and the material/position match the main menu.
    @ViewBuilder private func flyoutMenu(_ t: ActivityRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            flyoutRow("Resume", "arrowtriangle.right.fill") {
                flyout = nil; Task { await model.reactivate(t.id) }
            }
            flyoutRow("Resume", suffix: "(no AFK)", "arrowtriangle.right.fill") {
                flyout = nil; Task { await model.reactivate(t.id, afkImmune: true) }
            }
            flyoutRow("Archive", "arrow.down.to.line") {
                flyout = nil; Task { await model.archiveActivity(t.id) }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 155)
        .presentationBackground { VisualEffect() }
    }

    /// A flyout row. `suffix` (e.g. "(no AFK)" on the AFK-off Resume) renders as a
    /// small muted tag after the title; nil for plain rows.
    private func flyoutRow(_ title: LocalizedStringKey, suffix: LocalizedStringKey? = nil, _ icon: String, _ action: @escaping () -> Void) -> some View {
        HoverRow {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: iconColumn)
                    Text(title)
                    if let suffix { Text(suffix).font(.caption).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func flyoutBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { flyout == id }, set: { if !$0 && flyout == id { flyout = nil } })
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 1)
    }

    /// An upcoming activity's start: just the time if today, else short date + time.
    private func scheduleLabel(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date)
            ? time
            : date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }

    private func actionRow(_ title: LocalizedStringKey, _ icon: String, _ action: @escaping () -> Void) -> some View {
        HoverRow(onHover: { if $0 { flyout = nil } }) {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: icon).frame(width: iconColumn)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Row label: manual activities show their title. Auto activities show the
    /// title alone when set (a user-named session needs no source prefix);
    /// otherwise `<source display name> - <project>` (e.g. a bare `pty` `ssh
    /// beth` → "Terminal - ssh beth").
    private func rowLabel(_ a: ActivityRecord) -> String {
        if a.manual { return a.title ?? a.project ?? NSLocalizedString("Activity", comment: "") }
        if let title = a.title, !title.isEmpty { return title }
        if let suffix = a.project, !suffix.isEmpty { return "\(a.displayName) - \(suffix)" }
        return a.displayName
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

struct ActivityView: View {
    let model: DaemonModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var newTitle = ""
    @State private var newProject: String?
    @State private var newClient: Int64?
    @State private var afkImmune = false
    @State private var start = Date()
    @State private var ongoing = true
    @State private var end = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $newTitle)
            Picker("Project", selection: $newProject) {
                Text("None").tag(String?.none)
                ForEach(model.projects, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Client", selection: $newClient) {
                Text("None").tag(Int64?.none)
                ForEach(model.clients, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
            }
            DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
            Toggle("Ongoing", isOn: $ongoing)
            if !ongoing {
                DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
            }
            Divider()
            // A launch option, not content — AFK detection off while this task is focused.
            Toggle("AFK detection off", isOn: $afkImmune)
            HStack {
                Spacer()
                Button("Start") {
                    let title = newTitle
                    let project = newProject
                    let client = newClient
                    let immune = afkImmune
                    // The Start/End pickers expose only date + hour:minute, so their
                    // seconds are stale residue from the picker's initial `Date()`.
                    // Floor at this input boundary so the recorded start is minute-aligned.
                    let startTs = floorToMinute(start.timeIntervalSince1970)
                    let endTs = ongoing ? nil : floorToMinute(end.timeIntervalSince1970)
                    Task { await model.startManualActivity(source: "manual", externalId: nil, title: title, project: project, clientId: client, afkImmune: immune, start: startTs, end: endTs) }
                    newTitle = ""; newProject = nil; newClient = nil; afkImmune = false
                    ongoing = true; start = Date(); end = Date()
                    dismissWindow(id: "activity")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTitle.isEmpty || (!ongoing && end <= start))
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { start = Date(); end = Date() }
        .task { await model.refresh() }
    }
}

/// The app's "Launch at login" state via `SMAppService.mainApp` — the app itself
/// as a login item. Registering fills the system's "Open at Login" / "Allow in the
/// Background" entry; unregistering removes it cleanly (a bundled agent would also
/// leave a parent *app* entry behind that `unregister()` can't reach).
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    static var isEnabled: Bool { service.status == .enabled }

    /// Register / unregister the app as a login item. Returns nil on success, else
    /// a short message to show — surfacing it beats a silent no-op when macOS wants
    /// the user to approve the item.
    static func setEnabled(_ on: Bool) -> String? {
        do {
            try on ? service.register() : service.unregister()
            if on, service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return NSLocalizedString("Approve Kairos under Login Items to finish enabling.", comment: "")
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The `kairos` CLI shipped inside the bundle (`Contents/MacOS/kairos-cli`),
/// exposed on PATH via a symlink the user opts into. `/usr/local/bin` is on the
/// default PATH, so the command works in every shell once linked; creating the
/// symlink there needs root, hence the one AppleScript admin prompt.
enum CLITool {
    static let linkPath = "/usr/local/bin/kairos"
    static var bundledPath: String { Bundle.main.bundlePath + "/Contents/MacOS/kairos-cli" }

    /// Installed iff the symlink resolves to THIS bundle's binary — so the dev and
    /// release apps each report only their own link, and a brew/other `kairos` reads
    /// false (leaving it untouched).
    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledPath
    }

    @MainActor static func install() -> String? {
        run("mkdir -p /usr/local/bin && ln -sf \(shq(bundledPath)) \(shq(linkPath))")
    }
    @MainActor static func uninstall() -> String? { run("rm -f \(shq(linkPath))") }

    /// Run a shell command with one admin prompt (SecurityAgent draws it). Returns
    /// nil on success, else the error message. The prompt steals foreground from this
    /// accessory app, so re-activate once it returns — repairs focus for both callers.
    @MainActor private static func run(_ shell: String) -> String? {
        // Two nested layers to escape: the shell command sits inside an AppleScript
        // string literal. `shell` is our own literal (no metachars); only the
        // interpolated paths are quoted (via `sh`), so a path with `'` or `"` — a
        // renamed .app under an apostrophe'd home — still links correctly.
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        NSApp.activate(ignoringOtherApps: true)
        return err?[NSAppleScript.errorMessage] as? String
    }

    /// Single-quote a path for `sh`, escaping any embedded `'` as `'\''`.
    private static func shq(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum ConfigSection: String, CaseIterable, Identifiable {
    case general, clients, projects, plugins
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .clients: "Clients"
        case .projects: "Projects"
        case .plugins: "Plugins"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .clients: "person.2"
        case .projects: "folder"
        case .plugins: "puzzlepiece.extension"
        }
    }
}

struct ConfigView: View {
    let model: DaemonModel
    @State private var section: ConfigSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(ConfigSection.allCases) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 12) }
            .frame(width: 180)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { await model.refresh() }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .general {
        case .general: GeneralPane()
        case .clients: ClientsPane(model: model)
        case .projects: ProjectsPane(model: model)
        case .plugins: PluginsPane()
        }
    }
}

private struct GeneralPane: View {
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var status: String?
    @AppStorage(AppSettings.graceKey) private var grace = AppSettings.defaultGrace
    @AppStorage(AppSettings.idleThresholdKey) private var idleThreshold = AppSettings.defaultIdleThreshold
    @State private var language = AppSettings.effectiveLanguage
    @State private var cliInstalled = CLITool.isInstalled
    @State private var cliStatus: String?

    var body: some View {
        Form {
            Section("Startup") {
                // A custom binding (not `.onChange`) so re-reading the real state
                // back into `launchAtLogin` can't re-fire the setter into a loop.
                Toggle("Launch Kairos at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        status = LoginItem.setEnabled(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Command-Line Tool") {
                HStack {
                    Text(cliInstalled
                         ? "The `kairos` command is installed in /usr/local/bin."
                         : "Install the `kairos` command to use it in any shell.")
                    Spacer()
                    Button(cliInstalled ? "Uninstall" : "Install") {
                        cliStatus = cliInstalled ? CLITool.uninstall() : CLITool.install()
                        cliInstalled = CLITool.isInstalled
                    }
                }
                if let cliStatus { Text(cliStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Timer") {
                TimerRow(
                    title: "Blur Grace",
                    explanation: "Count a brief blur as focus only if you return to the same auto activity within this many seconds — and nothing else is focused in between.",
                    value: $grace, range: 0...600, step: 15)
                TimerRow(
                    title: "Idle Threshold",
                    explanation: "Mark the session idle after this many seconds with no keyboard or mouse activity.",
                    value: $idleThreshold, range: 15...600, step: 15)
            }
            Section("Language") {
                // Native i18n: the Picker writes `AppleLanguages` (the single source —
                // persisted across restarts); Bundle.main only re-resolves on the next
                // launch, so `language` diverges from the launch snapshot until then.
                Picker("Language", selection: $language) {
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                }
                .onChange(of: language) { _, new in
                    UserDefaults.standard.set([new], forKey: "AppleLanguages")
                }
                if language != AppSettings.launchLanguage {
                    Text("Changes apply on next launch.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The Plugins pane. Kairos integrates with Claude Code as a plugin: the app
/// registers its bundled local marketplace with Claude Code, and the user installs
/// the plugin with `claude plugin`. Gated on a detected Claude Code CLI.
private struct PluginsPane: View {
    // Detection (`claude` path, possibly via a login-shell subprocess) and the
    // settings.json read are loaded off the main thread in `.task` rather than in
    // the @State default, so a slow shell probe can't stall the window and neither
    // re-runs on every body re-render.
    @State private var claudePath: String?
    @State private var registered = false
    @State private var status: String?

    private static let installURL = URL(string: "https://code.claude.com/docs")!

    var body: some View {
        Form {
            Section("Claude Code") {
                if let claudePath {
                    registeredControls
                    if registered {
                        installInstructions
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                } else {
                    notInstalledRow
                }
            }
        }
        .formStyle(.grouped)
        .task {
            claudePath = await Task.detached { ClaudeCode.detect() }.value
            registered = ClaudeMarketplace.isRegistered
        }
    }

    private var notInstalledRow: some View {
        HStack {
            Text("Claude Code isn't installed. Install it, then reopen this window.")
            Spacer()
            Link("Install", destination: Self.installURL)
        }
    }

    private var registeredControls: some View {
        HStack {
            Text(registered
                 ? "The Kairos marketplace is registered with Claude Code."
                 : "Register the Kairos marketplace, then install the plugin below.")
            Spacer()
            Button(registered ? "Unregister" : "Register") {
                status = registered ? ClaudeMarketplace.unregister() : ClaudeMarketplace.register()
                registered = ClaudeMarketplace.isRegistered
            }
        }
    }

    private var installInstructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install the plugin (pick a scope):")
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "claude plugin install \(ClaudeMarketplace.pluginRef) --scope user")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("Scope: `user` (all projects), `project` (shared), or `local` (just you). Update or remove it later with `claude plugin update` / `uninstall`.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A tunable-number form row: the title and a small secondary explanation sit on
/// the left, the editable value, its unit, and a stepper sit right-aligned. Typed
/// values are clamped (rounded) into `range` so a stray entry can't escape bounds.
private struct TimerRow: View {
    let title: LocalizedStringKey
    let explanation: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max(range.lowerBound, $0.rounded()), range.upperBound) })
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // Labelless: a titled TextField would have its title hoisted into the
            // form's label column (a stray middle column) alongside the VStack.
            TextField(value: clamped, format: .number) { }
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityLabel(title)
            Stepper(value: $value, in: range, step: step) { }
                .labelsHidden()
        }
    }
}

private struct ClientsPane: View {
    let model: DaemonModel
    @State private var addClientName = ""

    var body: some View {
        Form {
            Section("Clients") {
                if model.clients.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.clients, id: \.id) { client in
                    HStack {
                        Image(systemName: "person.crop.square")
                        Text(client.name)
                        Spacer()
                        Text("\(client.id)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("New client", text: $addClientName)
                    Button("Add") {
                        let name = addClientName
                        Task { await model.addClient(name) }
                        addClientName = ""
                    }
                    .disabled(addClientName.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProjectsPane: View {
    let model: DaemonModel
    @State private var mapProject: String?
    @State private var mapClient: Int64?
    @State private var mapBillable = true

    var body: some View {
        let bound = model.mappings.filter { $0.clientId != nil }
        let boundSet = Set(bound.map(\.project))
        let available = model.projects.filter { !boundSet.contains($0) }
        Form {
            Section("Project → Client") {
                if bound.isEmpty {
                    Text("No client bindings yet — pick a project below to assign one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bound, id: \.project) { mapping in
                    HStack {
                        Text(mapping.project)
                        Spacer()
                        Text(model.clients.first(where: { $0.id == mapping.clientId })?.name ?? "—")
                        if !mapping.billable { Text("non-bill").font(.caption).foregroundStyle(.secondary) }
                        Button("Unbind") { Task { await model.setMapping(project: mapping.project, client: nil, billable: true) } }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("Project", selection: $mapProject) {
                        Text("Select…").tag(String?.none)
                        ForEach(available, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("Client", selection: $mapClient) {
                        Text("None").tag(Int64?.none)
                        ForEach(model.clients, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    Toggle("Billable", isOn: $mapBillable)
                    Button("Set") {
                        guard let project = mapProject else { return }
                        let client = mapClient
                        let billable = mapBillable
                        Task { await model.setMapping(project: project, client: client, billable: billable) }
                        mapProject = nil; mapClient = nil; mapBillable = true
                    }
                    .disabled(mapProject == nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Posts native macOS notifications behind the `Dispatcher.notify` seam
/// (`KairosServer` stays UI-free; this is the delivery side). Authorization is
/// requested once at launch; if the user denies it, `post` is a silent no-op
/// (the `NSLog` keeps a trace).
enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, subtitle: String?, body: String) {
        NSLog("kairos: notify — %@", title)
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    /// The `(NotificationContent) -> Void` seam shared by `DaemonModel` and
    /// `Dispatcher` — one definition so the two inits can't drift.
    static let deliver: @Sendable (NotificationContent) -> Void = { c in
        post(title: c.title, subtitle: c.subtitle, body: c.message)
    }
}

/// Shows banners even while the daemon's process is frontmost (e.g. its menu
/// popover is open). Held strongly by `AppDelegate` (the center keeps a weak ref).
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
