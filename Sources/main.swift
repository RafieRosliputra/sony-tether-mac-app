import AppKit
import GPhoto2

// MARK: - Bundle environment

/// Point libgphoto2 at the drivers and I/O plugins shipped inside the .app.
/// Falls back to the system/Homebrew paths when they are absent (dev builds).
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
    let app = Bundle.main
    print("bundle: \(app.bundlePath)")
    print("resources: \(app.resourceURL?.path ?? "—")")

    var verLine = "unknown"
    if let version = gp_library_version(GP_VERSION_SHORT), let first = version.pointee {
        verLine = String(cString: first)
    }
    print("libgphoto2: \(verLine)")

    let camlibs = ProcessInfo.processInfo.environment["CAMLIBS"] ?? "unset"
    let iolibs = ProcessInfo.processInfo.environment["IOLIBS"] ?? "unset"
    print("CAMLIBS: \(camlibs)")
    print("IOLIBS: \(iolibs)")

    var ok = verLine != "unknown"
    if !ok { print("FAIL: libgphoto2 not loadable") }

    let ctx = gp_context_new()
    guard let ctx else {
        print("FAIL: gp_context_new")
        return 1
    }
    gp_context_set_error_func(ctx, gpErrorCallback, nil)

    // Prove the bundled camlibs/iolibs are loadable (no camera needed).
    var abil: OpaquePointer?
    if gp_abilities_list_new(&abil) == GP_OK, let abil {
        let rc = gp_abilities_list_load(abil, ctx)
        let count = gp_abilities_list_count(abil)
        print("camlibs loaded: \(rc == GP_OK ? "OK" : "FAIL") · \(count) camera models known")
        if rc != GP_OK || count == 0 { ok = false }
        gp_abilities_list_free(abil)
    } else {
        print("camlibs loaded: FAIL (gp_abilities_list_new)")
        ok = false
    }

    var ports: OpaquePointer?
    if gp_port_info_list_new(&ports) == GP_OK, let ports {
        let rc = gp_port_info_list_load(ports)
        let count = gp_port_info_list_count(ports)
        print("iolibs loaded: \(rc == GP_OK ? "OK" : "FAIL") · \(count) port drivers")
        for i in 0..<max(0, count) {
            var info: OpaquePointer?
            if gp_port_info_list_get_info(ports, i, &info) == GP_OK, let info {
                var name: UnsafeMutablePointer<CChar>? = nil
                _ = gp_port_info_get_name(info, &name)
                print("  - \(name.map { String(cString: $0) } ?? "?")")
            }
        }
        if rc != GP_OK || count == 0 { ok = false }
        gp_port_info_list_free(ports)
    } else {
        print("iolibs loaded: FAIL (gp_port_info_list_new)")
        ok = false
    }

    var list: OpaquePointer?
    let lrc = gp_list_new(&list)
    if lrc == GP_OK, let list {
        let rc = gp_camera_autodetect(list, ctx)
        let count = gp_list_count(list)
        print("autodetect: \(count) camera(s) (rc \(rc))")
        for i in 0..<count {
            var name: UnsafePointer<CChar>? = nil
            _ = gp_list_get_name(list, i, &name)
            print("  - \(name.map { String(cString: $0) } ?? "?")")
        }
        gp_list_free(list)
    }

    var cam: UnsafeMutablePointer<Camera>? = nil
    if gp_camera_new(&cam) == GP_OK, let cam {
        let rc = gp_camera_init(cam, ctx)
        if rc == GP_OK {
            var summary = CameraText()
            _ = gp_camera_get_summary(cam, &summary, ctx)
            let text = fixedCString(&summary)
            print("camera init: OK")
            for line in text.split(separator: "\n").prefix(6) { print("  \(line)") }
            var file: OpaquePointer?
            if gp_file_new(&file) == GP_OK, let file {
                let prc = gp_camera_capture_preview(cam, file, ctx)
                var data: UnsafePointer<CChar>? = nil
                var size: UInt = 0
                if prc == GP_OK { _ = gp_file_get_data_and_size(file, &data, &size) }
                print("live view frame: rc \(prc), \(size) bytes")
                if prc != GP_OK { ok = false }
                gp_file_unref(file)
            }
            _ = gp_camera_exit(cam, ctx)
        } else {
            print("camera init: \(gpErrorText(rc)) (expected when no body is attached)")
        }
        gp_camera_unref(cam)
    }
    gp_context_unref(ctx)

    // Capture-file writing (hardware-free).
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonyTether-selftest-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let first = try CameraService.writeCapture(Data([1, 2, 3]), name: "DSC00001.ARW", into: scratch)
        let second = try CameraService.writeCapture(Data([4]), name: "DSC00001.ARW", into: scratch)
        let okNames = first.lastPathComponent == "DSC00001.ARW" && second.lastPathComponent == "DSC00001-1.ARW"
        print("capture write: \(okNames ? "OK" : "FAIL") (\(first.lastPathComponent), \(second.lastPathComponent))")
        if !okNames { ok = false }
        try? FileManager.default.removeItem(at: scratch)
    } catch {
        print("capture write: FAIL (\(error.localizedDescription))")
        ok = false
    }

    let dest = defaultDestination()
    let fm = FileManager.default
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let writable = fm.isWritableFile(atPath: dest.path)
    print("destination: \(dest.path) writable=\(writable)")
    if !writable { ok = false }

    print("log file: \(Logger.shared.fileURL.path)")
    Logger.shared.info("selftest run")

    print(ok ? "RESULT: PASS" : "RESULT: FAIL")
    return ok ? 0 : 1
}

