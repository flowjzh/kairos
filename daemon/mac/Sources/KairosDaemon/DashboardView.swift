import AppKit
import SwiftUI
import WebKit
import KairosCore

/// The Dashboard: a WKWebView hosted in a plain `NSWindow` that is **destroyed
/// on close and rebuilt fresh on reopen** (mirroring the Tauri/wry destroy +
/// `WebviewWindowBuilder::build()` pattern — e.g. cc-switch's Lightweight Mode).
///
/// A SwiftUI `Window` keeps its scene alive on close, so the WKWebView (and its
/// Web Content process) is never released, and an in-place teardown leaves the
/// rebuilt page gray. A manually-owned `NSWindow` lets us drop our ref on close
/// (deferred to the next runloop — releasing during `windowWillClose` races a
/// CATransaction commit and crashes) so the WKWebView deallocates → the process
/// exits — and the next `show()` builds a fresh window + webview that renders
/// like the first open.
///
/// Loading: bundled content over a custom `kairos://` scheme (`file://` has no
/// origin, so ES modules — which always CORS-fetch — fail there). Default URL is
/// the bundled build; override with `KAIROS_DASHBOARD_URL` to point at the Vite
/// dev server (launch the binary directly so the env reaches the process). Safari
/// inspector is enabled only when that override is set.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: DaemonModel
    private var window: NSWindow?

    init(model: DaemonModel) { self.model = model }

    func show() {
        // While the Dashboard (the app's main window) is open, be a `.regular`
        // app so Kairos shows in the Dock (and cmd-tab) — cc-switch's
        // `apply_tray_policy(true)`. windowWillClose returns to `.accessory`
        // (menu-bar only) so the resident daemon has no Dock icon at rest.
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let coordinator = DashboardCoordinator()
        coordinator.model = model
        let webView = Self.makeWebView(coordinator: coordinator)
        coordinator.webView = webView

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Kairos Dashboard", comment: "Dashboard window title")
        win.contentView = webView
        win.minSize = NSSize(width: 960, height: 640)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    /// On close, drop our ref so the window + its WKWebView dealloc → Web Content
    /// process exits, then return to `.accessory`. The release is deferred to the
    /// next runloop: tearing it down synchronously here (or via
    /// `isReleasedWhenClosed`) destroys the WKWebView's layer tree while a
    /// CATransaction is mid-commit → EXC_BAD_ACCESS; `.accessory` is set after, so
    /// the Dock tile (in the "Recent Apps" section, like cc-switch) shows without
    /// the running-indicator dot. Clicking it reopens via
    /// `applicationShouldHandleReopen`.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func makeWebView(coordinator: DashboardCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        if let root = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dashboard")?.deletingLastPathComponent() {
            config.setURLSchemeHandler(BundleSchemeHandler(root: root), forURLScheme: BundleSchemeHandler.scheme)
        }
        let userContent = WKUserContentController()
        userContent.add(coordinator, name: "kairos")
        userContent.addUserScript(WKUserScript(
            source: invokeBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = devURL != nil
        load(into: webView)
        return webView
    }

    /// The override URL (`KAIROS_DASHBOARD_URL`, e.g. the Vite dev server); nil →
    /// the bundled `kairos://` build. Read once; drives both inspector gating + load.
    private static var devURL: URL? {
        ProcessInfo.processInfo.environment["KAIROS_DASHBOARD_URL"].flatMap(URL.init(string:))
    }

    private static func load(into webView: WKWebView) {
        if let devURL {
            webView.load(URLRequest(url: devURL))
            return
        }
        if Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dashboard") != nil {
            webView.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://dashboard/index.html")!))
        } else {
            webView.loadHTMLString("<p style='font-family:sans-serif;padding:2em'>Dashboard bundle not found. Run <code>make app</code>.</p>", baseURL: nil)
        }
    }

    // The `invoke` bootstrap: a promise-based, host-agnostic invoke(method, params).
    // The host resolves/rejects via `window.kairos.__resolve` / `__reject`.
    // `window.kairos.locale` is the daemon's language (en / zh-Hans) — the web app's
    // sole locale source (no language picker); date/time formatting follows it.
    static var invokeBootstrap: String {
        let locale = AppSettings.effectiveLanguage
        return #"""
        (function () {
            const pending = new Map();
            let seq = 0;
            window.kairos = {
                locale: "\#(locale)",
                invoke(method, params) {
                    return new Promise((resolve, reject) => {
                        const id = String(++seq);
                        pending.set(id, { resolve, reject });
                        try {
                            window.webkit.messageHandlers.kairos.postMessage({ id, method, params: params || {} });
                        } catch (e) {
                            pending.delete(id);
                            reject(e);
                        }
                    });
                },
                __resolve(id, result) { const p = pending.get(id); if (p) { pending.delete(id); p.resolve(result); } },
                __reject(id, message) { const p = pending.get(id); if (p) { pending.delete(id); p.reject(new Error(message)); } },
            };
        })();
        """#
    }
}

/// The `kairos` script-message handler: dispatches `invoke` calls to the
/// in-process `ReportBridge` and resolves/rejects the pending JS promise.
final class DashboardCoordinator: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var model: DaemonModel?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "kairos",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        let report = model?.report
        let webView = self.webView

        Task { @MainActor in
            let json: String?
            switch method {
            case "report.overview":
                json = await report?.overview(from: dbl(params["from"]), to: dbl(params["to"]))
            case "report.segments":
                json = await report?.segments(
                    from: dbl(params["from"]),
                    to: dbl(params["to"]),
                    offset: int(params["offset"]),
                    limit: int(params["limit"]))
            default:
                webView?.reject(id, "unknown method: \(method)")
                return
            }
            if let json {
                webView?.resolve(id, json)
            } else {
                webView?.reject(id, "no data for \(method)")
            }
        }
    }

    private func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
}

private extension WKWebView {
    /// Resolve a pending `invoke` promise with raw JSON inlined as a JS value
    /// (JSON is a valid JS object-literal expression, so no string escaping).
    func resolve(_ id: String, _ json: String) {
        evaluateJavaScript("window.kairos.__resolve('\(id)', JSON.parse(\(jsString(json))))")
    }

    func reject(_ id: String, _ message: String) {
        evaluateJavaScript("window.kairos.__reject('\(id)', \(jsString(message)))")
    }

    /// Quote a Swift string as a safe JS single-quoted string literal.
    private func jsString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// Serves the bundled dashboard over a custom URL scheme so WKWebView loads it
/// with a real origin (ES modules fetch in CORS mode and fail under `file://`,
/// which has none). Maps `kairos://dashboard/<path>` to files under `root`. This
/// is Apple's documented way to vend app-bundled web content (and what Tauri does).
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kairos"
    private let root: URL

    init(root: URL) { self.root = root }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, status: 400) }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.contains("..") else { return fail(task, status: 403) }
        let file = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: file) else { return fail(task, status: 404) }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime(for: file.pathExtension), "Cache-Control": "no-cache"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, status: Int) {
        if let url = task.request.url {
            task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        task.didFinish()
    }

    private func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "png": "image/png"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }
}
