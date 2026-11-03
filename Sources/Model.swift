import Foundation

// MARK: - Preferences

/// Everything the user can change, persisted in UserDefaults.
struct Preferences {
    var downloadDirectory: String
    var filenameExpression: String
    var appNodeName: String
    var liveViewFPS: Int

    var autoConnect: Bool
    var resetSequenceOnLaunch: Bool
    var resetBatchOnLaunch: Bool
    var resetSequenceOnOptionsChange: Bool
    var resetBatchOnOptionsChange: Bool
    var autoFillSessionNameFromClipboard: Bool
    var autoFillUniqueTagFromClipboard: Bool
    var confirmCaptureOverwrite: Bool

    var apiEnabled: Bool
    var apiEventPort: Int
    var apiReplyPort: Int

    var lightroomEnabled: Bool
    var lightroomImportFolder: String

    var transferADBEnabled: Bool
    var adbPath: String
    var adbDevice: String
    var adbTargetFolder: String
    var transferSyncEnabled: Bool
    var syncFolder: String
    var syncMirrorTree: Bool

    var adbWirelessHost: String
    var adbWirelessPort: Int
    var adbOpenAfterPush: Bool
    var adbAutoPush: Bool
    var adbRestartAppEnabled: Bool
    var adbRestartAppMinutes: Int
    var adbGalleryPackage: String

    var barcodeEnabled: Bool
    var barcodeResetsSequence: Bool

