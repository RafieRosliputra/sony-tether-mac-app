import AppKit

/// Preferences window with the five panes from Smart Shooter: General,
/// Name Policy, Barcode, External API, Lightroom.
final class PreferencesWindowController: NSWindowController {
    private var prefs: Preferences
    private var completion: ((Preferences) -> Void)?
    private static var current: PreferencesWindowController?

    private let tabView = NSTabView()

    // General
    private let folderField = NSTextField()
    private let fpsField = NSTextField()
    private let nodeField = NSTextField()
    private let autoConnectCheck = NSButton(checkboxWithTitle: "Auto connect cameras", target: nil, action: nil)

    // Name policy
    private let expressionField = NSTextField()
    private let previewLabel = NSTextField(labelWithString: "")
    private let resetSeqLaunch = NSButton(checkboxWithTitle: "Reset sequence number when the app starts", target: nil, action: nil)
    private let resetBatchLaunch = NSButton(checkboxWithTitle: "Reset batch number when the app starts", target: nil, action: nil)
    private let fillSession = NSButton(checkboxWithTitle: "Fill session name from the clipboard", target: nil, action: nil)
    private let fillTag = NSButton(checkboxWithTitle: "Fill unique tag from the clipboard", target: nil, action: nil)

    // Barcode
    private let barcodeEnabled = NSButton(checkboxWithTitle: "Accept barcode scanner input", target: nil, action: nil)
    private let barcodeResets = NSButton(checkboxWithTitle: "A new barcode resets the sequence number", target: nil, action: nil)

    // API
    private let apiEnabled = NSButton(checkboxWithTitle: "Enable External API", target: nil, action: nil)
    private let eventPortField = NSTextField()
    private let replyPortField = NSTextField()

    // Lightroom
    private let lightroomEnabled = NSButton(checkboxWithTitle: "Enable Lightroom Classic plugin support", target: nil, action: nil)
    private let lightroomStatus = NSTextField(labelWithString: "")

