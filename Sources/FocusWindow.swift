import AppKit

// MARK: - Transfer (ADB + folder sync)

final class TransferService {
    var prefs: Preferences
    private let queue = DispatchQueue(label: "com.johorstudio.sonytether.transfer", qos: .utility)
    private let log = Logger.shared
    private(set) var lastADBStatus = "—"
    private(set) var lastSyncStatus = "—"

    init(prefs: Preferences) { self.prefs = prefs }

    var adbBinary: String? {
        let candidates = [prefs.adbPath, "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        for path in candidates where !path.isEmpty {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to PATH lookup
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "adb"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func adbDevices() -> [String] {
        guard let adb = adbBinary else { return [] }
        let output = run(adb, ["devices"])
        return output.split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, parts[1].contains("device") else { return nil }
                return String(parts[0])
            }
    }

    /// Called for every new capture, on a background queue.
    func handle(_ record: PhotoRecord) {
        let prefs = self.prefs
        queue.async { [weak self] in
            guard let self else { return }
            if prefs.transferADBEnabled && prefs.adbAutoPush { self.adbPush(record, prefs: prefs) }
            if prefs.transferSyncEnabled { self.sync(record, prefs: prefs) }
        }
    }

    /// Keeps the server copy in step when a shot is renamed or moved.
    func propagateRename(from old: URL, to new: URL) {
        let prefs = self.prefs
        queue.async { [weak self] in
            guard let self else { return }
            if prefs.transferSyncEnabled {
                let folder = (prefs.syncFolder as NSString).expandingTildeInPath
                let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
                func relative(_ url: URL, ext: String) -> String {
                    var path = url.path
                    if path.hasPrefix(root.path) { path = String(path.dropFirst(root.path.count)) }
                    return (path as NSString).deletingPathExtension + "." + ext
                }
                let oldTarget = URL(fileURLWithPath: folder).appendingPathComponent(relative(old, ext: "webp"))
                let newTarget = URL(fileURLWithPath: folder).appendingPathComponent(relative(new, ext: "webp"))
                if FileManager.default.fileExists(atPath: oldTarget.path) {
                    try? FileManager.default.createDirectory(at: newTarget.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: oldTarget, to: newTarget)
                    self.log.info("Sync: moved \(oldTarget.lastPathComponent) → \(newTarget.lastPathComponent)")
                } else if let record = PhotoRecord(url: new, name: new.lastPathComponent,
                                                   camera: "", node: "", batch: 0, sessionNumber: 0,
                                                   sessionName: "", width: 0, height: 0, format: "",
                                                   aperture: "", shutter: "", iso: "", focalLength: "",
                                                   bytes: 0, capturedAt: Date(), uniqueTag: "", barcode: "") as PhotoRecord? {
                    self.sync(record, prefs: prefs)
                }
            }
            if prefs.transferADBEnabled, let adb = self.adbBinary, let serial = self.adbDevices().first {
                let target = prefs.adbTargetFolder
                let oldRemote = target + "/" + (old.lastPathComponent as NSString).deletingPathExtension + ".webp"
                let newRemote = target + "/" + (new.lastPathComponent as NSString).deletingPathExtension + ".webp"
                _ = self.run(adb, ["-s", serial, "shell", "mv", oldRemote, newRemote])
                self.log.info("ADB: moved \(oldRemote) → \(newRemote)")
            }
        }
    }

    /// Mirrors the whole download tree to the sync folder as WebP: new files
    /// are converted, moved files follow the new folder, removed files go away.
    @discardableResult
    func mirrorSync() -> String {
        let prefs = self.prefs
        guard prefs.transferSyncEnabled else { return "sync disabled" }
        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        let dest = URL(fileURLWithPath: (prefs.syncFolder as NSString).expandingTildeInPath)
        guard !prefs.syncFolder.isEmpty else { return "no sync folder" }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return "cannot read \(root.lastPathComponent)"
        }
        var expected = Set<String>()
        var copied = 0
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "tif", "tiff", "arw"].contains(ext) else { continue }
            var rel = file.path
            if rel.hasPrefix(root.path) { rel = String(rel.dropFirst(root.path.count)) }
            rel = (rel as NSString).deletingPathExtension + ".webp"
            let target = dest.appendingPathComponent(rel)
            expected.insert(target.path)
            if fm.fileExists(atPath: target.path) { continue }
            let record = PhotoRecord(url: file, name: file.lastPathComponent, camera: "", node: "",
                                     batch: 0, sessionNumber: 0, sessionName: "", width: 0, height: 0,
                                     format: "", aperture: "", shutter: "", iso: "", focalLength: "",
                                     bytes: 0, capturedAt: Date(), uniqueTag: "", barcode: "")
            guard let webp = webpVersion(of: record) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                try fm.copyItem(at: webp, to: target)
                copied += 1
            } catch {
                log.warn("Mirror: \(rel) failed (\(error.localizedDescription))")
            }
        }
        // Remove server copies whose source moved away.
        var removed = 0
        if let serverEnum = fm.enumerator(at: dest, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in serverEnum where file.pathExtension.lowercased() == "webp" {
                if !expected.contains(file.path) {
                    try? fm.removeItem(at: file)
                    removed += 1
                }
            }
        }
        let summary = "mirror: \(copied) copied, \(removed) removed"
        lastSyncStatus = summary
        log.info("Sync \(summary) → \(dest.path)")
        publish()
        return summary
    }

    func pushLast(_ record: PhotoRecord) {
        let prefs = self.prefs
        queue.async { [weak self] in self?.adbPush(record, prefs: prefs) }
    }

    // MARK: - ADB controls (used by the ADB tab)

    @discardableResult
    func adbConnectWireless(host: String, port: Int) -> String {
        guard let adb = adbBinary else { return "adb not found" }
        let out = run(adb, ["connect", "\(host):\(port)"])
        log.info("ADB connect \(host):\(port): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        return out
    }

    @discardableResult
    func adbKillServer() -> String {
        guard let adb = adbBinary else { return "adb not found" }
        let out = run(adb, ["kill-server"])
        log.info("ADB kill-server")
        return out
    }

    @discardableResult
    func adbStartServer() -> String {
        guard let adb = adbBinary else { return "adb not found" }
        let out = run(adb, ["start-server"])
        log.info("ADB start-server")
        return out
    }

    @discardableResult
    func adbOpenGallery() -> String {
        guard let adb = adbBinary, let serial = adbDevices().first else { return "no device" }
        let pkg = prefs.adbGalleryPackage
        let out = run(adb, ["-s", serial, "shell", "monkey", "-p", pkg,
                            "-c", "android.intent.category.LAUNCHER", "1"])
        log.info("ADB open gallery (\(pkg))")
        return out
    }

    @discardableResult
    func adbRestartGallery() -> String {
        guard let adb = adbBinary, let serial = adbDevices().first else { return "no device" }
        let pkg = prefs.adbGalleryPackage
        _ = run(adb, ["-s", serial, "shell", "am", "force-stop", pkg])
        let out = run(adb, ["-s", serial, "shell", "monkey", "-p", pkg,
                            "-c", "android.intent.category.LAUNCHER", "1"])
        log.info("ADB restart gallery (\(pkg))")
        return out
    }

    @discardableResult
    func adbDeleteAllOnDevice() -> String {
        guard let adb = adbBinary, let serial = adbDevices().first else { return "no device" }
        let target = prefs.adbTargetFolder.isEmpty ? "/sdcard/DCIM/sonyTether" : prefs.adbTargetFolder
        let out = run(adb, ["-s", serial, "shell", "rm", "-rf", target])
        log.warn("ADB delete all in \(target) on \(serial)")
        return out
    }

    func adbOpenOnDevice(_ remote: String, serial: String) {
        guard let adb = adbBinary else { return }
        let pkg = prefs.adbGalleryPackage
        // Make the gallery see the new file first.
        _ = run(adb, ["-s", serial, "shell", "am", "broadcast",
                      "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                      "-d", "file://\(remote)"])
        // Force the chosen gallery package instead of showing the chooser.
        _ = run(adb, ["-s", serial, "shell", "am", "start",
                      "-a", "android.intent.action.VIEW",
                      "-d", "file://\(remote)",
                      "-t", "image/*",
                      "-p", pkg,
                      "--activity-clear-top"])
    }

    @discardableResult
    func adbScrcpy() -> String {
        guard let scrcpy = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "scrcpy not installed (brew install scrcpy)"
        }
        // Scrcpy runs on the Mac and mirrors the phone. Some Android 14
        // devices fail the default encoder, so pin h264 and cap the size.
        var args = ["--no-audio", "--video-codec=h264", "--max-size=1280",
                    "--window-title=sonyTether scrcpy"]
        if let serial = adbDevices().first { args += ["-s", serial] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scrcpy)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "scrcpy failed: \(error.localizedDescription)" }
        log.info("scrcpy launched \(args.joined(separator: " "))")
        return "scrcpy launched"
    }

    @discardableResult
    func adbPullToRefresh() -> String {
        guard let adb = adbBinary, let serial = adbDevices().first else { return "no device" }
        // Bring the gallery forward, then pull down inside its list. Starting
        // around 45% of the screen avoids the notification shade.
        _ = run(adb, ["-s", serial, "shell", "monkey", "-p", prefs.adbGalleryPackage,
                      "-c", "android.intent.category.LAUNCHER", "1"])
        Thread.sleep(forTimeInterval: 0.8)
        let out = run(adb, ["-s", serial, "shell", "input", "swipe", "540", "900", "540", "1650", "400"])
        log.info("ADB pull-to-refresh in \(prefs.adbGalleryPackage)")
        return out
    }

    @discardableResult
    func adbApplyDisplaySettings() -> String {
        guard let adb = adbBinary, let serial = adbDevices().first else { return "no device" }
        var out = ""
        if prefs.adbFullBrightness {
            out += run(adb, ["-s", serial, "shell", "settings", "put", "system",
                             "screen_brightness", "255"])
            out += run(adb, ["-s", serial, "shell", "settings", "put", "system",
                             "screen_brightness_mode", "0"])
        }
        if prefs.adbStayAwake {
            out += run(adb, ["-s", serial, "shell", "svc", "power", "stayon", "true"])
            out += run(adb, ["-s", serial, "shell", "settings", "put", "system",
                             "screen_off_timeout", "2147483647"])
        }
        log.info("ADB display settings applied (brightness=\(prefs.adbFullBrightness), stayon=\(prefs.adbStayAwake))")
        return out
    }

    func syncAll(_ records: [PhotoRecord]) {
        let prefs = self.prefs
        queue.async { [weak self] in
            for record in records { self?.sync(record, prefs: prefs) }
        }
    }

    /// Android and the server both want WebP; convert with cwebp.
    func webpVersion(of record: PhotoRecord) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonyTether-webp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (record.name as NSString).deletingPathExtension
        let target = dir.appendingPathComponent(base + ".webp")
        if !FileManager.default.fileExists(atPath: target.path) {
            let result = run("/opt/homebrew/bin/cwebp",
                             ["-quiet", "-q", "50", record.url.path, "-o", target.path])
            if !FileManager.default.fileExists(atPath: target.path) {
                log.warn("WebP conversion failed: \(result)")
                return nil
            }
        }
        return target
    }

    private func adbPush(_ record: PhotoRecord, prefs: Preferences) {
        guard let adb = adbBinary else {
            lastADBStatus = "adb not found"
            log.warn("ADB: binary not found (Preferences → Transfer)")
            return
        }
        let devices = adbDevices()
        guard !devices.isEmpty else {
            lastADBStatus = "no device"
            log.warn("ADB: no device attached (enable USB debugging)")
            return
        }
        let serial = prefs.adbDevice.isEmpty ? devices[0] : prefs.adbDevice
        guard devices.contains(serial) || prefs.adbDevice.isEmpty else {
            lastADBStatus = "device \(serial) missing"
            log.warn("ADB: device \(serial) is not attached")
            return
        }
        let target = prefs.adbTargetFolder.isEmpty ? "/sdcard/DCIM/sonyTether" : prefs.adbTargetFolder
        guard let webp = webpVersion(of: record) else {
            lastADBStatus = "webp failed"
            log.warn("ADB: skipped \(record.name), WebP conversion failed")
            return
        }
        let remote = target.hasSuffix("/") ? target + webp.lastPathComponent : target + "/" + webp.lastPathComponent
        let output = run(adb, ["-s", serial, "push", webp.path, remote])
        if output.lowercased().contains("error") || output.lowercased().contains("failed") {
            lastADBStatus = "push failed"
            log.warn("ADB push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lastADBStatus = "pushed \(record.name)"
            log.info("ADB: \(record.name) → \(remote) (\(serial))")
            if prefs.adbOpenAfterPush { adbOpenOnDevice(remote, serial: serial) }
        }
        publish()
    }

    private func sync(_ record: PhotoRecord, prefs: Preferences) {
        let folder = (prefs.syncFolder as NSString).expandingTildeInPath
        guard !folder.isEmpty else {
            lastSyncStatus = "no folder set"
            return
        }
        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        var relative = record.url.path
        if relative.hasPrefix(root.path) {
            relative = String(relative.dropFirst(root.path.count))
        } else {
            relative = "/" + record.name
        }
        let webpName = (record.name as NSString).deletingPathExtension + ".webp"
        let relativeWebp = (relative as NSString).deletingPathExtension + ".webp"
        let target = URL(fileURLWithPath: folder).appendingPathComponent(relativeWebp)
        guard let webp = webpVersion(of: record) else {
            lastSyncStatus = "webp failed"
            log.warn("Sync: skipped \(record.name), WebP conversion failed")
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: webp, to: target)
            lastSyncStatus = "synced \(webpName)"
            log.info("Sync: \(webpName) → \(target.path)")
        } catch {
            lastSyncStatus = "sync failed"
            log.warn("Sync failed for \(record.name): \(error.localizedDescription)")
        }
        publish()
    }

    private func publish() {
        TransferStatusBroker.shared.summary = "ADB \(lastADBStatus) · Sync \(lastSyncStatus)"
        TransferStatusBroker.shared.adbOK = lastADBStatus.hasPrefix("pushed")
        TransferStatusBroker.shared.syncOK = lastSyncStatus.hasPrefix("synced")
        TransferStatusBroker.shared.adbEnabled = prefs.transferADBEnabled
        TransferStatusBroker.shared.syncEnabled = prefs.transferSyncEnabled
        TransferStatusBroker.shared.append("ADB \(lastADBStatus) · Sync \(lastSyncStatus)")
        DispatchQueue.main.async { NotificationCenter.default.post(name: .transferStatus, object: nil) }
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "error: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

extension Notification.Name {
    static let transferStatus = Notification.Name("sonyTether.transferStatus")
}

// MARK: - Focus / display window

final class FocusImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var showGrid = true { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var overlay = "" { didSet { needsDisplay = true } }

    private var offset: NSPoint = .zero
    private var dragStart: NSPoint?
    private var lastZoom: CGFloat = 1
    private var lastOffset: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, image.size.width > 0 else {
            drawOverlay()
            return
        }
        // The photo keeps a fixed letterboxed frame; zoom and pan happen
        // inside it, so nothing spills over the rest of the window.
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let baseSize = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let frame = NSRect(x: (bounds.width - baseSize.width) / 2,
                           y: (bounds.height - baseSize.height) / 2,
                           width: baseSize.width, height: baseSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()

        let scaled = NSSize(width: frame.width * zoom, height: frame.height * zoom)
        let maxX = max(0, (scaled.width - frame.width) / 2)
        let maxY = max(0, (scaled.height - frame.height) / 2)
        let panX = min(maxX, max(-maxX, offset.x))
        let panY = min(maxY, max(-maxY, offset.y))
        let target = NSRect(x: frame.midX - scaled.width / 2 + panX,
                            y: frame.midY - scaled.height / 2 + panY,
                            width: scaled.width, height: scaled.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)

        if showGrid {
            NSColor.white.withAlphaComponent(0.28).setStroke()
            let path = NSBezierPath()
            for i in 1..<3 {
                let x = frame.minX + frame.width * CGFloat(i) / 3
                path.move(to: NSPoint(x: x, y: frame.minY))
                path.line(to: NSPoint(x: x, y: frame.maxY))
                let y = frame.minY + frame.height * CGFloat(i) / 3
                path.move(to: NSPoint(x: frame.minX, y: y))
                path.line(to: NSPoint(x: frame.maxX, y: y))
            }
            path.lineWidth = 1
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawOverlay()
    }

    private func drawOverlay() {
        guard !overlay.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let s = NSAttributedString(string: overlay, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY / 120
        zoomAroundMouse(factor: factor, event: event)
    }

    override func magnify(with event: NSEvent) {
        zoomAroundMouse(factor: 1 + event.magnification, event: event)
    }

    private func zoomAroundMouse(factor: CGFloat, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let newZoom = max(0.1, zoom * factor)
        let ratio = newZoom / zoom
        offset = NSPoint(x: (offset.x + (point.x - center.x)) * ratio - (point.x - center.x),
                         y: (offset.y + (point.y - center.y)) * ratio - (point.y - center.y))
        zoom = newZoom
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // toggle fit ↔ previous zoom/position
            if zoom > 1.001 || offset != .zero {
                lastZoom = zoom
                lastOffset = offset
                zoom = 1
                offset = .zero
            } else {
                zoom = lastZoom
                offset = lastOffset
            }
            needsDisplay = true
            return
        }
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = event.locationInWindow
        offset.x += now.x - start.x
        offset.y += now.y - start.y
        dragStart = now
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }


}

final class OverviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var onResize: ((NSSize) -> Void)?
    var aspect: CGFloat = 3.0 / 2.0 { didSet { needsDisplay = true } }

    private var resizing = false
    private var startSize = NSSize.zero
    private var startPoint = NSPoint.zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        addCursorRect(resizeHandle, cursor: .crosshair)
    }

    /// The print aspect box inside the view.
    private var aspectRect: NSRect {
        let available = bounds.insetBy(dx: 2, dy: 2)
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                      width: width, height: height)
    }

    private var resizeHandle: NSRect {
        NSRect(x: bounds.maxX - 14, y: bounds.minY, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else { return }
        let viewport = aspectRect
        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height) * zoom
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let rect = NSRect(x: viewport.midX - size.width / 2 + offset.x,
                          y: viewport.midY - size.height / 2 + offset.y,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // resize grip
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        for i in 0..<3 {
            let inset = CGFloat(i) * 4
            path.move(to: NSPoint(x: bounds.maxX - 3 - inset, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + inset))
        }
        path.lineWidth = 1
        path.stroke()
    }

    private var offset: NSPoint = .zero
    private var dragStart: NSPoint?
    private var dragged = false

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let factor = 1 + event.scrollingDeltaY / 160
        let newZoom = max(0.2, zoom * factor)
        let ratio = newZoom / zoom
        offset = NSPoint(x: (offset.x + (point.x - center.x)) * ratio - (point.x - center.x),
                         y: (offset.y + (point.y - center.y)) * ratio - (point.y - center.y))
        zoom = newZoom
    }

    override func magnify(with event: NSEvent) {
        zoom = max(0.2, zoom * (1 + event.magnification))
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        let point = convert(event.locationInWindow, from: nil)
        if resizeHandle.insetBy(dx: -6, dy: -6).contains(point) {
            resizing = true
            startSize = bounds.size
            startPoint = point
            return
        }
        dragStart = point
    }

    override func mouseUp(with event: NSEvent) {
        if resizing { resizing = false; return }
        if !dragged {
            // click = reset to fit
            zoom = 1
            offset = .zero
            needsDisplay = true
        }
        dragStart = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if resizing {
            let size = NSSize(width: max(80, min(520, startSize.width + (point.x - startPoint.x))),
                              height: max(60, min(520, startSize.height - (point.y - startPoint.y))))
            onResize?(size)
            return
        }
        guard let start = dragStart else { return }
        dragged = true
        offset.x += point.x - start.x
        offset.y += point.y - start.y
        dragStart = point
        needsDisplay = true
    }

}

