import SwiftUI
import UniformTypeIdentifiers

// MARK: - VMConsoleView

/// Sheet showing the VM terminal and ROS bridge status.
struct VMConsoleView: View {

    @EnvironmentObject var vmManager: VMManager
    @EnvironmentObject var rosBridge: ROSBridge
    @Environment(\.dismiss) private var dismiss

    @State private var showImagePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diskImageRow
            Divider()
            VMTerminalView(vmManager: vmManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [UTType(filenameExtension: "img") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                vmManager.setDiskImageURL(url)
                if accessing { url.stopAccessingSecurityScopedResource() }
                Task { await vmManager.boot() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("VM Console", systemImage: "terminal.fill")
                .font(.headline)
            Spacer()
            statusBadge(label: vmBridgeLabel, color: vmBridgeColor, icon: "server.rack")
            statusBadge(label: rosBridgeLabel, color: rosBridgeColor, icon: "network")
            Button("Close") { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding()
    }

    // MARK: - Disk Image Row

    private var diskImageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(vmManager.resolvedDiskImageURL != nil ? .green : .secondary)
            if let url = vmManager.resolvedDiskImageURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No disk image found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate Disk Image...") { showImagePicker = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if vmManager.vmState == .notStarted || vmManager.vmState == .stopped {
                Button("Boot VM") {
                    Task { await vmManager.boot() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vmManager.resolvedDiskImageURL == nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 16) {
            if let lastUpdate = rosBridge.lastJointUpdateTime {
                Label("Last joint update: \(lastUpdate.formatted(date: .omitted, time: .standard))",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if vmManager.vmState == .running {
                Button {
                    Task { await vmManager.shutdown() }
                } label: {
                    Label("Shut Down VM", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    // MARK: - Status Badges

    private func statusBadge(label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Labels

    private var vmBridgeLabel: String {
        switch vmManager.vmState {
        case .notStarted: return "VM: Not started"
        case .booting:    return "VM: Booting"
        case .running:    return "VM: Running"
        case .paused:     return "VM: Paused"
        case .stopped:    return "VM: Stopped"
        case .error:      return "VM: Error"
        }
    }

    private var vmBridgeColor: Color {
        switch vmManager.vmState {
        case .running: return .green
        case .booting: return .yellow
        case .error:   return .red
        default:       return .gray
        }
    }

    private var rosBridgeLabel: String {
        switch rosBridge.state {
        case .idle:             return "Bridge: Idle"
        case .listening:        return "Bridge: Listening"
        case .connected(let h): return "Bridge: \(h)"
        case .error(let e):     return "Bridge: Error - \(e)"
        }
    }

    private var rosBridgeColor: Color {
        switch rosBridge.state {
        case .connected: return .green
        case .listening: return .yellow
        case .error:     return .red
        case .idle:      return .gray
        }
    }
}

#Preview {
    VMConsoleView()
        .environmentObject(VMManager())
        .environmentObject(ROSBridge())
}
