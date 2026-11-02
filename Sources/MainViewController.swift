import AppKit

// MARK: - Small helpers

private func makeLabel(
    _ text: String,
    size: CGFloat = 12,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private func makeSectionTitle(_ text: String) -> NSTextField {
    makeLabel(text.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
}

final class DotView: NSView {
    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

private final class LiveView: NSView {
    let imageView = NSImageView()
    let overlay = NSTextField(labelWithString: "")
    let chip = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        overlay.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        overlay.textColor = NSColor.white.withAlphaComponent(0.55)
        overlay.alignment = .center
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        chip.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        chip.textColor = NSColor.white.withAlphaComponent(0.6)
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Main view controller

final class MainViewController: NSViewController, NSWindowDelegate {
    private let service: CameraService
    private let log = Logger.shared

    private var status = CameraStatus()
    private var wantConnected = true
    private var liveWanted = true
    private var liveRequested = false

    // Header
    private let dot = DotView()
    private let connectionLabel = makeLabel("Starting…", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let connectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let captureButton = NSButton(title: "Capture", target: nil, action: nil)
    private let liveCheckbox = NSButton(checkboxWithTitle: "Live view", target: nil, action: nil)

    // Sidebar values
    private var rows: [String: NSTextField] = [:]
    private let folderLabel = makeLabel("—", size: 11, color: .secondaryLabelColor)
    private let lastFileLabel = makeLabel("", size: 11, color: .secondaryLabelColor)

    // Right side
    private let live = LiveView()
    private let logView = NSTextView()

    // MARK: - Init

    init(service: CameraService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
        view.wantsLayer = true
        buildUI()
        wire()
        renderStatus()
        renderFolder(service.destination)
        log.onLine = { [weak self] line in self?.appendLog(line) }
        for line in log.lines { appendLog(line) }
    }

    // MARK: - UI

    private func buildUI() {
        let header = buildHeader()
        let sidebar = buildSidebar()
        let content = buildContent()

        for v in [header, sidebar, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 58),

            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 320),

            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildHeader() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = makeLabel(AppInfo.name, size: 16, weight: .semibold)
        let version = makeLabel("v\(AppInfo.version) · Sony PTP tether", size: 10, color: .tertiaryLabelColor)
        let titleStack = NSStackView(views: [title, version])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true

        let statusStack = NSStackView(views: [dot, connectionLabel])
        statusStack.orientation = .horizontal
        statusStack.spacing = 7
        statusStack.alignment = .centerY

        connectButton.target = self
        connectButton.action = #selector(toggleConnect)
        connectButton.bezelStyle = .rounded

        captureButton.target = self
        captureButton.action = #selector(captureNow)
        captureButton.bezelStyle = .rounded
        captureButton.isEnabled = false
        captureButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true

        liveCheckbox.target = self
        liveCheckbox.action = #selector(toggleLiveView(_:))
        liveCheckbox.state = .on

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [liveCheckbox, captureButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let left = NSStackView(views: [titleStack, statusStack, spacer])
        left.orientation = .horizontal
        left.spacing = 16
        left.alignment = .centerY

        left.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(left)
        bar.addSubview(buttons)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
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

    private func buildSidebar() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
        ])

        func addSection(_ title: String, gap: CGFloat) {
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(gap, after: last)
            }
            stack.addArrangedSubview(makeSectionTitle(title))
        }

        func addRow(_ key: String, title: String) {
            let titleLabel = makeLabel(title, size: 11, color: .secondaryLabelColor)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
            let value = makeLabel("—", size: 11, weight: .medium)
            value.alignment = .right
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            rows[key] = value
            let row = NSStackView(views: [titleLabel, value])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSection("Camera", gap: 0)
        addRow("model", title: "Model")
        addRow("serial", title: "Serial")
        addRow("firmware", title: "Firmware")
        addRow("battery", title: "Battery")
        addRow("exposure", title: "Exposure")
        addRow("live", title: "Live view")

        addSection("Destination", gap: 14)
        folderLabel.maximumNumberOfLines = 2
        folderLabel.preferredMaxLayoutWidth = 284
        stack.addArrangedSubview(folderLabel)
        folderLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(4, after: folderLabel)

        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        let reveal = NSButton(title: "Show", target: self, action: #selector(revealFolder))
        reveal.bezelStyle = .rounded
        let buttons = NSStackView(views: [choose, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        addSection("Session", gap: 14)
        addRow("captures", title: "Captures")
        addRow("bytes", title: "Written")
        lastFileLabel.font = NSFont.systemFont(ofSize: 10)
        lastFileLabel.stringValue = "no captures yet"
        lastFileLabel.maximumNumberOfLines = 1
        stack.addArrangedSubview(lastFileLabel)
        lastFileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    private func buildContent() -> NSView {
        let container = NSView()

        let logPanel = NSView()
        logPanel.translatesAutoresizingMaskIntoConstraints = false

        let logTitle = makeSectionTitle("Log")
        logTitle.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clear.bezelStyle = .inline
        clear.isBordered = false
        clear.controlSize = .small
        let openLog = NSButton(title: "Reveal log file", target: self, action: #selector(revealLogFile))
        openLog.bezelStyle = .inline
        openLog.isBordered = false
        openLog.controlSize = .small

        let logButtons = NSStackView(views: [openLog, clear])
        logButtons.orientation = .horizontal
        logButtons.spacing = 10
        logButtons.translatesAutoresizingMaskIntoConstraints = false
        logPanel.addSubview(logTitle)
        logPanel.addSubview(logButtons)

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 8, height: 6)
        logView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = logView
        logPanel.addSubview(scroll)

        NSLayoutConstraint.activate([
            logTitle.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor, constant: 18),
            logTitle.topAnchor.constraint(equalTo: logPanel.topAnchor, constant: 10),
            logButtons.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor, constant: -18),
            logButtons.centerYAnchor.constraint(equalTo: logTitle.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: logTitle.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: logPanel.bottomAnchor),
        ])

        live.translatesAutoresizingMaskIntoConstraints = false
        live.overlay.stringValue = "Searching for camera…"

        container.addSubview(live)
        container.addSubview(logPanel)

        NSLayoutConstraint.activate([
            live.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            live.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            live.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            live.bottomAnchor.constraint(equalTo: logPanel.topAnchor, constant: -10),

            logPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            logPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            logPanel.heightAnchor.constraint(equalToConstant: 210),
        ])
        return container
    }

    // MARK: - Wiring

    private func wire() {
        service.onStatus = { [weak self] status in
            guard let self else { return }
            self.status = status
            self.renderStatus()
        }
        service.onFrame = { [weak self] data in
            self?.renderFrame(data)
        }
        service.onCapture = { [weak self] record in
            self?.lastFileLabel.stringValue = record.name
            self?.lastFileLabel.toolTip = record.url.path
        }
    }

    // MARK: - Actions (buttons)

    @objc private func toggleConnect() {
        wantConnected.toggle()
        if wantConnected {
            service.setConnected(true)
            if liveWanted {
                liveRequested = false
            }
            log.info("Connect requested")
        } else {
            service.setConnected(false)
            service.setLiveView(false)
            liveRequested = false
            live.imageView.image = nil
            live.overlay.stringValue = "No camera"
            live.chip.stringValue = ""
        }
        renderStatus()
    }

    @objc private func captureNow() {
        service.capture()
    }

    @objc private func toggleLiveView(_ sender: NSButton) {
        liveWanted = sender.state == .on
        guard status.connected else {
            if !liveWanted {
                service.setLiveView(false)
                liveRequested = false
            }
            renderStatus()
            return
        }
        service.setLiveView(liveWanted)
        liveRequested = liveWanted
        if !liveWanted {
            live.imageView.image = nil
            live.overlay.stringValue = "Live view off"
            live.chip.stringValue = ""
        }
        renderStatus()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Where should captured photos be saved?"
        panel.directoryURL = service.destination
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.service.destination = url
            UserDefaults.standard.set(url.path, forKey: "saveFolder")
            self.renderFolder(url)
            self.log.info("Capture folder changed → \(url.path)")
        }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([service.destination])
    }

    @objc private func revealLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }

    @objc private func clearLog() {
        logView.string = ""
    }

    // MARK: - Menu entry points

    func menuChooseFolder() { chooseFolder() }
    func menuRevealFolder() { revealFolder() }
    func menuRevealLog() { revealLogFile() }
    func menuToggleConnect() { toggleConnect() }
    func menuCapture() { service.capture() }
    func menuToggleLive() {
        liveCheckbox.state = liveCheckbox.state == .on ? .off : .on
        toggleLiveView(liveCheckbox)
    }

    // MARK: - Rendering

    private func renderStatus() {
        let s = status
        captureButton.isEnabled = s.connected
        if s.connected {
            captureButton.bezelColor = .controlAccentColor
            captureButton.contentTintColor = .white
        } else {
            captureButton.bezelColor = nil
            captureButton.contentTintColor = nil
        }

        if s.connected {
            dot.color = .systemGreen
            connectionLabel.stringValue = "Connected · \(s.model.isEmpty ? "camera" : s.model)"
            connectionLabel.textColor = .labelColor
            connectButton.title = "Disconnect"
        } else if wantConnected {
            dot.color = .systemOrange
            connectionLabel.stringValue = s.connectAttempts > 3
                ? "No camera · retrying every 2 s"
                : "Searching for camera…"
            connectionLabel.textColor = .secondaryLabelColor
            connectButton.title = "Stop"
        } else {
            dot.color = .systemRed
            connectionLabel.stringValue = "Not connected"
            connectionLabel.textColor = .secondaryLabelColor
            connectButton.title = "Connect"
        }

        rows["model"]?.stringValue = s.model.isEmpty ? "—" : s.model
        rows["serial"]?.stringValue = s.serial.isEmpty ? "—" : shortenSerial(s.serial)
        rows["firmware"]?.stringValue = s.firmware.isEmpty ? "—" : s.firmware
        rows["battery"]?.stringValue = s.battery ?? (s.connected ? "not exposed" : "—")
        rows["exposure"]?.stringValue = s.exposure ?? "—"
        rows["live"]?.stringValue = s.connected ? s.liveViewState.rawValue : "Off"
        rows["live"]?.toolTip = s.lastError
        rows["captures"]?.stringValue = "\(s.captures)"
        rows["bytes"]?.stringValue = Fmt.bytes(s.bytes)

        // Live view state text
        if !s.connected {
            live.overlay.stringValue = wantConnected ? "Searching for camera…" : "No camera"
            live.chip.stringValue = ""
        } else if s.liveViewState == .running {
            live.overlay.stringValue = ""
        } else if s.liveViewState == .starting {
            live.overlay.stringValue = "Starting live view…"
        } else if s.liveViewState == .failed {
            live.overlay.stringValue = "Live view unavailable"
            if let err = s.lastError { live.chip.stringValue = err }
        } else if s.liveViewState == .unsupported {
            live.overlay.stringValue = "Live view not supported by this body/setting"
        } else {
            live.overlay.stringValue = liveWanted ? "" : "Live view off"
        }

        // Auto-enable live view once a body is connected.
        if s.connected, liveWanted, !liveRequested, s.liveViewState == .off {
            liveRequested = true
            service.setLiveView(true)
        }
        if !s.connected {
            liveRequested = false
        }
        renderChip()
    }

    private func renderChip() {
        guard status.connected, status.liveViewState == .running,
              let image = live.imageView.image,
              let rep = image.representations.first else {
            if status.liveViewState != .failed { live.chip.stringValue = "" }
            return
        }
        live.chip.stringValue = "\(rep.pixelsWide)×\(rep.pixelsHigh) · "
            + String(format: "%.0f", status.liveFps) + " fps"
    }

    private func renderFrame(_ data: Data) {
        if let image = NSImage(data: data) {
            live.imageView.image = image
            live.overlay.stringValue = ""
            renderChip()
        }
    }

    private func renderFolder(_ url: URL) {
        folderLabel.stringValue = url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        folderLabel.toolTip = url.path
        lastFileLabel.toolTip = nil
    }

    private func shortenSerial(_ s: String) -> String {
        let masked = s.allSatisfy { $0 == "0" || $0 == "n" }
        return masked ? "masked by body" : s
    }

    // MARK: - Log rendering

    private func appendLog(_ line: Logger.Line) {
        guard let storage = logView.textStorage else { return }
        let color: NSColor
        switch line.level {
        case .error: color = .systemRed
        case .warn: color = .systemOrange
        case .debug: color = .tertiaryLabelColor
        case .info: color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: color,
        ]
        storage.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        if storage.length > 400_000 {
            storage.deleteCharacters(in: NSRange(location: 0, length: 100_000))
        }
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        service.shutdown()
    }
}
