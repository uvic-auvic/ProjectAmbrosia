import SwiftUI
import SwiftTerm

/// A SwiftUI wrapper around SwiftTerm's `TerminalView` that
/// bridges serial-port I/O from `VMManager` into a proper
/// VT100/xterm terminal emulator.
struct VMTerminalView: NSViewRepresentable {
    @ObservedObject var vmManager: VMManager

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Dark VSCode-like theme
        tv.nativeBackgroundColor = NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        tv.nativeForegroundColor = NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1)

        // Store the view in coordinator so the callback can reach it
        context.coordinator.terminalView = tv

        // Register callback — receives raw bytes from VM serial port
        vmManager.onOutput = { [weak tv] bytes in
            let x = ArraySlice<UInt8>(bytes)
            tv?.feed(byteArray: x)
        }

        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Re-register whenever the view is updated (e.g. on new vmManager instance)
        vmManager.onOutput = { [weak nsView] bytes in
            let x = ArraySlice<UInt8>(bytes)
            nsView?.feed(byteArray: x)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(vmManager: vmManager) }

    // MARK: - Coordinator (terminal → VM input)

    final class Coordinator: NSObject, TerminalViewDelegate {
        var vmManager: VMManager
        weak var terminalView: TerminalView?

        init(vmManager: VMManager) { self.vmManager = vmManager }

        // Called by SwiftTerm when the user types; forward to VMManager serial port
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let str = String(bytes: data, encoding: .utf8) ?? String(data.map { Character(UnicodeScalar($0)) })
            vmManager.sendInput(str)
        }

        // Required delegate stubs
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
