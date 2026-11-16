import AppKit

/// Small stand-ins for APIs newer than Poly's oldest macOS (12).

/// Waits, ending early (silently) if the task is cancelled. `Task.sleep(for:)` needs macOS 13.
nonisolated func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

extension NSApplication {
    /// Brings Poly forward for an alert or Sparkle's window. `activate()` needs macOS 14.
    func activateForPrompt() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
