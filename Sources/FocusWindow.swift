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
            if prefs.transferADBEnabled { self.adbPush(record, prefs: prefs) }
            if prefs.transferSyncEnabled { self.sync(record, prefs: prefs) }
        }
    }

    func pushLast(_ record: PhotoRecord) {
        let prefs = self.prefs
        queue.async { [weak self] in self?.adbPush(record, prefs: prefs) }
    }

    func syncAll(_ records: [PhotoRecord]) {
        let prefs = self.prefs
        queue.async { [weak self] in
            for record in records { self?.sync(record, prefs: prefs) }
        }
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
        let remote = target.hasSuffix("/") ? target + record.name : target + "/" + record.name
        let output = run(adb, ["-s", serial, "push", record.url.path, remote])
        if output.lowercased().contains("error") || output.lowercased().contains("failed") {
            lastADBStatus = "push failed"
            log.warn("ADB push failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lastADBStatus = "pushed \(record.name)"
            log.info("ADB: \(record.name) → \(remote) (\(serial))")
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
        let target = URL(fileURLWithPath: folder).appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: record.url, to: target)
            lastSyncStatus = "synced \(record.name)"
            log.info("Sync: \(record.name) → \(target.path)")
        } catch {
            lastSyncStatus = "sync failed"
            log.warn("Sync failed for \(record.name): \(error.localizedDescription)")
        }
        publish()
    }

    private func publish() {
        TransferStatusBroker.shared.summary = "ADB \(lastADBStatus) · Sync \(lastSyncStatus)"
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

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, image.size.width > 0 else {
            drawOverlay()
            return
        }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let scale = fit * zoom
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        var rect = NSRect(x: (bounds.width - size.width) / 2 + offset.x,
                          y: (bounds.height - size.height) / 2 + offset.y,
                          width: size.width, height: size.height)
        rect = rect.intersection(bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        if showGrid {
            NSColor.white.withAlphaComponent(0.28).setStroke()
            let path = NSBezierPath()
            for i in 1..<3 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                path.move(to: NSPoint(x: x, y: rect.minY))
                path.line(to: NSPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: NSPoint(x: rect.minX, y: y))
                path.line(to: NSPoint(x: rect.maxX, y: y))
            }
            path.lineWidth = 1
            path.stroke()
        }
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
        zoom = min(8, max(1, zoom * factor))
        if zoom == 1 { offset = .zero }
    }

    override func mouseDown(with event: NSEvent) {
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

    override func magnify(with event: NSEvent) {
        zoom = min(8, max(1, zoom * (1 + event.magnification)))
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
    private let overview = NSImageView()
    private let strip = PhotoStripView()
    private let folderLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let statusLabel = makeLabel("waiting for a shot", size: 11)
    private let renameField = NSTextField()
    private let newFolderField = NSTextField()
    private let ratioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let liveCheck = NSButton(checkboxWithTitle: "Live view", target: nil, action: nil)
    private let gridCheck = NSButton(checkboxWithTitle: "Grid overlay", target: nil, action: nil)
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transferLabel = makeLabel("", size: 10, color: .tertiaryLabelColor)

    var photos: [PhotoRecord] = []
    var lastRecord: PhotoRecord?
    var onLiveView: ((Bool) -> Void)?
    var onGrid: ((Bool) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onNewFolder: ((String) -> Bool)?
    var onRename: ((PhotoRecord, String) -> Bool)?
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

        ratioPopup.addItems(withTitles: ["Auto", "Horizontal", "Vertical"])
        ratioPopup.controlSize = .small
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged)

        overview.imageScaling = .scaleProportionallyUpOrDown
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
            folderLabel,
            chooseFolder,
            row([newFolderField, createFolder]),
            makeSectionLabel("Rename last shot"),
            row([renameField, renameButton]),
            statusLabel,
            makeSectionLabel("View"),
            liveCheck,
            gridCheck,
            row([zoomPopup]),
            makeSectionLabel("Overview"),
            row([ratioPopup]),
            overview,
            transferLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: left.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -14),
            overview.widthAnchor.constraint(equalToConstant: 190),
            overview.heightAnchor.constraint(equalToConstant: 140),
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

    func show(_ record: PhotoRecord) {
        lastRecord = record
        guard let image = NSImage(contentsOf: record.url) else { return }
        liveFramesEnabled = false
        liveCheck.state = .off
        bigView.image = image
        bigView.zoom = 1
        bigView.overlay = ""
        updateOverview(image, aspect: record.width >= record.height ? .landscape : .portrait)
        renameField.stringValue = (record.name as NSString).deletingPathExtension
        statusLabel.stringValue = "\(record.name) · \(record.width)×\(record.height) · \(Fmt.bytes(record.bytes))"
        window?.title = "sonyTether — Focus · \(record.name)"
    }

    private enum Aspect { case landscape, portrait }

    private func updateOverview(_ image: NSImage, aspect: Aspect) {
        overview.imageScaling = .scaleProportionallyUpOrDown
        let choice = ratioPopup.titleOfSelectedItem ?? "Auto"
        let vertical = choice == "Vertical" || (choice == "Auto" && aspect == .portrait)
        if choice == "Vertical" {
            overview.image = Self.rotated(image, degrees: 90)
        } else if choice == "Horizontal" {
            overview.image = image
        } else {
            overview.image = vertical ? Self.rotated(image, degrees: 90) : image
        }
    }

    /// Rotates a copy so the small overview can show a portrait crop of a
    /// landscape frame.
    static func rotated(_ image: NSImage, degrees: CGFloat) -> NSImage {
        let radians = degrees * .pi / 180
        let width = abs(cos(radians)) * image.size.width + abs(sin(radians)) * image.size.height
        let height = abs(sin(radians)) * image.size.width + abs(cos(radians)) * image.size.height
        let out = NSImage(size: NSSize(width: width, height: height))
        out.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: width / 2, yBy: height / 2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -image.size.width / 2, yBy: -image.size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    // MARK: Actions

    @objc private func chooseFolder() { onChooseFolder?() }

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

    @objc private func ratioChanged() {
        if let record = lastRecord, let image = NSImage(contentsOf: record.url) {
            updateOverview(image, aspect: record.width >= record.height ? .landscape : .portrait)
        }
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
}
