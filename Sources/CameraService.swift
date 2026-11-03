import Foundation
import GPhoto2
import ImageIO

// MARK: - Public model types

struct ControlItem: Equatable {
    enum Kind: String { case choice, range }
    var name: String
    var label: String
    var current: String
    var kind: Kind
    var choices: [String] = []
    var min: Double = 0
    var max: Double = 0
    var step: Double = 1
}

struct ControlGroup: Equatable {
    var title: String
    var items: [ControlItem]
}

struct PhotoRecord: Equatable, Identifiable {
    var id = UUID()
    var url: URL
    var name: String
    var camera: String
    var node: String
    var batch: Int
    var sessionNumber: Int
    var sessionName: String
    var width: Int
    var height: Int
    var format: String
    var aperture: String
    var shutter: String
    var iso: String
    var focalLength: String
    var bytes: Int
    var capturedAt: Date
    var uniqueTag: String
    var barcode: String
}

struct CameraStatus: Equatable {
    var connected = false
    var model = ""
    var serial = ""
    var firmware = ""
    var battery: String?
    var storage: String?
    var lastError: String?
    var liveViewState: LiveViewState = .off
    var liveFps: Double = 0
    var captures = 0
    var bytes = 0
    var connectAttempts = 0

    enum LiveViewState: String, Equatable {
        case off = "Off", starting = "Starting", running = "Running",
             unsupported = "Not supported", failed = "Failed"
    }
}

/// A built-in script, run on the camera queue so it owns the body.
enum ScriptKind: String, CaseIterable {
    /// Scripts that only press the shutter. The bodies we tested hang when a
    /// setting is rewritten between frames, so bracket/HDR are parked until
    /// they can drive the camera's own bracket mode.
    static var shipped: [ScriptKind] { [.timelapse, .delayedTrigger] }

    case apertureBracket = "Aperture bracket"
    case shutterBracket = "Shutter bracket"
    case isoBracket = "ISO bracket"
    case hdr = "HDR"
    case timelapse = "Timelapse"
    case bulbTimelapse = "Bulb timelapse"
    case delayedTrigger = "Delayed trigger"
}

struct ScriptSettings {
    var kind: ScriptKind = .timelapse
    var steps: Int = 3
    var stepSize: Int = 1
    var count: Int = 10
    var interval: Double = 4
    var delay: Double = 3
    var bulbSeconds: Double = 8
}

// MARK: - Camera service

/// Owns the libgphoto2 context. Every call runs on `queue`; UI callbacks land
/// on the main thread.
final class CameraService {
    var onStatus: ((CameraStatus) -> Void)?
    var onControls: (([ControlGroup]) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onPhoto: ((PhotoRecord) -> Void)?
    var onScriptState: ((ScriptState) -> Void)?

    struct ScriptState {
        var name: String = ""
        var running = false
        var progress: Int = 0
        var total: Int = 0
        var status: String = "Ready"
    }

    private(set) var status = CameraStatus()
    let session = SessionState()
    var prefs: Preferences
    private(set) var controls: [ControlGroup] = []

    private let queue = DispatchQueue(label: "com.johorstudio.sonytether.camera", qos: .userInitiated)
    private static let log = Logger.shared

    private var context: OpaquePointer?
    private var camera: UnsafeMutablePointer<Camera>?
    private var connected = false
    private var wantConnected = false
    private var running = false

    private var liveViewWanted = false
    private var lastFrameAt = Date.distantPast
    private var previewInterval: TimeInterval = 0.08
    private var previewDurations: [TimeInterval] = []
    private var previewFailures = 0
    private var previewPaused = false
    private var scriptActive = false
    private var lastShutterAt = Date.distantPast
    private let minimumCaptureGap: TimeInterval = 6.0
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
    private var lastSettingsSnapshot: [String: String] = [:]

    private let callLock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.johorstudio.sonytether.watchdog")
    private var callName: String?
    private var callStartedAt: Date?
    private var warnedStall = false
    private var watchdog: DispatchSourceTimer?
    private var scriptTask: DispatchWorkItem?
    private var scriptStopRequested = false
    private var scriptState = ScriptState()

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.wantConnected = self.prefs.autoConnect
            Self.log.info("sonyTether \(AppInfo.version) started")
            self.startWatchdog()
            self.scheduleTick(0.05)
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.wantConnected = false
            self.watchdog?.cancel()
            self.watchdog = nil
            self.cancelScript()
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
                self.tryOpen()
            }
            self.publishStatus()
            self.scheduleTick(0.05)
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

