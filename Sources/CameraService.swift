import Foundation
import GPhoto2

/// Snapshot of everything the UI shows about the camera.
struct CameraStatus: Equatable {
    var connected = false
    var model = ""
    var manufacturer = ""
    var serial = ""
    var firmware = ""
    var library = ""
    var battery: String?
    var exposure: String?
    var lastError: String?
    var liveViewState = LiveViewState.off
    var liveFps: Double = 0
    var captures = 0
    var bytes = 0
    var connectAttempts = 0

    enum LiveViewState: String, Equatable {
        case off = "Off"
        case starting = "Starting"
        case running = "Running"
        case unsupported = "Not supported"
        case failed = "Failed"
    }
}

struct CaptureRecord {
    let name: String
    let url: URL
    let bytes: Int
    let duration: Double
    let source: String
}

/// Owns the libgphoto2 context and camera handle.
///
/// Threading: every libgphoto2 call happens on `queue`, never concurrently.
/// UI callbacks are delivered on the main thread.
final class CameraService {
    // MARK: - Public state

    var onStatus: ((CameraStatus) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onCapture: ((CaptureRecord) -> Void)?

    private(set) var status = CameraStatus()

    /// Destination folder. Guarded by `stateLock` for main-thread reads.
    var destination: URL {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return _destination
        }
        set {
            stateLock.lock(); _destination = newValue; stateLock.unlock()
        }
    }

    // MARK: - Private state

    private let queue = DispatchQueue(label: "com.johorstudio.sonytether.camera", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _destination: URL

    private var context: OpaquePointer?
    private var camera: UnsafeMutablePointer<Camera>?
    private var connected = false
    private var wantConnected = false
    private var running = false

    private var liveViewWanted = false
    private var lastFrameAt = Date.distantPast
    private var previewInterval: TimeInterval = 0.10
    private var previewDurations: [TimeInterval] = []
    private var previewFailures = 0
    private var lastPreviewLogAt = Date.distantPast
    private var liveFrames: [Date] = []
    private var lastFpsPublish = Date.distantPast

    private var lastStatusRefresh = Date.distantPast
    private var lastOpenAttempt = Date.distantPast
    private var lastOpenLog = Date.distantPast
    private var openFailureCount = 0
    private var downloaded = Set<String>()
    private var downloadOrder: [String] = []

    private var tickScheduled = false
    private var captureInFlight = false

    private static let log = Logger.shared

    init(destination: URL) {
        self._destination = destination
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.wantConnected = true
            Self.log.info("sonyTether \(AppInfo.version) started")
            Self.log.info("Capture folder: \(self.destination.path)")
            self.scheduleTick(0.05)
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.wantConnected = false
            self.liveViewWanted = false
            self.closeCamera(reason: "app quitting")
            if let ctx = self.context {
                gp_context_unref(ctx)
                self.context = nil
            }
        }
    }

