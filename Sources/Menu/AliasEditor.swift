import AppKit

/// Compact, icon-free alias editor. All editable/button text is explicitly 12 pt.
/// Empty string means "clear the alias"; nil means Cancel, Escape, or window close.
/// Call on the main thread after ending menu tracking.
final class BlueBarAliasEditor: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let field: NSTextField
    private var result: String?
    private var finished = false

    static func edit(alias: String, placeholder: String) -> String? {
        guard NSApp.modalWindow == nil else { return nil }
        let editor = BlueBarAliasEditor(alias: alias, placeholder: placeholder)
        // Keep the target/delegate alive throughout AppKit's nested modal loop.
        return withExtendedLifetime(editor) { editor.runModal() }
    }

    private init(alias: String, placeholder: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        field = NSTextField(frame: NSRect(x: 16, y: 56, width: 288, height: 24))
        super.init()

        panel.title = "Station name"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let font = NSFont.systemFont(ofSize: 12)
        field.font = font
        field.stringValue = alias
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(save(_:))
        field.setAccessibilityLabel("Station name")

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.frame = NSRect(x: 126, y: 12, width: 84, height: 26)
        cancelButton.bezelStyle = .rounded
        cancelButton.font = font
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.frame = NSRect(x: 218, y: 12, width: 86, height: 26)
        saveButton.bezelStyle = .rounded
        saveButton.font = font
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = []

        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(cancelButton)
        panel.contentView?.addSubview(saveButton)
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
        panel.initialFirstResponder = field
        field.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = field
    }

    private func runModal() -> String? {
        defer {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.selectText(nil)
        _ = NSApp.runModal(for: panel)
        // External abort/termination never commits the draft.
        return finished ? result : nil
    }

    @objc private func save(_ sender: Any?) {
        guard panel.makeFirstResponder(nil) else { return }
        finish(field.stringValue)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        result = value
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return true
    }
}