final class PhotoStripView: NSView {
    var onSelect: ((PhotoRecord) -> Void)?
    private var photos: [PhotoRecord] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let selectedID = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPhotos(_ list: [PhotoRecord]) {
        photos = list
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for record in list {
            let button = NSButton(title: "", target: self, action: #selector(selectPhoto(_:)))
            button.bezelStyle = .shadowlessSquare
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = Self.thumbnail(record.url, size: 64)
            button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
            button.toolTip = record.name
            button.widthAnchor.constraint(equalToConstant: 84).isActive = true
            button.heightAnchor.constraint(equalToConstant: 68).isActive = true
            stack.addArrangedSubview(button)
        }
        _ = selectedID
    }

    @objc private func selectPhoto(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw),
              let record = photos.first(where: { $0.id == id }) else { return }
        onSelect?(record)
    }

    static func thumbnail(_ url: URL, size: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}

final class FocusWindowController: NSWindowController, NSWindowDelegate {
    private let bigView = FocusImageView()
    private let overview = OverviewView()
    private let liveResumeField = NSTextField()
    private var overviewWidth: NSLayoutConstraint?
    private var overviewHeight: NSLayoutConstraint?
    private var liveResumeTimer: DispatchWorkItem?
    private let strip = PhotoStripView()
    private let folderLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let statusLabel = makeLabel("waiting for a shot", size: 11)
    private let renameField = NSTextField()
    private let newFolderField = NSTextField()
    private let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overviewHint = makeLabel("scroll = zoom · drag corner = resize", size: 9, color: .tertiaryLabelColor)
    private let liveCheck = NSButton(checkboxWithTitle: "Live view", target: nil, action: nil)
    private let gridCheck = NSButton(checkboxWithTitle: "Grid overlay", target: nil, action: nil)
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transferLabel = makeLabel("", size: 10, color: .tertiaryLabelColor)
    private let adbDot = NSView()
    private let syncDot = NSView()
    private let adbLabel = makeLabel("ADB —", size: 10, color: .secondaryLabelColor)
    private let syncLabel = makeLabel("Sync —", size: 10, color: .secondaryLabelColor)
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let statusLog = NSTextView()

