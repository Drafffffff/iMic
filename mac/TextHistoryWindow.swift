import AppKit

/// Local text history: browse, search and copy original/final text of every utterance.
final class TextHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: TextHistoryStore
    private var all: [TextHistoryEntry] = []
    private var shown: [TextHistoryEntry] = []

    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailMeta = NSTextField(wrappingLabelWithString: "")
    private let finalText = TextHistoryWindowController.readOnlyTextView()
    private let originalText = TextHistoryWindowController.readOnlyTextView()
    private var finalCopy: NSButton!
    private var originalCopy: NSButton!
    private var deleteButton: NSButton!
    private var clearButton: NSButton!
    private let detail = NSStackView()
    private let detailPlaceholder = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?

    init(store: TextHistoryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text("Text History")
        window.minSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VoxChordTextHistory")
        super.init(window: window)
        window.delegate = self
        build()
        observer = NotificationCenter.default.addObserver(forName: TextHistoryStore.didChange, object: store, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reload(keepSelection: true)
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func present() {
        reload(keepSelection: true)
        if window?.isVisible != true { window?.center() }
        DockPresence.willShowWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(search)
    }

    // MARK: - Layout

    private static func readOnlyTextView() -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        return view
    }

    private func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .semibold, muted: Bool = true) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        if muted { field.textColor = .secondaryLabelColor }
        return field
    }

    private func textSection(_ title: String, _ textView: NSTextView, copy: Selector) -> (NSView, NSButton) {
        let heading = label(title)
        let button = NSButton(title: L10n.text("Copy"), target: self, action: copy)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel("\(L10n.text("Copy")) · \(title)")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, button])
        header.orientation = .horizontal
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        let section = NSStackView(views: [header, scroll])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return (section, button)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        search.placeholderString = L10n.text("Search text or app")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        clearButton = NSButton(title: L10n.text("Clear History…"), target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .rounded
        let top = NSStackView(views: [search, countLabel, clearButton])
        top.orientation = .horizontal
        top.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.usesAutomaticRowHeights = false
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(L10n.text("Text History"))
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let listContainer = NSView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listScroll)
        listContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -24),
            listContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])

        detailMeta.font = .systemFont(ofSize: 12)
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.isSelectable = true
        let (finalSection, finalButton) = textSection(L10n.text("Final text"), finalText, copy: #selector(copyFinal))
        let (originalSection, originalButton) = textSection(L10n.text("Original recognition"), originalText, copy: #selector(copyOriginal))
        finalCopy = finalButton
        originalCopy = originalButton
        deleteButton = NSButton(title: L10n.text("Delete Entry"), target: self, action: #selector(deleteSelected))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        let privacy = label(L10n.text("Saved only on this Mac. Never uploaded."), size: 11, weight: .regular)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [privacy, footerSpacer, deleteButton])
        footer.orientation = .horizontal
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 14
        for view in [detailMeta, finalSection, originalSection, footer] {
            detail.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        finalSection.heightAnchor.constraint(equalTo: originalSection.heightAnchor).isActive = true
        detail.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        detailPlaceholder.stringValue = L10n.text("Select an entry to view its text.")
        detailPlaceholder.alignment = .center
        detailPlaceholder.textColor = .secondaryLabelColor
        let detailContainer = NSView()
        for view in [detail, detailPlaceholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            detailPlaceholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            detailPlaceholder.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 24),
            detailPlaceholder.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -24),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listContainer)
        split.addArrangedSubview(detailContainer)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        for view in [top, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        DispatchQueue.main.async { split.setPosition(320, ofDividerAt: 0) }
    }

    // MARK: - Data

    private func reload(keepSelection: Bool) {
        let selectedID = keepSelection ? selectedEntry?.id : nil
        all = store.entries()
        shown = TextHistorySearch.filter(all, query: search.stringValue)
        table.reloadData()
        if let selectedID, let row = shown.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        let query = !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        countLabel.stringValue = query
            ? L10n.text("%@ of %@ entries", L10n.argument(shown.count), L10n.argument(all.count))
            : L10n.text("%@ entries", L10n.argument(all.count))
        emptyLabel.stringValue = all.isEmpty
            ? L10n.text("No history yet. Text from each recording is saved here, on this Mac only.")
            : L10n.text("No matches")
        emptyLabel.isHidden = !shown.isEmpty
        clearButton.isEnabled = !all.isEmpty
        showDetail()
    }

    private var selectedEntry: TextHistoryEntry? {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
    }

    private func showDetail() {
        guard let entry = selectedEntry else {
            detail.isHidden = true
            detailPlaceholder.isHidden = shown.isEmpty
            return
        }
        detail.isHidden = false
        detailPlaceholder.isHidden = true
        detailMeta.stringValue = [Self.fullDate(entry.date), Self.appName(entry),
                                  Self.modeTitle(entry), Self.outcomeTitle(entry.outcome)].joined(separator: " · ")
        finalText.string = entry.final
        originalText.string = entry.original
        finalCopy.isEnabled = !entry.final.isEmpty
        originalCopy.isEnabled = !entry.original.isEmpty
    }

    static func appName(_ entry: TextHistoryEntry) -> String {
        entry.appName.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Unknown app")
    }

    static func modeTitle(_ entry: TextHistoryEntry) -> String {
        guard let polish = entry.polish else { return L10n.text("Recognition only") }
        var parts = [PolishMode(rawValue: polish.mode)?.title ?? polish.mode]
        if let tone = PolishTone(rawValue: polish.tone), tone != .normal { parts.append(tone.title) }
        if let output = PolishOutput(rawValue: polish.output), polish.mode != PolishMode.terminal.rawValue {
            parts.append(output.title)
        }
        if polish.fallback { parts.append(L10n.text("Polish fell back to the original")) }
        return parts.joined(separator: " · ")
    }

    static func outcomeTitle(_ outcome: TextHistoryEntry.Outcome) -> String {
        switch outcome {
        case .typed: return L10n.text("Typed")
        case .kept: return L10n.text("Not typed · kept here")
        case .failed: return L10n.text("Interrupted")
        }
    }

    private static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TextHistoryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TextHistoryCell ?? {
            let cell = TextHistoryCell(); cell.identifier = id; return cell
        }()
        let entry = shown[row]
        cell.meta.stringValue = "\(Self.shortDate(entry.date)) · \(Self.appName(entry))"
        cell.marker.isHidden = entry.outcome == .typed
        cell.marker.toolTip = Self.outcomeTitle(entry.outcome)
        let preview = (entry.final.isEmpty ? entry.original : entry.final)
            .replacingOccurrences(of: "\n", with: " ")
        cell.preview.stringValue = preview
        cell.setAccessibilityLabel("\(cell.meta.stringValue) · \(Self.outcomeTitle(entry.outcome)) · \(preview)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showDetail() }

    func controlTextDidChange(_ obj: Notification) { reload(keepSelection: true) }

    @objc private func searchChanged() { reload(keepSelection: true) }

    // MARK: - Actions

    private func copy(_ text: String, button: NSButton) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        button.title = L10n.text("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { button.title = L10n.text("Copy") }
    }

    @objc private func copyFinal() { selectedEntry.map { copy($0.final, button: finalCopy) } }
    @objc private func copyOriginal() { selectedEntry.map { copy($0.original, button: originalCopy) } }

    /// ⌘C in the list copies the selected entry's final text.
    @objc func copy(_ sender: Any?) {
        if let responder = window?.firstResponder as? NSTextView, responder.selectedRange().length > 0 {
            responder.copy(sender); return
        }
        copyFinal()
    }

    @objc private func deleteSelected() {
        guard let entry = selectedEntry else { return }
        store.delete(id: entry.id)
    }

    @objc private func clearAll() {
        guard let window, !all.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Clear all text history on this Mac?")
        alert.informativeText = L10n.text("This permanently deletes every saved original and final text. It cannot be undone.")
        alert.addButton(withTitle: L10n.text("Clear History"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.clear()
        }
    }
}

private final class TextHistoryCell: NSTableCellView {
    let meta = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    let marker = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 13)
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        // Orange marks entries that were not typed: the ones most likely to need recovery.
        marker.wantsLayer = true
        marker.layer?.backgroundColor = MicBrand.orange.cgColor
        marker.layer?.cornerRadius = 3
        for view in [meta, preview, marker] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 6),
            marker.heightAnchor.constraint(equalToConstant: 6),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            marker.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            meta.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 6),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            meta.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            preview.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 3)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// Sample entries for `--ui-preview=history`, written to a temporary store only.