    static func load() -> Preferences {
        let d = UserDefaults.standard
        func b(_ k: String, _ fallback: Bool) -> Bool {
            d.object(forKey: k) == nil ? fallback : d.bool(forKey: k)
        }
        func i(_ k: String, _ fallback: Int) -> Int {
            d.object(forKey: k) == nil ? fallback : d.integer(forKey: k)
        }
        let pictures = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/sonyTether", isDirectory: true).path
        return Preferences(
            downloadDirectory: d.string(forKey: "downloadDirectory") ?? pictures,
            filenameExpression: d.string(forKey: "filenameExpression") ?? "[D]_[T]_[S4].[E]",
            appNodeName: d.string(forKey: "appNodeName") ?? Host.current().localizedName ?? "mac",
            liveViewFPS: i("liveViewFPS", 15),
            autoConnect: b("autoConnect", true),
            resetSequenceOnLaunch: b("resetSequenceOnLaunch", false),
            resetBatchOnLaunch: b("resetBatchOnLaunch", false),
            resetSequenceOnOptionsChange: b("resetSequenceOnOptionsChange", false),
            resetBatchOnOptionsChange: b("resetBatchOnOptionsChange", false),
            autoFillSessionNameFromClipboard: b("autoFillSessionNameFromClipboard", false),
            autoFillUniqueTagFromClipboard: b("autoFillUniqueTagFromClipboard", false),
            confirmCaptureOverwrite: b("confirmCaptureOverwrite", true),
            apiEnabled: b("apiEnabled", false),
            apiEventPort: i("apiEventPort", 54643),
            apiReplyPort: i("apiReplyPort", 54644),
            lightroomEnabled: b("lightroomEnabled", false),
            lightroomImportFolder: d.string(forKey: "lightroomImportFolder") ?? "",
            transferADBEnabled: b("transferADBEnabled", false),
            adbPath: d.string(forKey: "adbPath") ?? "/opt/homebrew/bin/adb",
            adbDevice: d.string(forKey: "adbDevice") ?? "",
            adbTargetFolder: d.string(forKey: "adbTargetFolder") ?? "/sdcard/DCIM/sonyTether",
            transferSyncEnabled: b("transferSyncEnabled", false),
            syncFolder: d.string(forKey: "syncFolder") ?? "",
            syncMirrorTree: b("syncMirrorTree", true),
            adbWirelessHost: d.string(forKey: "adbWirelessHost") ?? "192.168.1.100",
            adbWirelessPort: i("adbWirelessPort", 5555),
            adbOpenAfterPush: b("adbOpenAfterPush", false),
            adbAutoPush: b("adbAutoPush", true),
            adbRestartAppEnabled: b("adbRestartAppEnabled", false),
            adbRestartAppMinutes: i("adbRestartAppMinutes", 5),
            adbGalleryPackage: d.string(forKey: "adbGalleryPackage") ?? "com.android.gallery3d",
            barcodeEnabled: b("barcodeEnabled", true),
            barcodeResetsSequence: b("barcodeResetsSequence", false)
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(downloadDirectory, forKey: "downloadDirectory")
        d.set(filenameExpression, forKey: "filenameExpression")
        d.set(appNodeName, forKey: "appNodeName")
        d.set(liveViewFPS, forKey: "liveViewFPS")
        d.set(autoConnect, forKey: "autoConnect")
        d.set(resetSequenceOnLaunch, forKey: "resetSequenceOnLaunch")
        d.set(resetBatchOnLaunch, forKey: "resetBatchOnLaunch")
        d.set(resetSequenceOnOptionsChange, forKey: "resetSequenceOnOptionsChange")
        d.set(resetBatchOnOptionsChange, forKey: "resetBatchOnOptionsChange")
        d.set(autoFillSessionNameFromClipboard, forKey: "autoFillSessionNameFromClipboard")
        d.set(autoFillUniqueTagFromClipboard, forKey: "autoFillUniqueTagFromClipboard")
        d.set(confirmCaptureOverwrite, forKey: "confirmCaptureOverwrite")
        d.set(apiEnabled, forKey: "apiEnabled")
        d.set(apiEventPort, forKey: "apiEventPort")
        d.set(apiReplyPort, forKey: "apiReplyPort")
        d.set(lightroomEnabled, forKey: "lightroomEnabled")
        d.set(lightroomImportFolder, forKey: "lightroomImportFolder")
        d.set(transferADBEnabled, forKey: "transferADBEnabled")
        d.set(adbPath, forKey: "adbPath")
        d.set(adbDevice, forKey: "adbDevice")
        d.set(adbTargetFolder, forKey: "adbTargetFolder")
        d.set(transferSyncEnabled, forKey: "transferSyncEnabled")
        d.set(syncFolder, forKey: "syncFolder")
        d.set(syncMirrorTree, forKey: "syncMirrorTree")
        d.set(adbWirelessHost, forKey: "adbWirelessHost")
        d.set(adbWirelessPort, forKey: "adbWirelessPort")
        d.set(adbOpenAfterPush, forKey: "adbOpenAfterPush")
        d.set(adbAutoPush, forKey: "adbAutoPush")
        d.set(adbRestartAppEnabled, forKey: "adbRestartAppEnabled")
        d.set(adbRestartAppMinutes, forKey: "adbRestartAppMinutes")
        d.set(adbGalleryPackage, forKey: "adbGalleryPackage")
        d.set(barcodeEnabled, forKey: "barcodeEnabled")
        d.set(barcodeResetsSequence, forKey: "barcodeResetsSequence")
    }
}

// MARK: - Session state

/// Session numbering, unique tag and barcode. Read from the camera queue, so
/// every access goes through the lock.
final class SessionState {
    private let lock = NSLock()
    private var _name = ""
    private var _number = 1
    private var _batch = 1
    private var _sequence = 1
    private var _uniqueTag = "CustomTag"
    private var _barcode = ""

    var name: String {
        get { lock.withLock { _name } }
        set { lock.withLock { _name = newValue } }
    }
    var number: Int {
        get { lock.withLock { _number } }
        set { lock.withLock { _number = newValue } }
    }
    var batch: Int {
        get { lock.withLock { _batch } }
        set { lock.withLock { _batch = newValue } }
    }
    var sequence: Int {
        get { lock.withLock { _sequence } }
        set { lock.withLock { _sequence = newValue } }
    }
    var uniqueTag: String {
        get { lock.withLock { _uniqueTag } }
        set { lock.withLock { _uniqueTag = newValue } }
    }
    var barcode: String {
        get { lock.withLock { _barcode } }
        set { lock.withLock { _barcode = newValue } }
    }

