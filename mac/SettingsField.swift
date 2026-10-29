import AppKit

/// A text draft has its own field and baseline, separate from the running ASR config.
final class SettingsField: NSStackView, NSTextFieldDelegate {
    let id: String
    let title: String
    let secure: Bool
    private let concealed: NSTextField
    private let revealed = NSTextField()
    let saveButton = NSButton(title: "验证并保存", target: nil, action: nil)
    private let eye = NSButton()
    let feedback = NSTextField(wrappingLabelWithString: "")
    let source = NSTextField(wrappingLabelWithString: "")
    private var showing = false
    private(set) var baseline: String
    var task: URLSessionDataTask?
    var generation = UUID()
    var onSave: ((SettingsField, @escaping (Bool) -> Void) -> Void)?
    var onEdit: (() -> Void)?
    var dirty: Bool { value != baseline }
    var value: String {
        get { (showing ? revealed : concealed).stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        set { concealed.stringValue = newValue; revealed.stringValue = newValue }
    }

    init(id: String, title: String, value: String, secure: Bool = false) {
        self.id = id; self.title = title; self.secure = secure; self.baseline = value
        concealed = secure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6; detachesHiddenViews = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .medium); heading.textColor = .imicIvory
        let fields = NSStackView(views: [concealed, revealed])
        fields.orientation = .horizontal; fields.spacing = 0; fields.detachesHiddenViews = true
        revealed.isHidden = true
        for field in [concealed, revealed] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.bezelStyle = .roundedBezel; field.delegate = self
            field.target = self; field.action = #selector(saveAction)
            field.setAccessibilityLabel(title)
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            field.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        self.value = value
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示 Key")
        eye.bezelStyle = .inline; eye.target = self; eye.action = #selector(toggleReveal)
        eye.setAccessibilityLabel("显示 \(title)"); eye.isHidden = !secure
        eye.widthAnchor.constraint(equalToConstant: 26).isActive = true
        saveButton.bezelStyle = .rounded; saveButton.controlSize = .small
        saveButton.target = self; saveButton.action = #selector(saveAction)
        saveButton.setAccessibilityLabel("验证并保存\(title)")
        let controls = NSStackView(views: [fields, eye, saveButton])
        controls.orientation = .horizontal; controls.spacing = 8; controls.alignment = .centerY
        for label in [feedback, source] {
            label.font = .systemFont(ofSize: 10); label.textColor = .imicMuted
            label.maximumNumberOfLines = 2; label.preferredMaxLayoutWidth = 512
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [heading, controls, source, feedback] { addArrangedSubview(view) }
        for view in [controls, source, feedback] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        source.isHidden = true
        updateButton()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setEditable(_ value: Bool) {
        concealed.isEditable = value; revealed.isEditable = value
    }
    func markSaved(_ value: String) {
        baseline = value; self.value = value; updateButton()
    }
    func cancel() { task?.cancel(); task = nil; generation = UUID(); saveButton.isEnabled = true }
    func reset() { cancel(); value = baseline; hideKey(); feedback.stringValue = ""; updateButton() }
    func hideKey() {
        guard showing else { return }
        value = revealed.stringValue; showing = false
        revealed.isHidden = true; concealed.isHidden = false
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示 Key")
        eye.setAccessibilityLabel("显示 \(title)")
    }
    func message(_ text: String, error: Bool = false) {
        feedback.stringValue = text; feedback.textColor = error ? .systemRed : .imicMuted
        updateButton()
    }
    func updateButton() {
        saveButton.title = dirty ? "验证并保存" : "验证"
        saveButton.bezelColor = dirty ? .imicOrange : nil
    }
    func controlTextDidChange(_ notification: Notification) {
        let text = (notification.object as? NSTextField)?.stringValue ?? value
        cancel(); value = text; message(dirty ? "尚未保存" : ""); onEdit?()
    }
    @objc func saveAction() { save { _ in } }
    func save(_ completion: @escaping (Bool) -> Void) { onSave?(self, completion) }
    @objc private func toggleReveal() {
        let current = value
        value = current; showing.toggle()
        concealed.isHidden = showing; revealed.isHidden = !showing
        eye.image = NSImage(systemSymbolName: showing ? "eye.slash" : "eye", accessibilityDescription: nil)
        eye.setAccessibilityLabel("\(showing ? "隐藏" : "显示")\(title)")
        window?.makeFirstResponder(showing ? revealed : concealed)
    }
}
