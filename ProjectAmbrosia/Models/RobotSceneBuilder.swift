import Foundation
import SceneKit
import simd

// MARK: - RobotSceneBuilder

/// Stateless builder that converts a `RobotModel` into a SceneKit node tree
/// and applies joint actuations.
enum RobotSceneBuilder {

    // MARK: - Scene Building

    /// Build a complete SCNNode hierarchy from a parsed `RobotModel`.
    /// The returned node is the robot root and should be added to `SCNScene.rootNode`.
    static func buildScene(from model: RobotModel) -> SCNNode {
        let rootContainer = SCNNode()
        rootContainer.name = "robot_\(model.name)"

        // Create a node for every link.
        var linkNodes: [String: SCNNode] = [:]
        for link in model.links {
            let node = makeLinkNode(link, baseURL: model.baseURL)
            linkNodes[link.name] = node
        }

        // Attach children according to joint hierarchy.
        for joint in model.joints {
            guard
                let parentNode = linkNodes[joint.parentLink],
                let childNode = linkNodes[joint.childLink]
            else { continue }

            let jointAnchor = makeJointAnchorNode(joint: joint)
            jointAnchor.addChildNode(childNode)
            parentNode.addChildNode(jointAnchor)
        }

        // Attach root link to the container.
        if let rootLink = model.rootLink, let rootNode = linkNodes[rootLink.name] {
            rootContainer.addChildNode(rootNode)
        } else if let firstLink = model.links.first, let firstNode = linkNodes[firstLink.name] {
            rootContainer.addChildNode(firstNode)
        }

        return rootContainer
    }

    // MARK: - Joint Actuation

    /// Apply a joint value (radians for revolute/continuous, metres for prismatic).
    /// Call this on `@MainActor` only — SCNNode mutations must be on the main thread.
    static func setJointValue(_ value: Double, joint: URDFJoint, in sceneRoot: SCNNode) {
        guard let anchorNode = sceneRoot.childNode(withName: jointAnchorName(joint.name),
                                                   recursively: true) else { return }
        let axis = SCNVector3(joint.axis.x, joint.axis.y, joint.axis.z)

        switch joint.type {
        case .revolute, .continuous:
            let clamped = clampJointValue(Float(value), limit: joint.limit)
            anchorNode.rotation = SCNVector4(axis.x, axis.y, axis.z, CGFloat(clamped))

        case .prismatic:
            let clamped = clampJointValue(Float(value), limit: joint.limit)
            let offset = joint.axis * clamped
            anchorNode.position = SCNVector3(offset.x, offset.y, offset.z)

        case .fixed, .floating, .planar:
            break
        }
    }

    // MARK: - Private Helpers

    private static func makeLinkNode(_ link: URDFLink, baseURL: URL?) -> SCNNode {
        let node = SCNNode()
        node.name = link.name

        if let visual = link.visual {
            let geometry = visual.geometry.toSCNGeometry(baseURL: baseURL)
            applyMaterial(visual.material, to: geometry)

            let visualNode = SCNNode(geometry: geometry)
            applyOrigin(visual.origin, to: visualNode)

            // Apply mesh scale if specified.
            if case .mesh(_, let scale) = visual.geometry, let s = scale {
                visualNode.scale = SCNVector3(s.x, s.y, s.z)
            }

            node.addChildNode(visualNode)
        }

        return node
    }

    private static func makeJointAnchorNode(joint: URDFJoint) -> SCNNode {
        let anchor = SCNNode()
        anchor.name = jointAnchorName(joint.name)
        applyOrigin(joint.origin, to: anchor)
        return anchor
    }

    private static func applyOrigin(_ origin: URDFOrigin, to node: SCNNode) {
        node.position = SCNVector3(origin.xyz.x, origin.xyz.y, origin.xyz.z)
        // Apply RPY as Euler angles (intrinsic XYZ).
        node.eulerAngles = SCNVector3(origin.rpy.x, origin.rpy.y, origin.rpy.z)
    }

    private static func applyMaterial(_ material: URDFMaterial?, to geometry: SCNGeometry) {
        let mat = SCNMaterial()
        if let m = material {
            mat.diffuse.contents = NSColor(red: CGFloat(m.rgba.x),
                                           green: CGFloat(m.rgba.y),
                                           blue: CGFloat(m.rgba.z),
                                           alpha: CGFloat(m.rgba.w))
        } else {
            mat.diffuse.contents = NSColor(white: 0.7, alpha: 1.0)
        }
        mat.lightingModel = .physicallyBased
        geometry.materials = [mat]
    }

    private static func clampJointValue(_ value: Float, limit: JointLimit?) -> Float {
        guard let limit = limit else { return value }
        return min(max(value, limit.lower), limit.upper)
    }

    private static func jointAnchorName(_ jointName: String) -> String {
        "joint_anchor_\(jointName)"
    }
}
