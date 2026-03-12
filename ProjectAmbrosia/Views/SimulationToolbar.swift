import SwiftUI

// MARK: - SimulationToolbar

/// Play/pause/reset controls and speed picker for the simulation.
struct SimulationToolbar: ToolbarContent {

    @EnvironmentObject var simulatorState: SimulatorState
    @EnvironmentObject var vmManager: VMManager

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            // Play / Pause
            Button {
                if simulatorState.isRunning { simulatorState.pause() }
                else { simulatorState.play() }
            } label: {
                Image(systemName: simulatorState.isRunning ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut("p", modifiers: [.command])
            .help(simulatorState.isRunning ? "Pause simulation" : "Play simulation")

            // Reset
            Button {
                simulatorState.reset()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .help("Reset simulation")

            Divider()

            // Speed picker
            Picker("Speed", selection: $simulatorState.simulationSpeed) {
                ForEach(SimulationSpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Simulation playback speed")

            Divider()

            // VM status indicator
            vmStatusIndicator
        }
    }

    // MARK: - VM Status

    private var vmStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(vmStateColor)
                .frame(width: 8, height: 8)
            Text(vmStateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("VM: \(vmStateLabel)")
    }

    private var vmStateColor: Color {
        switch vmManager.vmState {
        case .running: return .green
        case .booting: return .yellow
        case .error: return .red
        case .paused: return .orange
        case .stopped, .notStarted: return .gray
        }
    }

    private var vmStateLabel: String {
        switch vmManager.vmState {
        case .notStarted: return "VM not started"
        case .booting: return "Booting…"
        case .running: return "VM running"
        case .paused: return "VM paused"
        case .stopped: return "VM stopped"
        case .error(let msg): return "VM error: \(msg)"
        }
    }
}
