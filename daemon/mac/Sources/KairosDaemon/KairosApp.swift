import AppKit
import SwiftUI
import KairosCore
import KairosRPC
import KairosServer
import KairosStore

@main
struct KairosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Label(appDelegate.model.menuLabel, systemImage: appDelegate.model.isAfk ? "moon.zzz.fill" : "clock.fill")
        }
        Window("Activity", id: "activity") {
            ActivityView(model: appDelegate.model)
        }
        Window("Configure", id: "configure") {
            ConfigView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: DaemonModel
    private var socketServer: SocketServer?
    private var sampler: IdleSamplerController?
    private var checkpointTimer: Timer?

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/Kairos"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store: Store
        do {
            store = try Store(path: "\(dir)/kairos.db")
            NSLog("kairos: opened disk store at \(dir)/kairos.db")
        } catch {
            NSLog("kairos: failed to open store, falling back to in-memory: \(error)")
            store = try! Store(path: ":memory:")
        }
        self.model = DaemonModel(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = "\(home)/.kairos/daemon.sock"
        let spoolDir = "\(home)/.kairos/spool"
        let store = model.store
        let dispatcher = model.dispatcher

        Task { @MainActor in
            _ = await Spooler(spoolDir: spoolDir).drain(dispatcher: dispatcher, store: store)
            self.socketServer = SocketServer(dispatcher: dispatcher, store: store)
            do {
                try self.socketServer?.start(at: socketPath)
            } catch {
                NSLog("kairos: socket server failed: \(error)")
            }
            self.sampler = IdleSamplerController(store: store)
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
    let dispatcher: Dispatcher
    private(set) var menuLabel = "Kairos"
    private(set) var isPaused = false
    private(set) var isAfk = false
    private(set) var openActivities: [ActivityRecord] = []
    private(set) var clients: [Client] = []
    private(set) var mappings: [ProjectMapping] = []
    private(set) var projects: [String] = []
    private var kairosSourceId: Int64 = 0
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
        self.dispatcher = Dispatcher()
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
        let events = (try? await store.loadEvents()) ?? []
        let state = GlobalState.reduce(events: events, to: Date().timeIntervalSince1970)
        let owner = state.owner

        isPaused = state.isPaused
        isAfk = state.isAfk

        if isAfk {
            menuLabel = "Idle"
        } else if isPaused {
            menuLabel = "Paused"
        } else if let owner, let record = try? await store.loadActivity(id: owner) {
            menuLabel = record.title ?? record.project ?? record.source
        } else {
            menuLabel = "Kairos"
        }

        openActivities = (try? await store.activityRecords(ids: state.openActivities)) ?? []
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

    func newActivity(source: String, title: String, project: String?, clientId: Int64?, start: Double, end: Double?) async {
        let id = (try? await store.openActivity(source: source, externalId: nil, project: project, title: title, metadata: nil, ts: start)) ?? 0
        guard id != 0 else { return }
        if let clientId {
            let payload = try? Wire.data(OverridePayload(clientId: clientId, billable: nil))
            let sourceId = (try? await store.resolveSource(slug: source)) ?? 0
            _ = try? await store.appendEvent(activityId: id, sourceId: sourceId, kind: .activityOverride, ts: start, payload: payload)
        }
        if let end { try? await store.closeActivity(activityId: id, ts: end) }
        await refresh()
    }

    func closeActivity(_ id: Int64) async {
        try? await store.closeActivity(activityId: id, ts: Date().timeIntervalSince1970)
        await refresh()
    }
}

private struct MenuContent: View {
    let model: DaemonModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack {
            if model.isAfk {
                Text("Idle (auto)")
            } else if model.isPaused {
                Text("Paused")
            } else {
                Text(model.menuLabel)
            }
        }
        Button(model.isPaused ? "Resume" : "Pause") { Task { await model.togglePause() } }
        Divider()
        Button("New activity…") { open("activity") }.keyboardShortcut("n")
        Button("Configure…") { open("configure") }.keyboardShortcut(",")
        Divider()
        Button("Quit Kairos") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

struct ActivityView: View {
    let model: DaemonModel
    @State private var newTitle = ""
    @State private var newProject: String?
    @State private var newClient: Int64?
    @State private var start = Date()
    @State private var ongoing = true
    @State private var end = Date()

    var body: some View {
        Form {
            Section("Active activities") {
                if model.openActivities.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.openActivities, id: \.id) { activity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(activity.title ?? activity.source)
                            Text(activity.project ?? activity.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Close") { Task { await model.closeActivity(activity.id) } }
                    }
                }
            }

            Section("New activity") {
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
                Button("Start") {
                    let title = newTitle
                    let project = newProject
                    let client = newClient
                    let startTs = start.timeIntervalSince1970
                    let endTs = ongoing ? nil : end.timeIntervalSince1970
                    Task { await model.newActivity(source: "manual", title: title, project: project, clientId: client, start: startTs, end: endTs) }
                    newTitle = ""; newProject = nil; newClient = nil
                    ongoing = true; start = Date(); end = Date()
                }
                .disabled(newTitle.isEmpty || (!ongoing && end <= start))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 320)
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
