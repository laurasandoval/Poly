import AppKit

/// The standard alert asking whether to link accessories to an external display. One accessory gets a plain
/// question; several that connected together get a checkbox each, so one (a borrowed mouse) can be
/// left out. Returns the addresses to link; Don’t Link (or Escape) links none.
enum LinkPrompt {
    static func ask(_ offer: LinkOffer) async -> Set<String> {
        // Let a menu or a just-finished connection settle before taking focus.
        await pause(0.1)
        let alert = NSAlert()
        var boxes: [(address: String, box: NSButton)] = []
        if offer.accessories.count == 1, let accessory = offer.accessories.first {
            alert.messageText = String(localized: "Link \(accessory.name) to \(offer.monitorName)?")
            alert.informativeText = String(
                localized: "Your Mac will connect to \(accessory.name) automatically when it’s connected to \(offer.monitorName).")
            alert.icon = SystemIcons.accessory(accessory)
        } else {
            let names = offer.accessories.map(\.name).formatted(.list(type: .and))
            alert.messageText = String(localized: "Link \(names) to \(offer.monitorName)?")
            alert.informativeText = String(
                localized: "Your Mac will connect to them automatically when it’s connected to \(offer.monitorName).")
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            for accessory in offer.accessories {
                let box = NSButton(checkboxWithTitle: accessory.name, target: nil, action: nil)
                box.state = .on
                stack.addArrangedSubview(box)
                boxes.append((accessory.address, box))
            }
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
        }
        alert.addButton(withTitle: String(localized: "Link"))
        alert.addButton(withTitle: String(localized: "Don’t Link")).keyEquivalent = "\u{1b}"
        NSApp.activateForPrompt()
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        if boxes.isEmpty { return Set(offer.accessories.map(\.address)) }
        return Set(boxes.filter { $0.box.state == .on }.map(\.address))
    }
}
