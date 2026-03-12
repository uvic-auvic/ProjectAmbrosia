import Foundation
import SceneKit
import Combine

// MARK: - Simulation Speed

enum SimulationSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case normal = 1.0
    case double = 2.0
    case quadruple = 4.0

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .half: return "0.5×"
        case .normal: return "1×"
        case .double: return "2×"
        case .quadruple: return "4×"
        }
    }
}

// MARK: - SimulatorState

/// Central simulation state. All mutations must occur on the main actor.
@MainActor
final class SimulatorState: ObservableObject {

    // MARK: - Scene

    /// The live SceneKit scene rendered by `ViewportView`.
    let scene: SCNScene = {
        let s = SCNScene()
        s.background.contents = NSColor(white: 0.12, alpha: 1)

        // Ambient light
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 200
        s.rootNode.addChildNode(ambient)

        // Directional light
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 800
        sun.light?.castsShadow = true
        sun.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        s.rootNode.addChildNode(sun)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 1, 3)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        s.rootNode.addChildNode(cameraNode)

        return s
    }()

    // MARK: - Robot Model

    @Published var robotModel: RobotModel?
    @Published var jointValues: [String: Double] = [:]

    private var robotRootNode: SCNNode?

    // MARK: - Simulation Control

    @Published var isRunning = false
    @Published var simulationSpeed: SimulationSpeed = .normal

    private var simTimer: AnyCancellable?
    private var simTime: Double = 0

    // MARK: - Error Surface

    @Published var errorMessage: String?

    // MARK: - Physics

    @Published var gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0)
    @Published var waterPlaneHeight: Float = -0.5
    @Published var dragCoefficient: Float = 0.1

    // MARK: - Public API

    /// Apply a fully parsed `RobotModel` to the scene, replacing any existing robot.
    func applyRobot(_ model: RobotModel) {
        robotRootNode?.removeFromParentNode()
        robotModel = model
        jointValues = [:]

        let rootNode = RobotSceneBuilder.buildScene(from: model)
        scene.rootNode.addChildNode(rootNode)
        robotRootNode = rootNode
    }

    /// Set a single joint position and update the scene.
    func setJointValue(_ value: Double, for jointName: String) {
        guard let model = robotModel,
              let joint = model.joints.first(where: { $0.name == jointName }),
              let sceneRoot = robotRootNode else { return }

        jointValues[jointName] = value
        RobotSceneBuilder.setJointValue(value, joint: joint, in: sceneRoot)
    }

    // MARK: - Simulation Timer

    /// Start the simulation loop.
    func play() {
        guard !isRunning else { return }
        isRunning = true
        simTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let dt = (1.0 / 60.0) * self.simulationSpeed.rawValue
                self.stepSimulation(dt: dt)
            }
    }

    /// Pause the simulation loop.
    func pause() {
        isRunning = false
        simTimer?.cancel()
        simTimer = nil
    }

    /// Reset the simulation to the initial state.
    func reset() {
        pause()
        simTime = 0
        jointValues = [:]
        guard let model = robotModel, let root = robotRootNode else { return }
        for joint in model.joints {
            RobotSceneBuilder.setJointValue(0, joint: joint, in: root)
        }
    }

    // MARK: - Physics Step

    /// Advance simulation by `dt` seconds. Called at 60 Hz during play.
    func stepSimulation(dt: Double) {
        simTime += dt
        guard let model = robotModel, let root = robotRootNode else { return }

        // Apply buoyancy forces to links that have physics bodies.
        for link in model.links {
            applyBuoyancy(to: link, sceneRoot: root, dt: Float(dt))
        }
    }

    // MARK: - Buoyancy

    private func applyBuoyancy(to link: URDFLink, sceneRoot: SCNNode, dt: Float) {
        guard let linkNode = sceneRoot.childNode(withName: link.name, recursively: true),
              let body = linkNode.physicsBody else { return }

        let worldY = Float(linkNode.worldPosition.y)
        guard worldY < waterPlaneHeight else { return }

        // Approximate submerged volume from visual geometry bounding box.
        let submergedDepth = waterPlaneHeight - worldY
        let volume = approximateVolume(link: link, submergedDepth: submergedDepth)

        let waterDensity: Float = 1000.0  // kg/m³
        let buoyancyMagnitude = waterDensity * 9.81 * volume
        let dragMagnitude = dragCoefficient * Float(body.velocity.y)

        let netForce = buoyancyMagnitude - dragMagnitude
        body.applyForce(SCNVector3(0, CGFloat(netForce), 0), asImpulse: false)
    }

    private func approximateVolume(link: URDFLink, submergedDepth: Float) -> Float {
        guard let visual = link.visual else { return 0.001 }
        switch visual.geometry {
        case .box(let size):
            let subH = min(submergedDepth, size.y)
            return size.x * subH * size.z
        case .cylinder(let r, let l):
            let subH = min(submergedDepth, l)
            return Float.pi * r * r * subH
        case .sphere(let r):
            let subH = min(submergedDepth, 2 * r)
            return (Float.pi * subH * subH * (3 * r - subH)) / 3
        case .mesh:
            return 0.01
        }
    }
}
