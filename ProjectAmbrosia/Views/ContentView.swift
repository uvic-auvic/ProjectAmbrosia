import SwiftUI
import SceneKit
import UniformTypeIdentifiers

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject var simulatorState: SimulatorState
    @EnvironmentObject var vmManager: VMManager
    @EnvironmentObject var rosBridge: ROSBridge

    @State private var showConsole = false
    @State private var showURDFImporter = false

    var body: some View {
        NavigationSplitView {
            SceneHierarchyPanel()
                .environmentObject(simulatorState)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            ViewportView(scene: simulatorState.scene)
                .toolbar {
                    SimulationToolbar()
//                        .environmentObject(simulatorState)
//                        .environmentObject(vmManager)
                }
        } detail: {
            InspectorPanel()
                .environmentObject(simulatorState)
                .environmentObject(rosBridge)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Load URDF…") { showURDFImporter = true }
            }
            ToolbarItem {
                Button {
                    showConsole = true
                } label: {
                    Label("VM Console", systemImage: "terminal")
                }
            }
        }
        .fileImporter(
            isPresented: $showURDFImporter,
            allowedContentTypes: [.xml, UTType(filenameExtension: "urdf") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            handleURDFImport(result)
        }
        .sheet(isPresented: $showConsole) {
            VMConsoleView()
                .environmentObject(vmManager)
                .environmentObject(rosBridge)
        }
        .alert("Error", isPresented: .init(
            get: { simulatorState.errorMessage != nil },
            set: { if !$0 { simulatorState.errorMessage = nil } }
        )) {
            Button("OK") { simulatorState.errorMessage = nil }
        } message: {
            Text(simulatorState.errorMessage ?? "")
        }
    }

    // MARK: - URDF Import

    private func handleURDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let model = try URDFParser.parse(url: url)
                simulatorState.applyRobot(model)
            } catch {
                simulatorState.errorMessage = error.localizedDescription
            }
        case .failure(let error):
            simulatorState.errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SimulatorState())
        .environmentObject(VMManager())
        .environmentObject(ROSBridge())
}
