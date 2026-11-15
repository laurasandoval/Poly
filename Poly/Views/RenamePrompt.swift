import AppKit

/// The standard rename alert: the display's or accessory's own artwork, and one text field holding
/// the current name, selected.
enum RenamePrompt {
    static func ask(current: String, icon: NSImage, then rename: @escaping (String) -> Void) {
        // Let the menu finish closing first, then bring Poly forward so the alert takes typing.
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(localized: "Rename “\(current)”")
            alert.icon = icon
            alert.addButton(withTitle: String(localized: "Rename"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSTextField(string: current)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, field.stringValue != current else { return }
            rename(field.stringValue)
        }
    }
}
