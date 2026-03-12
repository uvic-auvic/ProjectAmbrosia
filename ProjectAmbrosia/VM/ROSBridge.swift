import Foundation
import Network
import Combine

// MARK: - Bridge State

enum BridgeState: Equatable {
    case idle
    case listening
    case connected(remoteHost: String)
    case error(String)
}

// MARK: - ROSBridge

/// TCP server on port 8765 that bridges the ROS 2 Python node (running in the VM)
/// to the Swift simulation state.
@MainActor
final class ROSBridge: ObservableObject {

    // MARK: - Published State

    @Published var state: BridgeState = .idle
    @Published var receivedMessageCount: Int = 0
    @Published var lastJointUpdateTime: Date?

    // MARK: - Callbacks

    /// Called when joint states arrive from the VM.
    var onJointStates: (([String: Double]) -> Void)?
    /// Called when a URDF description arrives from the VM (once on connect).
    var onRobotDescription: ((String) -> Void)?

    // MARK: - Private

    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    // vsock file handle (bidirectional socket, set when guest connects via VirtioSocket)
    private var vsockHandle: FileHandle?

    private let port: NWEndpoint.Port = 8765
    private let queue = DispatchQueue(label: "com.macrobosim.rosbridge", qos: .userInteractive)

    // MARK: - Lifecycle

    /// Start listening for incoming connections from the VM bridge node.
    func startListening() {
        guard state == .idle else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: port)
        } catch {
            state = .error("Failed to create listener: \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .listening
                case .failed(let err):
                    self.state = .error(err.localizedDescription)
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] newConn in
            Task { @MainActor [weak self] in
                self?.acceptConnection(newConn)
            }
        }

        listener?.start(queue: queue)
    }

    /// Stop the listener and disconnect any active client.
    func stopListening() {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        vsockHandle?.readabilityHandler = nil
        vsockHandle = nil
        state = .idle
    }

    // MARK: - VirtioSocket Connection

    /// Accept a VirtioSocket guest connection (bypasses network + firewall).
    func acceptVsockConnection(_ fh: FileHandle) {
        connection?.cancel()
        connection = nil
        vsockHandle?.readabilityHandler = nil

        vsockHandle = fh
        receiveBuffer = Data()
        state = .connected(remoteHost: "VM vsock")

        fh.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveBuffer.append(data)
                self.processBuffer()
            }
        }
    }

    // MARK: - Sending

    /// Send a `cmd_vel` command to the VM.
    func sendCmdVel(linearX: Double, linearY: Double, linearZ: Double,
                    angularX: Double, angularY: Double, angularZ: Double) {
        let msg: [String: Any] = [
            "type": "cmd_vel",
            "linear": ["x": linearX, "y": linearY, "z": linearZ],
            "angular": ["x": angularX, "y": angularY, "z": angularZ]
        ]
        sendJSON(msg)
    }

    /// Send a joint position command to the VM.
    func sendJointCmd(name: String, position: Double) {
        let msg: [String: Any] = ["type": "joint_cmd", "name": name, "position": position]
        sendJSON(msg)
    }

    // MARK: - Private Connection Handling

    private func acceptConnection(_ newConn: NWConnection) {
        // Only allow one connection at a time; cancel previous.
        connection?.cancel()
        connection = newConn
        receiveBuffer = Data()

        let remoteHost = connectionHost(newConn)
        state = .connected(remoteHost: remoteHost)

        newConn.stateUpdateHandler = { [weak self] connState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed(let err) = connState {
                    self.state = .error(err.localizedDescription)
                } else if case .cancelled = connState {
                    if self.state != .idle {
                        self.state = .listening
                    }
                }
            }
        }

        newConn.start(queue: queue)
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data = data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
                if let error = error {
                    self.state = .error(error.localizedDescription)
                    return
                }
                if !isComplete {
                    self.receiveNextChunk()
                }
            }
        }
    }

    private func processBuffer() {
        while let newlineRange = receiveBuffer.range(of: Data([0x0A])) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<newlineRange.lowerBound]
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineRange.lowerBound)
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        receivedMessageCount += 1

        switch type {
        case "joint_states":
            handleJointStates(json)
        case "robot_description":
            if let urdf = json["urdf"] as? String {
                onRobotDescription?(urdf)
            }
        case "ping":
            sendJSON(["type": "pong"])
        default:
            break
        }
    }

    private func handleJointStates(_ json: [String: Any]) {
        guard let joints = json["joints"] as? [[String: Any]] else { return }
        var values: [String: Double] = [:]
        for joint in joints {
            guard let name = joint["name"] as? String,
                  let position = joint["position"] as? Double else { continue }
            values[name] = position
        }
        lastJointUpdateTime = Date()
        onJointStates?(values)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var payload = data
        payload.append(0x0A)  // newline delimiter
        if let vsock = vsockHandle {
            vsock.write(payload)
        } else if let conn = connection {
            conn.send(content: payload, completion: .idempotent)
        }
    }

    private func connectionHost(_ conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint {
            return "\(host)"
        }
        return "unknown"
    }
}
