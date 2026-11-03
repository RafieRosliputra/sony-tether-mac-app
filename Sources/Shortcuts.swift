import AppKit

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

    var display: String {
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
            if let key = raw["key"] as? String {
                let mods = NSEvent.ModifierFlags(rawValue: UInt(raw["mods"] as? Int ?? 0))
                return MenuShortcut(key: key, modifiers: mods)
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