private func defaultDestination() -> URL {
    if let saved = UserDefaults.standard.string(forKey: "saveFolder"), !saved.isEmpty {
        return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/sonyTether", isDirectory: true)
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var viewController: MainViewController!
    private var service: CameraService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureBundleEnvironment()
        buildMenu()

        let dest = defaultDestination()
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        service = CameraService(destination: dest)
        viewController = MainViewController(service: service)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "sonyTether"
        window.contentViewController = viewController
        window.minSize = NSSize(width: 980, height: 640)
        window.setFrameAutosaveName("sonyTetherMainWindow")
        window.delegate = viewController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        service.start()
        Logger.shared.info("UI ready · \(AppInfo.name) \(AppInfo.version)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        service?.shutdown()
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About sonyTether", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide sonyTether", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit sonyTether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Choose Capture Folder…", action: #selector(chooseFolderMenuItem), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Show Capture Folder", action: #selector(revealFolderMenuItem), keyEquivalent: "o").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Reveal Log File", action: #selector(revealLogMenuItem), keyEquivalent: "l").keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu = fileMenu

        let cameraMenuItem = NSMenuItem()
        mainMenu.addItem(cameraMenuItem)
        let cameraMenu = NSMenu(title: "Camera")
        cameraMenu.addItem(withTitle: "Connect", action: #selector(toggleConnectMenuItem), keyEquivalent: "d")
        cameraMenu.addItem(withTitle: "Capture", action: #selector(captureMenuItem), keyEquivalent: "r")
        cameraMenu.addItem(withTitle: "Toggle Live View", action: #selector(toggleLiveMenuItem), keyEquivalent: "l")
        cameraMenuItem.submenu = cameraMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Route every custom action through this delegate.
        for menu in [appMenu, fileMenu, cameraMenu, editMenu, windowMenu] {
            for item in menu.items where item.action != nil {
                if item.target == nil && !isStandardAction(item.action!) {
                    item.target = self
                }
            }
        }
        NSApp.mainMenu = mainMenu
    }

    private func isStandardAction(_ action: Selector) -> Bool {
        let standard = [
            #selector(NSApplication.hide(_:)),
            #selector(NSApplication.hideOtherApplications(_:)),
            #selector(NSApplication.unhideAllApplications(_:)),
            #selector(NSApplication.terminate(_:)),
            #selector(NSText.copy(_:)),
            #selector(NSText.selectAll(_:)),
            #selector(NSWindow.miniaturize(_:)),
            #selector(NSWindow.zoom(_:)),
        ].map { NSStringFromSelector($0) }
        return standard.contains(NSStringFromSelector(action))
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Sony PTP tether for macOS.\nBuilt on libgphoto2 \(libgphotoVersion()) (LGPL-2.1).\n"
                + AppInfo.repoURL,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
        ])
    }

    private func libgphotoVersion() -> String {
        if let version = gp_library_version(GP_VERSION_SHORT), let first = version.pointee {
            return String(cString: first)
        }
        return "?"
    }

    @objc private func chooseFolderMenuItem() { viewController.menuChooseFolder() }
    @objc private func revealFolderMenuItem() { viewController.menuRevealFolder() }
    @objc private func revealLogMenuItem() { viewController.menuRevealLog() }
    @objc private func toggleConnectMenuItem() { viewController.menuToggleConnect() }
    @objc private func captureMenuItem() { viewController.menuCapture() }
    @objc private func toggleLiveMenuItem() { viewController.menuToggleLive() }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(runSelfTest())
}
if args.contains("--version") {
    print("\(AppInfo.name) \(AppInfo.version)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
