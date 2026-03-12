# MacRoboSim — GitHub Copilot Prompt

You are helping build **MacRoboSim**, a macOS-native robotics simulator written in Swift.
This is a real project being developed for a RoboSub technical report. Read this entire file
before suggesting any code. Every suggestion must be consistent with the architecture described here.

---

## What This Project Is

A macOS App (SwiftUI + SceneKit) that:
1. Boots an embedded Ubuntu 22.04 ARM64 Linux VM on launch using `Virtualization.framework`
2. The VM runs ROS 2 Humble and a Python bridge node that connects back to the Swift app over TCP
3. Joint states published on `/joint_states` in ROS 2 are forwarded over TCP and drive a 3D robot model rendered in SceneKit
4. The user can load URDF/SDF robot description files, inspect the link/joint hierarchy, and manually drive joints via sliders
5. The simulation can be played/paused/reset, and ROS 2 code running inside the VM controls the model in real time

Target platform: **macOS 13+, Apple Silicon (ARM64)**. No Intel support needed.

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI framework | SwiftUI |
| 3D rendering | SceneKit (`SCNView`, `SCNNode`, `SCNScene`) |
| VM execution | `Virtualization.framework` (Apple, macOS 13+) |
| Networking | `Network.framework` (`NWListener`, `NWConnection`) |
| Robot format | URDF (XML), SDF (future) |
| VM OS | Ubuntu 22.04 LTS ARM64 |
| ROS version | ROS 2 Humble Hawksbill |
| Bridge protocol | Newline-delimited JSON over TCP port 8765 |
| Concurrency | Swift Structured Concurrency (`async/await`, `@MainActor`, `Task`) |

---

## Project File Structure

```
MacRoboSim/
├── MacRoboSimApp.swift              # @main App — boots VM and wires bridge on launch
├── MacRoboSim.entitlements          # Requires com.apple.security.virtualization
│
├── State/
│   └── SimulatorState.swift         # Central @MainActor ObservableObject
│                                    # Owns: SCNScene, RobotModel, jointValues, sim timer
│
├── Models/
│   ├── URDFModels.swift             # Value types: RobotModel, URDFLink, URDFJoint,
│   │                                #   URDFGeometry, URDFOrigin, JointLimit, etc.
│   ├── URDFParser.swift             # XMLDocument → RobotModel (uses Foundation XMLDocument)
│   └── RobotSceneBuilder.swift      # RobotModel → SCNNode tree + joint actuation
│
├── VM/
│   ├── VMManager.swift              # Virtualization.framework VM lifecycle
│   │                                #   boot(), shutdown(), console output piped to UI
│   ├── ROSBridge.swift              # NWListener TCP server on :8765
│   │                                #   Parses joint_states, robot_description
│   │                                #   Sends cmd_vel, joint_cmd back to VM
│   └── README.md                    # VM setup and architecture diagram
│
├── Views/
│   ├── ContentView.swift            # NavigationSplitView: hierarchy | viewport | inspector
│   ├── ViewportView.swift           # NSViewRepresentable wrapping SCNView
│   ├── SceneHierarchyPanel.swift    # Left panel: robot link tree (List + Section)
│   ├── InspectorPanel.swift         # Right panel: joint sliders, link info
│   ├── SimulationToolbar.swift      # Play/pause/reset + speed picker
│   └── VMConsoleView.swift          # Sheet: VM boot log + bridge status indicators
│
└── Scripts/
    ├── ros2_swift_bridge.py         # ROS 2 Python node (runs INSIDE the VM)
    │                                #   Connects to 10.0.2.2:8765, bridges topics↔TCP
    └── build_vm_image.sh            # One-time script: builds Ubuntu+ROS2 disk image
```

---

## Core Data Model

```swift
// A fully parsed URDF robot
struct RobotModel {
    var name: String
    var links: [URDFLink]
    var joints: [URDFJoint]
}

// A single link (rigid body)
struct URDFLink: Identifiable {
    var name: String
    var visual: URDFVisual?      // geometry + material for rendering
    var collision: URDFCollision?
    var inertial: URDFInertial?
}

// A joint connecting two links
struct URDFJoint: Identifiable {
    var name: String
    var type: JointType          // .fixed .revolute .continuous .prismatic
    var parentLink: String
    var childLink: String
    var origin: URDFOrigin       // xyz + rpy
    var axis: SIMD3<Float>
    var limit: JointLimit?       // lower/upper bounds
}

// Geometry variants
enum URDFGeometry {
    case box(size: SIMD3<Float>)
    case cylinder(radius: Float, length: Float)
    case sphere(radius: Float)
    case mesh(filename: String, scale: SIMD3<Float>?)
}
```

---

## TCP Bridge Protocol

All messages are **newline-delimited JSON** (`\n` terminated).

### VM → Swift (inbound to ROSBridge)

```json
// Joint states from /joint_states topic
{"type":"joint_states","joints":[{"name":"joint1","position":1.23,"velocity":0.0,"effort":0.0}]}

// URDF string from /robot_description topic (sent once on connect)
{"type":"robot_description","urdf":"<robot name='...'>...</robot>"}

// Keepalive
{"type":"ping"}
```

### Swift → VM (outbound from ROSBridge)

```json
// Drive the robot
{"type":"cmd_vel","linear":{"x":0.5,"y":0.0,"z":0.0},"angular":{"x":0.0,"y":0.0,"z":0.2}}

// Move a specific joint
{"type":"joint_cmd","name":"joint1","position":1.57}

// Keepalive response
{"type":"pong"}
```

---

## Key Architecture Rules

