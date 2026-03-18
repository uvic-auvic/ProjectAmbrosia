import SwiftUI

// MARK: - SimulationToolbar

/// Unified toolbar: panel toggles, playback, speed, VM status, file actions, terminal toggle.
struct SimulationToolbar: ToolbarContent {

    @EnvironmentObject var simulatorState: SimulatorState
    @EnvironmentObject var vmManager: VMManager

    @Binding var showSidebar:      Bool
    @Binding var showInspector:    Bool
    @Binding var showTerminal:     Bool
    @Binding var showModelImporter: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {

                // ── Panel toggles ───────────────────────────────────────
                toggleButton("sidebar.left",  active: showSidebar,  help: "Toggle Hierarchy  ⌘1") {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                }
                .keyboardShortcut("1", modifiers: .command)

                sep

                // ── Playback ────────────────────────────────────────────
                Button {
                    if simulatorState.isRunning { simulatorState.pause() }
                    else { simulatorState.play() }
                } label: {
                    Image(systemName: simulatorState.isRunning ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut("p", modifiers: .command)
                .help(simulatorState.isRunning ? "Pause  ⌘P" : "Play  ⌘P")
                .buttonStyle(.borderless)

                Button { simulatorState.reset() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reset  ⌘R")
                .buttonStyle(.borderless)

                sep

                // ── Speed ───────────────────────────────────────────────
                Picker("Speed", selection: $simulatorState.simulationSpeed) {
                    ForEach(SimulationSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()

                sep

                // ── VM status ───────────────────────────────────────────
                HStack(spacing: 5) {
                    Circle().fill(vmStateColor).frame(width: 7, height: 7)
                    Text(vmStateLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .help("VM: \(vmStateLabel)")

                sep

                // ── File / Terminal ─────────────────────────────────────
                Button("Load Model…") { showModelImporter = true }
                    .buttonStyle(.borderless)
                    .help("Load model (.urdf or .obj)")

                toggleButton("terminal", active: showTerminal, help: "Toggle Terminal  ⌃`") {
                    withAnimation(.easeInOut(duration: 0.2)) { showTerminal.toggle() }
                }
                .keyboardShortcut("`", modifiers: .control)
                
                sep
                
                toggleButton("sidebar.right", active: showInspector, help: "Toggle Inspector  ⌘2") {
                    withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
                }
                .keyboardShortcut("2", modifiers: .command)

                sep
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Helpers

    private var sep: some View {
        Divider().frame(height: 16).padding(.horizontal, 8)
    }

    private func toggleButton(
        _ icon: String,
        active: Bool,
        help helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .symbolVariant(active ? .fill : .none)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(helpText)
    }

    private var vmStateColor: Color {
        switch vmManager.vmState {
        case .running: return .green
        case .booting: return .yellow
        case .error:   return .red
        case .paused:  return .orange
        case .stopped, .notStarted: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var vmStateLabel: String {
        switch vmManager.vmState {
        case .notStarted: return "VM off"
        case .booting:    return "Booting…"
        case .running:    return "VM running"
        case .paused:     return "VM paused"
        case .stopped:    return "VM stopped"
        case .error:      return "VM error"
        }
    }
}