    var photos: [PhotoRecord] = []
    var lastRecord: PhotoRecord?
    var onLiveView: ((Bool) -> Void)?
    var onGrid: ((Bool) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onNewFolder: ((String) -> Bool)?
    var onRename: ((PhotoRecord, String) -> Bool)?
    var onBack: (() -> Void)?
    var onFocusMain: (() -> Void)?
    var canGoBack = false
    var liveFramesEnabled = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "sonyTether — Focus"
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        build()
        window.delegate = self
    }

    func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let left = NSView()
        left.wantsLayer = true
        left.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        // Left column widgets
        let title = makeLabel("Capture", size: 13, weight: .semibold)
        let backButton = makeButton("← Back", target: self, action: #selector(goBack))
        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        folderButton.alignment = .left
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)
        folderButton.toolTip = "Click to choose another folder"
        folderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLabel.maximumNumberOfLines = 2
        folderLabel.preferredMaxLayoutWidth = 250
        let chooseFolder = makeButton("Choose Folder…", target: self, action: #selector(chooseFolder))
        newFolderField.placeholderString = "new subfolder name"
        newFolderField.font = NSFont.systemFont(ofSize: 11)
        newFolderField.controlSize = .small
        let createFolder = makeButton("Create", target: self, action: #selector(createFolder))
        newFolderField.identifier = NSUserInterfaceItemIdentifier("newFolderField")

        renameField.font = NSFont.systemFont(ofSize: 11)
        renameField.controlSize = .small
        renameField.placeholderString = "file name"
        renameField.target = self
        renameField.action = #selector(applyRename)
        let renameButton = makeButton("Rename", target: self, action: #selector(applyRename))

        liveResumeField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        liveResumeField.controlSize = .small
        liveResumeField.stringValue = "3"
        liveResumeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        liveCheck.target = self
        liveCheck.action = #selector(toggleLive)
        liveCheck.state = .off
        gridCheck.target = self
        gridCheck.action = #selector(toggleGrid)
        gridCheck.state = .on

        zoomPopup.addItems(withTitles: ["Fit", "2×", "3×", "4×", "6×", "8×"])
        zoomPopup.controlSize = .small
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)

        overview.zoom = 1
        overview.onResize = { [weak self] size in self?.resizeOverview(size) }
        aspectPopup.addItems(withTitles: ["Free", "2:3", "3:2", "4:5", "5:4", "3:4", "4:3"])
        aspectPopup.controlSize = .small
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged)

        for dot in [adbDot, syncDot] {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        statusLog.isEditable = false
        statusLog.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        statusLog.drawsBackground = true
        statusLog.backgroundColor = .textBackgroundColor
        let statusScroll = NSScrollView()
        statusScroll.documentView = statusLog
        statusScroll.hasVerticalScroller = true
        statusScroll.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        statusScroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        overview.wantsLayer = true
        overview.layer?.backgroundColor = NSColor.black.cgColor
        overview.layer?.cornerRadius = 4
        overview.translatesAutoresizingMaskIntoConstraints = false

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 4
            s.alignment = .centerY
            return s
        }

        let stack = NSStackView(views: [
            title,
            row([backButton, folderButton]),
            folderLabel,
            chooseFolder,
            row([newFolderField, createFolder]),
            makeSectionLabel("Rename last shot"),
            row([renameField, renameButton]),
            statusLabel,
            makeSectionLabel("View"),
            liveCheck,
            row([makeLabel("resume live after", size: 10, color: .secondaryLabelColor), liveResumeField,
                 makeLabel("s", size: 10, color: .secondaryLabelColor)]),
            gridCheck,
            row([zoomPopup]),
            makeSectionLabel("Overview"),
            row([aspectPopup, makeButton("Main view", target: self, action: #selector(focusMainView))]),
            overview,
            overviewHint,
            makeSectionLabel("Transfer"),
            row([adbDot, adbLabel]),
            row([syncDot, syncLabel]),
            statusScroll,
            transferLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(stack)
        overviewWidth = overview.widthAnchor.constraint(equalToConstant: 220)
        overviewHeight = overview.heightAnchor.constraint(equalToConstant: 150)
        overviewWidth?.isActive = true
        overviewHeight?.isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: left.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -14),
            overview.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            overview.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            newFolderField.widthAnchor.constraint(equalToConstant: 140),
        ])

        bigView.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSelect = { [weak self] record in self?.show(record) }
        let right = NSView()
        right.addSubview(bigView)
        right.addSubview(strip)
        NSLayoutConstraint.activate([
            bigView.topAnchor.constraint(equalTo: right.topAnchor),
            bigView.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            bigView.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            bigView.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: 96),
        ])

        for v in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: content.topAnchor),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 300),
            right.topAnchor.constraint(equalTo: content.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(transferChanged),
                                              name: .transferStatus, object: nil)
    }