1. **All UI and state mutation happens on `@MainActor`**. `SimulatorState` is `@MainActor`. Never mutate `@Published` properties from background threads — always wrap in `Task { @MainActor in ... }`.

2. **`VMManager` and `ROSBridge` are both `@MainActor` `ObservableObject`s**. They are created as `@StateObject` in `MacRoboSimApp` and passed via `.environmentObject()`.

3. **SceneKit node mutations must happen on the main thread**. `SCNNode` position/rotation/orientation changes go through `SimulatorState.setJointValue()` which is always called on `@MainActor`.

4. **The TCP listener starts BEFORE the VM boots**. In `MacRoboSimApp.task`, `rosBridge.startListening()` is called first, then `await vmManager.boot()`. Never reverse this order.

5. **URDF parsing is pure/synchronous** — `URDFParser.parse(url:)` is a static throwing function. It does not touch the scene. `SimulatorState.applyRobot()` applies the parsed model to the scene.

6. **`RobotSceneBuilder` is stateless**. `buildScene(from:)` and `setJointValue(_:joint:in:)` are both static functions. No state stored in the builder.

7. **VM network topology**: Inside the QEMU NAT VM, the host Mac is always reachable at `10.0.2.2`. The Swift TCP server listens on `0.0.0.0:8765`. The Python bridge node connects TO the host — Swift never connects into the VM.

8. **No third-party Swift packages**. All functionality uses Apple SDKs only: SceneKit, SwiftUI, Virtualization, Network, Foundation.

9. **Error messages surface via `SimulatorState.errorMessage`** which triggers `.alert()` in `ContentView`. Never use `fatalError` or `print`-only error handling in production paths.

10. **Geometry → SCNGeometry conversion lives in `URDFGeometry.toSCNGeometry()`** — not in the parser, not in the builder. Keep conversion logic with the type.

---

## Coding Style

- Swift 5.9+, macOS 13+ APIs only
- Prefer `async/await` over callbacks or `DispatchQueue` unless interoperating with a callback-based API
- Use `@MainActor` on classes rather than individual methods where the whole class is UI-bound
- `// MARK: -` sections for every logical group within a file
- Prefer `struct` over `class` for model types; `class` for stateful managers
- All `ObservableObject` classes use `@Published` for every property that drives UI
- Explicit `weak self` in closures that are stored (timers, network handlers)
- All public functions have a one-line doc comment

---

## What Is NOT Yet Implemented (your job)

These are the open tasks, in priority order:

### High Priority
- [ ] **STL/OBJ mesh loading** in `URDFGeometry.mesh` case — currently returns a placeholder box. Use `SCNSceneSource` or `MDLAsset` (ModelIO) to load mesh files referenced in URDF `<mesh filename="...">` tags
- [ ] **SDF parser** (`SDFParser.swift`) — Gazebo's native format, similar structure to URDF but with different tag names. Should produce the same `RobotModel` output as `URDFParser`
- [ ] **Physics environment panel** (`PhysicsEnvironmentView.swift`) — UI to configure gravity vector, buoyancy plane height, drag coefficient. Values applied to `SCNPhysicsWorld` and as per-frame forces in `SimulatorState.stepSimulation()`
- [ ] **Buoyancy force simulation** in `stepSimulation()` — apply upward force to links below a configurable water plane, proportional to submerged volume approximation
- [ ] **Thruster force model** — define thruster attachment points and direction vectors on the robot, apply `SCNPhysicsBody` impulses each simulation step

### Medium Priority
- [ ] **RealityKit migration** — swap `SCNView`/`SCNNode` for `RealityView`/`ModelEntity` for better lighting and future AR support. Keep `RobotSceneBuilder` interface identical, swap internals
- [ ] **USDZ export** — convert loaded robot to `.usdz` via `ModelIO` for RealityKit compatibility and AR Quick Look
- [ ] **Joint trajectory recording** — record `[String: Double]` joint value snapshots at 60Hz during simulation, export to CSV
- [ ] **VM snapshot/restore** — use `VZVirtualMachine` save/restore APIs to snapshot VM state so users don't wait for full boot every launch

### Lower Priority  
- [ ] **ROS 2 topic browser** — query the VM bridge for a list of active topics, display in a panel, let user remap which topic drives joint states
- [ ] **SolidWorks import** — accept `.step` files, shell out to FreeCAD CLI for conversion to OBJ, then load via mesh pipeline
- [ ] **Statistics overlay** in viewport — polygon count, frame rate, joint state update rate
- [ ] **App icon and branding**

---

## Testing

There is no XCTest suite yet. When adding tests:
- Unit test `URDFParser` against known URDF XML strings
- Unit test `URDFGeometry.toSCNGeometry()` for each geometry type
- Unit test `ROSBridge` message parsing with mock JSON strings
- Do NOT test SceneKit node hierarchy in unit tests — use UI tests or manual verification

---

## Reference URDFs for Testing

These are small, well-known URDFs suitable for testing the parser and renderer:
- `rrbot.urdf` — 2-link revolute arm (classic ROS tutorial)
- `turtlebot3_burger.urdf` — differential drive mobile robot
- Both available in the ROS 2 `demos` repository on GitHub

---

## VM Image

The VM disk image (`ros2_ubuntu2204.img`) is NOT in the repository.
Build it once using `Scripts/build_vm_image.sh` (requires `brew install qemu wget`).
Add the output image to the Xcode project under Resources and mark it in
Build Phases → Copy Bundle Resources.

During development without the VM image, the app should degrade gracefully:
- `VMManager` shows `.error("Disk image not found")` state
- `ROSBridge` stays in `.listening` state
- The rest of the app (URDF loading, manual joint control, simulation) works normally
