import SwiftUI

// MARK: - InspectorPanel

/// Right panel showing joint sliders and bridge/link status.
struct InspectorPanel: View {

    @EnvironmentObject var simulatorState: SimulatorState
    @EnvironmentObject var rosBridge: ROSBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                bridgeStatusSection
                if let model = simulatorState.robotModel {
                    jointControlSection(model: model)
                    physicsSection
                } else {
                    noRobotPlaceholder
                }
            }
            .padding()
        }
    }

    // MARK: - Bridge Status

    private var bridgeStatusSection: some View {
        GroupBox("ROS Bridge") {
            HStack {
                Circle()
                    .fill(bridgeColor)
                    .frame(width: 10, height: 10)
                Text(bridgeLabel)
                    .font(.caption)
                Spacer()
                if case .connected = rosBridge.state {
                    Text("\(rosBridge.receivedMessageCount) msgs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var bridgeColor: Color {
        switch rosBridge.state {
        case .idle: return .gray
        case .listening: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }

    private var bridgeLabel: String {
        switch rosBridge.state {
        case .idle: return "Idle"
        case .listening: return "Listening on :8765"
        case .connected(let host): return "Connected: \(host)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Joint Controls

    private func jointControlSection(model: RobotModel) -> some View {
        let actuated = model.joints.filter { $0.type != .fixed }
        return GroupBox("Joint Control (\(actuated.count) actuated)") {
            if actuated.isEmpty {
                Text("No actuated joints")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(actuated) { joint in
                        JointSliderRow(joint: joint)
                            .environmentObject(simulatorState)
                    }
                }
            }
        }
    }

    // MARK: - Physics

    private var physicsSection: some View {
        GroupBox("Physics") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gravity Y")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(simulatorState.gravity.y) },
                        set: { simulatorState.gravity.y = Float($0) }
                    ), in: -20...0, step: 0.1)
                    Text(String(format: "%.1f", simulatorState.gravity.y))
                        .font(.caption2)
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    Text("Water Plane")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(simulatorState.waterPlaneHeight) },
                        set: { simulatorState.waterPlaneHeight = Float($0) }
                    ), in: -5...5, step: 0.1)
                    Text(String(format: "%.1f m", simulatorState.waterPlaneHeight))
                        .font(.caption2)
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    Text("Drag")
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(simulatorState.dragCoefficient) },
                        set: { simulatorState.dragCoefficient = Float($0) }
                    ), in: 0...1, step: 0.01)
                    Text(String(format: "%.2f", simulatorState.dragCoefficient))
                        .font(.caption2)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Empty State

    private var noRobotPlaceholder: some View {
        Text("Load a URDF to inspect joints.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding()
    }
}

// MARK: - Joint Slider Row

private struct JointSliderRow: View {
    let joint: URDFJoint
    @EnvironmentObject var simulatorState: SimulatorState

    private var currentValue: Double {
        simulatorState.jointValues[joint.name] ?? 0
    }

    private var sliderRange: ClosedRange<Double> {
        if let limit = joint.limit {
            return Double(limit.lower)...Double(limit.upper)
        }
        switch joint.type {
        case .revolute: return -Double.pi...Double.pi
        case .continuous: return -Double.pi...Double.pi
        case .prismatic: return -1.0...1.0
        default: return 0...0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(joint.name)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(String(format: "%.3f", currentValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { currentValue },
                set: { simulatorState.setJointValue($0, for: joint.name) }
            ), in: sliderRange)
        }
    }
}

#Preview {
    InspectorPanel()
        .environmentObject(SimulatorState())
        .environmentObject(ROSBridge())
        .frame(width: 280, height: 600)
}