    func setConnected(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantConnected = on
            if !on {
                self.liveViewWanted = false
                self.closeCamera(reason: "disconnected by user")
            } else if !self.connected {
                self.openFailureCount = 0
                self.lastOpenAttempt = .distantPast
                Self.log.info("Connecting to camera…")
                self.tryOpen()
                self.scheduleTick(0.05)
            }
            self.publishStatus()
        }
    }

    func setLiveView(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.liveViewWanted = on
            if on && self.connected {
                self.status.liveViewState = .starting
                self.previewFailures = 0
                Self.log.info("Live view on")
            } else {
                self.status.liveViewState = .off
                if !on { Self.log.info("Live view off") }
            }
            self.publishStatus()
        }
    }

    func capture() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connected, let cam = self.camera, let ctx = self.context else {
                Self.log.warn("Capture ignored: camera not connected")
                return
            }
            guard !self.captureInFlight else {
                Self.log.warn("Capture ignored: previous capture still running")
                return
            }
            self.captureInFlight = true
            defer { self.captureInFlight = false }

            Self.log.info("Capture requested")
            let started = Date()
            var path = CameraFilePath()
            let rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &path, ctx)
            guard rc == GP_OK else {
                let msg = gpErrorText(rc)
                Self.log.error("Capture failed: \(msg)")
                self.status.lastError = "Capture failed: \(msg)"
                self.publishStatus()
                return
            }
            let name = fixedCString(&path.name)
            let folder = fixedCString(&path.folder)
            let elapsed = Date().timeIntervalSince(started)
            Self.log.info("Shutter released → \(folder)/\(name) (\(Fmt.ms(elapsed * 1000)))")

            // libgphoto2's Sony path needs an event round-trip to flush the
            // image out of the body's buffer (see libgphoto2 issue #966).
            self.drainEvents(limit: 20, dwell: 0.01)

            self.previewFailures = 0
            self.lastFrameAt = Date().addingTimeInterval(0.15)
            self.download(folder: folder, name: name, source: "app")
        }
    }

    func refreshStatusNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastStatusRefresh = .distantPast
            self.refreshStatus()
            self.publishStatus()
        }
    }

    // MARK: - Camera open / close

    private func tryOpen() {
        guard wantConnected, !connected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOpenAttempt) > 2.0 else { return }
        lastOpenAttempt = now
        status.connectAttempts += 1

        if context == nil {
            context = gp_context_new()
            if let ctx = context {
                gp_context_set_error_func(ctx, gpErrorCallback, nil)
                gp_context_set_message_func(ctx, gpMessageCallback, nil)
            }
        }
        guard let ctx = context else {
            Self.log.error("Could not create gphoto2 context")
            return
        }

        // Which bodies does libgphoto2 see right now? Useful in the log when
        // the USB mode is wrong: the body shows up as an MTP device, not a PTP one.
        var list: OpaquePointer?
        if gp_list_new(&list) == GP_OK, let list {
            let dret = gp_camera_autodetect(list, ctx)
            let count = gp_list_count(list)
            if count > 0 {
                var names: [String] = []
                for i in 0..<count {
                    var name: UnsafePointer<CChar>? = nil
                    var value: UnsafePointer<CChar>? = nil
                    _ = gp_list_get_name(list, i, &name)
                    _ = gp_list_get_value(list, i, &value)
                    let n = name.map { String(cString: $0) } ?? "?"
                    let v = value.map { String(cString: $0) } ?? "?"
                    names.append("\(n) @ \(v)")
                }
                Self.log.info("Autodetect (\(dret)): \(names.joined(separator: ", "))")
            }
            gp_list_free(list)
        }

        var cam: UnsafeMutablePointer<Camera>? = nil
        guard gp_camera_new(&cam) == GP_OK, let cam else {
            Self.log.error("gp_camera_new failed")
            return
        }
        let rc = gp_camera_init(cam, ctx)
        guard rc == GP_OK else {
            let detail = gpErrorText(rc)
            gp_camera_unref(cam)
            openFailureCount += 1
            status.connected = false
            status.lastError = detail
            let now = Date()
            if openFailureCount <= 2 || openFailureCount % 30 == 0
                || now.timeIntervalSince(lastOpenLog) > 60 {
                lastOpenLog = now
                Self.log.error("Camera connect failed (\(openFailureCount)x): \(detail)")
                Self.log.info("Checklist: body powered on · USB cable in the camera port · "
                    + "Menu → Setup → USB → PC Remote · close Imaging Edge / Lightroom / Photos")
                let sony = USBBus.sonyDevices()
                if sony.isEmpty {
                    Self.log.warn("USB: no Sony device on the bus at all — cable, port or camera power")
                } else {
                    let list = sony.map { "\($0.hexIDs) \($0.product)" }.joined(separator: ", ")
                    Self.log.warn("USB: Sony device present (\(list)) but libgphoto2 did not claim it — "
                        + "USB mode is probably not PC Remote, or another app owns the PTP interface")
                }
            }
            publishStatus()
            return
        }

        camera = cam
        connected = true
        openFailureCount = 0
        readIdentity()
        status.connected = true
        status.lastError = nil
        lastStatusRefresh = .distantPast
        Self.log.info("Connected: \(status.model.isEmpty ? "unknown body" : status.model) "
            + "via \(status.library.isEmpty ? "libgphoto2" : status.library)")
        if !status.serial.isEmpty { Self.log.info("Serial: \(status.serial) · firmware \(status.firmware)") }
        if status.model.uppercased().contains("ILCE") && status.library == "ptp2" {
            Self.log.info("Tip: set the body to PC Remote. PTP control (ISO, shutter, capture) is only "
                + "available in that mode.")
        }
        publishStatus()
    }

    private func readIdentity() {
        guard let cam = camera, let ctx = context else { return }
        var summary = CameraText()
        if gp_camera_get_summary(cam, &summary, ctx) == GP_OK {
            let text = fixedCString(&summary)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Manufacturer:") {
                    status.manufacturer = String(trimmed.dropFirst("Manufacturer:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Model:") {
                    status.model = String(trimmed.dropFirst("Model:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Serial Number:") {
                    status.serial = String(trimmed.dropFirst("Serial Number:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Version:") {
                    status.firmware = String(trimmed.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
            if status.model.isEmpty {
                // Fall back to the "Model:" anywhere in the blob.
                if let r = text.range(of: "Model:") {
                    let rest = text[r.upperBound...].split(separator: "\n").first ?? ""
                    status.model = rest.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        var abilities = CameraAbilities()
        if gp_camera_get_abilities(cam, &abilities) == GP_OK {
            var model = abilities.model
            var library = abilities.library
            let m = fixedCString(&model)
            if !m.isEmpty { status.model = m }
            status.library = fixedCString(&library)
        }
    }

    private func closeCamera(reason: String) {
        guard let cam = camera else { return }
        if let ctx = context {
            _ = gp_camera_exit(cam, ctx)
        }
        gp_camera_unref(cam)
        camera = nil
        connected = false
        status.connected = false
        status.liveViewState = .off
        status.liveFps = 0
        liveViewWanted = false
        Self.log.info("Camera released (\(reason))")
        publishStatus()
    }

    // MARK: - Tick loop

    private func scheduleTick(_ delay: TimeInterval) {
        guard running else { return }
        guard !tickScheduled else { return }
        tickScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            self.tick()
        }
    }

    private func tick() {
        guard running else { return }
        if !wantConnected {
            scheduleTick(0.5)
            return
        }
        if !connected {
            tryOpen()
            scheduleTick(1.0)
            return
        }
        drainEvents()

        if liveViewWanted {
            grabPreviewIfDue()
            scheduleTick(0.02)
        } else {
            if Date().timeIntervalSince(lastStatusRefresh) > 3.0 { refreshStatus() }
            scheduleTick(0.15)
        }
        if Date().timeIntervalSince(lastStatusRefresh) > 3.0 && liveViewWanted { refreshStatus() }
        publishFpsIfDue()
    }

    // MARK: - Events

    private func drainEvents(limit: Int = 8, dwell: TimeInterval = 0) {
        guard let cam = camera, let ctx = context else { return }
        for _ in 0..<limit {
            var type = GP_EVENT_UNKNOWN
            var data: UnsafeMutableRawPointer? = nil
            let rc = gp_camera_wait_for_event(cam, 0, &type, &data, ctx)
            guard rc == GP_OK else {
                if rc != GP_ERROR_TIMEOUT { Self.log.warn("wait_for_event: \(gpErrorText(rc))") }
                break
            }
            if type == GP_EVENT_TIMEOUT {
                free(data)
                break
            }
            if type == GP_EVENT_FILE_ADDED, let data {
                let pathPtr = data.assumingMemoryBound(to: CameraFilePath.self)
                let name = fixedCString(&pathPtr.pointee.name)
                let folder = fixedCString(&pathPtr.pointee.folder)
                free(data)
                Self.log.info("Camera file event: \(folder)/\(name)")
                download(folder: folder, name: name, source: "camera")
                if dwell > 0 { Thread.sleep(forTimeInterval: dwell) }
                continue
            }
            if type == GP_EVENT_CAPTURE_COMPLETE {
                Self.log.debug("Capture complete event")
            }
            free(data)
            if dwell > 0 { Thread.sleep(forTimeInterval: dwell) }
        }
    }

    // MARK: - Live view

    private func grabPreviewIfDue() {
        guard connected, let cam = camera, let ctx = context else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= previewInterval else { return }

        var file: OpaquePointer?
        guard gp_file_new(&file) == GP_OK, let file else { return }
        defer { gp_file_unref(file) }

        let t0 = Date()
        let rc = gp_camera_capture_preview(cam, file, ctx)
        let took = Date().timeIntervalSince(t0)

        guard rc == GP_OK else {
            previewFailures += 1
            if rc == GP_ERROR {
                // The body drops the preview object for a moment after a
                // capture; it comes back on its own. Retry quietly, no log
                // spam, no error state.
                if previewFailures > 10,
                   Date().timeIntervalSince(lastPreviewLogAt) > 30 {
                    lastPreviewLogAt = Date()
                    Self.log.debug("Live view re-warming after capture "
                        + "(\(previewFailures) empty frames)")
                }
                lastFrameAt = Date().addingTimeInterval(0.25)
                return
            }
            if previewFailures == 1 || previewFailures % 20 == 0 {
                Self.log.warn("Live view frame failed (\(previewFailures)x): \(gpErrorText(rc))")
            }
            if rc == GP_ERROR_NOT_SUPPORTED || rc == GP_ERROR_MODEL_NOT_FOUND {
                status.liveViewState = .unsupported
                status.lastError = "Live view: \(gpErrorText(rc))"
                liveViewWanted = false
                publishStatus()
            } else if previewFailures == 3 {
                status.liveViewState = .failed
                publishStatus()
            }
            lastFrameAt = Date().addingTimeInterval(0.3)
            return
        }

        var data: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        guard gp_file_get_data_and_size(file, &data, &size) == GP_OK, let data, size > 0 else {
            return
        }
        let payload = Data(bytes: data, count: Int(size))
        lastFrameAt = Date()
        previewFailures = 0
        if status.liveViewState != .running {
            status.liveViewState = .running
            status.lastError = nil
            Self.log.info("Live view running (\(size / 1024) KB/frame)")
        }
        if previewFailures > 0 {
            previewFailures = 0
        }

        // Adaptive pacing: never hammer a slow body.
        previewDurations.append(took)
        if previewDurations.count > 15 { previewDurations.removeFirst() }
        let avg = previewDurations.reduce(0, +) / Double(previewDurations.count)
        previewInterval = max(0.06, min(0.30, avg * 1.05))

        liveFrames.append(now)
        if liveFrames.count > 120 { liveFrames.removeFirst() }

        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(payload)
        }
    }

    private func publishFpsIfDue() {
        guard liveViewWanted else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFpsPublish) >= 1.0 else { return }
        lastFpsPublish = now
        liveFrames = liveFrames.filter { now.timeIntervalSince($0) < 1.0 }
        status.liveFps = Double(liveFrames.count)
        publishStatus()
    }

    // MARK: - Status

    private func refreshStatus() {
        lastStatusRefresh = Date()
        guard connected, let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }

        status.battery = widgetText(cfg, "batterylevel") ?? widgetText(cfg, "battery")

        var parts: [String] = []
        if let iso = widgetText(cfg, "iso") { parts.append("ISO \(iso)") }
        if let shutter = widgetText(cfg, "shutterspeed") { parts.append(shutter) }
        if let aperture = widgetText(cfg, "f-number") { parts.append(aperture) }
        if let wb = widgetText(cfg, "whitebalance") { parts.append("WB \(wb)") }
        status.exposure = parts.isEmpty ? nil : parts.joined(separator: " · ")
        publishStatus()
    }

    private func widgetText(_ root: OpaquePointer, _ name: String) -> String? {
        var child: OpaquePointer?
        guard gp_widget_get_child_by_name(root, name, &child) == GP_OK, let child else { return nil }
        return widgetString { ptr in
            gp_widget_get_value(child, UnsafeMutableRawPointer(ptr))
        }
    }

    // MARK: - Download

    private func download(folder: String, name: String, source: String) {
        guard connected, let cam = camera, let ctx = context else { return }
        let key = "\(folder)/\(name)"
        if downloaded.contains(key) {
            Self.log.debug("Skip duplicate download: \(key)")
            return
        }
        downloaded.insert(key)
        downloadOrder.append(key)
        if downloadOrder.count > 400 {
            let old = downloadOrder.removeFirst()
            downloaded.remove(old)
        }

        let started = Date()
        var file: OpaquePointer?
        guard gp_file_new(&file) == GP_OK, let file else {
            Self.log.error("gp_file_new failed")
            return
        }
        defer { gp_file_unref(file) }

        let rc = gp_camera_file_get(cam, folder, name, GP_FILE_TYPE_NORMAL, file, ctx)
        guard rc == GP_OK else {
            let msg = gpErrorText(rc)
            Self.log.error("Download failed for \(key): \(msg)")
            status.lastError = "Download failed: \(msg)"
            publishStatus()
            return
        }

        var data: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        guard gp_file_get_data_and_size(file, &data, &size) == GP_OK, let data, size > 0 else {
            Self.log.error("Download produced no data for \(key)")
            return
        }
        let payload = Data(bytes: data, count: Int(size))

        let dir = destination
        var target = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            target = try Self.writeCapture(payload, name: name, into: dir)
        } catch {
            Self.log.error("Could not write \(target.path): \(error.localizedDescription)")
            status.lastError = "Write failed: \(error.localizedDescription)"
            publishStatus()
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        status.captures += 1
        status.bytes += payload.count
        status.lastError = nil

        let record = CaptureRecord(
            name: target.lastPathComponent,
            url: target,
            bytes: payload.count,
            duration: elapsed,
            source: source
        )
        Self.log.info("Saved \(record.name) · \(Fmt.bytes(payload.count)) · "
            + "\(Fmt.ms(elapsed * 1000)) → \(dir.path)")
        publishStatus()
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(record)
        }
    }

    /// Write a captured file, never overwriting an existing one.
    static func writeCapture(_ data: Data, name: String, into dir: URL) throws -> URL {
        var target = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            target = dir.appendingPathComponent(candidate)
            n += 1
        }
        try data.write(to: target, options: .atomic)
        return target
    }

    // MARK: - Publishing

    private func publishStatus() {
        let snapshot = status
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(snapshot)
        }
    }
}

// MARK: - C callbacks

func gpErrorCallback(_ ctx: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ data: UnsafeMutableRawPointer?) {
    guard let text else { return }
    let message = String(cString: text)
    // The Sony body returns a non-JPEG preview for a moment after each shot.
    // That is normal and self-healing, so keep it out of the error log.
    if message.contains("JPEG image in LiveView mode") {
        Logger.shared.debug("libgphoto2: \(message)")
        return
    }
    Logger.shared.error("libgphoto2: \(message)")
}

func gpMessageCallback(_ ctx: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ data: UnsafeMutableRawPointer?) {
    guard let text else { return }
    Logger.shared.debug("libgphoto2: \(String(cString: text))")
}
