import AppKit

// MARK: - Shortcuts tab

final class ShortcutTabView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (() -> Void)?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = makeLabel("", size: 10, color: .tertiaryLabelColor)
    private var pending: AppAction?
    private let actions = AppAction.allCases

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = makeLabel("Keyboard Shortcuts", size: 13, weight: .semibold)
        let note = makeLabel("Menu shortcuts apply while sonyTether is frontmost. "
            + "The global capture trigger (sidebar) works in the background.",
            size: 10, color: .secondaryLabelColor)

        for (id, name, width) in [("action", "Action", 240.0), ("key", "Shortcut", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = name
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let set = makeButton("Set…", target: self, action: #selector(setShortcut))
        let clear = makeButton("Clear", target: self, action: #selector(clearShortcut))
        let reset = makeButton("Reset All", target: self, action: #selector(resetAll))
        let buttons = NSStackView(views: [set, clear, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, note, buttons, scroll, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        detail.stringValue = "Select a row, then Set…"
    }

    func reload() { table.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < actions.count else { return nil }
        let action = actions[row]
        let text = column.identifier.rawValue == "action"
            ? action.title
            : (ShortcutStore.shared.shortcut(for: action)?.display ?? "—")
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = NSFont.systemFont(ofSize: 11)
        }
        cell.stringValue = text
        return cell
    }

    @objc private func setShortcut() {
        let row = table.selectedRow
        guard row >= 0, row < actions.count else {
            detail.stringValue = "Select an action first."
            return
        }
        pending = actions[row]
        detail.stringValue = "Press a key combination for \(actions[row].title)…"
        let recorder = ShortcutRecorderViewController()
        recorder.onShortcut = { [weak self] captured in
            guard let self, let action = self.pending else { return }
            if let menuShortcut = Self.menuShortcut(from: captured) {
                ShortcutStore.shared.set(menuShortcut, for: action)
                self.detail.stringValue = "\(action.title) → \(menuShortcut.display)"
                self.onChange?()
            } else {
                self.detail.stringValue = "That key cannot be used as a menu shortcut."
            }
            self.table.reloadData()
        }
        recorder.onCancel = { [weak self] in self?.detail.stringValue = "Cancelled." }
        window?.contentViewController?.presentAsSheet(recorder)
    }

    @objc private func clearShortcut() {
        let row = table.selectedRow
        guard row >= 0, row < actions.count else { return }
        ShortcutStore.shared.set(nil, for: actions[row])
        table.reloadData()
        onChange?()
    }

    @objc private func resetAll() {
        ShortcutStore.shared.resetAll()
        table.reloadData()
        detail.stringValue = "Reset to defaults."
        onChange?()
    }

    private static func menuShortcut(from captured: CaptureShortcut) -> MenuShortcut? {
        guard captured.mouseButton == nil, captured.keyCode != nil else { return nil }
        let key = captured.keyLabel
        guard !key.isEmpty else { return nil }
        let mods = captured.modifierFlags
        switch key {
        case "Return", "Tab", "Space", "Delete", "Esc":
            return MenuShortcut(key: key, modifiers: mods)
        default:
            guard key.count == 1 else { return nil }
            return MenuShortcut(key: key.lowercased(), modifiers: mods)
        }
    }
}

// MARK: - ADB tab

final class ADBTabView: NSView {
    var prefProvider: () -> Preferences = { Preferences.load() }
    var onCommit: ((Preferences) -> Void)?
    var service: TransferService?
    var onRequestADB: ((String) -> Void)?

    private let enabled = NSButton(checkboxWithTitle: "Enable ADB transfer", target: nil, action: nil)
    private let autoPush = NSButton(checkboxWithTitle: "Push automatically after every capture", target: nil, action: nil)
    private let openAfter = NSButton(checkboxWithTitle: "Open the photo on the phone after sending", target: nil, action: nil)
    private let adbPath = NSTextField()
    private let device = NSTextField()
    private let targetFolder = NSTextField()
    private let wirelessHost = NSTextField()
    private let wirelessPort = NSTextField()
    private let galleryPkg = NSTextField()
    private let restartEnabled = NSButton(checkboxWithTitle: "Restart the gallery app on the phone automatically", target: nil, action: nil)
    private let fullBrightness = NSButton(checkboxWithTitle: "Force full brightness on the phone", target: nil, action: nil)
    private let stayAwake = NSButton(checkboxWithTitle: "Keep the phone screen on (no sleep)", target: nil, action: nil)
    private let restartMinutes = NSTextField()
    private let status = makeLabel("", size: 10, color: .secondaryLabelColor)
    private let output = NSTextView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for f in [adbPath, device, targetFolder, wirelessHost, wirelessPort, galleryPkg, restartMinutes] {
            f.delegate = self
            f.font = NSFont.systemFont(ofSize: 11)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
        }
        adbPath.widthAnchor.constraint(equalToConstant: 260).isActive = true
        device.widthAnchor.constraint(equalToConstant: 180).isActive = true
        targetFolder.widthAnchor.constraint(equalToConstant: 260).isActive = true
        wirelessHost.widthAnchor.constraint(equalToConstant: 150).isActive = true
        wirelessPort.widthAnchor.constraint(equalToConstant: 60).isActive = true
        galleryPkg.widthAnchor.constraint(equalToConstant: 220).isActive = true
        restartMinutes.widthAnchor.constraint(equalToConstant: 50).isActive = true

        for check in [enabled, autoPush, openAfter, restartEnabled, fullBrightness, stayAwake] {
            check.target = self
            check.action = #selector(changed)
        }

        let connect = makeButton("Connect wireless", target: self, action: #selector(connectWireless))
        let kill = makeButton("Kill server", target: self, action: #selector(killServer))
        let start = makeButton("Start server", target: self, action: #selector(startServer))
        let gallery = makeButton("Open gallery", target: self, action: #selector(openGallery))
        let restartGallery = makeButton("Restart gallery", target: self, action: #selector(restartGallery))
        let deleteAll = makeButton("Delete all photos on device", target: self, action: #selector(deleteAll))
        let devices = makeButton("Devices", target: self, action: #selector(listDevices))
        deleteAll.contentTintColor = .systemRed

        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let l = makeLabel(label, size: 11, color: .secondaryLabelColor)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let s = NSStackView(views: [l] + views)
            s.orientation = .horizontal
            s.spacing = 6
            s.alignment = .centerY
            return s
        }

        output.isEditable = false
        output.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        output.drawsBackground = true
        output.backgroundColor = .textBackgroundColor
        let outputScroll = NSScrollView()
        outputScroll.documentView = output
        outputScroll.hasVerticalScroller = true
        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        outputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        outputScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let stack = NSStackView(views: [
            makeSectionLabel("ADB"), enabled, autoPush, openAfter,
            row("adb binary", [adbPath]),
            row("Device", [device, devices]),
            row("Photos go to", [targetFolder]),
            makeSectionLabel("Wireless"),
            row("Host", [wirelessHost]),
            row("Port", [wirelessPort, connect]),
            makeSectionLabel("Server"),
            row("", [kill, start]),
            makeSectionLabel("Gallery"),
            row("Package", [galleryPkg]),
            row("", [gallery, restartGallery]),
            makeSectionLabel("Maintenance"),
            row("", [deleteAll]),
            makeSectionLabel("Phone control"),
            row("", [makeButton("Open scrcpy", target: self, action: #selector(openScrcpy)),
                     makeButton("Pull to refresh", target: self, action: #selector(pullToRefresh))]),
            makeSectionLabel("Phone display"),
            fullBrightness, stayAwake,
            row("", [makeButton("Apply to phone", target: self, action: #selector(applyDisplaySettings))]),
            makeSectionLabel("Auto restart (phone gallery)"),
            row("Every", [restartMinutes, makeLabel("minutes", size: 11)]),
            restartEnabled,
            status,
            outputScroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])
        reload()
    }

    func reload() {
        let p = prefProvider()
        enabled.state = p.transferADBEnabled ? .on : .off
        autoPush.state = p.adbAutoPush ? .on : .off
        openAfter.state = p.adbOpenAfterPush ? .on : .off
        adbPath.stringValue = p.adbPath
        device.stringValue = p.adbDevice
        targetFolder.stringValue = p.adbTargetFolder
        wirelessHost.stringValue = p.adbWirelessHost
        wirelessPort.stringValue = "\(p.adbWirelessPort)"
        galleryPkg.stringValue = p.adbGalleryPackage
        restartEnabled.state = p.adbRestartGalleryEnabled ? .on : .off
        restartMinutes.stringValue = "\(p.adbRestartGalleryMinutes)"
        fullBrightness.state = p.adbFullBrightness ? .on : .off
        stayAwake.state = p.adbStayAwake ? .on : .off
        status.stringValue = TransferStatusBroker.shared.summary
    }

    private func commit() {
        var p = prefProvider()
        p.transferADBEnabled = enabled.state == .on
        p.adbAutoPush = autoPush.state == .on
        p.adbOpenAfterPush = openAfter.state == .on
        p.adbPath = adbPath.stringValue
        p.adbDevice = device.stringValue
        p.adbTargetFolder = targetFolder.stringValue
        p.adbWirelessHost = wirelessHost.stringValue
        p.adbWirelessPort = Int(wirelessPort.stringValue) ?? 5555
        p.adbGalleryPackage = galleryPkg.stringValue
        p.adbRestartGalleryEnabled = restartEnabled.state == .on
        p.adbRestartGalleryMinutes = max(1, Int(restartMinutes.stringValue) ?? 5)
        p.adbFullBrightness = fullBrightness.state == .on
        p.adbStayAwake = stayAwake.state == .on
        onCommit?(p)
    }

    @objc private func changed() { commit() }

    private func run(_ title: String, _ body: @escaping () -> String) {
        status.stringValue = title + "…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = body()
            DispatchQueue.main.async {
                self.status.stringValue = result.isEmpty ? "\(title): done" : result
                self.output.string += "\(title): \(result)\n"
            }
        }
    }

    @objc private func connectWireless() {
        let host = wirelessHost.stringValue
        let port = Int(wirelessPort.stringValue) ?? 5555
        run("Connect") { self.service?.adbConnectWireless(host: host, port: port) ?? "no service" }
    }
    @objc private func killServer() { run("Kill server") { self.service?.adbKillServer() ?? "" } }
    @objc private func startServer() { run("Start server") { self.service?.adbStartServer() ?? "" } }
    @objc private func openGallery() { run("Open gallery") { self.service?.adbOpenGallery() ?? "" } }
    @objc private func restartGallery() { run("Restart gallery") { self.service?.adbRestartGallery() ?? "" } }

    @objc private func deleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete every photo on the device?"
        alert.informativeText = "Removes all files in \(targetFolder.stringValue) on the phone. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Delete all") { self.service?.adbDeleteAllOnDevice() ?? "" }
    }

    @objc private func openScrcpy() {
        run("scrcpy") { self.service?.adbScrcpy() ?? "" }
    }

    @objc private func pullToRefresh() {
        run("Pull to refresh") { self.service?.adbPullToRefresh() ?? "" }
    }

    @objc private func applyDisplaySettings() {
        status.stringValue = "Applying display settings…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.service?.adbApplyDisplaySettings() ?? ""
            DispatchQueue.main.async {
                self.status.stringValue = result.isEmpty ? "Display settings applied" : result
                self.output.string += "display: \(result)\n"
            }
        }
    }

    @objc private func listDevices() {
        run("Devices") {
            let devices = self.service?.adbDevices() ?? []
            return devices.isEmpty ? "no device attached" : devices.joined(separator: ", ")
        }
    }
}

extension ADBTabView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commit() }
}

// MARK: - Sync tab

final class SyncTabView: NSView {
    var prefProvider: () -> Preferences = { Preferences.load() }
    var onCommit: ((Preferences) -> Void)?
    var onSyncAll: (() -> Void)?

    private let enabled = NSButton(checkboxWithTitle: "Copy every capture to the sync folder", target: nil, action: nil)
    private let mirror = NSButton(checkboxWithTitle: "Keep the session subfolder structure", target: nil, action: nil)
    private let folder = NSTextField()
    private let status = makeLabel("", size: 10, color: .secondaryLabelColor)
    private let detail = makeLabel("", size: 10, color: .tertiaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        folder.font = NSFont.systemFont(ofSize: 11)
        folder.controlSize = .small
        folder.bezelStyle = .roundedBezel
        folder.widthAnchor.constraint(equalToConstant: 320).isActive = true
        for check in [enabled, mirror] {
            check.target = self
            check.action = #selector(changed)
        }
        let browse = makeButton("Browse…", target: self, action: #selector(browse))
        let syncNow = makeButton("Sync All Now", target: self, action: #selector(syncNowAction))
        let reveal = makeButton("Reveal Folder", target: self, action: #selector(reveal))

        let stack = NSStackView(views: [
            makeSectionLabel("Folder sync"),
            enabled,
            mirror,
            NSStackView(views: [folder, browse]),
            NSStackView(views: [syncNow, reveal]),
            status,
            detail,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        detail.stringValue = "Point this at a mounted NAS share (e.g. /Volumes/storage) or a local backup folder."
        reload()
    }

    func reload() {
        let p = prefProvider()
        enabled.state = p.transferSyncEnabled ? .on : .off
        mirror.state = p.syncMirrorTree ? .on : .off
        folder.stringValue = p.syncFolder
        status.stringValue = TransferStatusBroker.shared.summary
    }

    private func commit() {
        var p = prefProvider()
        p.transferSyncEnabled = enabled.state == .on
        p.syncMirrorTree = mirror.state == .on
        p.syncFolder = folder.stringValue
        onCommit?(p)
    }

    @objc private func changed() { commit() }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folder.stringValue = url.path
            commit()
        }
    }

    @objc private func syncNowAction() { onSyncAll?() }

    @objc private func reveal() {
        let path = (folder.stringValue as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
