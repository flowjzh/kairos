import AppKit
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

@main
struct KairosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
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

    override init() {
        // One indirection point for socket/spool (runtime) + db (data), resolved
        // purely from the environment. A separate instance (dev) is just a
        // different `$KAIROS_RUNTIME_DIR`/`$KAIROS_DATA_DIR`, supplied by the
        // build/launch config — never a dev/release branch in code.
        let paths = KairosPaths(
            env: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser.path
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
            self.sampler = IdleSamplerController(store: store, sessions: model.sessions)
            await self.sampler?.start()
            await self.model.refresh()
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
}

@MainActor
@Observable
final class DaemonModel {
    let store: Store
    let sessions: SessionRegistry
    let dispatcher: Dispatcher
    private(set) var menuLabel = "Kairos"
    private(set) var isPaused = false
    private(set) var isAfk = false
    private(set) var focusedId: Int64?
    private(set) var activeActivities: [ActivityRecord] = []
    private(set) var manualTasks: [ActivityRecord] = []
    private(set) var clients: [Client] = []
    private(set) var mappings: [ProjectMapping] = []
    private(set) var projects: [String] = []
    private var kairosSourceId: Int64 = 0
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
        let sessions = SessionRegistry()
        self.sessions = sessions
        self.dispatcher = Dispatcher(sessions: sessions) { c in Notifier.post(title: c.title, subtitle: c.subtitle, body: c.message) }
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

    func refresh() async {
        if kairosSourceId == 0 {
            kairosSourceId = (try? await store.resolveSource(slug: DaemonSources.control)) ?? 0
        }
        let events = (try? await store.loadGlobalEvents()) ?? []
        let state = GlobalState.reduce(events: events, to: Date().timeIntervalSince1970)
        let focused = state.focused

        isPaused = state.isPaused
        isAfk = state.isAfk
        focusedId = focused

        if isAfk {
            menuLabel = "Idle"
        } else if isPaused {
            menuLabel = "Paused"
        } else if let focused, let record = try? await store.loadActivity(id: focused) {
            menuLabel = record.title ?? record.project ?? record.source
        } else {
            menuLabel = "Kairos"
        }

        activeActivities = (try? await store.activeActivities()) ?? []
        manualTasks = (try? await store.recentStoppedManualActivities()) ?? []
        clients = (try? await store.listClients()) ?? []
        mappings = (try? await store.listMapping()) ?? []
        projects = (try? await store.listProjects()) ?? []
    }

    func togglePause() async {
        let now = Date().timeIntervalSince1970
        _ = try? await store.appendEvent(activityId: nil, sourceId: kairosSourceId, kind: !isPaused ? .pauseOn : .pauseOff, ts: now)
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

    /// Start (or reactivate) a manual activity (M4p3): create-or-resume
    /// the row (active) and write a `focus` at `start`. An end time writes a
    /// `blur` and stops it; otherwise it stays the focused/active backdrop.
    func startManualActivity(source: String, externalId: String?, title: String, project: String?, clientId: Int64?, afkImmune: Bool, start: Double, end: Double?) async {
        guard let id = try? await store.startActivity(source: source, externalId: externalId, project: project, title: title.isEmpty ? nil : title, metadata: nil) else { return }
        await sessions.setAfkImmune(id, afkImmune)
        if let clientId {
            let payload = try? Wire.data(OverridePayload(clientId: clientId, billable: nil))
            try? await store.appendActivityEvent(activityId: id, kind: .activityOverride, ts: start, payload: payload)
        }
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: start)
        if let end {
            try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: end)
            try? await store.setActivityState(activityId: id, .stopped)
        }
        await refresh()
    }

    /// Reactivate a stopped manual activity by its id (focus it now).
    func reactivate(_ id: Int64) async {
        try? await store.setActivityState(activityId: id, .active)
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: Date().timeIntervalSince1970)
        await refresh()
    }

    /// Manual focus switch (green-dot activity), a `focus` event.
    func focusActivity(_ id: Int64) async {
        try? await store.appendActivityEvent(activityId: id, kind: .focus, ts: Date().timeIntervalSince1970)
        await refresh()
    }

    /// Stop (menu ✕): `blur` + state=stopped.
    func stopActivity(_ id: Int64) async {
        try? await store.appendActivityEvent(activityId: id, kind: .blur, ts: Date().timeIntervalSince1970)
        try? await store.setActivityState(activityId: id, .stopped)
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
    @Environment(\.openWindow) private var openWindow
    @State private var flyout: Int64?   // the Recent task whose submenu is open

    // Every row reserves this leading column so all text starts at the same x.
    private let iconColumn: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.activeActivities.isEmpty {
                sectionLabel("Active Activities")
                ForEach(model.activeActivities, id: \.id) { a in
                    HoverRow(onHover: { if $0 { flyout = nil } }) {
                        HStack(spacing: 8) {
                            // Left dot: green = focused, gray = not. Click the row to focus.
                            Button { Task { await model.focusActivity(a.id) } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(model.focusedId == a.id ? Color.green : Color.gray)
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

            if !model.manualTasks.isEmpty {
                sectionLabel("Recent Activities")
                ForEach(model.manualTasks, id: \.id) { t in
                    HoverRow(onHover: { if $0 { flyout = t.id } }) {
                        HStack(spacing: 5) {
                            Color.clear.frame(width: iconColumn, height: 1)   // align text with icon rows
                            Text(t.title ?? "Activity").lineLimit(1)
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
            flyoutRow("Start", "arrowtriangle.right.fill") {
                flyout = nil; Task { await model.reactivate(t.id) }
            }
            flyoutRow("Archive", "arrow.down.to.line") {
                flyout = nil; Task { await model.archiveActivity(t.id) }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 150)
        .presentationBackground { VisualEffect() }
    }

    private func flyoutRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        HoverRow {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: iconColumn)
                    Text(title); Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func flyoutBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { flyout == id }, set: { if !$0 && flyout == id { flyout = nil } })
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 1)
    }

    private func actionRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
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

    /// Row label: manual activities show their title. Auto activities show
    /// `<source display name> - <suffix>`, where the suffix is the project if set,
    /// else the command (e.g. a `pty` `ssh beth` → "Terminal - ssh beth").
    private func rowLabel(_ a: ActivityRecord) -> String {
        if a.manual { return a.title ?? a.project ?? "Activity" }
        if let suffix = a.project ?? a.title, !suffix.isEmpty { return "\(a.displayName) - \(suffix)" }
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
            Toggle("AFK detection off (passive work)", isOn: $afkImmune)
            DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
            Toggle("Ongoing", isOn: $ongoing)
            if !ongoing {
                DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
            }
            HStack {
                Spacer()
                Button("Start") {
                    let title = newTitle
                    let project = newProject
                    let client = newClient
                    let immune = afkImmune
                    let startTs = start.timeIntervalSince1970
                    let endTs = ongoing ? nil : end.timeIntervalSince1970
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

struct ConfigView: View {
    let model: DaemonModel
    @State private var addClientName = ""
    @State private var mapProject: String?
    @State private var mapClient: Int64?
    @State private var mapBillable = true

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

            Section("Project → client") {
                let bound = model.mappings.filter { $0.clientId != nil }
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
                        ForEach(model.projects, id: \.self) { Text($0).tag(String?.some($0)) }
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
        .frame(minWidth: 480, minHeight: 360)
        .task { await model.refresh() }
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
