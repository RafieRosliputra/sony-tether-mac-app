import AppKit
import Carbon.HIToolbox

/// A capture trigger that works while the app is in the background.
/// Either a keyboard chord (Carbon hot key, no permission needed) or an extra
/// mouse button (NSEvent global monitor, no permission needed for mouse).
struct CaptureShortcut: Equatable {
    var keyCode: UInt16?
    var keyLabel: String
    var modifiers: UInt
    var mouseButton: Int?

    static let none = CaptureShortcut(keyCode: nil, keyLabel: "", modifiers: 0, mouseButton: nil)

    var isSet: Bool { keyCode != nil || mouseButton != nil }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .option, .control, .shift])
    }

    var display: String {
        if let mouseButton {
            switch mouseButton {
            case 2: return "Mouse · middle"
            case 3: return "Mouse · back"
            case 4: return "Mouse · forward"
            default: return "Mouse · button \(mouseButton)"
            }
        }
        guard let keyCode else { return "not set" }
        _ = keyCode
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    /// Function keys are allowed without modifiers, everything else needs one.
    var isValid: Bool {
        if mouseButton != nil { return true }
        guard keyCode != nil else { return false }
        if !modifierFlags.isEmpty { return true }
        return keyLabel.hasPrefix("F") && (Int(keyLabel.dropFirst()) ?? 0) >= 1
    }

    // MARK: Persistence

    private static let key = "captureShortcut"

    static func load() -> CaptureShortcut {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return .defaultShortcut }
        let code = dict["keyCode"] as? Int
        let mods = dict["modifiers"] as? Int ?? 0
        let mouse = dict["mouseButton"] as? Int
        let mouseButton = (mouse ?? -1) >= 0 ? mouse : nil
        let label = dict["keyLabel"] as? String ?? ""
        return CaptureShortcut(keyCode: code.map { UInt16($0) }.flatMap { $0 >= 0 ? $0 : nil },
                               keyLabel: label,
                               modifiers: UInt(mods), mouseButton: mouseButton)
    }

    func save() {
        UserDefaults.standard.set([
            "keyCode": keyCode.map(Int.init) ?? -1,
            "keyLabel": keyLabel,
            "modifiers": Int(modifiers),
            "mouseButton": mouseButton ?? -1,
        ], forKey: Self.key)
    }

    /// Works out of the box: Ctrl+Option+C.
    static let defaultShortcut = CaptureShortcut(
        keyCode: 8, keyLabel: "C",
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
        mouseButton: nil
    )
}

/// Owns the global trigger. Registering a keyboard chord uses Carbon's
/// RegisterEventHotKey (no Accessibility prompt); mouse buttons use NSEvent
/// global monitors (mouse events do not need permission either).
final class HotKeyCenter {
    var onTrigger: (() -> Void)?

    private(set) var shortcut: CaptureShortcut = .none
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var mouseMonitors: [Any] = []
    private static let signature: OSType = 0x5374_684B // 'SthK'
    private static let log = Logger.shared

    var isRecording = false

    func start(with shortcut: CaptureShortcut) {
        apply(shortcut)
    }

    func apply(_ newValue: CaptureShortcut) {
        unregister()
        shortcut = newValue
        if newValue.keyCode != nil { registerKey(newValue) }
        if newValue.mouseButton != nil { registerMouse(newValue.mouseButton!) }
        Self.log.info("Capture shortcut: \(newValue.display)\(newValue.isSet ? " (global)" : "")")
    }

    func stop() {
        unregister()
    }

    // MARK: - Keyboard (Carbon)

    private func registerKey(_ shortcut: CaptureShortcut) {
        guard let keyCode = shortcut.keyCode else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.fire()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        guard status == noErr else {
            Self.log.warn("Global shortcut could not install handler (\(status))")
            return
        }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let reg = RegisterEventHotKey(UInt32(keyCode), carbonModifiers(shortcut.modifierFlags),
                                      id, GetApplicationEventTarget(), 0, &ref)
        if reg == noErr {
            hotKeyRef = ref
            Self.log.info("Global hotkey armed: \(shortcut.display) (works in the background)")
        } else {
            Self.log.warn("Global shortcut rejected by the system (code \(reg)) — pick another combination")
        }
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }

