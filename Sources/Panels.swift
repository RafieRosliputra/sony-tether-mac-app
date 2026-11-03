import AppKit

// MARK: - Filename / session panel

final class FilenamePanel: NSView {
    var onChange: (() -> Void)?

    let sessionNameField = NSTextField()
    let sessionNumberField = NSTextField()
    let batchField = NSTextField()
    let uniqueTagField = NSTextField()
    let barcodeField = NSTextField()
    let sequenceLabel = makeLabel("1", size: 11, weight: .medium)
    let prefixCombo = NSComboBox()
    let nextNumberLabel = makeLabel("", size: 11, weight: .medium)
    let expressionPreview = makeLabel("", size: 10, color: .secondaryLabelColor)

    private let numberStepper = NSStepper()
    private let batchStepper = NSStepper()

    var onResyncBatch: (() -> Void)?
    var onBarcode: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = makeLabel("Filename Options", size: 13, weight: .semibold)

        for f in [sessionNameField, uniqueTagField, barcodeField] {
            f.font = NSFont.systemFont(ofSize: 11)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
        }
        sessionNameField.placeholderString = "session name"
        uniqueTagField.placeholderString = "unique tag"
        barcodeField.placeholderString = "scan barcode…"

        for f in [sessionNumberField, batchField] {
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.controlSize = .small
            f.isEditable = false
            f.isBordered = false
            f.alignment = .right
        }

        prefixCombo.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        prefixCombo.controlSize = .small
        prefixCombo.completes = true
        prefixCombo.numberOfVisibleItems = 8
        prefixCombo.target = self
        prefixCombo.action = #selector(changed)
        prefixCombo.widthAnchor.constraint(equalToConstant: 150).isActive = true
        barcodeField.target = self
        barcodeField.action = #selector(barcodeEntered)
        sessionNameField.target = self
        sessionNameField.action = #selector(changed)
        uniqueTagField.target = self
        uniqueTagField.action = #selector(changed)

        numberStepper.minValue = 0; numberStepper.maxValue = 9999; numberStepper.increment = 1
        numberStepper.valueWraps = false
        numberStepper.controlSize = .small
        numberStepper.target = self; numberStepper.action = #selector(stepperChanged)
        batchStepper.minValue = 0; batchStepper.maxValue = 9999; batchStepper.increment = 1
        batchStepper.valueWraps = false
        batchStepper.controlSize = .small
        batchStepper.target = self; batchStepper.action = #selector(stepperChanged)

        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let l = makeLabel(label, size: 11, color: .secondaryLabelColor)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let s = NSStackView(views: [l] + views)
            s.orientation = .horizontal
            s.spacing = 4
            s.alignment = .centerY
            return s
        }

        let resync = makeButton("Resync Batch Number", target: self, action: #selector(resyncBatch))
        let tagRow = row("Unique Tag", [uniqueTagField])
        prefixCombo.translatesAutoresizingMaskIntoConstraints = false
        let stackRows: [NSView] = [
            row("Prefix", [prefixCombo]),
            row("Next file", [nextNumberLabel]),
            row("Session Name", [sessionNameField]),
            row("Session Number", [sessionNumberField, numberStepper]),
            row("Sequence", [sequenceLabel]),
            row("Batch Number", [batchField, batchStepper]),
            tagRow,
            row("Barcode", [barcodeField]),
            resync,
            expressionPreview,
        ]

        let stack = NSStackView(views: [title] + stackRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        sessionNameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        uniqueTagField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        barcodeField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        expressionPreview.maximumNumberOfLines = 2
        expressionPreview.preferredMaxLayoutWidth = 250
        expressionPreview.lineBreakMode = .byTruncatingMiddle
    }

    @objc private func changed() { onChange?() }
    @objc private func stepperChanged() { onChange?() }
    @objc private func resyncBatch() { onResyncBatch?() }
    @objc private func barcodeEntered() {
        onBarcode?(barcodeField.stringValue)
    }

    func renderPrefixes(_ prefixes: [String], current: String, nextNumber: Int) {
        prefixCombo.removeAllItems()
        prefixCombo.addItems(withObjectValues: prefixes)
        prefixCombo.stringValue = current
        nextNumberLabel.stringValue = String(format: "%04d", nextNumber)
    }

    var prefixValue: String { prefixCombo.stringValue }

    func render(session: SessionSnapshot, preview: String) {
        sessionNameField.stringValue = session.name
        sessionNumberField.stringValue = "\(session.number)"
        batchField.stringValue = "\(session.batch)"
        uniqueTagField.stringValue = session.uniqueTag
        barcodeField.stringValue = session.barcode
        sequenceLabel.stringValue = "\(session.sequence)"
        expressionPreview.stringValue = preview
        numberStepper.integerValue = session.number
        batchStepper.integerValue = session.batch
    }
}