    // MARK: Data

    func update(folder: String, session: SessionSnapshot, photos: [PhotoRecord], transfer: String) {
        folderLabel.stringValue = folder.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        folderButton.title = (folder as NSString).lastPathComponent.isEmpty
            ? folder : "📁 " + (folder as NSString).lastPathComponent
        folderButton.toolTip = folder
        renderTransferStatus()
        transferLabel.stringValue = transfer
        self.photos = photos
        strip.setPhotos(photos)
        if lastRecord == nil, let last = photos.last { show(last) }
        _ = session
    }

    func setLiveFrame(_ image: NSImage) {
        guard liveFramesEnabled else { return }
        bigView.image = image
        bigView.overlay = ""
    }

    func show(_ record: PhotoRecord, isNew: Bool = false) {
        lastRecord = record
        guard let image = NSImage(contentsOf: record.url) else { return }
        let wasLive = liveFramesEnabled
        liveFramesEnabled = false
        liveCheck.state = .off
        bigView.image = image
        bigView.overlay = ""
        // zoom deliberately kept across photos
        overview.image = image
        overview.zoom = 1
        if wasLive {
            onLiveView?(false)
            scheduleLiveResume()
        }
        renameField.stringValue = (record.name as NSString).deletingPathExtension
        statusLabel.stringValue = "\(record.name) · \(record.width)×\(record.height) · \(Fmt.bytes(record.bytes))"
        window?.title = "sonyTether — Focus · \(record.name)"
    }