    // MARK: - Mouse

    private func registerMouse(_ button: Int) {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.buttonNumber == button else { return }
            self.fire()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown],
                                                          handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown], handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
        Self.log.info("Mouse button \(button) armed as capture trigger")
    }

    // MARK: - Fire

    private func fire() {
        guard !isRecording else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
    }

    deinit { unregister() }
}

// MARK: - Recorder sheet

/// Records the next key chord or extra mouse button press.
final class ShortcutRecorderViewController: NSViewController {
    var onShortcut: ((CaptureShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private let hintLabel = NSTextField(labelWithString: "Press a key combination, or a middle/back/forward mouse button.")
    private let valueLabel = NSTextField(labelWithString: "…")
    private let noteLabel = NSTextField(labelWithString: "Esc to cancel")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var captured: CaptureShortcut = .none
    private var monitors: [Any] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 168))
        root.wantsLayer = true

        let title = NSTextField(labelWithString: "Capture shortcut")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        valueLabel.alignment = .center
        valueLabel.stringValue = "waiting…"
        valueLabel.wantsLayer = true
        valueLabel.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        valueLabel.layer?.cornerRadius = 8

        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 10)

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false
        saveButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .inline
        clear.isBordered = false
        clear.controlSize = .small

        for v in [title, hintLabel, valueLabel, noteLabel, saveButton, cancel, clear] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            hintLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            valueLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            valueLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            valueLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            valueLabel.heightAnchor.constraint(equalToConstant: 46),

            noteLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            clear.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            clear.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            cancel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            saveButton.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            saveButton.bottomAnchor.constraint(equalTo: cancel.bottomAnchor),
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        installMonitors()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func installMonitors() {
        if let key = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }
            self.capture(keyCode: event.keyCode,
                         label: Self.label(for: event),
                         modifiers: event.modifierFlags.rawValue)
            return nil
        }) {
            monitors.append(key)
        }
        if let mouse = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            guard event.buttonNumber >= 2 else { return event }
            self.captured = CaptureShortcut(keyCode: nil, keyLabel: "", modifiers: 0,
                                            mouseButton: event.buttonNumber)
            self.valueLabel.stringValue = self.captured.display
            self.saveButton.isEnabled = true
            self.noteLabel.stringValue = "Click Save to use this mouse button."
            return nil
        }) {
            monitors.append(mouse)
        }
    }

    private func capture(keyCode: UInt16, label: String, modifiers: UInt) {
        var shortcut = CaptureShortcut(keyCode: keyCode, keyLabel: label,
                                       modifiers: modifiers, mouseButton: nil)
        if !shortcut.isValid {
            shortcut = CaptureShortcut(keyCode: keyCode, keyLabel: label,
                                       modifiers: NSEvent.ModifierFlags(rawValue: modifiers).rawValue,
                                       mouseButton: nil)
        }
        guard shortcut.isValid else {
            valueLabel.stringValue = "add a modifier"
            noteLabel.stringValue = "Needs ⌘, ⌥, ⌃ or ⇧ — unless it is an F-key."
            saveButton.isEnabled = false
            return
        }
        captured = shortcut
        valueLabel.stringValue = shortcut.display
        noteLabel.stringValue = "Works even when sonyTether is in the background."
        saveButton.isEnabled = true
    }

    private static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        default:
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return chars.isEmpty ? "key \(event.keyCode)" : chars
        }
    }

    @objc private func save() {
        guard captured.isSet else { return }
        onShortcut?(captured)
        closeSheet()
    }

    @objc private func clear() {
        onShortcut?(.none)
        closeSheet()
    }

    @objc private func cancel() {
        onCancel?()
        closeSheet()
    }

    private func closeSheet() {
        if let window = view.window {
            if let parent = window.sheetParent {
                parent.endSheet(window)
            } else {
                window.close()
            }
        }
    }
}
