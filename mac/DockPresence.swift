import AppKit

/// VoxChord lives in the menu bar (LSUIElement), so by default it has no Dock icon.
/// While any of its real windows is open (visible or minimized) it becomes a regular
/// app with a Dock icon and menu bar, so the window can be found with Cmd-Tab and the
/// Dock; when the last one closes it returns to menu-bar only.
final class DockPresence {
    /// Titled, non-panel windows count: the main window, Settings, Text History, the
    /// setup wizard and the update dialog. Panels (alerts, the polish sweep) do not.
    static func counts(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.styleMask.contains(.titled) else { return false }
        return window.isVisible || window.isMiniaturized
    }

    static func wanted(_ windows: [NSWindow], closing: NSWindow? = nil) -> NSApplication.ActivationPolicy {
        windows.contains { $0 !== closing && counts($0) } ? .regular : .accessory
    }

    /// The app-wide instance; nil in headless runs and tests, where nothing changes.
    static var shared: DockPresence?

    /// Call right before showing a window, so it opens with the Dock icon and menu bar in place.
    static func willShowWindow() { shared?.apply(.regular) }

    private let app: NSApplication
    private var observers: [NSObjectProtocol] = []

    init(app: NSApplication = .shared) {
        self.app = app
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        // Fallback for windows shown without becoming key (the app is inactive): a cheap
        // re-check after each event-loop pass. apply() does nothing unless the policy changes.
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: app, queue: .main) { [weak self] _ in
            self?.update()
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            self?.update(closing: note.object as? NSWindow)
            // Re-check once the close has finished, in case another window opened meanwhile.
            DispatchQueue.main.async { self?.update() }
        })
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func update(closing: NSWindow? = nil) {
        apply(Self.wanted(app.windows, closing: closing))
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard app.activationPolicy() != policy else { return }
        app.setActivationPolicy(policy)
        IMicLog.write("mac.dock", policy == .regular ? "shown" : "hidden")
    }
}
