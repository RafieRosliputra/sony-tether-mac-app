import AppKit
import GPhoto2

// MARK: - Bundle environment

/// Point libgphoto2 at the drivers and I/O plugins shipped inside the .app.
/// Falls back to the system paths when they are absent (dev builds).
func configureBundleEnvironment() {
    guard let resources = Bundle.main.resourceURL else { return }
    let gphoto = resources.appendingPathComponent("gphoto", isDirectory: true)
    let camlibs = gphoto.appendingPathComponent("camlibs", isDirectory: true)
    let iolibs = gphoto.appendingPathComponent("iolibs", isDirectory: true)
    let fm = FileManager.default
    if fm.fileExists(atPath: camlibs.path) { setenv("CAMLIBS", camlibs.path, 0) }
    if fm.fileExists(atPath: iolibs.path) { setenv("IOLIBS", iolibs.path, 0) }
}

// MARK: - Self test

private func runSelfTest() -> Int32 {
    configureBundleEnvironment()
    print("sonyTether \(AppInfo.version) — selftest")
    print("bundle: \(Bundle.main.bundlePath)")

    var verLine = "unknown"
    if let version = gp_library_version(GP_VERSION_SHORT), let first = version.pointee {
        verLine = String(cString: first)
    }
    print("libgphoto2: \(verLine)")
    var ok = verLine != "unknown"

    print("CAMLIBS: \(ProcessInfo.processInfo.environment["CAMLIBS"] ?? "unset")")
    print("IOLIBS: \(ProcessInfo.processInfo.environment["IOLIBS"] ?? "unset")")
    let usb = USBBus.devices()
    print("usb devices: \(usb.count) · Sony: \(usb.filter { $0.vendorID == USBBus.sonyVendorID }.count)")

    let ctx = gp_context_new()
    guard let ctx else { print("FAIL: gp_context_new"); return 1 }
    gp_context_set_error_func(ctx, gpErrorCallback, nil)

    var abil: OpaquePointer?
    if gp_abilities_list_new(&abil) == GP_OK, let abil {
        let rc = gp_abilities_list_load(abil, ctx)
        let count = gp_abilities_list_count(abil)
        print("camlibs loaded: \(rc == GP_OK ? "OK" : "FAIL") · \(count) camera models known")
        if rc != GP_OK || count == 0 { ok = false }
        gp_abilities_list_free(abil)
    } else {
        print("camlibs loaded: FAIL")
        ok = false
    }

    var ports: OpaquePointer?
    if gp_port_info_list_new(&ports) == GP_OK, let ports {
        let rc = gp_port_info_list_load(ports)
        print("iolibs loaded: \(rc == GP_OK ? "OK" : "FAIL") · \(gp_port_info_list_count(ports)) port drivers")
        if rc != GP_OK { ok = false }
        gp_port_info_list_free(ports)
    }

    let context = NamePolicy.Context(originalName: "DSC00001", extensionName: "JPG",
                                     cameraName: "ILCE-7RM3", serial: "0",
                                     session: SessionSnapshot(name: "luar", number: 2, batch: 7,
                                                              sequence: 42, uniqueTag: "TAG", barcode: "123"),
                                     appNodeName: "mac")
    for expr in ["[D]_[T]_[S4].[E]", "[N]/[S3].[E]", "[Z]_[o].[E]", "[U]_[S2].[E]"] {
        let (dir, file) = NamePolicy.resolve(expression: expr, context: context)
        print("name policy \(expr) → \(dir.isEmpty ? "" : dir + "/")\(file)")
    }
    let resolved = NamePolicy.resolve(expression: "[N]/[S3].[E]", context: context)
    let okName = resolved.subdirectory == "luar" && resolved.fileName == "042.JPG"
    print("name policy check: \(okName ? "OK" : "FAIL")")
    if !okName { ok = false }

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonyTether-selftest-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appendingPathComponent(resolved.fileName)
        try Data([1, 2, 3]).write(to: target)
        print("write test: OK (\(target.lastPathComponent))")
        try? FileManager.default.removeItem(at: scratch)
    } catch {
        print("write test: FAIL (\(error.localizedDescription))")
        ok = false
    }

    // Prefix sequencing (hardware free)
    let seqDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonyTether-seq-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)
        for name in ["sk-0001.JPG", "sk-0002.JPG", "bd-0001.JPG"] {
            try Data().write(to: seqDir.appendingPathComponent(name))
        }
        let nextSK = CameraService.nextSequence(prefix: "sk", in: seqDir)
        let nextBD = CameraService.nextSequence(prefix: "bd", in: seqDir)
        let nextNew = CameraService.nextSequence(prefix: "zz", in: seqDir)
        let okSeq = nextSK == 3 && nextBD == 2 && nextNew == 1
        print("prefix sequence: sk→\(nextSK), bd→\(nextBD), zz→\(nextNew) \(okSeq ? "OK" : "FAIL")")
        if !okSeq { ok = false }
        try? FileManager.default.removeItem(at: seqDir)
    } catch {
        print("prefix sequence: FAIL (\(error.localizedDescription))")
        ok = false
    }

    let dest = Preferences.load().downloadDirectory
    try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
    let writable = FileManager.default.isWritableFile(atPath: dest)
    print("download folder: \(dest) writable=\(writable)")
    if !writable { ok = false }

    print("log file: \(Logger.shared.fileURL.path)")
    print(ok ? "RESULT: PASS" : "RESULT: FAIL")
    return ok ? 0 : 1
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: MainViewController!
    private var camera: CameraService!
    private var prefs = Preferences.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureBundleEnvironment()
        buildMenu()

        var directory = (prefs.downloadDirectory as NSString).expandingTildeInPath
        if directory.isEmpty {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/sonyTether").path
            prefs.downloadDirectory = directory
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        camera = CameraService(prefs: prefs)
        controller = MainViewController(camera: camera, prefs: prefs)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "sonyTether"
        window.contentViewController = controller
        window.minSize = NSSize(width: 1150, height: 700)
        window.setFrameAutosaveName("sonyTetherMainWindow")
        window.delegate = controller
        if UserDefaults.standard.string(forKey: "NSWindow Frame sonyTetherMainWindow") == nil {
            window.center()
        }
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        camera.start()
        GlobalShortcuts.shared.handler = { [weak self] action in
            self?.perform(action)
        }
        GlobalShortcuts.shared.reload()
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.buildMenu()
            GlobalShortcuts.shared.reload()
        }
        Logger.shared.info("UI ready · \(AppInfo.name) \(AppInfo.version)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { camera?.shutdown() }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About sonyTether", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide sonyTether", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit sonyTether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Choose Download Folder…", action: #selector(chooseFolder), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Show Download Folder", action: #selector(showFolder), keyEquivalent: "o").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Reveal Log File", action: #selector(revealLog), keyEquivalent: "l").keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu

        let cameraItem = NSMenuItem()
        mainMenu.addItem(cameraItem)
        let cameraMenu = NSMenu(title: "Camera")
        cameraMenu.addItem(withTitle: "Connect", action: #selector(connectCamera), keyEquivalent: "d")
        cameraMenu.addItem(withTitle: "Capture", action: #selector(capture), keyEquivalent: "r")
        cameraMenu.addItem(withTitle: "Auto Focus", action: #selector(autoFocus), keyEquivalent: "f")
        cameraMenu.addItem(withTitle: "Toggle Live View", action: #selector(toggleLive), keyEquivalent: "l")
        cameraMenu.addItem(NSMenuItem.separator())
        cameraMenu.addItem(withTitle: "Set Capture Shortcut…", action: #selector(setShortcut), keyEquivalent: "k").keyEquivalentModifierMask = [.command, .shift]
        cameraMenu.addItem(NSMenuItem.separator())
        cameraMenu.addItem(withTitle: "Restart App", action: #selector(restartApp), keyEquivalent: "")
        cameraItem.submenu = cameraMenu

        let scriptsItem = NSMenuItem()
        mainMenu.addItem(scriptsItem)
        let scriptsMenu = NSMenu(title: "Scripts")
        for kind in ScriptKind.shipped {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(runBuiltInScript(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.target = self
            scriptsMenu.addItem(item)
        }
        scriptsMenu.addItem(NSMenuItem.separator())
        scriptsMenu.addItem(withTitle: "Stop Script", action: #selector(stopScript), keyEquivalent: ".")
        scriptsItem.submenu = scriptsMenu

        let displayItem = NSMenuItem()
        mainMenu.addItem(displayItem)
        let displayMenu = NSMenu(title: "Display")
        displayMenu.addItem(withTitle: "Photographer View", action: #selector(showDisplayWindow), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .shift]
        displayMenu.addItem(withTitle: "Client View", action: #selector(showClientView), keyEquivalent: "m").keyEquivalentModifierMask = [.command, .shift]
        displayMenu.addItem(withTitle: "Toggle Log Viewer", action: #selector(toggleLog), keyEquivalent: "j")
        displayMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        displayItem.submenu = displayMenu

        let transferItem = NSMenuItem()
        mainMenu.addItem(transferItem)
        let transferMenu = NSMenu(title: "Transfer")
        transferMenu.addItem(withTitle: "Sync All Now", action: #selector(syncAllNow), keyEquivalent: "")
        transferMenu.addItem(withTitle: "ADB Push Last Photo", action: #selector(adbPushLast), keyEquivalent: "")
        transferMenu.addItem(withTitle: "ADB Devices", action: #selector(adbDevices), keyEquivalent: "")
        transferItem.submenu = transferMenu

        let photosItem = NSMenuItem()
        mainMenu.addItem(photosItem)
        let photosMenu = NSMenu(title: "Photos")
        photosMenu.addItem(withTitle: "Show Photos", action: #selector(showPhotos), keyEquivalent: "2")
        photosMenu.addItem(withTitle: "Show Capture", action: #selector(showCapture), keyEquivalent: "1")
        photosItem.submenu = photosMenu

        let cacheItem = NSMenuItem()
        mainMenu.addItem(cacheItem)
        let cacheMenu = NSMenu(title: "Cache")
        cacheMenu.addItem(withTitle: "Delete Cache (keep settings)", action: #selector(clearCache), keyEquivalent: "")
        cacheMenu.addItem(withTitle: "Reveal Cache Folder", action: #selector(revealCache), keyEquivalent: "")
        cacheMenu.addItem(NSMenuItem.separator())
        cacheMenu.addItem(withTitle: "Reset All Settings to Default", action: #selector(resetSettings), keyEquivalent: "")
        cacheItem.submenu = cacheMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "GitHub Repository", action: #selector(openRepo), keyEquivalent: "")
        helpItem.submenu = helpMenu

        let standard = [
            #selector(NSApplication.hide(_:)), #selector(NSApplication.terminate(_:)),
            #selector(NSWindow.miniaturize(_:)), #selector(NSWindow.zoom(_:)),
            #selector(NSWindow.toggleFullScreen(_:)),
        ].map { NSStringFromSelector($0) }
        for menu in [appMenu, fileMenu, cameraMenu, scriptsMenu, displayMenu, transferMenu, cacheMenu, photosMenu, windowMenu, helpMenu] {
            for item in menu.items where item.action != nil {
                if item.target == nil && !standard.contains(NSStringFromSelector(item.action!)) {
                    item.target = self
                }
            }
        }
        ShortcutStore.shared.applyAll(to: mainMenu)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu actions

    @objc private func showAbout() {
        let credits = NSAttributedString(string:
            "Sony tether for macOS. Built on libgphoto2 \(libgphotoVersion()) (LGPL-2.1).\n\(AppInfo.repoURL)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits, .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version, .version: AppInfo.build,
        ])
    }

    private func libgphotoVersion() -> String {
        if let version = gp_library_version(GP_VERSION_SHORT), let first = version.pointee {
            return String(cString: first)
        }
        return "?"
    }

    @objc private func showPreferences() { controller.showPreferencesWindow() }
    @objc private func chooseFolder() { controller.chooseFolder() }
    @objc private func showFolder() { controller.revealSessionFolder() }
    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.fileURL])
    }
    @objc private func connectCamera() { camera.setConnected(true) }
    @objc private func capture() { controller.captureNow() }
    @objc private func autoFocus() { controller.autofocus() }
    @objc private func toggleLive() { controller.setLiveView(true) }
    @objc private func setShortcut() { controller.showShortcutRecorder() }
    @objc private func runBuiltInScript(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ScriptKind(rawValue: raw) else { return }
        controller.runScript(kind)
    }
    @objc private func stopScript() { controller.stopScript() }
    @objc private func toggleLog() { controller.toggleLog() }
    @objc private func showDisplayWindow() { controller.showFocusWindow() }
    @objc private func showClientView() { controller.showClientView() }
    @objc private func syncAllNow() { controller.syncAllNow() }
    @objc private func adbPushLast() { controller.adbPushLast() }
    @objc private func adbDevices() { controller.adbDevicesToList() }
    @objc private func showPhotos() { controller.showPhotos() }
    @objc private func showCapture() { controller.showCapture() }
    @objc private func restartApp() {
        camera?.shutdown()
        let url = Bundle.main.bundleURL
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", url.path]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private func perform(_ action: AppAction) {
        switch action {
        case .capture: capture()
        case .autofocus: autoFocus()
        case .liveView: controller.toggleLiveView()
        case .focusWindow: showDisplayWindow()
        case .syncAll: syncAllNow()
        case .adbPush: adbPushLast()
        case .showPhotos: showPhotos()
        case .showCapture: showCapture()
        case .toggleLog: toggleLog()
        case .preferences: showPreferences()
        case .restartApp: restartApp()
        }
    }

    @objc private func clearCache() { controller.clearCache() }
    @objc private func revealCache() { controller.revealCache() }
    @objc private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset every setting to default?"
        alert.informativeText = "Shortcuts, folders, ADB, sync, naming and layout go back to defaults. Photo files are not touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { controller.resetAllSettings() }
    }

    @objc private func openRepo() {
        if let url = URL(string: AppInfo.repoURL) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Entry point

private func runProbe() -> Int32 {
    configureBundleEnvironment()
    print("probe: CAMLIBS=\(ProcessInfo.processInfo.environment["CAMLIBS"] ?? "-")")
    let ctx = gp_context_new()!
    var list: OpaquePointer?
    gp_list_new(&list)
    print("autodetect rc=\(gp_camera_autodetect(list, ctx)) count=\(gp_list_count(list))")
    var cam: UnsafeMutablePointer<Camera>? = nil
    gp_camera_new(&cam)
    let rc = gp_camera_init(cam!, ctx)
    print("init rc=\(rc) \(gpErrorText(rc))")
    if rc == GP_OK {
        var text = CameraText()
        gp_camera_get_summary(cam!, &text, ctx)
        print(fixedCString(&text).split(separator: "\n").prefix(4).joined(separator: " | "))
        gp_camera_exit(cam!, ctx)
    }
    return rc == GP_OK ? 0 : 1
}

let args = CommandLine.arguments
if args.contains("--probe") { exit(runProbe()) }
if args.contains("--selftest") { exit(runSelfTest()) }
if args.contains("--version") {
    print("\(AppInfo.name) \(AppInfo.version)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
