import Foundation

// MARK: - Errors

enum URDFParseError: LocalizedError {
    case invalidFile(String)
    case missingAttribute(String, element: String)
    case noRobotElement

    var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return "Invalid URDF file: \(msg)"
        case .missingAttribute(let attr, let el): return "Missing attribute '\(attr)' on <\(el)>"
        case .noRobotElement: return "No <robot> root element found in URDF"
        }
    }
}

// MARK: - Parser

/// Parses a URDF XML file (or string) into a `RobotModel`.
/// Pure, synchronous, does not touch SceneKit.
enum URDFParser {

    /// Parse a URDF from a file URL.
    static func parse(url: URL) throws -> RobotModel {
        let data = try Data(contentsOf: url)
        var model = try parse(data: data)
        model.baseURL = url.deletingLastPathComponent()
        return model
    }

    /// Parse a URDF from a raw XML string.
    static func parse(xmlString: String) throws -> RobotModel {
        guard let data = xmlString.data(using: .utf8) else {
            throw URDFParseError.invalidFile("Could not encode XML string as UTF-8")
        }
        return try parse(data: data)
    }

    // MARK: - Private

    private static func parse(data: Data) throws -> RobotModel {
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "robot" else {
            throw URDFParseError.noRobotElement
        }

        let robotName = root.attribute(forName: "name")?.stringValue ?? "unnamed"

        let linkNodes = root.elements(forName: "link")
        let jointNodes = root.elements(forName: "joint")

        let links = try linkNodes.map { try parseLink($0) }
        let joints = try jointNodes.map { try parseJoint($0) }

        return RobotModel(name: robotName, links: links, joints: joints)
    }

    // MARK: Link Parsing

    private static func parseLink(_ node: XMLElement) throws -> URDFLink {
        let name = try requireAttr("name", of: node, element: "link")

        let visual = try node.elements(forName: "visual").first.map { try parseVisual($0) }
        let collision = try node.elements(forName: "collision").first.map { try parseCollision($0) }
        let inertial = try node.elements(forName: "inertial").first.map { try parseInertial($0) }

        return URDFLink(name: name, visual: visual, collision: collision, inertial: inertial)
    }

    private static func parseVisual(_ node: XMLElement) throws -> URDFVisual {
        let origin = parseOrigin(node.elements(forName: "origin").first)
        let geoNode = node.elements(forName: "geometry").first
        let geometry = try parseGeometry(geoNode)
        let material = node.elements(forName: "material").first.map { parseMaterial($0) }
        return URDFVisual(geometry: geometry, origin: origin, material: material)
    }

    private static func parseCollision(_ node: XMLElement) throws -> URDFCollision {
        let origin = parseOrigin(node.elements(forName: "origin").first)
        let geoNode = node.elements(forName: "geometry").first
        let geometry = try parseGeometry(geoNode)
        return URDFCollision(geometry: geometry, origin: origin)
    }

    private static func parseInertial(_ node: XMLElement) throws -> URDFInertial {
        let origin = parseOrigin(node.elements(forName: "origin").first)
        let mass = Float(node.elements(forName: "mass").first?.attribute(forName: "value")?.stringValue ?? "0") ?? 0
        let inertiaNode = node.elements(forName: "inertia").first
        let ixx = floatAttr("ixx", of: inertiaNode)
        let ixy = floatAttr("ixy", of: inertiaNode)
        let ixz = floatAttr("ixz", of: inertiaNode)
        let iyy = floatAttr("iyy", of: inertiaNode)
        let iyz = floatAttr("iyz", of: inertiaNode)
        let izz = floatAttr("izz", of: inertiaNode)
        return URDFInertial(mass: mass, origin: origin,
                            ixx: ixx, ixy: ixy, ixz: ixz,
                            iyy: iyy, iyz: iyz, izz: izz)
    }

    // MARK: Geometry Parsing

