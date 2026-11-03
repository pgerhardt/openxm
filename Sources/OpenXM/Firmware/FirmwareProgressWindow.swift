import AppKit

/// Keep a visible status when firmware commands are launched through Launch Services without a terminal.
@MainActor
final class FirmwareProgressWindow {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 200),
                                  styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
    private let stage = NSTextField(labelWithString: "Preparing firmware transfer…")
    private let detail = NSTextField(wrappingLabelWithString: "Keep the Mac awake and headphones nearby. Do not turn them off or connect any cables.")
    private let progress = NSProgressIndicator()

    init(targetVersion: String) {
        window.title = "WH-1000XM3 · Firmware \(targetVersion)"
        window.isReleasedWhenClosed = false
        stage.font = .boldSystemFont(ofSize: 17)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = true
        let stack = NSStackView(views: [stage, progress, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        progress.startAnimation(nil)
    }

    func update(phase: VMUTransfer.Phase, offset: Int, total: Int) {
        progress.isIndeterminate = phase != .transferring
        if phase == .transferring {
            progress.stopAnimation(nil)
            progress.doubleValue = Double(offset) / Double(total) * 100
            stage.stringValue = "Transferring firmware · \(offset * 100 / total)%"
        } else {
            progress.startAnimation(nil)
            switch phase {
            case .preparing: stage.stringValue = "Preparing firmware transfer…"
            case .validating: stage.stringValue = "Validating firmware on the headphones…"
            case .rebooting: stage.stringValue = "Waiting for the headphones to restart…"
            case .committing: stage.stringValue = "Finishing firmware installation…"
            case .complete: stage.stringValue = "Verifying the installed firmware version…"
            case .transferring: break
            }
        }
    }
}
