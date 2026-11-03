import AppKit
import Carbon.HIToolbox

/// A menu action whose key equivalent the user can change.
enum AppAction: String, CaseIterable {
    case capture, autofocus, liveView, focusWindow, syncAll, adbPush, showPhotos, showCapture,
         toggleLog, preferences, restartApp

    var title: String {
        switch self {
        case .capture: return "Capture"
        case .autofocus: return "Auto Focus"
        case .liveView: return "Toggle Live View"
        case .focusWindow: return "New Display Window"
        case .syncAll: return "Sync All Now"
        case .adbPush: return "ADB Push Last Photo"
        case .showPhotos: return "Show Photos"
        case .showCapture: return "Show Capture"
        case .toggleLog: return "Toggle Log Viewer"
        case .preferences: return "Preferences…"
        case .restartApp: return "Restart App"
        }
    }

    var defaultShortcut: MenuShortcut? {
        switch self {
        case .capture: return MenuShortcut(key: "r", modifiers: [.command])
        case .autofocus: return MenuShortcut(key: "f", modifiers: [.command])
        case .liveView: return MenuShortcut(key: "l", modifiers: [.command])
        case .focusWindow: return MenuShortcut(key: "n", modifiers: [.command, .shift])
        case .syncAll: return nil
        case .adbPush: return nil
        case .showPhotos: return MenuShortcut(key: "2", modifiers: [.command])
        case .showCapture: return MenuShortcut(key: "1", modifiers: [.command])
        case .toggleLog: return MenuShortcut(key: "j", modifiers: [.command])
        case .preferences: return MenuShortcut(key: ",", modifiers: [.command])
        case .restartApp: return nil
        }
    }
}

struct MenuShortcut: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags
    var mouseButton: Int?

    init(key: String, modifiers: NSEvent.ModifierFlags, mouseButton: Int? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.mouseButton = mouseButton
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
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }

    var menuKey: String {
        switch key {
        case "Return": return "\r"
        case "Tab": return "\t"
        case "Space": return " "
        case "Delete": return "\u{8}"
        case "Esc": return "\u{1b}"
        default: return key.lowercased()
        }
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("sonyTether.shortcutsChanged")
}

/// Persisted overrides of the menu key equivalents.
final class ShortcutStore {
    static let shared = ShortcutStore()
    private let defaultsKey = "menuShortcuts"
    private var overrides: [String: [String: Any]] = [:]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
    }

    func shortcut(for action: AppAction) -> MenuShortcut? {
        if let raw = overrides[action.rawValue] {
            if raw["cleared"] as? Bool == true { return nil }
            let mouse = raw["mouse"] as? Int ?? -1
            if let key = raw["key"] as? String, !key.isEmpty {
                let mods = NSEvent.ModifierFlags(rawValue: UInt(raw["mods"] as? Int ?? 0))
                return MenuShortcut(key: key, modifiers: mods,
                                    mouseButton: mouse >= 0 ? mouse : nil)
            }
            if mouse >= 0 {
                return MenuShortcut(key: "", modifiers: [], mouseButton: mouse)
            }
        }
        if action == .preferences { return action.defaultShortcut }
        return action.defaultShortcut
    }

    func set(_ shortcut: MenuShortcut?, for action: AppAction) {
        if let shortcut {
            overrides[action.rawValue] = [
                "key": shortcut.key,
                "mods": Int(shortcut.modifiers.rawValue),
                "mouse": shortcut.mouseButton ?? -1,
            ]
        } else {
            overrides[action.rawValue] = ["cleared": true]
        }
        UserDefaults.standard.set(overrides, forKey: defaultsKey)
    }

    func resetAll() {
        overrides = [:]
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static let selectorMap: [String: AppAction] = [
        "capture:": .capture,
        "autoFocus:": .autofocus,
        "toggleLive:": .liveView,
        "showDisplayWindow:": .focusWindow,
        "syncAllNow:": .syncAll,
        "adbPushLast:": .adbPush,
        "showPhotos:": .showPhotos,
        "showCapture:": .showCapture,
        "toggleLog:": .toggleLog,
        "showPreferences:": .preferences,
        "restartApp:": .restartApp,
    ]

    /// Walks the whole menu tree and applies the stored shortcuts.
    func applyAll(to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { applyAll(to: submenu) }
            guard let action = item.action else { continue }
            if let mapped = Self.selectorMap[NSStringFromSelector(action)] {
                apply(mapped, to: item)
            }
        }
    }

    /// Menu key equivalents applied at menu build time.
    func apply(to menu: NSMenu) {
        for item in menu.items {
            guard let action = item.representedObject as? String,
                  let appAction = AppAction(rawValue: action) else {
                if let id = item.identifier?.rawValue, let appAction = AppAction(rawValue: id) {
                    apply(appAction, to: item)
                }
                continue
            }
            apply(appAction, to: item)
        }
    }

    private func apply(_ action: AppAction, to item: NSMenuItem) {
        if let shortcut = shortcut(for: action) {
            item.keyEquivalent = shortcut.menuKey
            item.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
}


/// Registers every configured action as a system-wide trigger: Carbon hot key
/// for keyboard chords (works with no modifiers too), NSEvent monitor for the
/// extra mouse buttons.
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()
    var handler: ((AppAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var mouseMonitors: [Any] = []
    private var actionForID: [UInt32: AppAction] = [:]
    private var actionForMouse: [Int: AppAction] = [:]
    private var installed = false
    private static let signature: OSType = 0x536E_7953 // 'SnyS'

    func reload() {
        unregister()
        installHandlerIfNeeded()
        var nextID: UInt32 = 1
        for action in AppAction.allCases {
            guard let shortcut = ShortcutStore.shared.shortcut(for: action) else { continue }
            if let mouse = shortcut.mouseButton {
                actionForMouse[mouse] = action
                continue
            }
            guard let keyCode = Self.keyCode(for: shortcut.key) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: nextID)
            var mods: UInt32 = 0
            if shortcut.modifiers.contains(.command) { mods |= UInt32(cmdKey) }
            if shortcut.modifiers.contains(.option) { mods |= UInt32(optionKey) }
            if shortcut.modifiers.contains(.control) { mods |= UInt32(controlKey) }
            if shortcut.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
            let reg = RegisterEventHotKey(UInt32(keyCode), mods, id,
                                          GetApplicationEventTarget(), 0, &ref)
            if reg == noErr, let ref {
                hotKeyRefs.append(ref)
                actionForID[nextID] = action
                nextID += 1
            } else {
                Logger.shared.warn("Shortcut \(action.title): system refused \(shortcut.display)")
            }
        }
        installMouseMonitors()
        Logger.shared.info("Global shortcuts: \(hotKeyRefs.count) keys, \(actionForMouse.count) mouse")
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == GlobalShortcuts.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            if let action = center.actionForID[hotKeyID.id] {
                DispatchQueue.main.async { center.handler?(action) }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func installMouseMonitors() {
        guard !actionForMouse.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, let action = self.actionForMouse[event.buttonNumber] else { return }
            DispatchQueue.main.async { self.handler?(action) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown], handler: handle) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown], handler: { event in
            handle(event); return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        actionForID.removeAll()
        actionForMouse.removeAll()
    }

    /// Maps a recorder label ("C", "F13", "Space") to a virtual key code.
    static func keyCode(for label: String) -> UInt16? {
        let map: [String: UInt16] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
            "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37, "J": 38,
            "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47,
            "Tab": 48, "Space": 49, "Return": 36, "Delete": 51, "Esc": 53,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98,
            "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105,
            "F14": 107, "F15": 113,
        ]
        return map[label.uppercased()]
    }
}