    /// Takes the next sequence number for a capture.
    func nextSequence() -> Int {
        lock.withLock {
            let value = _sequence
            _sequence += 1
            return value
        }
    }

    func resetSequence(_ value: Int = 1) {
        lock.withLock { _sequence = value }
    }

    func snapshot() -> SessionSnapshot {
        lock.withLock {
            SessionSnapshot(name: _name, number: _number, batch: _batch,
                            sequence: _sequence, uniqueTag: _uniqueTag, barcode: _barcode)
        }
    }
}

struct SessionSnapshot {
    var name: String
    var number: Int
    var batch: Int
    var sequence: Int
    var uniqueTag: String
    var barcode: String
}

// MARK: - Name policy

/// Smart Shooter-style filename expression, e.g. `[D]_[T]_[S4].[E]`.
/// Tokens: [N] session name, [I] session number, [S] sequence, [B] batch,
/// [C] camera name, [A] app/node, [U] unique tag, [Z] barcode,
/// [E] extension, [D] date, [T] time, [M] milliseconds, [G] group,
/// [X] serial, [o] original name. A width suffix sets zero padding: [S4].
/// A "/" creates a subfolder.
enum NamePolicy {
    struct Context {
        var originalName: String
        var extensionName: String
        var cameraName: String
        var serial: String
        var session: SessionSnapshot
        var appNodeName: String
        var date: Date = Date()

        func value(_ token: Character, _ width: Int) -> String {
            let df = DateFormatter()
            let raw: String
            switch token {
            case "N": raw = session.name
            case "I": raw = String(session.number)
            case "S": raw = String(session.sequence)
            case "B": raw = String(session.batch)
            case "C": raw = cameraName
            case "A": raw = appNodeName
            case "U": raw = session.uniqueTag
            case "Z": raw = session.barcode
            case "E": raw = extensionName
            case "o": raw = originalName
            case "X": raw = serial
            case "G": raw = "single"
            case "D":
                df.dateFormat = "yyyy-MM-dd"
                raw = df.string(from: date)
            case "T":
                df.dateFormat = "HHmmss"
                raw = df.string(from: date)
            case "M":
                df.dateFormat = "SSS"
                raw = df.string(from: date)
            default:
                return "[\(token)]"
            }
            if width > 0, token == "S" || token == "I" || token == "B" {
                return String(repeating: "0", count: max(0, width - raw.count)) + raw
            }
            return raw
        }
    }

    static func expand(_ expression: String, _ context: Context) -> String {
        var out = ""
        var i = expression.startIndex
        while i < expression.endIndex {
            let ch = expression[i]
            if ch == "[" {
                if let close = expression[i...].firstIndex(of: "]") {
                    let body = expression[expression.index(after: i)..<close]
                    if let token = body.first {
                        var digits = ""
                        for c in body.dropFirst() where c.isNumber { digits.append(c) }
                        out += context.value(token, Int(digits) ?? 0)
                        i = expression.index(after: close)
                        continue
                    }
                }
            }
            out.append(ch)
            i = expression.index(after: i)
        }
        return out
    }

    /// Splits a path expression into directory components and the file name,
    /// sanitising each component.
    static func resolve(expression: String, context: Context) -> (subdirectory: String, fileName: String) {
        let expanded = expand(expression, context)
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitize(String($0)) }
        guard let file = parts.last else { return ("", "untitled") }
        let dir = parts.dropLast().joined(separator: "/")
        return (dir, file)
    }

    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")

    static func sanitize(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}

// MARK: - Lock helper

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