    static func present(prefs: Preferences, completion: @escaping (Preferences) -> Void) {
        let controller = PreferencesWindowController(prefs: prefs, completion: completion)
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(prefs: Preferences, completion: @escaping (Preferences) -> Void) {
        self.prefs = prefs
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "sonyTether Options"
        window.center()
        super.init(window: window)
        build()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 470))
        tabView.frame = NSRect(x: 0, y: 56, width: 620, height: 414)
        tabView.autoresizingMask = [.width, .height]
        container.addSubview(tabView)

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPrefs))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        apply.bezelStyle = .rounded
        cancel.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        ])
        window.contentView = container
        fill()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for (title, build) in [("General", buildGeneral), ("Name Policy", buildNamePolicy),
                               ("Barcode", buildBarcode), ("External API", buildAPI),
                               ("Lightroom", buildLightroom)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = build()
            tabView.addTabViewItem(item)
        }
    }

    private func pane() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
    }

    private func row(_ label: String, _ views: [NSView], width: CGFloat = 150) -> NSStackView {
        let l = makeLabel(label, size: 12, color: .secondaryLabelColor)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        let stack = NSStackView(views: [l] + views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    private func buildGeneral() -> NSView {
        let v = pane()
        autoConnectCheck.state = .on
        let browse = makeButton("Browse…", target: self, action: #selector(chooseFolder))
        folderField.font = NSFont.systemFont(ofSize: 11)
        fpsField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        nodeField.font = NSFont.systemFont(ofSize: 11)
        folderField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        fpsField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        nodeField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let stack = NSStackView(views: [
            makeSectionLabel("Photo download directory"),
            row("Folder", [folderField, browse]),
            makeSectionLabel("Camera"),
            row("Live view FPS", [fpsField]),
            row("App / node name", [nodeField]),
            makeSectionLabel("Application behaviour"),
            autoConnectCheck,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        return v
    }

    private func buildNamePolicy() -> NSView {
        let v = pane()
        expressionField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        expressionField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        expressionField.target = self
        expressionField.action = #selector(expressionChanged)
        expressionField.delegate = self
        previewLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor

        let help = NSTextField(labelWithString:
            "[N] session name   [I] session number   [S] sequence   [B] batch   [C] camera   "
            + "[A] app/node   [U] unique tag   [Z] barcode   [E] extension   [D] date   "
            + "[T] time   [M] ms   [X] serial   [o] original name\n"
            + "Add a width for zero padding: [S4]. A \"/\" creates a subfolder.")
        help.font = NSFont.systemFont(ofSize: 10)
        help.textColor = .tertiaryLabelColor
        help.maximumNumberOfLines = 3
        help.lineBreakMode = .byWordWrapping
        help.preferredMaxLayoutWidth = 540

        let stack = NSStackView(views: [
            makeSectionLabel("Filename expression"),
            row("Expression", [expressionField]),
            row("Preview", [previewLabel]),
            help,
            makeSectionLabel("Automation"),
            resetSeqLaunch, resetBatchLaunch, fillSession, fillTag,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        return v
    }

    private func buildBarcode() -> NSView {
        let v = pane()
        let note = NSTextField(labelWithString:
            "A USB barcode scanner types into the Barcode field. The value is available "
            + "in the filename as [Z] and can reset the sequence number.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [makeSectionLabel("Barcode"), barcodeEnabled, barcodeResets, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        return v
    }

    private func buildAPI() -> NSView {
        let v = pane()
        eventPortField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        replyPortField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        eventPortField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        replyPortField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let help = NSTextField(labelWithString:
            "Local JSON lines over TCP.\n"
            + "Events (port \(prefs.apiEventPort)): {\"event\":\"photo\",\"photo\":{…}}\n"
            + "Commands (port \(prefs.apiReplyPort)): {\"cmd\":\"capture\"} → {\"ok\":true}")
        help.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        help.textColor = .tertiaryLabelColor
        help.maximumNumberOfLines = 4
        help.lineBreakMode = .byWordWrapping
        help.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [
            makeSectionLabel("External API"),
            apiEnabled,
            row("Event port", [eventPortField]),
            row("Command port", [replyPortField]),
            help,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        return v
    }

    private func buildLightroom() -> NSView {
        let v = pane()
        let note = NSTextField(labelWithString:
            "The plugin lives in the app bundle (Contents/Resources/lightroom/sonyTether.lrplugin). "
            + "Install it once, then use File → Plug-in Manager in Lightroom Classic and point it "
            + "at that folder. In Lightroom, Photo → Plug-in Extras → sonyTether → Import session.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 5
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 520
        lightroomStatus.font = NSFont.systemFont(ofSize: 10)
        lightroomStatus.textColor = .tertiaryLabelColor

        let install = makeButton("Reveal plugin in Finder", target: self, action: #selector(revealPlugin))
        let stack = NSStackView(views: [
            makeSectionLabel("Lightroom Classic"),
            lightroomEnabled, note, install, lightroomStatus,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
        ])
        return v
    }

    // MARK: Fill / collect

    private func fill() {
        folderField.stringValue = prefs.downloadDirectory
        fpsField.stringValue = "\(prefs.liveViewFPS)"
        nodeField.stringValue = prefs.appNodeName
        autoConnectCheck.state = prefs.autoConnect ? .on : .off

        expressionField.stringValue = prefs.filenameExpression
        resetSeqLaunch.state = prefs.resetSequenceOnLaunch ? .on : .off
        resetBatchLaunch.state = prefs.resetBatchOnLaunch ? .on : .off
        fillSession.state = prefs.autoFillSessionNameFromClipboard ? .on : .off
        fillTag.state = prefs.autoFillUniqueTagFromClipboard ? .on : .off
        updatePreview()

        barcodeEnabled.state = prefs.barcodeEnabled ? .on : .off
        barcodeResets.state = prefs.barcodeResetsSequence ? .on : .off

        apiEnabled.state = prefs.apiEnabled ? .on : .off
        eventPortField.stringValue = "\(prefs.apiEventPort)"
        replyPortField.stringValue = "\(prefs.apiReplyPort)"

        lightroomEnabled.state = prefs.lightroomEnabled ? .on : .off
        updateLightroomStatus()
    }

    private func collect() -> Preferences {
        var p = prefs
        p.downloadDirectory = folderField.stringValue
        p.liveViewFPS = max(1, min(30, Int(fpsField.stringValue) ?? 15))
        p.appNodeName = nodeField.stringValue
        p.autoConnect = autoConnectCheck.state == .on
        p.filenameExpression = expressionField.stringValue
        p.resetSequenceOnLaunch = resetSeqLaunch.state == .on
        p.resetBatchOnLaunch = resetBatchLaunch.state == .on
        p.autoFillSessionNameFromClipboard = fillSession.state == .on
        p.autoFillUniqueTagFromClipboard = fillTag.state == .on
        p.barcodeEnabled = barcodeEnabled.state == .on
        p.barcodeResetsSequence = barcodeResets.state == .on
        p.apiEnabled = apiEnabled.state == .on
        p.apiEventPort = Int(eventPortField.stringValue) ?? 54643
        p.apiReplyPort = Int(replyPortField.stringValue) ?? 54644
        p.lightroomEnabled = lightroomEnabled.state == .on
        return p
    }

    private func updatePreview() {
        let context = NamePolicy.Context(originalName: "DSC00001", extensionName: "JPG",
                                         cameraName: "ILCE-7RM3", serial: "0",
                                         session: SessionSnapshot(name: "event", number: 1, batch: 1,
                                                                  sequence: 42, uniqueTag: "TAG",
                                                                  barcode: "BARCODE"),
                                         appNodeName: nodeField.stringValue)
        previewLabel.stringValue = NamePolicy.expand(expressionField.stringValue, context)
    }

    private func updateLightroomStatus() {
        guard let resources = Bundle.main.resourceURL else { return }
        let plugin = resources.appendingPathComponent("lightroom/sonyTether.lrplugin")
        lightroomStatus.stringValue = FileManager.default.fileExists(atPath: plugin.path)
            ? "Plugin bundled ✓" : "Plugin not bundled in this build"
    }

    @objc private func expressionChanged() { updatePreview() }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            folderField.stringValue = url.path
        }
    }

    @objc private func revealPlugin() {
        guard let resources = Bundle.main.resourceURL else { return }
        let plugin = resources.appendingPathComponent("lightroom/sonyTether.lrplugin")
        NSWorkspace.shared.activateFileViewerSelecting([plugin])
    }

    // MARK: Buttons

    @objc private func applyPrefs() {
        let updated = collect()
        updated.save()
        dismissWindow()
        completion?(updated)
    }

    @objc private func cancel() { dismissWindow() }

    private func dismissWindow() {
        window?.sheetParent?.endSheet(window!)
        window?.close()
        PreferencesWindowController.current = nil
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === expressionField { updatePreview() }
    }
}
