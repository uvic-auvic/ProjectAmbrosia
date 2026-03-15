import SwiftUI
import UniformTypeIdentifiers

// MARK: - TerminalPanelView

/// VSCode/Zed-style integrated terminal panel docked to the bottom of the window.
/// Resizable by dragging the top edge. Toggled via Ctrl+` from ContentView.
struct TerminalPanelView: View {

    @EnvironmentObject var vmManager: VMManager
    @EnvironmentObject var rosBridge: ROSBridge

    @Binding var height: CGFloat
    @State private var showImagePicker = false

    private let minHeight: CGFloat = 100
    private let maxHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            tabBar
            Divider()
            VMTerminalView(vmManager: vmManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .frame(height: height)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.init(filenameExtension: "img") ?? .data],
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

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 5)
            .background(Color(nsColor: .separatorColor))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = -value.translation.height
                        height = min(maxHeight, max(minHeight, height + delta))
                    }
            )
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            // Active tab
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                Text("TERMINAL")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.15))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 1)
            }

            Divider().frame(height: 20)

            // Disk image indicator
            diskImageIndicator

            Spacer()

            // Status badges
            rosBridgeBadge
            vmStateBadge

            Divider().frame(height: 20).padding(.horizontal, 4)

            // Action buttons
            actionButtons
        }
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
    }

    // MARK: - Disk Image Indicator

    private var diskImageIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "internaldrive")
                .font(.caption2)
                .foregroundStyle(vmManager.resolvedDiskImageURL != nil ? .green : .secondary)
            if let url = vmManager.resolvedDiskImageURL {
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Locate Image…") { showImagePicker = true }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Status Badges

    private var rosBridgeBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(rosBridgeColor).frame(width: 6, height: 6)
            Text(rosBridgeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private var vmStateBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(vmStateColor).frame(width: 6, height: 6)
            Text(vmStateLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if vmManager.vmState == .notStarted || vmManager.vmState == .stopped {
                Button {
                    Task { await vmManager.boot() }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Boot VM")
                .disabled(vmManager.resolvedDiskImageURL == nil)
            }
            if vmManager.vmState == .running {
                Button {
                    Task { await vmManager.shutdown() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Shut Down VM")
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Labels & Colors

    private var vmStateLabel: String {
        switch vmManager.vmState {
        case .notStarted: return "VM off"
        case .booting:    return "Booting"
        case .running:    return "VM running"
        case .paused:     return "VM paused"
        case .stopped:    return "VM stopped"
        case .error:      return "VM error"
        }
    }

    private var vmStateColor: Color {
        switch vmManager.vmState {
        case .running: return .green
        case .booting: return .yellow
        case .error:   return .red
        default:       return .gray
        }
    }

    private var rosBridgeLabel: String {
        switch rosBridge.state {
        case .idle:             return "Bridge idle"
        case .listening:        return "Bridge listening"
        case .connected(let h): return "Bridge: \(h)"
        case .error:            return "Bridge error"
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