    // MARK: Controls

    func refreshControls() {
        queue.async { [weak self] in self?.loadControls() }
    }

    private static let controlSchema: [(String, String, String)] = [
        ("exposure", "Aperture", "f-number"),
        ("exposure", "Shutter Speed", "shutterspeed"),
        ("exposure", "ISO", "iso"),
        ("exposure", "Exposure ±", "exposurecompensation"),
        ("image", "Quality", "imagequality"),
        ("image", "Image Size", "imagesize"),
        ("image", "White Balance", "whitebalance"),
        ("image", "Colour Temp", "colortemperature"),
        ("image", "DRO", "dro"),
        ("camera", "Program Mode", "expprogram"),
        ("camera", "Metering Mode", "exposuremetermode"),
        ("camera", "Focus Mode", "focusmode"),
        ("camera", "Focus Area", "focusarea"),
        ("camera", "Drive Mode", "capturemode"),
        ("camera", "Aspect Ratio", "aspectratio"),
        ("camera", "Capture Target", "capturetarget"),
        ("camera", "Live View Effect", "liveviewsettingeffect"),
    ]

    private func loadControls() {
        guard connected, let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        beginCall("read settings")
        let rc = gp_camera_get_config(cam, &cfg, ctx)
        endCall()
        guard rc == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }

