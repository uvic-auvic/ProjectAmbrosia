import Foundation
import SceneKit
import ModelIO

// MARK: - OBJLoader

/// Utility for loading standalone .obj files and wrapping them as RobotModel objects.
enum OBJLoader {

    /// Loads a .obj file from the given URL and wraps it in a RobotModel.
    /// The file is treated as a single-link, single-mesh model.
    /// - Parameter url: URL to the .obj file
    /// - Returns: A RobotModel containing the loaded geometry
    /// - Throws: OBJLoaderError if the file cannot be read or decoded
    static func loadOBJAsRobotModel(from url: URL) throws -> RobotModel {
        // Load the .obj geometry
        let geometry = try loadOBJGeometry(from: url)

        // Create a single link with the loaded geometry
        let visual = URDFVisual(
            geometry: .mesh(filename: url.lastPathComponent, scale: nil),
            origin: .identity,
            material: nil
        )

        let link = URDFLink(
            name: "obj_mesh",
            visual: visual,
            collision: nil,
            inertial: nil
        )

        // Build a minimal RobotModel with just this link
        let model = RobotModel(
            name: url.deletingPathExtension().lastPathComponent,
            links: [link],
            joints: [],
            baseURL: url.deletingLastPathComponent()
        )

        return model
    }

    /// Loads a .obj file and returns an SCNGeometry.
    /// - Parameter url: URL to the .obj file
    /// - Returns: The loaded SCNGeometry
    /// - Throws: OBJLoaderError if the file cannot be read or decoded
    private static func loadOBJGeometry(from url: URL) throws -> SCNGeometry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OBJLoaderError.fileNotFound(url.path)
        }

        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw OBJLoaderError.unsupportedFileType(url.pathExtension)
        }

        let asset = MDLAsset(url: url)
        asset.loadTextures()

        // Walk the asset hierarchy looking for the first mesh
        for i in 0..<asset.count {
            let mdlObject = asset.object(at: i)
            if let geometry = scnGeometry(from: mdlObject) {
                return geometry
            }
        }

        throw OBJLoaderError.noMeshFound
    }

    /// Recursively extract the first SCNGeometry from an MDLObject tree.
    private static func scnGeometry(from mdlObject: MDLObject) -> SCNGeometry? {
        if let mesh = mdlObject as? MDLMesh {
            let node = SCNNode(mdlObject: mesh)
            if let geo = node.geometry { return geo }
        }
        for child in mdlObject.children.objects {
            if let geo = scnGeometry(from: child) { return geo }
        }
        return nil
    }
}

// MARK: - OBJLoaderError

enum OBJLoaderError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFileType(String)
    case noMeshFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext). Only .obj files are supported."
        case .noMeshFound:
            return "No mesh found in the .obj file."
        }
    }
}