    private static func parseGeometry(_ node: XMLElement?) throws -> URDFGeometry {
        guard let node = node else {
            return .box(size: SIMD3<Float>(0.1, 0.1, 0.1))
        }

        if let boxNode = node.elements(forName: "box").first {
            let size = parseVec3(boxNode.attribute(forName: "size")?.stringValue ?? "0.1 0.1 0.1")
            return .box(size: size)
        }
        if let cylNode = node.elements(forName: "cylinder").first {
            let r = Float(cylNode.attribute(forName: "radius")?.stringValue ?? "0.05") ?? 0.05
            let l = Float(cylNode.attribute(forName: "length")?.stringValue ?? "0.1") ?? 0.1
            return .cylinder(radius: r, length: l)
        }
        if let sphNode = node.elements(forName: "sphere").first {
            let r = Float(sphNode.attribute(forName: "radius")?.stringValue ?? "0.05") ?? 0.05
            return .sphere(radius: r)
        }
        if let meshNode = node.elements(forName: "mesh").first {
            let filename = meshNode.attribute(forName: "filename")?.stringValue ?? ""
            var scale: SIMD3<Float>? = nil
            if let scaleStr = meshNode.attribute(forName: "scale")?.stringValue {
                scale = parseVec3(scaleStr)
            }
            return .mesh(filename: filename, scale: scale)
        }

        return .box(size: SIMD3<Float>(0.1, 0.1, 0.1))
    }

    // MARK: Joint Parsing

    private static func parseJoint(_ node: XMLElement) throws -> URDFJoint {
        let name = try requireAttr("name", of: node, element: "joint")
        let typeStr = node.attribute(forName: "type")?.stringValue ?? "fixed"
        let type = JointType(rawValue: typeStr) ?? .fixed

        let parent = try requireAttr("link",
                                     of: node.elements(forName: "parent").first,
                                     element: "parent")
        let child = try requireAttr("link",
                                    of: node.elements(forName: "child").first,
                                    element: "child")

        let origin = parseOrigin(node.elements(forName: "origin").first)

        let axisNode = node.elements(forName: "axis").first
        let axisVec = parseVec3(axisNode?.attribute(forName: "xyz")?.stringValue ?? "1 0 0")

        let limit = node.elements(forName: "limit").first.map { parseLimits($0) }

        return URDFJoint(name: name, type: type,
                         parentLink: parent, childLink: child,
                         origin: origin, axis: axisVec, limit: limit)
    }

    // MARK: Shared Helpers

    private static func parseOrigin(_ node: XMLElement?) -> URDFOrigin {
        guard let node = node else { return .identity }
        let xyz = parseVec3(node.attribute(forName: "xyz")?.stringValue ?? "0 0 0")
        let rpy = parseVec3(node.attribute(forName: "rpy")?.stringValue ?? "0 0 0")
        return URDFOrigin(xyz: xyz, rpy: rpy)
    }

    private static func parseMaterial(_ node: XMLElement) -> URDFMaterial {
        let name = node.attribute(forName: "name")?.stringValue
        let colorNode = node.elements(forName: "color").first
        let rgba = parseVec4(colorNode?.attribute(forName: "rgba")?.stringValue ?? "0.7 0.7 0.7 1")
        return URDFMaterial(name: name, rgba: rgba)
    }

    private static func parseLimits(_ node: XMLElement) -> JointLimit {
        let lower = Float(node.attribute(forName: "lower")?.stringValue ?? "0") ?? 0
        let upper = Float(node.attribute(forName: "upper")?.stringValue ?? "0") ?? 0
        let effort = Float(node.attribute(forName: "effort")?.stringValue ?? "0") ?? 0
        let velocity = Float(node.attribute(forName: "velocity")?.stringValue ?? "0") ?? 0
        return JointLimit(lower: lower, upper: upper, effort: effort, velocity: velocity)
    }

    private static func parseVec3(_ s: String) -> SIMD3<Float> {
        let parts = s.split(separator: " ").compactMap { Float($0) }
        guard parts.count >= 3 else { return .zero }
        return SIMD3<Float>(parts[0], parts[1], parts[2])
    }

    private static func parseVec4(_ s: String) -> SIMD4<Float> {
        let parts = s.split(separator: " ").compactMap { Float($0) }
        guard parts.count >= 4 else { return SIMD4<Float>(0.7, 0.7, 0.7, 1) }
        return SIMD4<Float>(parts[0], parts[1], parts[2], parts[3])
    }

    private static func floatAttr(_ name: String, of node: XMLElement?) -> Float {
        Float(node?.attribute(forName: name)?.stringValue ?? "0") ?? 0
    }

    private static func requireAttr(_ attr: String, of node: XMLElement?, element: String) throws -> String {
        guard let value = node?.attribute(forName: attr)?.stringValue, !value.isEmpty else {
            throw URDFParseError.missingAttribute(attr, element: element)
        }
        return value
    }
}