        var groups: [ControlGroup] = []
        var snapshots: [String: String] = [:]
        for (group, label, name) in Self.controlSchema {
            guard let node = widget(cfg, name) else { continue }
            var item = ControlItem(name: name, label: label, current: "", kind: .choice)
            var type: CameraWidgetType = GP_WIDGET_WINDOW
            _ = gp_widget_get_type(node, &type)
            if type == GP_WIDGET_RANGE {
                item.kind = .range
                var f: Float = 0
                _ = gp_widget_get_value(node, &f)
                var minValue: Float = 0
                var maxValue: Float = 0
                var step: Float = 0
                _ = gp_widget_get_range(node, &minValue, &maxValue, &step)
                item.min = Double(minValue)
                item.max = Double(maxValue)
                item.step = Double(step)
                item.current = formatRange(f)
            } else {
                item.current = widgetStringValue(node) ?? ""
                let count = gp_widget_count_choices(node)
                if count > 0 {
                    var choices: [String] = []
                    for i in 0..<count {
                        var c: UnsafePointer<CChar>? = nil
                        if gp_widget_get_choice(node, i, &c) == GP_OK, let c {
                            choices.append(String(cString: c))
                        }
                    }
                    item.choices = choices
                } else {
                    item.kind = .range
                    var f: Float = 0
                    _ = gp_widget_get_value(node, &f)
                    item.min = 0; item.max = 100; item.step = 1
                    item.current = formatRange(f)
                }
            }
            snapshots[name] = item.current
            if let idx = groups.firstIndex(where: { $0.title == group }) {
                groups[idx].items.append(item)
            } else {
                groups.append(ControlGroup(title: group, items: [item]))
            }
        }
        lastSettingsSnapshot = snapshots
        controls = groups
        let snapshot = groups
        DispatchQueue.main.async { [weak self] in self?.onControls?(snapshot) }
    }

    private func formatRange(_ f: Float) -> String {
        f == f.rounded() ? String(Int(f)) : String(format: "%.1f", f)
    }

    func setControl(name: String, value: String) {
        queue.async { [weak self] in
            guard let self, self.connected, let cam = self.camera, let ctx = self.context else { return }
            var cfg: OpaquePointer?
            guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
            defer { gp_widget_unref(cfg) }
            guard let node = self.widget(cfg, name) else {
                Self.log.warn("Setting \(name) is not exposed by this body")
                return
            }
            var type: CameraWidgetType = GP_WIDGET_WINDOW
            _ = gp_widget_get_type(node, &type)
            let rc: Int32
            if type == GP_WIDGET_RANGE {
                var f = Float(value) ?? 0
                rc = gp_widget_set_value(node, &f)
            } else {
                rc = value.withCString { gp_widget_set_value(node, UnsafeRawPointer($0)) }
            }
            guard rc == GP_OK else {
                Self.log.warn("Set \(name)=\(value) failed: \(gpErrorText(rc))")
                return
            }
            let setrc = gp_camera_set_config(cam, cfg, ctx)
            if setrc != GP_OK {
                Self.log.warn("Apply \(name)=\(value) failed: \(gpErrorText(setrc))")
            } else {
                Self.log.info("Set \(name) = \(value)")
            }
            Thread.sleep(forTimeInterval: 0.20)
            self.loadControls()
            self.publishStatus()
        }
    }

    func stepControl(name: String, direction: Int) {
        queue.async { [weak self] in
            guard let self, let item = self.controls.flatMap({ $0.items }).first(where: { $0.name == name }) else { return }
            if item.kind == .range {
                let step = item.step > 0 ? item.step : 1
                let next = min(item.max, max(item.min, (Double(item.current) ?? item.min) + Double(direction) * step))
                self.setControl(name: name, value: self.formatRange(Float(next)))
            } else if let idx = item.choices.firstIndex(of: item.current) {
                let next = min(item.choices.count - 1, max(0, idx + direction))
                self.setControl(name: name, value: item.choices[next])
            }
        }
    }

    func autofocus() {
        queue.async { [weak self] in
            guard let self, self.connected, let cam = self.camera, let ctx = self.context else { return }
            var cfg: OpaquePointer?
            guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
            defer { gp_widget_unref(cfg) }
            guard let node = self.widget(cfg, "autofocus") else {
                Self.log.warn("Auto focus is not exposed by this body")
                return
            }
            var on: Int32 = 2
            _ = gp_widget_set_value(node, &on)
            _ = gp_camera_set_config(cam, cfg, ctx)
            Thread.sleep(forTimeInterval: 0.25)
            var off: Int32 = 1
            _ = gp_widget_set_value(node, &off)
            _ = gp_camera_set_config(cam, cfg, ctx)
            Self.log.info("Auto focus")
        }
    }

    // MARK: Capture

    func capture(source: String = "app") {
        queue.async { [weak self] in
            guard let self else { return }
            if source == "app" && self.scriptActive {
                Self.log.warn("Capture ignored: a script is running")
                return
            }
            self.performCapture(source: source)
        }
    }

    private func performCapture(source: String) {
        guard connected, let cam = camera, let ctx = context else {
            Self.log.warn("Capture ignored: camera not connected")
            return
        }
        guard !captureInFlight else {
            Self.log.warn("Capture ignored: previous capture still running")
            return
        }
        captureInFlight = true
        defer { captureInFlight = false }

        Self.log.info("Capture requested")
        let started = Date()
        // The body will not accept a shutter release while live view is being
        // polled; stop pulling frames and give it a beat.
        previewPaused = true
        defer {
            previewPaused = false
            lastFrameAt = Date().addingTimeInterval(0.35)
        }
        let sinceLast = Date().timeIntervalSince(lastShutterAt)
        if sinceLast < minimumCaptureGap {
            Thread.sleep(forTimeInterval: minimumCaptureGap - sinceLast)
        }
        if !waitUntilReady(timeout: 10) {
            Self.log.warn("Camera did not report ready before capture; trying anyway")
        }
        var path = CameraFilePath()
        beginCall("capture")
        let rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &path, ctx)
        endCall()
        guard rc == GP_OK else {
            let msg = gpErrorText(rc)
            Self.log.error("Capture failed: \(msg)")
            status.lastError = "Capture failed: \(msg)"
            publishStatus()
            return
        }
        lastShutterAt = Date()
        let original = fixedCString(&path.name)
        let folder = fixedCString(&path.folder)
        let releaseTime = Date().timeIntervalSince(started)
        Self.log.info("Shutter released → \(original) (\(Fmt.ms(releaseTime * 1000)))")

        drainEvents(limit: 20, dwell: 0.01)
        previewFailures = 0
        download(folder: folder, name: original, source: source, capturedAt: started)
    }

    private func download(folder: String, name: String, source: String, capturedAt: Date) {
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

        var file: OpaquePointer?
        guard gp_file_new(&file) == GP_OK, let file else { return }
        defer { gp_file_unref(file) }

        let t0 = Date()
        beginCall("download")
        let rc = gp_camera_file_get(cam, folder, name, GP_FILE_TYPE_NORMAL, file, ctx)
        endCall()
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
        let transfer = Date().timeIntervalSince(t0)

        let originalBase = (name as NSString).deletingPathExtension
        let originalExt = (name as NSString).pathExtension
        var namingSession = session.snapshot()
        namingSession.sequence = session.nextSequence()
        let context = NamePolicy.Context(
            originalName: originalBase,
            extensionName: originalExt.isEmpty ? "JPG" : originalExt,
            cameraName: status.model.isEmpty ? "camera" : status.model,
            serial: status.serial,
            session: namingSession,
            appNodeName: prefs.appNodeName
        )
        let (subdir, fileName) = NamePolicy.resolve(expression: prefs.filenameExpression, context: context)

        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        var dir = root
        if !subdir.isEmpty { dir = root.appendingPathComponent(subdir) }
        var target = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var n = 1
            let base = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            while FileManager.default.fileExists(atPath: target.path) {
                let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                target = dir.appendingPathComponent(candidate)
                n += 1
            }
            try payload.write(to: target, options: .atomic)
        } catch {
            Self.log.error("Could not write \(target.path): \(error.localizedDescription)")
            status.lastError = "Write failed: \(error.localizedDescription)"
            publishStatus()
            return
        }

        let record = makeRecord(url: target, bytes: payload.count, capturedAt: capturedAt,
                                session: namingSession)
        appendManifest(record)
        status.captures += 1
        status.bytes += payload.count
        status.lastError = nil
        Self.log.info("Saved \(record.name) · \(Fmt.bytes(payload.count)) · "
            + "transfer \(Fmt.ms(transfer * 1000)) → \(target.deletingLastPathComponent().path)")
        publishStatus()
        DispatchQueue.main.async { [weak self] in self?.onPhoto?(record) }
    }

    /// One JSON object per line, read by the Lightroom plugin.
    private func appendManifest(_ record: PhotoRecord) {
        let root = URL(fileURLWithPath: (prefs.downloadDirectory as NSString).expandingTildeInPath)
        let file = root.appendingPathComponent("sonyTether-captures.jsonl")
        let payload: [String: Any] = [
            "name": record.name, "path": record.url.path, "camera": record.camera,
            "capturedAt": ISO8601DateFormatter().string(from: record.capturedAt),
            "width": record.width, "height": record.height, "format": record.format,
            "aperture": record.aperture, "shutter": record.shutter, "iso": record.iso,
            "session": record.sessionNumber, "batch": record.batch,
            "tag": record.uniqueTag, "barcode": record.barcode, "bytes": record.bytes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    private func makeRecord(url: URL, bytes: Int, capturedAt: Date,
                            session namingSession: SessionSnapshot) -> PhotoRecord {
        var width = 0
        var height = 0
        var aperture = lastSettingsSnapshot["f-number"] ?? ""
        var shutter = lastSettingsSnapshot["shutterspeed"] ?? ""
        var iso = lastSettingsSnapshot["iso"] ?? ""
        var focal = ""

        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            if let w = props[kCGImagePropertyPixelWidth as String] as? Int { width = w }
            if let h = props[kCGImagePropertyPixelHeight as String] as? Int { height = h }
            if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                if let a = exif[kCGImagePropertyExifFNumber as String] as? Double {
                    aperture = String(format: "f/%.1f", a)
                }
                if let e = exif[kCGImagePropertyExifExposureTime as String] as? Double, e > 0 {
                    shutter = e < 1 ? "1/\(Int((1 / e).rounded()))" : String(format: "%.1fs", e)
                }
                if let list = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
                   let first = list.first {
                    iso = "\(first)"
                }
                if let f = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                    focal = String(format: "%.0f mm", f)
                }
            }
        }
        let fmt = url.pathExtension.uppercased()
        return PhotoRecord(url: url, name: url.lastPathComponent,
                           camera: status.model, node: prefs.appNodeName,
                           batch: namingSession.batch, sessionNumber: namingSession.number,
                           sessionName: namingSession.name, width: width, height: height,
                           format: fmt.isEmpty ? "JPG" : fmt,
                           aperture: aperture, shutter: shutter, iso: iso,
                           focalLength: focal, bytes: bytes, capturedAt: capturedAt,
                           uniqueTag: namingSession.uniqueTag, barcode: namingSession.barcode)
    }

    // MARK: Scripts

    func startScript(_ settings: ScriptSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connected else {
                Self.log.warn("Script needs a connected camera")
                return
            }
            guard self.scriptTask == nil else {
                Self.log.warn("A script is already running")
                return
            }
            self.scriptStopRequested = false
            self.scriptActive = true
            self.scriptState = ScriptState(name: settings.kind.rawValue, running: true,
                                           progress: 0, total: 1, status: "Starting")
            self.publishScriptState()
            Self.log.info("Script started: \(settings.kind.rawValue)")
            let total: Int
            switch settings.kind {
            case .timelapse, .bulbTimelapse: total = max(1, settings.count)
            case .apertureBracket, .shutterBracket, .isoBracket, .hdr: total = max(2, settings.steps)
            case .delayedTrigger: total = 1
            }
            self.scriptState.total = total
            let work = DispatchWorkItem { [weak self] in self?.runScript(settings) }
            self.scriptTask = work
            self.queue.async(execute: work)
        }
    }

    func stopScript() {
        queue.async { [weak self] in
            self?.scriptStopRequested = true
            Self.log.info("Script stop requested")
        }
    }

    func resetScriptState() {
        queue.async { [weak self] in
            guard let self, self.scriptTask == nil else { return }
            self.scriptState = ScriptState()
            self.publishScriptState()
        }
    }

    private func publishScriptState() {
        let state = scriptState
        DispatchQueue.main.async { [weak self] in self?.onScriptState?(state) }
    }

    private func cancelScript() {
        scriptActive = false
        scriptStopRequested = true
        scriptTask = nil
        scriptState.running = false
        scriptState.status = "Stopped"
        publishScriptState()
    }

    private func finishScript(_ message: String) {
        scriptActive = false
        lastFrameAt = Date().addingTimeInterval(0.4)
        scriptTask = nil
        scriptState.running = false
        scriptState.status = message
        publishScriptState()
        Self.log.info("Script finished: \(message)")
    }

    private func runScript(_ settings: ScriptSettings) {
        if settings.delay > 0 {
            scriptState.status = "Waiting \(Int(settings.delay))s"
            publishScriptState()
            if !sleepInterruptible(settings.delay) {
                finishScript("Stopped")
                return
            }
        }

        switch settings.kind {
        case .delayedTrigger:
            performCapture(source: "script")
            finishScript("Done")

        case .timelapse:
            let total = max(1, settings.count)
            for i in 0..<total {
                if scriptStopRequested { finishScript("Stopped"); return }
                scriptState.progress = i + 1
                scriptState.status = "Frame \(i + 1)/\(total)"
                publishScriptState()
                performCapture(source: "script")
                if i < total - 1, !sleepInterruptible(max(1.0, settings.interval)) {
                    finishScript("Stopped")
                    return
                }
            }
            finishScript("Done · \(total) frames")

        case .bulbTimelapse:
            let total = max(1, settings.count)
            for i in 0..<total {
                if scriptStopRequested { finishScript("Stopped"); return }
                scriptState.progress = i + 1
                scriptState.status = "Bulb \(i + 1)/\(total)"
                publishScriptState()
                performBulb(seconds: settings.bulbSeconds)
                if i < total - 1, !sleepInterruptible(max(1.0, settings.interval)) {
                    finishScript("Stopped")
                    return
                }
            }
            finishScript("Done · \(total) frames")

        case .apertureBracket:
            runBracket(settings, control: "f-number", label: settings.kind.rawValue)
        case .shutterBracket:
            runBracket(settings, control: "shutterspeed", label: settings.kind.rawValue)
        case .isoBracket:
            runBracket(settings, control: "iso", label: settings.kind.rawValue)
        case .hdr:
            runBracket(settings, control: "exposurecompensation", label: "HDR")
        }
    }

    private func runBracket(_ settings: ScriptSettings, control: String, label: String) {
        guard let item = controls.flatMap({ $0.items }).first(where: { $0.name == control }),
              !item.choices.isEmpty,
              let startIndex = item.choices.firstIndex(of: item.current) else {
            finishScript("\(label): setting not available")
            return
        }
        let steps = max(2, settings.steps)
        let half = steps / 2
        var indices: [Int] = []
        for i in 0..<steps {
            let offset = (i - half) * max(1, settings.stepSize)
            indices.append(min(item.choices.count - 1, max(0, startIndex + offset)))
        }
        let original = item.choices[startIndex]
        for (n, index) in indices.enumerated() {
            if scriptStopRequested { break }
            scriptState.progress = n + 1
            scriptState.status = "\(label) \(n + 1)/\(indices.count) · \(item.choices[index])"
            publishScriptState()
            applyControlBlocking(name: control, value: item.choices[index])
            performCapture(source: "script")
        }
        applyControlBlocking(name: control, value: original)
        finishScript(scriptStopRequested ? "Stopped" : "Done · \(indices.count) frames")
    }

    private func applyControlBlocking(name: String, value: String) {
        guard let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }
        guard let node = widget(cfg, name) else { return }
        var type: CameraWidgetType = GP_WIDGET_WINDOW
        _ = gp_widget_get_type(node, &type)
        if type == GP_WIDGET_RANGE {
            var f = Float(value) ?? 0
            _ = gp_widget_set_value(node, &f)
        } else {
            _ = value.withCString { gp_widget_set_value(node, UnsafeRawPointer($0)) }
        }
        let applied = gp_camera_set_config(cam, cfg, ctx)
        if applied != GP_OK { Self.log.warn("Bracket: setting \(name) failed") }
        Thread.sleep(forTimeInterval: 0.8)
        _ = waitUntilReady(timeout: 4)
        loadControls()
    }

    private func performBulb(seconds: Double) {
        guard let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }
        guard let node = widget(cfg, "bulb") else {
            Self.log.warn("Bulb is not exposed by this body")
            return
        }
        var on: Int32 = 2
        _ = gp_widget_set_value(node, &on)
        _ = gp_camera_set_config(cam, cfg, ctx)
        Self.log.info("Bulb open \(seconds)s")
        _ = sleepInterruptible(seconds)
        var off: Int32 = 1
        _ = gp_widget_set_value(node, &off)
        _ = gp_camera_set_config(cam, cfg, ctx)
        Thread.sleep(forTimeInterval: 0.3)
        drainEvents(limit: 40, dwell: 0.01)
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func sleepInterruptible(_ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if scriptStopRequested { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !scriptStopRequested
    }

    // MARK: Stall watchdog

    private func beginCall(_ name: String) {
        callLock.withLock {
            callName = name
            callStartedAt = Date()
            warnedStall = false
        }
    }

    private func endCall() {
        callLock.withLock {
            callName = nil
            callStartedAt = nil
        }
    }

    /// libgphoto2 can block forever in a USB transfer when a body stops
    /// answering (typically after a previous app was killed mid-session).
    /// The watchdog makes that visible instead of looking like "no camera".
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stall: (String, TimeInterval)?
            stall = self.callLock.withLock {
                guard let name = self.callName, let started = self.callStartedAt,
                      !self.warnedStall else { return nil }
                let elapsed = Date().timeIntervalSince(started)
                guard elapsed > 8 else { return nil }
                self.warnedStall = true
                return (name, elapsed)
            }
            guard let (name, elapsed) = stall else { return }
            Self.log.error("Camera stopped responding during \(name) "
                + "(\(Int(elapsed))s) — unplug the USB cable, plug it back in, then press Connect")
            self.status.lastError = "Camera not responding during \(name)"
            self.publishStatus()
        }
        timer.resume()
        watchdog = timer
    }

    /// Tethering is much more reliable when the body keeps the frame on the
    /// card instead of parking it in SDRAM.
    private func ensureCardCaptureTarget() {
        guard let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        guard gp_camera_get_config(cam, &cfg, ctx) == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }
        guard let node = widget(cfg, "capturetarget") else { return }
        let current = widgetStringValue(node) ?? ""
        guard current != "card+sdram" else { return }
        let rc = "card+sdram".withCString { gp_widget_set_value(node, UnsafeRawPointer($0)) }
        guard rc == GP_OK, gp_camera_set_config(cam, cfg, ctx) == GP_OK else { return }
        Thread.sleep(forTimeInterval: 0.3)
        Self.log.info("Capture target → card+sdram (was \(current))")
    }

    /// The a7R III needs a moment after each frame; a config read is the
    /// cheapest way to ask "are you listening yet?".
    private func waitUntilReady(timeout: TimeInterval) -> Bool {
        guard let cam = camera, let ctx = context else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var cfg: OpaquePointer?
            let rc = gp_camera_get_config(cam, &cfg, ctx)
            if rc == GP_OK {
                if let cfg { gp_widget_unref(cfg) }
                return true
            }
            if rc == -53 || rc == GP_ERROR_IO { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// ptpcamerad is a system daemon under SIP; killing it works, and it
    /// respawns without re-claiming while our handle is open.
    private func evictPTPDaemon() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["-9", "ptpcamerad"]
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                Self.log.info("macOS Image Capture daemon was holding the camera — released it")
                return true
            }
        } catch {
            Self.log.warn("Could not release the Image Capture daemon: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: Tick loop / connection

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
        if scriptActive {
            // A script owns the body: no preview, no config reads, just events.
            scheduleTick(0.1)
            return
        }
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
        guard let ctx = context else { return }

        var rc: Int32 = GP_ERROR
        var opened: UnsafeMutablePointer<Camera>?
        for _ in 0..<5 {
            var cam: UnsafeMutablePointer<Camera>? = nil
            guard gp_camera_new(&cam) == GP_OK, let cam else { return }
            beginCall("connect")
            rc = gp_camera_init(cam, ctx)
            endCall()
            if rc == GP_OK {
                opened = cam
                break
            }
            gp_camera_unref(cam)
            // macOS's Image Capture daemon (ptpcamerad) claims PTP bodies and
            // libusb then cannot open them (-53). Ask it to let go, then retry.
            if rc == -53, evictPTPDaemon() {
                Thread.sleep(forTimeInterval: 0.08)
                continue
            }
            break
        }
        guard rc == GP_OK, let cam = opened else {
            let detail = gpErrorText(rc)
            openFailureCount += 1
            status.connected = false
            status.lastError = detail
            let nowDate = Date()
            if openFailureCount <= 2 || openFailureCount % 30 == 0
                || nowDate.timeIntervalSince(lastOpenLog) > 60 {
                lastOpenLog = nowDate
                Self.log.error("Camera connect failed (\(openFailureCount)x): \(detail)")
                Self.log.info("Checklist: body on · USB PC Remote · close Imaging Edge / Lightroom / Smart Shooter")
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
        Self.log.info("Connected: \(status.model.isEmpty ? "unknown body" : status.model)")
        if !status.serial.isEmpty {
            Self.log.info("Serial: \(status.serial) · firmware \(status.firmware)")
        }
        loadControls()
        refreshStatus()
        publishStatus()
        scheduleTick(0.05)
    }

    private func readIdentity() {
        guard let cam = camera, let ctx = context else { return }
        var summary = CameraText()
        if gp_camera_get_summary(cam, &summary, ctx) == GP_OK {
            let text = fixedCString(&summary)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Model:") {
                    status.model = String(trimmed.dropFirst("Model:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Serial Number:") {
                    status.serial = String(trimmed.dropFirst("Serial Number:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Version:") {
                    status.firmware = String(trimmed.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }

    private func closeCamera(reason: String) {
        guard let cam = camera else { return }
        if let ctx = context { _ = gp_camera_exit(cam, ctx) }
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

    // MARK: Events / preview

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
            if type == GP_EVENT_TIMEOUT { free(data); break }
            if type == GP_EVENT_FILE_ADDED, let data {
                let pathPtr = data.assumingMemoryBound(to: CameraFilePath.self)
                let name = fixedCString(&pathPtr.pointee.name)
                let folder = fixedCString(&pathPtr.pointee.folder)
                free(data)
                Self.log.info("Camera file event: \(name)")
                download(folder: folder, name: name, source: "camera", capturedAt: Date())
                if dwell > 0 { Thread.sleep(forTimeInterval: dwell) }
                continue
            }
            free(data)
            if dwell > 0 { Thread.sleep(forTimeInterval: dwell) }
        }
    }

    private func grabPreviewIfDue() {
        guard connected, !previewPaused, !scriptActive, let cam = camera, let ctx = context else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= previewInterval else { return }
        var file: OpaquePointer?
        guard gp_file_new(&file) == GP_OK, let file else { return }
        defer { gp_file_unref(file) }
        let t0 = Date()
        beginCall("live view")
        let rc = gp_camera_capture_preview(cam, file, ctx)
        endCall()
        let took = Date().timeIntervalSince(t0)
        guard rc == GP_OK else {
            previewFailures += 1
            if rc == GP_ERROR {
                if previewFailures > 10, Date().timeIntervalSince(lastPreviewLogAt) > 30 {
                    lastPreviewLogAt = Date()
                    Self.log.debug("Live view re-warming after capture (\(previewFailures) empty frames)")
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
            }
            lastFrameAt = Date().addingTimeInterval(0.3)
            return
        }
        var data: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        guard gp_file_get_data_and_size(file, &data, &size) == GP_OK, let data, size > 0 else { return }
        let payload = Data(bytes: data, count: Int(size))
        lastFrameAt = Date()
        previewFailures = 0
        if status.liveViewState != .running {
            status.liveViewState = .running
            status.lastError = nil
            Self.log.info("Live view running (\(size / 1024) KB/frame)")
        }
        previewDurations.append(took)
        if previewDurations.count > 15 { previewDurations.removeFirst() }
        let avg = previewDurations.reduce(0, +) / Double(previewDurations.count)
        let target = 1.0 / Double(max(1, prefs.liveViewFPS))
        previewInterval = max(target, min(0.30, avg * 1.05))
        liveFrames.append(now)
        if liveFrames.count > 120 { liveFrames.removeFirst() }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(payload) }
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

    // MARK: Status

    private func refreshStatus() {
        lastStatusRefresh = Date()
        guard connected, let cam = camera, let ctx = context else { return }
        var cfg: OpaquePointer?
        beginCall("read status")
        let rc = gp_camera_get_config(cam, &cfg, ctx)
        endCall()
        guard rc == GP_OK, let cfg else { return }
        defer { gp_widget_unref(cfg) }
        if let batteryWidget = widget(cfg, "batterylevel") {
            status.battery = widgetStringValue(batteryWidget)
        }
        if let target = widget(cfg, "capturetarget") {
            status.storage = widgetStringValue(target)
        }
        publishStatus()
    }

    // MARK: Helpers

    private func widget(_ root: OpaquePointer, _ name: String) -> OpaquePointer? {
        var child: OpaquePointer?
        guard gp_widget_get_child_by_name(root, name, &child) == GP_OK else { return nil }
        return child
    }

    private func widgetStringValue(_ node: OpaquePointer) -> String? {
        widgetString { ptr in
            gp_widget_get_value(node, UnsafeMutableRawPointer(ptr))
        }
    }

    private func publishStatus() {
        let snapshot = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
    }
}

// MARK: - C callbacks

func gpErrorCallback(_ ctx: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ data: UnsafeMutableRawPointer?) {
    guard let text else { return }
    let message = String(cString: text)
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
