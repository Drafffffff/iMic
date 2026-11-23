import AppKit
import UniformTypeIdentifiers

/// Sample terms for --ui-preview=vocabulary. Never written to disk.
enum VocabularyPreview {
    static let entries: [VocabularyEntry] = [
        VocabularyEntry(term: "VoxChord"),
        VocabularyEntry(term: "Kubernetes", weight: 5, modes: [.agent, .terminal]),
        VocabularyEntry(term: "Argo CD"),
        VocabularyEntry(term: "Otty", weight: 3, enabled: false)
    ]
}

extension VocabularyIssue {
    var message: String {
        switch self {
        case .empty: return L10n.text("Enter a term")
        case .invalidCharacters: return L10n.text("Terms cannot contain line breaks or tabs.")
        case .tooLong: return L10n.text("Terms with Chinese or other non-ASCII characters can have up to 15 characters.")
        case .tooManyWords: return L10n.text("English terms can have up to 7 words.")
        case .duplicate: return L10n.text("This term already exists")
        case .limit: return L10n.text("Up to 2,000 terms can be enabled")
        }
    }
}

/// Settings › Vocabulary: add, edit, enable per mode, remove, import and export.
final class VocabularySettingsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let store: VocabularyStore
    private let defaults: UserDefaults
    let table = NSTableView()
    let addField = NSTextField()
    let issueLabel = NSTextField(wrappingLabelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let rejectedLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var removeButton: NSButton!
    private var observer: NSObjectProtocol?
    private static let termColumn = NSUserInterfaceItemIdentifier("term")
    private static let enabledColumn = NSUserInterfaceItemIdentifier("enabled")
    private static let weightColumn = NSUserInterfaceItemIdentifier("weight")
    private static let modesColumn = NSUserInterfaceItemIdentifier("modes")

    init(store: VocabularyStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        super.init()
        observer = NotificationCenter.default.addObserver(forName: VocabularyStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private var entries: [VocabularyEntry] { store.entries }

    // MARK: - Layout

    /// Views for the settings column; `note`, `heading`, `checkbox` come from the coordinator for a consistent style.
    func makeViews(note: (String) -> NSTextField, heading: (String) -> NSView,
                   checkbox: (String, String) -> NSButton) -> [NSView] {
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = .imicMuted
        countLabel.alignment = .right
        let header = NSStackView(views: [heading("VOCABULARY"), NSView(), countLabel])
        header.orientation = .horizontal

        let recognition = checkbox(L10n.text("Use vocabulary during recognition"), "vocabulary.recognition")
        let polish = checkbox(L10n.text("Protect vocabulary spelling when polishing"), "vocabulary.polish")

        addField.placeholderString = L10n.text("Add a term")
        addField.setAccessibilityLabel(L10n.text("Add a term"))
        addField.target = self; addField.action = #selector(addTerm)
        addField.delegate = self
        let add = NSButton(title: L10n.text("Add"), target: self, action: #selector(addTerm))
        add.bezelStyle = .rounded; add.setAccessibilityLabel(add.title)
        let addRow = NSStackView(views: [addField, add])
        addRow.orientation = .horizontal; addRow.spacing = 8
        addField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        issueLabel.font = .systemFont(ofSize: 11); issueLabel.textColor = .imicOrange
        issueLabel.isHidden = true
        rejectedLabel.font = .systemFont(ofSize: 11); rejectedLabel.textColor = .imicOrange
        rejectedLabel.stringValue = L10n.text("Model Studio rejected the vocabulary in a recent recording, so it was recognized without it. Check for unusual terms.")

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        removeButton = NSButton(title: L10n.text("Remove"), target: self, action: #selector(removeSelected))
        let importButton = NSButton(title: L10n.text("Import…"), target: self, action: #selector(importTerms))
        let exportButton = NSButton(title: L10n.text("Export…"), target: self, action: #selector(exportTerms))
        for button in [removeButton!, importButton, exportButton] {
            button.bezelStyle = .rounded; button.controlSize = .small; button.setAccessibilityLabel(button.title)
        }
        let actions = NSStackView(views: [removeButton, NSView(), importButton, exportButton])
        actions.orientation = .horizontal

        reload()
        return [header,
                note(L10n.text("Terms help recognition spell names, products, and technical words correctly. They stay on this Mac and are sent with each recognition request to Model Studio; nothing is stored in the cloud.")),
                recognition, polish,
                note(L10n.text("Polish only keeps these spellings. It does not add terms you did not say.")),
                addRow, issueLabel, rejectedLabel, scroll, actions,
                note(L10n.text("Higher weight makes a term more likely; too high may replace similar-sounding words.")),
                note(L10n.text("Plain text: one term per line, optionally followed by a tab, a weight from 1 to 5, another tab, and modes. Weight defaults to 4."))]
    }

    private func configureTable() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.enabledColumn, L10n.text("Enabled"), 70),
            (Self.termColumn, L10n.text("Term"), 168),
            (Self.weightColumn, L10n.text("Weight"), 64),
            (Self.modesColumn, L10n.text("Modes"), 140)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: id)
            column.title = title; column.width = width; column.minWidth = min(width, 44)
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel(L10n.text("Vocabulary"))
    }

    func reload() {
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(IndexSet(selected.filter { $0 < entries.count }), byExtendingSelection: false)
        countLabel.stringValue = "\(entries.filter(\.enabled).count) / \(Vocabulary.maxEnabled)"
        rejectedLabel.isHidden = !defaults.bool(forKey: "vocabulary.lastRejected")
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private func show(_ issue: VocabularyIssue?) {
        issueLabel.stringValue = issue?.message ?? ""
        issueLabel.isHidden = issue == nil
    }

    private func show(message: String) {
        issueLabel.stringValue = message
        issueLabel.isHidden = message.isEmpty
    }

    /// Any edit clears the stale "rejected" warning: the user is fixing the vocabulary.
    private func commit(_ change: (inout [VocabularyEntry]) -> Void) -> Bool {
        do {
            try store.update(change)
            defaults.removeObject(forKey: "vocabulary.lastRejected")
            reload()
            return true
        } catch {
            show(message: L10n.text("Could not save the vocabulary"))
            return false
        }
    }

    // MARK: - Actions

    @objc func addTerm() {
        let term = Vocabulary.normalize(addField.stringValue)
        if let issue = Vocabulary.issue(adding: term, to: entries) { show(issue); return }
        guard commit({ $0.append(VocabularyEntry(term: term)) }) else { return }
        show(nil)
        addField.stringValue = ""
        table.scrollRowToVisible(entries.count - 1)
    }

    @objc func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let ids = Set(rows.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
        _ = commit { $0.removeAll { ids.contains($0.id) } }
        table.deselectAll(nil)
        show(nil)
    }

    @objc private func importTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            show(message: L10n.text("Could not read this file")); return
        }
        importText(text)
    }

    /// Merges parsed terms after the existing list; duplicates and invalid lines are skipped.
    @discardableResult
    func importText(_ text: String) -> Vocabulary.ImportResult {
        let result = Vocabulary.parse(text, existing: entries)
        if !result.entries.isEmpty, !commit({ $0.append(contentsOf: result.entries) }) { return result }
        show(message: L10n.text("Imported %@ terms, skipped %@", L10n.argument(String(result.entries.count)), L10n.argument(String(result.skipped))))
        return result
    }

    @objc private func exportTerms() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = L10n.text("VoxChord Vocabulary") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Vocabulary.export(entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show(message: L10n.text("Could not save the vocabulary"))
        }
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        let enabled = sender.state == .on
        if enabled, let issue = Vocabulary.issue(adding: entry.term, to: entries, replacing: entry.id) {
            sender.state = .off; show(issue); return
        }
        _ = commit { $0[row].enabled = enabled }
        show(nil)
    }

    @objc private func changeWeight(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard entries.indices.contains(row) else { return }
        let weight = Vocabulary.clampWeight(sender.indexOfSelectedItem + Vocabulary.weights.lowerBound)
        _ = commit { $0[row].weight = weight }
    }

    @objc private func changeMode(_ sender: NSMenuItem) {
        guard let row = (sender.representedObject as? Int), entries.indices.contains(row) else { return }
        _ = commit { list in
            if sender.tag < 0 { list[row].modes = nil; return }
            let mode = PolishMode.allCases[sender.tag]
            var modes = Set(list[row].modes ?? [])
            if modes.contains(mode) { modes.remove(mode) } else { modes.insert(mode) }
            // Selecting every mode, or none, means "all modes".
            list[row].modes = modes.isEmpty || modes.count == PolishMode.allCases.count
                ? nil : PolishMode.allCases.filter(modes.contains)
        }
    }

    static func modesTitle(_ modes: [PolishMode]?) -> String {
        guard let modes else { return L10n.text("All modes") }
        return modes.map(\.title).joined(separator: ", ")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        switch id {
        case Self.enabledColumn:
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            check.state = entry.enabled ? .on : .off
            check.setAccessibilityLabel(L10n.text("Enabled") + " · " + entry.term)
            return centered(check)
        case Self.termColumn:
            let field = NSTextField(string: entry.term)
            field.isBordered = false; field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.textColor = entry.enabled ? .labelColor : .imicMuted
            field.lineBreakMode = .byTruncatingTail
            field.identifier = NSUserInterfaceItemIdentifier("term.\(entry.id.uuidString)")
            field.delegate = self
            field.setAccessibilityLabel(L10n.text("Term"))
            return centered(field, fill: true)
        case Self.weightColumn:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small; popup.font = .systemFont(ofSize: 11)
            popup.addItems(withTitles: Vocabulary.weights.map(String.init))
            popup.selectItem(at: Vocabulary.clampWeight(entry.weight) - Vocabulary.weights.lowerBound)
            popup.target = self; popup.action = #selector(changeWeight(_:))
            popup.setAccessibilityLabel(L10n.text("Weight") + " · " + entry.term)
            return centered(popup, fill: true)
        case Self.modesColumn:
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.controlSize = .small; popup.font = .systemFont(ofSize: 11)
            popup.addItem(withTitle: Self.modesTitle(entry.modes))
            let all = NSMenuItem(title: L10n.text("All modes"), action: #selector(changeMode(_:)), keyEquivalent: "")
            all.tag = -1; all.state = entry.modes == nil ? .on : .off
            popup.menu?.addItem(all)
            popup.menu?.addItem(.separator())
            for (index, mode) in PolishMode.allCases.enumerated() {
                let item = NSMenuItem(title: mode.title, action: #selector(changeMode(_:)), keyEquivalent: "")
                item.tag = index; item.state = entry.modes?.contains(mode) == true ? .on : .off
                popup.menu?.addItem(item)
            }
            for item in popup.menu?.items ?? [] { item.target = self; item.representedObject = row }
            popup.toolTip = Self.modesTitle(entry.modes)
            popup.setAccessibilityLabel(L10n.text("Modes") + " · " + entry.term)
            return centered(popup, fill: true)
        default: return nil
        }
    }

    private func centered(_ view: NSView, fill: Bool = false) -> NSView {
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        var constraints = [view.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if fill {
            constraints += [view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)]
        } else {
            constraints.append(view.centerXAnchor.constraint(equalTo: cell.centerXAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    // MARK: - Inline term editing

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== addField,
              let raw = field.identifier?.rawValue, raw.hasPrefix("term."),
              let id = UUID(uuidString: String(raw.dropFirst("term.".count))),
              let row = entries.firstIndex(where: { $0.id == id }) else { return }
        let term = Vocabulary.normalize(field.stringValue)
        guard term != entries[row].term else { field.stringValue = term; return }
        if let issue = Vocabulary.issue(adding: term, to: entries, replacing: id, enabled: false) {
            field.stringValue = entries[row].term; show(issue); return
        }
        _ = commit { $0[row].term = term }
        show(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === addField, !issueLabel.isHidden { show(nil) }
    }
}
