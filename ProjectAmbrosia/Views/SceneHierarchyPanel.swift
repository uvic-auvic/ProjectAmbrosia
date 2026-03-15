import SwiftUI

// MARK: - SceneHierarchyPanel

/// Left panel showing the robot link/joint tree.
struct SceneHierarchyPanel: View {

    @EnvironmentObject var simulatorState: SimulatorState
    @State private var selectedLink: String?

    var body: some View {
        Group {
            if let model = simulatorState.robotModel {
                robotTree(model: model)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Robot Tree

    private func robotTree(model: RobotModel) -> some View {
        List(selection: $selectedLink) {
            Section("Robot: \(model.name)") {
                if let root = model.rootLink {
                    linkRow(root, model: model, depth: 0)
                }
            }
            Section("Joints (\(model.joints.count))") {
                ForEach(model.joints) { joint in
                    HStack(spacing: 6) {
                        Image(systemName: jointIcon(joint.type))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(joint.name)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(joint.parentLink) → \(joint.childLink)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
    }

    
    private func linkRow(_ link: URDFLink, model: RobotModel, depth: Int) -> AnyView {
        let children = model.joints(from: link.name)
        if children.isEmpty {
            return AnyView(
                Label(link.name, systemImage: "cube.fill")
                    .font(.system(.caption, design: .monospaced))
                    .tag(link.name)
            )
        } else {
            return AnyView(
                DisclosureGroup(
                    content: {
                        ForEach(children) { joint in
                            if let childLink = model.link(named: joint.childLink) {
                                linkRow(childLink, model: model, depth: depth + 1)
                                    .padding(.leading, 8)
                            }
                        }
                    },
                    label: {
                        Label(link.name, systemImage: "cube.fill")
                            .font(.system(.caption, design: .monospaced))
                            .tag(link.name)
                    }
                )
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No robot loaded")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Use File → Load URDF… to open a robot description.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Icons

    private func jointIcon(_ type: JointType) -> String {
        switch type {
        case .fixed: return "lock.fill"
        case .revolute: return "arrow.triangle.2.circlepath"
        case .continuous: return "arrow.circlepath"
        case .prismatic: return "arrow.up.and.down"
        case .floating: return "move.3d"
        case .planar: return "square.dashed"
        }
    }
}

#Preview {
    SceneHierarchyPanel()
        .environmentObject(SimulatorState())
        .frame(width: 240, height: 500)
}