// MARK: - Script panel

final class ScriptPanel: NSView {
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countField = NSTextField()
    private let intervalField = NSTextField()
    private let delayField = NSTextField()
    private let stepsField = NSTextField()
    private let bulbField = NSTextField()
    private let statusLabel = makeLabel("Ready", size: 11)
    private let progress = NSProgressIndicator()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let hint = makeLabel("", size: 10, color: .secondaryLabelColor)

    var onRun: ((ScriptSettings) -> Void)?
    var onStop: (() -> Void)?

    private var settings = ScriptSettings()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = makeLabel("Script Controls", size: 13, weight: .semibold)
        kindPopup.addItems(withTitles: ScriptKind.shipped.map { $0.rawValue })
        kindPopup.controlSize = .small
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)

        for f in [countField, intervalField, delayField, stepsField, bulbField] {
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
            f.alignment = .right
        }
        countField.stringValue = "10"
        intervalField.stringValue = "4"
        delayField.stringValue = "3"
        stepsField.stringValue = "3"
        bulbField.stringValue = "8"

        runButton.target = self; runButton.action = #selector(run)
        stopButton.target = self; stopButton.action = #selector(stop)
        runButton.controlSize = .small; runButton.bezelStyle = .rounded
        stopButton.controlSize = .small; stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        runButton.bezelColor = .controlAccentColor
        runButton.contentTintColor = .white

        progress.isIndeterminate = false
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.controlSize = .small

        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let l = makeLabel(label, size: 11, color: .secondaryLabelColor)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let s = NSStackView(views: [l] + views)
            s.orientation = .horizontal
            s.spacing = 4
            s.alignment = .centerY
            return s
        }
        for f in [countField, intervalField, delayField, stepsField, bulbField] {
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }

        let buttons = NSStackView(views: [runButton, stopButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [
            title,
            kindPopup,
            row("Frames", [countField]),
            row("Interval s", [intervalField]),
            row("Delay s", [delayField]),
            row("Steps", [stepsField]),
            row("Bulb s", [bulbField]),
            buttons,
            statusLabel,
            progress,
            hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        kindPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 250).isActive = true
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 250
        statusLabel.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 250
        hint.lineBreakMode = .byWordWrapping
        updateHint()
    }

    @objc private func kindChanged() {
        updateHint()
    }

    private func updateHint() {
        guard let kind = ScriptKind(rawValue: kindPopup.titleOfSelectedItem ?? "") else { return }
        switch kind {
        case .timelapse: hint.stringValue = "Frames × interval, each frame downloaded and named."
        case .bulbTimelapse: hint.stringValue = "Bulb exposure per frame, then interval."
        case .apertureBracket, .shutterBracket, .isoBracket, .hdr:
            hint.stringValue = "Parked in 0.2.0 — the body hangs when settings change between frames."
        case .delayedTrigger: hint.stringValue = "Single frame after the delay."
        }
    }

    @objc private func run() {
        guard let kind = ScriptKind(rawValue: kindPopup.titleOfSelectedItem ?? "") else { return }
        settings = ScriptSettings(kind: kind,
                                  steps: max(2, Int(stepsField.stringValue) ?? 3),
                                  stepSize: 1,
                                  count: max(1, Int(countField.stringValue) ?? 10),
                                  interval: max(0.5, Double(intervalField.stringValue) ?? 5),
                                  delay: max(0, Double(delayField.stringValue) ?? 3),
                                  bulbSeconds: max(1, Double(bulbField.stringValue) ?? 8))
        onRun?(settings)
    }

    @objc private func stop() { onStop?() }

    func render(_ state: CameraService.ScriptState) {
        runButton.isEnabled = !state.running
        stopButton.isEnabled = state.running
        statusLabel.stringValue = state.name.isEmpty ? "Ready" : "\(state.name) · \(state.status)"
        progress.maxValue = Double(max(1, state.total))
        progress.doubleValue = Double(state.progress)
        progress.isHidden = !state.running && state.progress == 0
    }
}

