import SwiftUI
import SceneKit
import AppKit

// MARK: - ViewportView

/// SwiftUI wrapper around an `SCNView` for 3D robot visualization.
struct ViewportView: NSViewRepresentable {

    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.showsStatistics = false
        scnView.backgroundColor = NSColor(white: 0.1, alpha: 1)
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = true

        // Overlay grid
        addGrid(to: scene)

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Scene mutations are handled through SimulatorState; nothing to do here.
    }

    // MARK: - Reference Grid

    private func addGrid(to scene: SCNScene) {
        guard scene.rootNode.childNode(withName: "reference_grid", recursively: false) == nil else { return }

        let gridNode = SCNNode()
        gridNode.name = "reference_grid"

        let gridSize: Float = 5
        let step: Float = 0.5
        var current: Float = -gridSize

        while current <= gridSize {
            gridNode.addChildNode(lineNode(from: SCNVector3(current, 0, -gridSize),
                                           to: SCNVector3(current, 0, gridSize)))
            gridNode.addChildNode(lineNode(from: SCNVector3(-gridSize, 0, current),
                                           to: SCNVector3(gridSize, 0, current)))
            current += step
        }

        scene.rootNode.addChildNode(gridNode)
    }

    private func lineNode(from start: SCNVector3, to end: SCNVector3) -> SCNNode {
        let vertices: [SCNVector3] = [start, end]
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [UInt8] = [0, 1]
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [source], elements: [element])
        geo.firstMaterial?.diffuse.contents = NSColor(white: 0.3, alpha: 0.6)
        geo.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: geo)
    }
}
