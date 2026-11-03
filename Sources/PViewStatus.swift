import AppKit

struct PViewStatusData {
    var cameraConnected = false
    var liveOn = false
    var battery = "—"
    var storage = "—"
    var exposure = "—"
    var lastError = ""
    var adbEnabled = false
    var adbDevice = "—"
    var adbLast = "—"
    var syncEnabled = false
    var syncReachable = false
    var syncLast = "—"
    var folder = "—"
    var prefix = "—"
    var nextNumber = 0
    var fileCounter = "—"
    var lastFile = "—"
    var scriptName = ""
    var scriptRunning = false
    var apiOn = false
    var nextRestart = "—"
    var phoneNote = "—"
}

/// The scrollable status panel in the Photographer View. Toggle rows are
/// buttons (green = on, red = off); the rest are plain indicators.
final class PViewStatusView: NSView {
    var onToggle: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var rows: [String: (NSView, NSView, NSTextField)] = [:]  // key → (row, dot, value)
    private var last = PViewStatusData()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        buildRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildRows() {
        let toggles: [(String, String)] = [
            ("camera", "Camera"),
            ("live", "Live view"),
            ("adb", "ADB push"),
            ("sync", "Folder sync"),
            ("api", "External API"),
            ("stayawake", "Phone stays on"),
        ]
        let indicators: [(String, String)] = [
            ("battery", "Battery"),
            ("storage", "Camera storage"),
            ("exposure", "Exposure"),
            ("adbdevice", "ADB device"),
            ("adblast", "Last push"),
            ("nas", "Server"),
            ("synclast", "Last sync"),
            ("folder", "Folder"),
            ("prefix", "Prefix / next"),
            ("last", "Last file"),
            ("script", "Script"),
            ("restart", "Auto restart"),
            ("error", "Last error"),
            ("phone", "Phone"),
        ]
        stack.addArrangedSubview(makeSectionLabel("Status"))
        for (key, title) in toggles {
            let button = NSButton(title: title, target: self, action: #selector(toggleRow(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key)
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            let dot = Dot(color: .systemRed)
            let row = NSStackView(views: [dot, button])
            row.orientation = .horizontal
            row.spacing = 6
            row.identifier = NSUserInterfaceItemIdentifier("row-" + key)
            stack.addArrangedSubview(row)
            rows[key] = (row, dot, NSTextField(labelWithString: ""))
        }
        for (key, title) in indicators {
            let label = makeLabel(title, size: 9, color: .tertiaryLabelColor)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let value = makeLabel("—", size: 10, weight: .medium)
            value.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.spacing = 4
            row.identifier = NSUserInterfaceItemIdentifier("row-" + key)
            stack.addArrangedSubview(row)
            rows[key] = (row, label, value)
        }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        onToggle?(sender.identifier?.rawValue ?? "")
    }

    func update(_ data: PViewStatusData) {
        last = data
        setToggle("camera", on: data.cameraConnected, title: data.cameraConnected ? "Camera connected" : "Camera disconnected")
        setToggle("live", on: data.liveOn, title: data.liveOn ? "Live view on" : "Live view off")
        setToggle("adb", on: data.adbEnabled, title: data.adbEnabled ? "ADB on" : "ADB off")
        setToggle("sync", on: data.syncEnabled, title: data.syncEnabled ? "Sync on" : "Sync off")
        setToggle("api", on: data.apiOn, title: data.apiOn ? "API on" : "API off")
        setIndicator("battery", data.battery)
        setIndicator("storage", data.storage)
        setIndicator("exposure", data.exposure)
        setIndicator("adbdevice", data.adbDevice)
        setIndicator("adblast", data.adbLast)
        setIndicator("nas", data.syncReachable ? "reachable" : "not mounted", color: data.syncReachable ? .systemGreen : .systemRed)
        setIndicator("synclast", data.syncLast)
        setIndicator("folder", data.folder)
        setIndicator("prefix", "\(data.prefix) · \(String(format: "%04d", data.nextNumber))")
        setIndicator("last", "\(data.fileCounter) · \(data.lastFile)")
        setIndicator("script", data.scriptRunning ? (data.scriptName + " running") : "idle")
        setIndicator("restart", data.nextRestart)
        setIndicator("error", data.lastError.isEmpty ? "none" : data.lastError)
        setIndicator("phone", data.phoneNote)
    }

    private func setToggle(_ key: String, on: Bool, title: String) {
        guard let (_, dot, _) = rows[key], let button = (rows[key]?.0 as? NSStackView)?.views.last as? NSButton else { return }
        button.title = title
        button.contentTintColor = on ? .systemGreen : .systemRed
        (dot as? Dot)?.color = on ? .systemGreen : .systemRed
    }

    private func setIndicator(_ key: String, _ text: String, color: NSColor = .labelColor) {
        guard let (_, _, value) = rows[key] else { return }
        value.stringValue = text
        value.textColor = color
    }
}

final class Dot: NSView {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    init(color: NSColor) {
        super.init(frame: .zero)
        self.color = color
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 7).isActive = true
        heightAnchor.constraint(equalToConstant: 7).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