// MARK: - Photos table

final class PhotosView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let summary = makeLabel("0 photos", size: 11, color: .secondaryLabelColor)
    private(set) var photos: [PhotoRecord] = []

    var onOpen: ((PhotoRecord) -> Void)?
    var onReveal: ((PhotoRecord) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let columns: [(String, String, CGFloat)] = [
        ("name", "Name", 190), ("time", "Time", 70), ("size", "Size", 90),
        ("format", "Format", 60), ("aperture", "Aperture", 66), ("shutter", "Shutter", 66),
        ("iso", "ISO", 50), ("batch", "Batch", 50), ("session", "Session", 60),
        ("tag", "Tag", 90), ("bytes", "Bytes", 70),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(openSelected)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reveal = makeButton("Show in Finder", target: self, action: #selector(revealSelected))
        let open = makeButton("Open", target: self, action: #selector(openSelected))
        let folder = makeButton("Choose Folder…", target: self, action: #selector(chooseFolder))
        let buttons = NSStackView(views: [open, reveal, folder])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        summary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(buttons)
        addSubview(summary)

        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summary.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setPhotos(_ list: [PhotoRecord]) {
        photos = list
        table.reloadData()
        summary.stringValue = "\(list.count) photos · \(Fmt.bytes(list.reduce(0) { $0 + $1.bytes }))"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { photos.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < photos.count else { return nil }
        let p = photos[row]
        let text: String
        switch column.identifier.rawValue {
        case "name": text = p.name
        case "time": text = Fmt.time.string(from: p.capturedAt)
        case "size": text = p.width > 0 ? "\(p.width)×\(p.height)" : "—"
        case "format": text = p.format
        case "aperture": text = p.aperture
        case "shutter": text = p.shutter
        case "iso": text = p.iso
        case "batch": text = "\(p.batch)"
        case "session": text = "\(p.sessionNumber)"
        case "tag": text = p.uniqueTag
        case "bytes": text = Fmt.bytes(p.bytes)
        default: text = ""
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        }
        cell.stringValue = text
        return cell
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < photos.count else { return }
        onOpen?(photos[row])
    }

    @objc private func revealSelected() {
        let row = table.selectedRow
        guard row >= 0, row < photos.count else { return }
        onReveal?(photos[row])
    }

    @objc private func chooseFolder() { onChooseFolder?() }
}

// MARK: - Log pane

final class LogPane: NSView {
    private let textView = NSTextView()
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pauseCheck = NSButton(checkboxWithTitle: "Pause", target: nil, action: nil)
    private var paused = false
    private var minLevel = 0
    private let levels: [(String, Int)] = [("All", 0), ("Info", 1), ("Warnings", 2), ("Errors", 3)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        Logger.shared.onLine = { [weak self] line in self?.append(line) }
        for line in Logger.shared.lines { append(line) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let title = makeSectionLabel("Log Viewer")
        levelPopup.addItems(withTitles: levels.map { $0.0 })
        levelPopup.controlSize = .mini
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)
        pauseCheck.target = self
        pauseCheck.action = #selector(togglePause)
        pauseCheck.controlSize = .mini

        let clear = makeButton("Clear", target: self, action: #selector(clear))
        let reveal = makeButton("Reveal log file", target: self, action: #selector(revealLog))
        let buttons = NSStackView(views: [levelPopup, pauseCheck, clear, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView

        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(buttons)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            buttons.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @objc private func levelChanged() {
        minLevel = levels[levelPopup.indexOfSelectedItem].1
    }

    @objc private func togglePause() { paused = pauseCheck.state == .on }
    @objc private func clear() { textView.string = "" }
    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.fileURL])
    }

    private func append(_ line: Logger.Line) {
        guard !paused, let storage = textView.textStorage else { return }
        let rank: Int
        switch line.level {
        case .debug: rank = 0
        case .info: rank = 1
        case .warn: rank = 2
        case .error: rank = 3
        }
        guard rank >= minLevel else { return }
        let color: NSColor
        switch line.level {
        case .error: color = .systemRed
        case .warn: color = .systemOrange
        case .debug: color = .tertiaryLabelColor
        case .info: color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color,
        ]
        storage.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        if storage.length > 500_000 {
            storage.deleteCharacters(in: NSRange(location: 0, length: 150_000))
        }
        textView.scrollToEndOfDocument(nil)
    }
}
