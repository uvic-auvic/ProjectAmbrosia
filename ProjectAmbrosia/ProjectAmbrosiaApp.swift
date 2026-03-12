//
//  ProjectAmbrosiaApp.swift
//  ProjectAmbrosia
//
//  Created by miniman on 2026-03-09.
//

import SwiftUI

@main
struct MacRoboSimApp: App {

    @StateObject private var simulatorState = SimulatorState()
    @StateObject private var vmManager = VMManager()
    @StateObject private var rosBridge = ROSBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(simulatorState)
                .environmentObject(vmManager)
                .environmentObject(rosBridge)
                .task {
                    // Start TCP listener BEFORE booting the VM.
                    rosBridge.startListening()

                    // Wire vsock handler — used by Virtualization.framework VM (bypasses firewall)
                    vmManager.vsockConnectionHandler = { [weak rosBridge] fh in
                        rosBridge?.acceptVsockConnection(fh)
                    }

                    // Wire bridge callbacks into simulator state.
                    rosBridge.onJointStates = { [weak simulatorState] values in
                        Task { @MainActor in
                            for (name, value) in values {
                                simulatorState?.setJointValue(value, for: name)
                            }
                        }
                    }

                    rosBridge.onRobotDescription = { [weak simulatorState] urdfString in
                        Task { @MainActor in
                            do {
                                let model = try URDFParser.parse(xmlString: urdfString)
                                simulatorState?.applyRobot(model)
                            } catch {
                                simulatorState?.errorMessage = error.localizedDescription
                            }
                        }
                    }

                    await vmManager.boot()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Load URDF…") {
                    // Handled inside ContentView via toolbar button.
                    // This entry provides a matching menu item.
                    NotificationCenter.default.post(name: .loadURDF, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let loadURDF = Notification.Name("com.macrobosim.loadURDF")
}
