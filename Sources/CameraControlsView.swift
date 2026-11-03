import AppKit

// MARK: - Small builders

func makeLabel(_ text: String, size: CGFloat = 12,
               weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle
    return l
}

func makeSectionLabel(_ text: String) -> NSTextField {
    makeLabel(text.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
}

func makeButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .small
    return b
}

private let panelBackground = NSColor.underPageBackgroundColor

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Camera controls panel

final class CameraControlsView: NSView {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onCapture: (() -> Void)?
    var onAutofocus: (() -> Void)?
    var onLiveView: ((Bool) -> Void)?
    var onSet: ((String, String) -> Void)?
    var onStep: ((String, Int) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let cameraName = makeLabel("no camera", size: 11, weight: .medium)
    private let batteryLabel = makeLabel("—", size: 11)
    private let storageLabel = makeLabel("—", size: 11)
    private let liveLabel = makeLabel("off", size: 10, color: .secondaryLabelColor)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let shootButton = NSButton(title: "Shoot", target: nil, action: nil)
    private let afButton = NSButton(title: "Auto Focus", target: nil, action: nil)
    private let liveCheck = NSButton(checkboxWithTitle: "Enable live view", target: nil, action: nil)

    private var lastControls: [ControlGroup] = []
    private var controlRows: [String: NSPopUpButton] = [:]
    private var inserted: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = panelBackground.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = makeLabel("Camera Controls", size: 13, weight: .semibold)

        cameraName.textColor = .secondaryLabelColor

        connectButton.target = self; connectButton.action = #selector(connect)
        disconnectButton.target = self; disconnectButton.action = #selector(disconnect)
        shootButton.target = self; shootButton.action = #selector(shoot)
        afButton.target = self; afButton.action = #selector(autofocus)
        liveCheck.target = self; liveCheck.action = #selector(toggleLive)
        for b in [connectButton, disconnectButton, shootButton, afButton] { b.controlSize = .small; b.bezelStyle = .rounded }
        shootButton.bezelColor = .controlAccentColor
        shootButton.contentTintColor = .white

        let cameraRow = NSStackView(views: [cameraName])
        cameraRow.orientation = .horizontal
        let connectRow = NSStackView(views: [connectButton, disconnectButton])
        connectRow.orientation = .horizontal; connectRow.spacing = 6
        let shootRow = NSStackView(views: [shootButton, afButton])
        shootRow.orientation = .horizontal; shootRow.spacing = 6

        let powerTitle = makeLabel("Power", size: 10, color: .secondaryLabelColor)
        let storageTitle = makeLabel("Storage", size: 10, color: .secondaryLabelColor)
        let infoRow = NSStackView(views: [powerTitle, batteryLabel, storageTitle, storageLabel])
        infoRow.orientation = .horizontal; infoRow.spacing = 6

        let liveRow = NSStackView(views: [liveCheck, liveLabel])
        liveRow.orientation = .horizontal; liveRow.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, cameraRow, connectRow, shootRow, infoRow, liveRow] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
        }
        stack.setCustomSpacing(10, after: cameraRow)
        stack.setCustomSpacing(10, after: shootRow)
        stack.setCustomSpacing(10, after: liveRow)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    @objc private func connect() { onConnect?() }
    @objc private func disconnect() { onDisconnect?() }
    @objc private func shoot() { onCapture?() }
    @objc private func autofocus() { onAutofocus?() }
    @objc private func toggleLive() { onLiveView?(liveCheck.state == .on) }

    func update(status: CameraStatus, controls: [ControlGroup], liveOn: Bool) {
        cameraName.stringValue = status.connected
            ? (status.model.isEmpty ? "camera" : status.model)
            : (status.connectAttempts > 0 ? "searching…" : "no camera")
        batteryLabel.stringValue = status.battery ?? "—"
        storageLabel.stringValue = status.storage ?? "—"
        liveLabel.stringValue = status.connected ? status.liveViewState.rawValue : "off"
        connectButton.isEnabled = !status.connected
        disconnectButton.isEnabled = status.connected
        shootButton.isEnabled = status.connected
        afButton.isEnabled = status.connected
        liveCheck.isEnabled = status.connected
        liveCheck.state = liveOn ? .on : .off
        shootButton.bezelColor = status.connected ? .controlAccentColor : nil
        shootButton.contentTintColor = status.connected ? .white : nil

        if controls != lastControls {
            lastControls = controls
            rebuildControls(controls)
        }
    }

    private func rebuildControls(_ groups: [ControlGroup]) {
        controlRows.removeAll()
        for view in inserted {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        inserted.removeAll()
        for group in groups {
            let header = makeSectionLabel(group.title)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(4, after: header)
            inserted.append(header)
            for item in group.items {
                let r = row(for: item)
                stack.addArrangedSubview(r)
                inserted.append(r)
            }
        }
    }

    private func row(for item: ControlItem) -> NSStackView {
        let label = makeLabel(item.label, size: 11, color: .secondaryLabelColor)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: 11)
        if item.kind == .range {
            popup.addItem(withTitle: item.current)
            popup.isEnabled = true
        } else {
            popup.addItems(withTitles: item.choices)
            if let idx = item.choices.firstIndex(of: item.current) { popup.selectItem(at: idx) }
        }
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(item.name)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.widthAnchor.constraint(equalToConstant: 118).isActive = true
        controlRows[item.name] = popup

        let minus = NSButton(title: "−", target: self, action: #selector(stepDown(_:)))
        minus.bezelStyle = .inline; minus.isBordered = false; minus.controlSize = .small
        minus.identifier = NSUserInterfaceItemIdentifier(item.name)
        let plus = NSButton(title: "+", target: self, action: #selector(stepUp(_:)))
        plus.bezelStyle = .inline; plus.isBordered = false; plus.controlSize = .small
        plus.identifier = NSUserInterfaceItemIdentifier(item.name)
        minus.widthAnchor.constraint(equalToConstant: 16).isActive = true
        plus.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let row = NSStackView(views: [label, popup, minus, plus])
        row.orientation = .horizontal
        row.spacing = 2
        row.identifier = NSUserInterfaceItemIdentifier("controlRow")
        return row
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let item = lastControls.flatMap { $0.items }.first { $0.name == name }
        if item?.kind == .range { return }
        onSet?(name, sender.titleOfSelectedItem ?? "")
    }

    @objc private func stepDown(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onStep?(name, -1)
    }

    @objc private func stepUp(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onStep?(name, 1)
    }
}