enum TextHistoryPreview {
    static func seed(_ store: TextHistoryStore) {
        let now = Date()
        store.append(TextHistoryEntry(date: now.addingTimeInterval(-3_600 * 26), appName: "Notes", bundleID: "com.apple.Notes",
            original: L10n.text("Preview history: remember to send the revised layout tomorrow morning"),
            final: L10n.text("Preview history: remember to send the revised layout tomorrow morning"),
            polish: nil, outcome: .typed))
        store.append(TextHistoryEntry(date: now.addingTimeInterval(-540), appName: "Terminal", bundleID: "com.apple.Terminal",
            original: L10n.text("Preview history: list the ten largest files in downloads"),
            final: "ls -S ~/Downloads | head -n 10",
            polish: .init(mode: PolishMode.terminal.rawValue, tone: PolishTone.normal.rawValue,
                          output: PolishOutput.chinese.rawValue, fallback: false), outcome: .typed))
        store.append(TextHistoryEntry(date: now.addingTimeInterval(-60), appName: "Mail", bundleID: "com.apple.mail",
            original: L10n.text("Preview history: um so the meeting is moved to thursday afternoon I think three"),
            final: L10n.text("Preview history: The meeting has moved to Thursday at 3 p.m."),
            polish: .init(mode: PolishMode.agent.rawValue, tone: PolishTone.normal.rawValue,
                          output: PolishOutput.chinese.rawValue, fallback: false), outcome: .kept))
    }
}
