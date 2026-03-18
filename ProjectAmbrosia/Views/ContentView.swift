import SwiftUI
import SceneKit
import UniformTypeIdentifiers

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject var simulatorState: SimulatorState
    @EnvironmentObject var vmManager: VMManager
    @EnvironmentObject var rosBridge: ROSBridge

    @State private var showSidebar   = true
    @State private var showInspector = true
    @State private var showTerminal  = false
    @State private var terminalHeight: CGFloat = 260
    @State private var showModelImporter = false

    // Fixed-width panels (can add drag-resize later)
    private let sidebarWidth:   CGFloat = 240
    private let inspectorWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            // ── Main workspace ──────────────────────────────────────────
            HStack(spacing: 0) {

                // Sidebar
                if showSidebar {
                    SceneHierarchyPanel()
                        .environmentObject(simulatorState)
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .slide))

                    Divider()
                }

                // Viewport
                ViewportView(scene: simulatorState.scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Inspector
                if showInspector {
                    Divider()

                    InspectorPanel()
                        .environmentObject(simulatorState)
                        .environmentObject(rosBridge)
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Terminal panel ──────────────────────────────────────────
            if showTerminal {
                Divider()
                TerminalPanelView(height: $terminalHeight)
                    .environmentObject(vmManager)
                    .environmentObject(rosBridge)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            SimulationToolbar(
                showSidebar:       $showSidebar,
                showInspector:     $showInspector,
                showTerminal:      $showTerminal,
                showModelImporter: $showModelImporter
            )
        }
        .fileImporter(
            isPresented: $showModelImporter,
            allowedContentTypes: [
                .xml,
                UTType(filenameExtension: "urdf") ?? .xml,
                UTType(filenameExtension: "obj") ?? .plainText
            ],
            allowsMultipleSelection: false
        ) { handleModelImport($0) }
        .alert("Error", isPresented: .init(
            get:  { simulatorState.errorMessage != nil },
            set:  { if !$0 { simulatorState.errorMessage = nil } }
        )) {
            Button("OK") { simulatorState.errorMessage = nil }
        } message: {
            Text(simulatorState.errorMessage ?? "")
        }
    }

    // MARK: - Model Import

    private func handleModelImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let fileExtension = url.pathExtension.lowercased()
            do {
                let model: RobotModel
                
                switch fileExtension {
                case "obj":
                    model = try OBJLoader.loadOBJAsRobotModel(from: url)
                case "urdf":
                    model = try URDFParser.parse(url: url)
                default:
                    throw ModelImportError.unsupportedFileType(fileExtension)
                }
                
                simulatorState.applyRobot(model)
            } catch {
                simulatorState.errorMessage = error.localizedDescription
            }
        case .failure(let error):
            simulatorState.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - ModelImportError

enum ModelImportError: LocalizedError {
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext). Supported formats: .urdf, .obj"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SimulatorState())
        .environmentObject(VMManager())
        .environmentObject(ROSBridge())
}
