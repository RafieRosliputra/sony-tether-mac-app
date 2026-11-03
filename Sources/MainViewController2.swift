import AppKit

// MARK: - Live view canvas

final class LiveViewerView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var rotation: Int = 0 { didSet { needsDisplay = true } }
    var showGrid = false { didSet { needsDisplay = true } }
    var overlayText = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else {
            drawOverlay()
            return
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let rotated = rotation % 180 == 90
        let target = rotated ? NSSize(width: size.height, height: size.width) : size
        let fit = min(bounds.width / target.width, bounds.height / target.height) * zoom
        let w = target.width * fit
        let h = target.height * fit
        let rect = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: CGFloat(rotation))
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        if showGrid {
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let path = NSBezierPath()
            for i in 1..<3 {
                let x = bounds.width * CGFloat(i) / 3
                path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: bounds.height))
                let y = bounds.height * CGFloat(i) / 3
                path.move(to: NSPoint(x: 0, y: y)); path.line(to: NSPoint(x: bounds.width, y: y))
            }
            path.lineWidth = 1
            path.stroke()
        }
        drawOverlay()
    }

    private func drawOverlay() {
        guard !overlayText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let s = NSAttributedString(string: overlayText, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Main window content

final class MainViewController: NSViewController, NSWindowDelegate {
    var camera: CameraService
    var prefs: Preferences { didSet { camera.prefs = prefs } }
    let api = ExternalAPI()
    private let hotKey = HotKeyCenter()
    private var photos: [PhotoRecord] = []
    private let transfer: TransferService
    private var focusWindow: FocusWindowController?
    private var clientView: ClientViewWindowController?
    private var folderStack: [String] = []

    // Panels
    private let controls = CameraControlsView()
    private let filenamePanel = FilenamePanel()
    private let scriptPanel = ScriptPanel()
    private let photosView = PhotosView()
    private let logPane = LogPane()
    private let liveView = LiveViewerView()

    // Tabs + chrome
    private let tabs = NSSegmentedControl(labels: ["Capture", "Photos", "Shortcuts", "ADB", "Sync"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let shortcutTab = ShortcutTabView()
    private let adbTab = ADBTabView()
    private let syncTab = SyncTabView()
    private var restartTimer: Timer?
    private var disconnectPanel: NSPanel?
    private var everConnected = false
    private var captureArea = NSView()
    private let liveCard = NSView()
    private let logCard = NSView()
    private let statusDot = NSView()
    private let statusLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let statusRight = makeLabel("", size: 10, color: .tertiaryLabelColor)
    private let fpsLabel = makeLabel("", size: 10, color: .secondaryLabelColor)
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridCheck = NSButton(checkboxWithTitle: "Grid", target: nil, action: nil)
    private let rotateButton = NSButton(title: "Rotate", target: nil, action: nil)
    private let fullscreenButton = NSButton(title: "Full Screen", target: nil, action: nil)

    private var liveOn = true
    private var logVisible = true
    private var captureStatus = CameraStatus()
    private var session = SessionSnapshot(name: "", number: 1, batch: 1, sequence: 1, uniqueTag: "", barcode: "")

    init(camera: CameraService, prefs: Preferences) {
        self.camera = camera
        self.prefs = prefs
        self.transfer = TransferService(prefs: prefs)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        view.wantsLayer = true
        build()
        wire()
        updateTabs()
    }

    // MARK: Layout

    private func build() {
        let tabBar = buildTabBar()
        let left = controls
        let right = buildRightColumn()
        let center = buildCenter()

        for v in [tabBar, left, center, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        let statusBar = buildStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 46),

            left.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            left.widthAnchor.constraint(equalToConstant: 286),

            center.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            center.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            center.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            center.trailingAnchor.constraint(equalTo: right.leadingAnchor),

            right.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            right.widthAnchor.constraint(equalToConstant: 300),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func buildTabBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let pviewButton = makeButton("PView", target: self, action: #selector(openPView))
        pviewButton.bezelStyle = .rounded
        pviewButton.controlSize = .small
        pviewButton.translatesAutoresizingMaskIntoConstraints = false

        let dotRow = NSStackView(views: [statusDot, statusLabel])
        dotRow.orientation = .horizontal
        dotRow.spacing = 6
        dotRow.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(tabs)
        bar.addSubview(pviewButton)
        bar.addSubview(dotRow)
        NSLayoutConstraint.activate([
            pviewButton.leadingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 10),
            pviewButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            tabs.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            tabs.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dotRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            dotRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        return bar
    }

    private func buildCenter() -> NSView {
        let container = NSView()

        liveCard.wantsLayer = true
        liveCard.layer?.backgroundColor = NSColor.black.cgColor
        liveCard.layer?.cornerRadius = 8
        liveCard.layer?.masksToBounds = true
        liveCard.translatesAutoresizingMaskIntoConstraints = false

        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.overlayText = "Live view off"
        liveCard.addSubview(liveView)

        zoomPopup.addItems(withTitles: ["1×", "2×", "3×", "4×"])
        zoomPopup.controlSize = .mini
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        gridCheck.target = self
        gridCheck.action = #selector(toggleGrid)
        gridCheck.controlSize = .mini
        rotateButton.target = self
        rotateButton.action = #selector(rotateLive)
        fullscreenButton.target = self
        fullscreenButton.action = #selector(enterFullScreen)

        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        liveCard.addSubview(fpsLabel)

        let tools = NSStackView(views: [zoomPopup, gridCheck, rotateButton, fullscreenButton])
        tools.orientation = .horizontal
        tools.spacing = 6
        tools.translatesAutoresizingMaskIntoConstraints = false

        captureArea = NSView()
        captureArea.translatesAutoresizingMaskIntoConstraints = false
        captureArea.addSubview(liveCard)
        captureArea.addSubview(tools)

        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: captureArea.topAnchor, constant: 8),
            tools.trailingAnchor.constraint(equalTo: captureArea.trailingAnchor, constant: -12),
            liveCard.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 8),
            liveCard.leadingAnchor.constraint(equalTo: captureArea.leadingAnchor, constant: 12),
            liveCard.trailingAnchor.constraint(equalTo: captureArea.trailingAnchor, constant: -12),
            liveCard.bottomAnchor.constraint(equalTo: captureArea.bottomAnchor, constant: -8),
            liveView.leadingAnchor.constraint(equalTo: liveCard.leadingAnchor),
            liveView.trailingAnchor.constraint(equalTo: liveCard.trailingAnchor),
            liveView.topAnchor.constraint(equalTo: liveCard.topAnchor),
            liveView.bottomAnchor.constraint(equalTo: liveCard.bottomAnchor),
            fpsLabel.leadingAnchor.constraint(equalTo: liveCard.leadingAnchor, constant: 8),
            fpsLabel.bottomAnchor.constraint(equalTo: liveCard.bottomAnchor, constant: -6),
        ])

        photosView.translatesAutoresizingMaskIntoConstraints = false
        shortcutTab.translatesAutoresizingMaskIntoConstraints = false
        adbTab.translatesAutoresizingMaskIntoConstraints = false
        syncTab.translatesAutoresizingMaskIntoConstraints = false
        logCard.wantsLayer = true
        logCard.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        logCard.translatesAutoresizingMaskIntoConstraints = false
        logPane.translatesAutoresizingMaskIntoConstraints = false
        logCard.addSubview(logPane)

        container.addSubview(captureArea)
        container.addSubview(photosView)
        container.addSubview(shortcutTab)
        container.addSubview(adbTab)
        container.addSubview(syncTab)
        container.addSubview(logCard)

        NSLayoutConstraint.activate([
            captureArea.topAnchor.constraint(equalTo: container.topAnchor),
            captureArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            captureArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            photosView.topAnchor.constraint(equalTo: container.topAnchor),
            photosView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            photosView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            photosView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            shortcutTab.topAnchor.constraint(equalTo: container.topAnchor),
            shortcutTab.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shortcutTab.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shortcutTab.bottomAnchor.constraint(equalTo: logCard.topAnchor),
            adbTab.topAnchor.constraint(equalTo: container.topAnchor),
            adbTab.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            adbTab.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            adbTab.bottomAnchor.constraint(equalTo: logCard.topAnchor),
            syncTab.topAnchor.constraint(equalTo: container.topAnchor),
            syncTab.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            syncTab.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            syncTab.bottomAnchor.constraint(equalTo: logCard.topAnchor),
            logCard.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logCard.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            logCard.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            logCard.heightAnchor.constraint(equalToConstant: 170),
            logPane.leadingAnchor.constraint(equalTo: logCard.leadingAnchor),
            logPane.trailingAnchor.constraint(equalTo: logCard.trailingAnchor),
            logPane.topAnchor.constraint(equalTo: logCard.topAnchor),
            logPane.bottomAnchor.constraint(equalTo: logCard.bottomAnchor),
        ])

        // Capture area sits above the log pane.
        let captureBottom = captureArea.bottomAnchor.constraint(equalTo: logCard.topAnchor)
        captureBottom.isActive = true

        return container
    }

    private func buildRightColumn() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        filenamePanel.translatesAutoresizingMaskIntoConstraints = false
        scriptPanel.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(filenamePanel)
        container.addSubview(divider)
        container.addSubview(scriptPanel)
        NSLayoutConstraint.activate([
            filenamePanel.topAnchor.constraint(equalTo: container.topAnchor),
            filenamePanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filenamePanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.topAnchor.constraint(equalTo: filenamePanel.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scriptPanel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            scriptPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scriptPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scriptPanel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func buildStatusBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusRight.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusRight)
        NSLayoutConstraint.activate([
            statusRight.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            statusRight.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: Wiring

    private func wire() {
        camera.onStatus = { [weak self] status in
            guard let self else { return }
            let wasConnected = self.captureStatus.connected
            self.captureStatus = status
            if status.connected { self.everConnected = true }
            self.updateConnectionChrome(connected: status.connected,
                                        transition: wasConnected != status.connected)
            self.controls.update(status: status, controls: self.camera.controls, liveOn: self.liveOn)
            self.renderStatus(status)
            self.api.broadcast(["event": status.connected ? "connected" : "disconnected",
                                "model": status.model])
        }
        camera.onControls = { [weak self] groups in
            guard let self else { return }
            self.controls.update(status: self.captureStatus, controls: groups, liveOn: self.liveOn)
        }
        camera.onFrame = { [weak self] data in
            guard let self else { return }
            if let image = NSImage(data: data) {
                self.focusWindow?.setLiveFrame(image)
                self.liveView.image = image
                self.liveView.overlayText = ""
                let rep = image.representations.first
                self.fpsLabel.stringValue = rep == nil ? "" :
                    "\(rep!.pixelsWide)×\(rep!.pixelsHigh) · \(String(format: "%.0f", self.captureStatus.liveFps)) fps"
            }
        }
        camera.onPhoto = { [weak self] record in
            guard let self else { return }
            self.photos.append(record)
            self.photosView.setPhotos(self.photos)
            self.updateSessionUI()
            self.transfer.handle(record)
            self.refreshFocusWindow(select: record, isNew: true)
            self.updateFocusStatuses()
            self.clientView?.show(image: NSImage(contentsOf: record.url))
            self.api.broadcast(["event": "photo", "photo": self.json(for: record)])
        }
        camera.onScriptState = { [weak self] state in
            self?.scriptPanel.render(state)
            self?.api.broadcast(["event": "script", "name": state.name,
                                 "status": state.status, "progress": state.progress,
                                 "total": state.total])
        }

        controls.onConnect = { [weak self] in self?.camera.setConnected(true) }
        controls.onDisconnect = { [weak self] in self?.camera.setConnected(false) }
        controls.onCapture = { [weak self] in self?.captureNow() }
        controls.onAutofocus = { [weak self] in self?.camera.autofocus() }
        controls.onLiveView = { [weak self] on in self?.setLiveView(on) }
        controls.onSet = { [weak self] name, value in self?.camera.setControl(name: name, value: value) }
        controls.onStep = { [weak self] name, dir in self?.camera.stepControl(name: name, direction: dir) }

        filenamePanel.onChange = { [weak self] in
            guard let self else { return }
            if self.filenamePanel.prefixValue != self.prefs.filenamePrefix {
                self.applyPrefix(self.filenamePanel.prefixValue)
            }
            self.applySessionFromUI()
        }
        filenamePanel.onResyncBatch = { [weak self] in
            guard let self else { return }
            self.camera.session.batch += 1
            self.updateSessionUI()
        }
        filenamePanel.onBarcode = { [weak self] code in
            guard let self else { return }
            self.camera.session.barcode = code
            if self.prefs.barcodeResetsSequence { self.camera.session.resetSequence(1) }
            self.updateSessionUI()
            Logger.shared.info("Barcode: \(code)")
        }

        scriptPanel.onRun = { [weak self] settings in self?.camera.startScript(settings) }
        scriptPanel.onStop = { [weak self] in self?.camera.stopScript() }

        photosView.onOpen = { record in NSWorkspace.shared.open(record.url) }
        photosView.onReveal = { record in
            NSWorkspace.shared.activateFileViewerSelecting([record.url])
        }
        photosView.onChooseFolder = { [weak self] in self?.chooseFolder() }
        photosView.onMove = { [weak self] urls, folder in
            self?.movePhotos(urls, to: folder)
        }
        // photosView.setRoot(URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath))

        // Capture is registered through the Shortcuts tab (global).

        api.onCommand = { [weak self] command in
            guard let self else { return ["ok": false] }
            return self.handleAPI(command)
        }
        if prefs.apiEnabled {
            api.start(eventPort: prefs.apiEventPort, replyPort: prefs.apiReplyPort)
        }

        shortcutTab.isHidden = true
        adbTab.isHidden = true
        syncTab.isHidden = true
        NotificationCenter.default.addObserver(forName: .transferStatus, object: nil, queue: .main) { [weak self] _ in
            self?.focusWindow?.renderTransferStatus()
            self?.updateFocusStatuses()
        }
        adbTab.prefProvider = { [weak self] in self?.prefs ?? Preferences.load() }
        adbTab.service = transfer
        adbTab.onCommit = { [weak self] updated in self?.applyPrefs(updated) }
        syncTab.prefProvider = { [weak self] in self?.prefs ?? Preferences.load() }
        syncTab.onCommit = { [weak self] updated in self?.applyPrefs(updated) }
        syncTab.onSyncAll = { [weak self] in self?.syncAllNow() }
        syncTab.onMirror = { [weak self] in
            guard let self else { return }
            self.transfer.mirrorSync()
            self.focusWindow?.renderTransferStatus()
        }
        shortcutTab.onChange = { NotificationCenter.default.post(name: .shortcutsChanged, object: nil) }
        scheduleAutoRestart()
        updateSessionUI()
        controls.update(status: captureStatus, controls: [], liveOn: liveOn)
        setLiveView(true)
        applySessionFromUI()
    }

    // MARK: Connection chrome

    /// Red frame on every window while the body is unreachable, plus a warning
    /// panel that closes itself as soon as the camera answers again.
    private func updateConnectionChrome(connected: Bool, transition: Bool) {
        for window in [view.window, focusWindow?.window] {
            guard let content = window?.contentView else { continue }
            content.wantsLayer = true
            content.layer?.borderWidth = connected ? 0 : 3
            content.layer?.borderColor = NSColor.systemRed.cgColor
        }
        focusWindow?.setCameraConnected(connected)
        if connected {
            if let panel = disconnectPanel {
                panel.close()
                disconnectPanel = nil
            }
            return
        }
        if transition && everConnected && disconnectPanel == nil {
            showDisconnectWarning()
        }
    }

    private func showDisconnectWarning() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Camera disconnected"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let label = makeLabel("The camera stopped answering. Reconnect the USB cable — "
            + "this notice closes by itself when the camera is back.", size: 11)
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 320
        label.lineBreakMode = .byWordWrapping
        let button = makeButton("Reconnect", target: self, action: #selector(reconnectCamera))
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            ])
        }
        if let window = view.window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.maxY - 170))
        }
        panel.orderFront(nil)
        disconnectPanel = panel
    }

    @objc private func reconnectCamera() {
        camera.setConnected(false)
        camera.setConnected(true)
    }

    // MARK: Focus status

    private func handleStatusToggle(_ key: String) {
        switch key {
        case "camera":
            camera.setConnected(!captureStatus.connected)
        case "live":
            toggleLiveView()
        case "adb":
            prefs.transferADBEnabled.toggle()
            applyPrefs(prefs)
        case "sync":
            prefs.transferSyncEnabled.toggle()
            applyPrefs(prefs)
        case "api":
            prefs.apiEnabled.toggle()
            applyPrefs(prefs)
        case "stayawake":
            prefs.adbStayAwake.toggle()
            applyPrefs(prefs)
            transfer.adbApplyDisplaySettings()
        default:
            break
        }
        updateFocusStatuses()
    }

    func updateFocusStatuses() {
        guard let focusWindow else { return }
        var data = PViewStatusData()
        data.cameraConnected = captureStatus.connected
        data.liveOn = captureStatus.liveViewState == .running
        data.battery = captureStatus.battery ?? "—"
        data.storage = captureStatus.storage ?? "—"
        let items = camera.controls.flatMap { $0.items }
        func value(_ name: String) -> String { items.first { $0.name == name }?.current ?? "—" }
        data.exposure = "\(value("iso")) · \(value("shutterspeed")) · \(value("f-number"))"
        data.lastError = captureStatus.lastError ?? ""
        data.adbEnabled = prefs.transferADBEnabled
        data.adbDevice = transfer.adbDevices().first ?? "none"
        data.adbLast = TransferStatusBroker.shared.summary
        data.syncEnabled = prefs.transferSyncEnabled
        let syncPath = (prefs.syncFolder as NSString).expandingTildeInPath
        data.syncReachable = !syncPath.isEmpty && FileManager.default.fileExists(atPath: syncPath)
        data.syncLast = TransferStatusBroker.shared.summary
        data.folder = (prefs.downloadDirectory as NSString).lastPathComponent
        data.prefix = prefs.filenamePrefix
        let dir = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        data.nextNumber = CameraService.nextSequence(prefix: prefs.filenamePrefix, in: dir)
        data.lastFile = photos.last?.name ?? "—"
        data.fileCounter = photos.isEmpty ? "0/0" : "\(photos.count)/\(photos.count)"
        data.apiOn = api.isRunning
        data.phoneNote = transfer.adbDevices().isEmpty ? "not connected" : "connected"
        focusWindow.updateStatuses(data)
    }

    // MARK: Focus window

    func showFocusWindow() {
        if focusWindow == nil {
            let w = FocusWindowController()
            w.onChooseFolder = { [weak self] in self?.chooseFolder() }
            w.onNewFolder = { [weak self] name in self?.createSubfolder(name) ?? false }
            w.onRename = { [weak self] record, name in self?.rename(record, to: name) ?? false }
            w.onLiveView = { [weak self] on in self?.setLiveView(on) }
            w.onBack = { [weak self] in self?.goBackFolder() }
            w.onStatusToggle = { [weak self] key in self?.handleStatusToggle(key) }
            w.onFocusMain = { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.view.window?.makeKeyAndOrderFront(nil)
            }
            focusWindow = w
        }
        refreshFocusWindow(select: photos.last)
        focusWindow?.canGoBack = !folderStack.isEmpty
        updateFocusStatuses()
        if let screen = focusWindow?.window?.screen ?? NSScreen.main {
            focusWindow?.window?.setFrame(screen.visibleFrame, display: true)
        }
        focusWindow?.showWindow(nil)
        focusWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func movePhotos(_ urls: [URL], to folder: URL) {
        var moved: [(URL, URL)] = []
        for url in urls {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            guard target != url else { continue }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: url, to: target)
                moved.append((url, target))
            } catch {
                Logger.shared.warn("Move failed: \(error.localizedDescription)")
            }
        }
        for (old, new) in moved {
            if let index = photos.firstIndex(where: { $0.url == old }) {
                photos[index].url = new
                photos[index].name = new.lastPathComponent
            }
            transfer.propagateRename(from: old, to: new)
        }
        photosView.setPhotos(photos)
        // photosView.setRoot(URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath))
        Logger.shared.info("Moved \(moved.count) file(s) → \(folder.lastPathComponent)")
        transfer.mirrorSync()
    }

    func goBackFolder() {
        guard let previous = folderStack.popLast() else { return }
        prefs.downloadDirectory = previous
        prefs.save()
        Logger.shared.info("Download folder ← \(previous)")
        updateSessionUI()
        refreshFocusWindow(select: nil)
        focusWindow?.canGoBack = !folderStack.isEmpty
    }

    private func refreshFocusWindow(select: PhotoRecord?, isNew: Bool = false) {
        guard let focusWindow else { return }
        focusWindow.canGoBack = !folderStack.isEmpty
        focusWindow.update(folder: prefs.downloadDirectory,
                           session: camera.session.snapshot(),
                           photos: photos,
                           transfer: TransferStatusBroker.shared.summary)
        if let select { focusWindow.show(select, isNew: isNew) }
    }

    private func createSubfolder(_ name: String) -> Bool {
        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        let target = root.appendingPathComponent(NamePolicy.sanitize(name))
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            Logger.shared.warn("Could not create \(target.path): \(error.localizedDescription)")
            return false
        }
        folderStack.append(prefs.downloadDirectory)
        prefs.downloadDirectory = target.path
        prefs.save()
        Logger.shared.info("Download folder → \(target.path)")
        updateSessionUI()
        refreshFocusWindow(select: nil)
        return true
    }

    private func rename(_ record: PhotoRecord, to newBase: String) -> Bool {
        let ext = record.url.pathExtension
        let cleaned = NamePolicy.sanitize(newBase)
        let fileName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
        let target = record.url.deletingLastPathComponent().appendingPathComponent(fileName)
        guard target.path != record.url.path else { return true }
        do {
            try FileManager.default.moveItem(at: record.url, to: target)
        } catch {
            Logger.shared.warn("Rename failed: \(error.localizedDescription)")
            return false
        }
        if let index = photos.firstIndex(where: { $0.id == record.id }) {
            photos[index].url = target
            photos[index].name = target.lastPathComponent
            photosView.setPhotos(photos)
        }
        Logger.shared.info("Renamed \(record.name) → \(target.lastPathComponent)")
        if var last = focusWindow?.lastRecord, last.id == record.id {
            last.url = target
            last.name = target.lastPathComponent
            focusWindow?.lastRecord = last
        }
        return true
    }

    func clearCache() {
        let fm = FileManager.default
        let webp = fm.temporaryDirectory.appendingPathComponent("sonyTether-webp", isDirectory: true)
        try? fm.removeItem(at: webp)
        let sessionWebp = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
            .appendingPathComponent(TransferService.webpFolderName, isDirectory: true)
        try? fm.removeItem(at: sessionWebp)
        let caches = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sonyTether", isDirectory: true)
        try? fm.removeItem(at: caches)
        Logger.shared.info("Cache cleared (webp temp + thumbnails); settings kept")
    }

    func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier ?? "com.johorstudio.sonytether"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        Logger.shared.warn("All settings reset to defaults — restart the app to apply")
        prefs = Preferences.load()
        camera.prefs = prefs
        transfer.prefs = prefs
        updateSessionUI()
    }

    func revealCache() {
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([caches])
    }

    func syncAllNow() {
        transfer.syncAll(photos)
    }

    func adbPushLast() {
        guard let record = photos.last else { return }
        transfer.pushLast(record)
    }

    func adbDevicesToList() {
        let devices = transfer.adbDevices()
        Logger.shared.info("ADB devices: \(devices.isEmpty ? "none (enable USB debugging)" : devices.joined(separator: ", "))")
    }

    // MARK: Actions

    func captureNow() {
        guard captureStatus.connected else {
            Logger.shared.warn("Capture shortcut pressed, but no camera is connected")
            return
        }
        camera.capture()
    }

    func autofocus() { camera.autofocus() }

    func setLiveView(_ on: Bool) {
        liveOn = on
        camera.setLiveView(on)
        liveView.overlayText = on ? "" : "Live view off"
        if !on { liveView.image = nil }
        controls.update(status: captureStatus, controls: camera.controls, liveOn: on)
    }

    func toggleLog() {
        logVisible.toggle()
        logCard.isHidden = !logVisible
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.folderStack.append(self.prefs.downloadDirectory)
            self.prefs.downloadDirectory = url.path
            self.prefs.save()
            self.updateSessionUI()
            Logger.shared.info("Download folder → \(url.path)")
        }
    }

    func revealSessionFolder() {
        let url = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showClientView() {
        if clientView == nil {
            let controller = ClientViewWindowController()
            controller.onClose = { [weak self] in self?.clientView = nil }
            clientView = controller
        }
        let image = photos.last.flatMap { NSImage(contentsOf: $0.url) }
        clientView?.show(image: image)
        Logger.shared.info("Client View opened on \(NSScreen.screens.count > 1 ? "second display" : "main display")")
    }

    func showPhotos() {
        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        photosView.scanFolder(root)
        tabs.selectedSegment = 1
        updateTabs()
    }

    func showCapture() {
        tabs.selectedSegment = 0
        updateTabs()
    }

    func showShortcutRecorder() {
        tabs.selectedSegment = 2
        updateTabs()
    }

    func toggleLiveView() {
        setLiveView(!liveOn)
    }

    func windowWillClose(_ notification: Notification) {
        api.stop()
        camera.shutdown()
    }

    func runScript(_ kind: ScriptKind) {
        var settings = ScriptSettings()
        settings.kind = kind
        camera.startScript(settings)
    }

    func stopScript() { camera.stopScript() }

    func showPreferencesWindow() {
        PreferencesWindowController.present(prefs: prefs) { [weak self] updated in
            guard let self else { return }
            self.prefs = updated
            self.camera.prefs = updated
            if updated.apiEnabled {
                self.api.start(eventPort: updated.apiEventPort, replyPort: updated.apiReplyPort)
            } else {
                self.api.stop()
            }
            self.updateSessionUI()
            self.camera.refreshControls()
        }
    }

    // MARK: UI updates

    private func renderStatus(_ status: CameraStatus) {
        statusDot.layer?.backgroundColor = status.connected
            ? NSColor.systemGreen.cgColor
            : (status.connectAttempts > 0 ? NSColor.systemOrange.cgColor : NSColor.systemRed.cgColor)
        statusLabel.stringValue = status.connected
            ? "\(status.model) · \(status.battery ?? "—")"
            : "no camera"
        statusRight.stringValue = [
            "Session \(session.number)",
            "Batch \(session.batch)",
            "Seq \(session.sequence)",
            api.isRunning ? "API \(prefs.apiEventPort)/\(prefs.apiReplyPort)" : "API off",
        ].joined(separator: "  ·  ")
        if status.connected && liveOn && liveView.image == nil {
            liveView.overlayText = status.liveViewState == .running ? "" : "Live view \(status.liveViewState.rawValue.lowercased())…"
        }
        if !status.connected {
            liveView.overlayText = "No camera"
            liveView.image = nil
            fpsLabel.stringValue = ""
        }
    }

    private func updateSessionUI() {
        session = camera.session.snapshot()
        let preview = NamePolicy.expand(prefs.filenameExpression, NamePolicy.Context(
            originalName: "DSC00001",
            extensionName: "JPG",
            cameraName: captureStatus.model.isEmpty ? "camera" : captureStatus.model,
            serial: captureStatus.serial,
            session: session,
            appNodeName: prefs.appNodeName
        ))
        filenamePanel.render(session: session, preview: preview)
        let dir = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        let next = CameraService.nextSequence(prefix: prefs.filenamePrefix, in: dir)
        filenamePanel.renderPrefixes(prefs.prefixHistory, current: prefs.filenamePrefix, nextNumber: next)
        statusRight.stringValue = [
            "Session \(session.number)",
            "Batch \(session.batch)",
            "Seq \(session.sequence)",
            api.isRunning ? "API on" : "API off",
        ].joined(separator: "  ·  ")
    }

    private func applyPrefix(_ value: String) {
        let cleaned = NamePolicy.sanitize(value.trimmingCharacters(in: .whitespaces))
        guard !cleaned.isEmpty else { return }
        prefs.filenamePrefix = cleaned
        if !prefs.prefixHistory.contains(cleaned) {
            prefs.prefixHistory.append(cleaned)
            if prefs.prefixHistory.count > 20 { prefs.prefixHistory.removeFirst() }
        }
        prefs.save()
        camera.prefs = prefs
        updateSessionUI()
        Logger.shared.info("Filename prefix → \(cleaned) (next \(String(format: "%04d", CameraService.nextSequence(prefix: cleaned, in: URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)))))")
    }

    private func applySessionFromUI() {
        camera.session.name = filenamePanel.sessionNameField.stringValue
        camera.session.number = Int(filenamePanel.sessionNumberField.stringValue) ?? 1
        camera.session.batch = Int(filenamePanel.batchField.stringValue) ?? 1
        camera.session.uniqueTag = filenamePanel.uniqueTagField.stringValue
        updateSessionUI()
    }

    @objc private func tabChanged() { updateTabs() }

    @objc private func openPView() { showFocusWindow() }

    private func updateTabs() {
        let segment = tabs.selectedSegment
        captureArea.isHidden = segment != 0
        photosView.isHidden = segment != 1
        shortcutTab.isHidden = segment != 2
        adbTab.isHidden = segment != 3
        syncTab.isHidden = segment != 4
        if segment == 2 {
            shortcutTab.reload()
        } else if segment == 3 {
            adbTab.reload()
        } else if segment == 4 {
            syncTab.reload()
        }
        logCard.isHidden = !logVisible || segment >= 2
    }

    func applyPrefs(_ updated: Preferences) {
        prefs = updated
        prefs.save()
        camera.prefs = updated
        transfer.prefs = updated
        scheduleAutoRestart()
        updateSessionUI()
        refreshFocusWindow(select: nil)
        adbTab.reload()
        syncTab.reload()
    }

    private func scheduleAutoRestart() {
        restartTimer?.invalidate()
        restartTimer = nil
        guard prefs.adbRestartGalleryEnabled else { return }
        let interval = TimeInterval(max(1, prefs.adbRestartGalleryMinutes) * 60)
        Logger.shared.info("Phone gallery restart every \(Int(interval / 60)) min")
        restartTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.prefs.adbRestartGalleryEnabled else { return }
            Logger.shared.info("Restarting the gallery app on the phone")
            self.transfer.adbRestartGallery()
        }
    }

    func restartApplication() {
        api.stop()
        camera.shutdown()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    @objc private func zoomChanged() {
        liveView.zoom = CGFloat(zoomPopup.indexOfSelectedItem + 1)
    }

    @objc private func toggleGrid() { liveView.showGrid = gridCheck.state == .on }

    @objc private func rotateLive() {
        liveView.rotation = (liveView.rotation + 90) % 360
    }

    @objc private func enterFullScreen() {
        view.window?.toggleFullScreen(nil)
    }

    // MARK: API

    private func json(for record: PhotoRecord) -> [String: Any] {
        ["name": record.name, "path": record.url.path, "camera": record.camera,
         "width": record.width, "height": record.height, "format": record.format,
         "aperture": record.aperture, "shutter": record.shutter, "iso": record.iso,
         "bytes": record.bytes, "session": record.sessionNumber, "batch": record.batch,
         "tag": record.uniqueTag, "barcode": record.barcode]
    }

    private func handleAPI(_ command: [String: Any]) -> [String: Any] {
        let cmd = command["cmd"] as? String ?? ""
        switch cmd {
        case "status":
            return ["ok": true, "connected": captureStatus.connected,
                    "model": captureStatus.model, "battery": captureStatus.battery ?? "",
                    "session": session.number, "batch": session.batch,
                    "sequence": session.sequence, "folder": prefs.downloadDirectory]
        case "capture":
            captureNow()
            return ["ok": true, "queued": true]
        case "autofocus":
            autofocus()
            return ["ok": true]
        case "liveview":
            let on = command["on"] as? Bool ?? true
            setLiveView(on)
            return ["ok": true, "on": on]
        case "set":
            guard let name = command["name"] as? String, let value = command["value"] as? String else {
                return ["ok": false, "error": "name and value required"]
            }
            camera.setControl(name: name, value: value)
            return ["ok": true]
        case "session":
            if let name = command["name"] as? String { camera.session.name = name }
            if let number = command["number"] as? Int { camera.session.number = number }
            if let batch = command["batch"] as? Int { camera.session.batch = batch }
            if let tag = command["tag"] as? String { camera.session.uniqueTag = tag }
            DispatchQueue.main.async { self.updateSessionUI() }
            return ["ok": true]
        case "mirror":
            return ["ok": true, "result": transfer.mirrorSync()]
        case "scrcpy":
            return ["ok": true, "result": transfer.adbScrcpy()]
        case "refresh":
            return ["ok": true, "result": transfer.adbPullToRefresh()]
        case "controls":
            var out: [[String: Any]] = []
            for group in camera.controls {
                for item in group.items {
                    out.append(["group": group.title, "name": item.name, "label": item.label,
                                "value": item.current, "kind": item.kind.rawValue,
                                "choices": item.choices])
                }
            }
            return ["ok": true, "controls": out]
        case "photos":
            return ["ok": true, "photos": photos.map { json(for: $0) }]
        case "script":
            guard let name = command["name"] as? String,
                  let kind = ScriptKind(rawValue: name) else {
                return ["ok": false, "error": "unknown script"]
            }
            var settings = ScriptSettings()
            settings.kind = kind
            if let count = command["count"] as? Int { settings.count = max(1, count) }
            if let interval = command["interval"] as? Double { settings.interval = max(0.5, interval) }
            if let delay = command["delay"] as? Double { settings.delay = max(0, delay) }
            if let steps = command["steps"] as? Int { settings.steps = max(2, steps) }
            if let bulb = command["bulb"] as? Double { settings.bulbSeconds = max(1, bulb) }
            camera.startScript(settings)
            return ["ok": true, "script": name]
        default:
            return ["ok": false, "error": "unknown command \(cmd)"]
        }
    }
}
