import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

// MARK: - Joint Types

enum JointType: String {
    case fixed
    case revolute
    case continuous
    case prismatic
    case floating
    case planar
}

// MARK: - Geometry

/// All supported URDF geometry variants.
enum URDFGeometry {
    case box(size: SIMD3<Float>)
    case cylinder(radius: Float, length: Float)
    case sphere(radius: Float)
    case mesh(filename: String, scale: SIMD3<Float>?)

    /// Converts the geometry description into an SCNGeometry ready for rendering.
    /// Pass `baseURL` (the directory containing the URDF file) for relative mesh resolution.
    func toSCNGeometry(baseURL: URL? = nil) -> SCNGeometry {
        switch self {
        case .box(let size):
            return SCNBox(width: CGFloat(size.x),
                          height: CGFloat(size.y),
                          length: CGFloat(size.z),
                          chamferRadius: 0)

        case .cylinder(let radius, let length):
            return SCNCylinder(radius: CGFloat(radius),
                               height: CGFloat(length))

        case .sphere(let radius):
            return SCNSphere(radius: CGFloat(radius))

        case .mesh(let filename, _):
            return loadMeshGeometry(filename: filename, baseURL: baseURL)
        }
    }

    // MARK: - Mesh Loading

    private func loadMeshGeometry(filename: String, baseURL: URL?) -> SCNGeometry {
        guard let url = resolveMeshURL(filename: filename, baseURL: baseURL) else {
            return makeFallbackGeometry(reason: "File not found: \(filename)")
        }

        let ext = url.pathExtension.lowercased()

        // DAE and SCN are natively supported by SCNSceneSource.
        if ["dae", "scn"].contains(ext) {
            if let geo = loadViaSCNSceneSource(url: url) { return geo }
        }

        // STL, OBJ, PLY, ABC and others go through ModelIO.
        if let geo = loadViaMDLAsset(url: url) { return geo }

        // Fallback: try SCNSceneSource for any remaining types.
        if let geo = loadViaSCNSceneSource(url: url) { return geo }

        return makeFallbackGeometry(reason: "Could not decode: \(url.lastPathComponent)")
    }

    /// Load geometry via `SCNSceneSource` — best for DAE/COLLADA and SCN files.
    private func loadViaSCNSceneSource(url: URL) -> SCNGeometry? {
        let options: [SCNSceneSource.LoadingOption: Any] = [
            .checkConsistency: false,
            .flattenScene: true,
            .createNormalsIfAbsent: true
        ]
        guard let source = SCNSceneSource(url: url, options: options),
              let scene = source.scene(options: nil) else { return nil }
        return firstGeometry(in: scene.rootNode)
    }

    /// Load geometry via `MDLAsset` — handles STL, OBJ, PLY, ABC, and USD variants.
    private func loadViaMDLAsset(url: URL) -> SCNGeometry? {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else { return nil }
        let asset = MDLAsset(url: url)
        asset.loadTextures()

        // Walk the asset hierarchy looking for the first mesh.
        for i in 0..<asset.count {
            let mdlObject = asset.object(at: i)
            if let geo = scnGeometry(from: mdlObject) { return geo }
        }
        return nil
    }

    /// Recursively extract the first `SCNGeometry` from an `MDLObject` tree.
    private func scnGeometry(from mdlObject: MDLObject) -> SCNGeometry? {
        if let mesh = mdlObject as? MDLMesh {
            let node = SCNNode(mdlObject: mesh)
            if let geo = node.geometry { return geo }
        }
        for child in mdlObject.children.objects {
            if let geo = scnGeometry(from: child) { return geo }
        }
        return nil
    }

    /// Recursively find the first geometry in a SceneKit node tree.
    private func firstGeometry(in node: SCNNode) -> SCNGeometry? {
        if let geo = node.geometry { return geo }
        for child in node.childNodes {
            if let geo = firstGeometry(in: child) { return geo }
        }
        return nil
    }

    // MARK: - URL Resolution

    private func resolveMeshURL(filename: String, baseURL: URL?) -> URL? {
        var path = filename

        // Strip package:// prefix (ROS convention).
        if path.hasPrefix("package://") {
            path = String(path.dropFirst("package://".count))
            // Remove the package name segment: "pkg_name/rest/of/path" → "rest/of/path"
            if let slash = path.range(of: "/") {
                path = String(path[slash.upperBound...])
            }
        }

        // 1. Try relative to the URDF file's directory.
        if let base = baseURL {
            let candidate = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

            // Also try just the filename component (meshes often live alongside the URDF).
            let nameOnly = base.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            if FileManager.default.fileExists(atPath: nameOnly.path) { return nameOnly }
        }

        // 2. Try app bundle resources (filename without path).
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        let stem = URL(fileURLWithPath: lastComponent).deletingPathExtension().lastPathComponent
        let ext  = URL(fileURLWithPath: lastComponent).pathExtension
        if let bundleURL = Bundle.main.url(forResource: stem, withExtension: ext) {
            return bundleURL
        }

        // 3. Try as an absolute path.
        let absolute = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: absolute.path) { return absolute }

        return nil
    }

    // MARK: - Fallback

    private func makeFallbackGeometry(reason: String = "") -> SCNGeometry {
        let box = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = NSColor.systemOrange
        box.firstMaterial?.lightingModel = .physicallyBased
        return box
    }
}

// MARK: - Material

struct URDFMaterial {
    var name: String?
    var rgba: SIMD4<Float>  // r g b a
}

// MARK: - Origin

struct URDFOrigin {
    var xyz: SIMD3<Float>
    var rpy: SIMD3<Float>  // roll pitch yaw in radians

    static let identity = URDFOrigin(xyz: .zero, rpy: .zero)
}

// MARK: - Visual / Collision / Inertial

struct URDFVisual {
    var geometry: URDFGeometry
    var origin: URDFOrigin
    var material: URDFMaterial?
}

struct URDFCollision {
    var geometry: URDFGeometry
    var origin: URDFOrigin
}

struct URDFInertial {
    var mass: Float
    var origin: URDFOrigin
    var ixx, ixy, ixz, iyy, iyz, izz: Float
}

// MARK: - Link

/// A single rigid body in the robot model.
struct URDFLink: Identifiable {
    var id: String { name }
    var name: String
    var visual: URDFVisual?
    var collision: URDFCollision?
    var inertial: URDFInertial?
}

// MARK: - Joint Limit

struct JointLimit {
    var lower: Float
    var upper: Float
    var effort: Float
    var velocity: Float
}

// MARK: - Joint

/// A connection between two links.
struct URDFJoint: Identifiable {
    var id: String { name }
    var name: String
    var type: JointType
    var parentLink: String
    var childLink: String
    var origin: URDFOrigin
    var axis: SIMD3<Float>
    var limit: JointLimit?
}

// MARK: - Robot Model

/// Top-level fully parsed URDF robot.
struct RobotModel {
    var name: String
    var links: [URDFLink]
    var joints: [URDFJoint]
    /// Directory containing the URDF file — used to resolve relative mesh paths.
    var baseURL: URL?

    /// Returns the root link (the one not referenced as any joint's child).
    var rootLink: URDFLink? {
        let childNames = Set(joints.map { $0.childLink })
        return links.first { !childNames.contains($0.name) }
    }

    /// Returns all joints whose parent link matches the given link name.
    func joints(from linkName: String) -> [URDFJoint] {
        joints.filter { $0.parentLink == linkName }
    }

    /// Returns a link by name.
    func link(named name: String) -> URDFLink? {
        links.first { $0.name == name }
    }
}