    private func resizeOverview(_ size: NSSize) {
        overviewWidth?.constant = size.width
        overviewHeight?.constant = size.height
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func scheduleLiveResume() {
        liveResumeTimer?.cancel()
        let seconds = max(0.5, Double(liveResumeField.stringValue) ?? 3)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveFramesEnabled = true
            self.liveCheck.state = .on
            self.onLiveView?(true)
            self.bigView.overlay = "Live view"
        }
        liveResumeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Red frame around the window while the body is unreachable.
    func setCameraConnected(_ connected: Bool) {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.borderWidth = connected ? 0 : 3
        content.layer?.borderColor = NSColor.systemRed.cgColor
    }

    @objc private func chooseFolder() { onChooseFolder?() }

    @objc private func focusMainView() { onFocusMain?() }

    @objc private func aspectChanged() {
        let ratios: [CGFloat] = [1.5, 2.0/3.0, 1.5, 0.8, 1.25, 0.75, 4.0/3.0]
        let index = max(0, aspectPopup.indexOfSelectedItem)
        if index == 0 {
            overviewWidth?.constant = 220
            overviewHeight?.constant = 150
            overview.aspect = 220.0 / 150.0
            window?.contentView?.layoutSubtreeIfNeeded()
            return
        }
        let ratio = ratios[index]
        overview.aspect = ratio
        let width: CGFloat = 220
        overviewWidth?.constant = width
        overviewHeight?.constant = width / ratio
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func goBack() {
        guard canGoBack else { return }
        onBack?()
    }

    func renderTransferStatus() {
        let broker = TransferStatusBroker.shared
        func color(_ ok: Bool, _ enabled: Bool) -> NSColor {
            if !enabled { return .systemGray }
            return ok ? .systemGreen : .systemRed
        }
        adbDot.layer?.backgroundColor = color(broker.adbOK, broker.adbEnabled).cgColor
        syncDot.layer?.backgroundColor = color(broker.syncOK, broker.syncEnabled).cgColor
        adbLabel.stringValue = broker.adbEnabled
            ? (broker.adbOK ? "ADB OK" : "ADB failed") : "ADB off"
        syncLabel.stringValue = broker.syncEnabled
            ? (broker.syncOK ? "Sync OK" : "Sync failed") : "Sync off"
        statusLog.string = broker.logLines.joined(separator: "\n")
        transferLabel.stringValue = broker.summary
    }

    @objc private func createFolder() {
        let name = newFolderField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if onNewFolder?(name) == true {
            newFolderField.stringValue = ""
        }
    }

    @objc private func applyRename() {
        guard let record = lastRecord else { return }
        let name = renameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if onRename?(record, name) == true {
            // reload from disk after rename
            if let updated = try? FileManager.default.contentsOfDirectory(
                at: record.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(name) }) {
                var newRecord = record
                newRecord.url = updated
                newRecord.name = updated.lastPathComponent
                show(newRecord)
            }
        }
    }

    @objc private func toggleLive() {
        liveFramesEnabled = liveCheck.state == .on
        onLiveView?(liveFramesEnabled)
        if liveFramesEnabled {
            bigView.overlay = "Live view"
        } else if let record = lastRecord {
            show(record)
        }
    }

    @objc private func toggleGrid() {
        bigView.showGrid = gridCheck.state == .on
        onGrid?(gridCheck.state == .on)
    }

    @objc private func zoomChanged() {
        let values: [CGFloat] = [1, 2, 3, 4, 6, 8]
        bigView.zoom = values[max(0, min(values.count - 1, zoomPopup.indexOfSelectedItem))]
    }

    @objc private func transferChanged() {
        transferLabel.stringValue = TransferStatusBroker.shared.summary
    }
}

/// Small bridge so the focus window can show ADB/sync status without owning
/// the transfer service.
final class TransferStatusBroker {
    static let shared = TransferStatusBroker()
    var summary = ""
    var adbOK = false
    var syncOK = false
    var adbEnabled = false
    var syncEnabled = false
    var logLines: [String] = []

    func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 6 { logLines.removeFirst() }
    }
}


// MARK: - Client view (clean preview for a second display)

final class ClientViewWindowController: NSWindowController {
    private let canvas = FocusImageView()
    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    convenience init() {
        let secondary = NSScreen.screens.count > 1 ? NSScreen.screens[1] : nil
        let frame = secondary?.frame ?? NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(contentRect: frame,
                              styleMask: secondary == nil ? [.titled, .closable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        window.title = "sonyTether — Client View"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        if let secondary {
            window.setFrame(secondary.frame, display: true)
            window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        }
        self.init(window: window)
        canvas.frame = window.contentView?.bounds ?? frame
        canvas.autoresizingMask = [.width, .height]
        canvas.showGrid = false
        window.contentView?.addSubview(canvas)
        window.makeFirstResponder(canvas)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 && event.modifierFlags.contains(.command) { self?.closeClient(); return nil }
            return event
        }
    }

    func show(image: NSImage?) {
        if let image { canvas.image = image }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    private func closeClient() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        window?.close()
        onClose?()
    }
}
