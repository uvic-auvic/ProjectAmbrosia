import Foundation
import Virtualization
import Combine

// MARK: - VM State

enum VMState: Equatable {
    case notStarted
    case booting
    case running
    case paused
    case stopped
    case error(String)
}

// MARK: - VMManager

/// Manages the lifecycle of the embedded Ubuntu 22.04 ARM64 virtual machine
/// using `Virtualization.framework`. Degrades gracefully if the disk image is absent.
@MainActor
final class VMManager: ObservableObject {

    // MARK: - Published State

    @Published var vmState: VMState = .notStarted
    @Published var consoleOutput: String = ""   // kept for logging/debug
    @Published var resolvedDiskImageURL: URL?

    /// Called on the main thread whenever the VM writes bytes to the serial port.
    var onOutput: (([UInt8]) -> Void)?

    /// Called when a guest connects via VirtioSocket (port 8765).
    /// Receives a bidirectional `FileHandle` wrapping the vsock file descriptor.
    var vsockConnectionHandler: ((FileHandle) -> Void)?

    // MARK: - Private

    private var virtualMachine: VZVirtualMachine?
    private var consolePipe: Pipe?
    private var inputPipe: Pipe?       // writes go TO the VM serial port
    private var vmDelegateAdapter: VMDelegateAdapter?
    private var vsockListenerAdapter: VsockListenerAdapter?
    /// Strong references to open vsock connections (keeps file handles alive)
    private var vsockConnections: [VZVirtioSocketConnection] = []

    private let diskImageName = "ros2_ubuntu2204"
    private let diskImageExtension = "img"
    private let cpuCount = 4
    private let memorySizeMB: UInt64 = 4096

    private let userDefaultsKey = "com.macrobosim.diskImagePath"
    private let bookmarkKey = "com.macrobosim.diskImageBookmark"
    private var diskImageAccessToken: URL?  // URL currently being accessed

    // MARK: - Disk Image Location

    /// Send a line of text input to the VM serial console (e.g. login, shell commands).
    func sendInput(_ text: String) {
        guard let pipe = inputPipe else { return }
        if let data = text.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    /// Set a user-chosen disk image URL, saving a security-scoped bookmark for future launches.
    func setDiskImageURL(_ url: URL) {
        // Save a security-scoped bookmark so sandbox access survives app restarts.
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            appendConsole("[VMManager] Warning: could not create bookmark: \(error.localizedDescription)\n")
            // Fall back to plain path.
            UserDefaults.standard.set(url.path, forKey: userDefaultsKey)
        }
        resolvedDiskImageURL = url
        if case .error = vmState { vmState = .notStarted }
        appendConsole("[VMManager] Disk image set: \(url.path)\n")
    }

    // MARK: - Lifecycle

    /// Boot the VM. The ROS bridge should be started BEFORE calling this.
    func boot() async {
        guard vmState == .notStarted || vmState == .stopped else { return }

        vmState = .booting
        appendConsole("[VMManager] Booting virtual machine…\n")

        guard let config = buildConfiguration() else { return }

        do {
            try config.validate()
        } catch {
            vmState = .error("VM configuration invalid: \(error.localizedDescription)")
            appendConsole("[VMManager] Configuration error: \(error.localizedDescription)\n")
            return
        }

        let vm = VZVirtualMachine(configuration: config)
        virtualMachine = vm

        let adapter = VMDelegateAdapter(manager: self)
        vmDelegateAdapter = adapter
        vm.delegate = adapter

        do {
            try await vm.start()
            vmState = .running
            setupVsockListener()
            appendConsole("[VMManager] VM started successfully.\n")
        } catch {
            vmState = .error("VM failed to start: \(error.localizedDescription)")
            appendConsole("[VMManager] Start error: \(error.localizedDescription)\n")
        }
    }

    /// Gracefully shut down the VM.
    func shutdown() async {
        guard let vm = virtualMachine, vmState == .running else { return }
        do {
            try await vm.stop()
            vmState = .stopped
            appendConsole("[VMManager] VM stopped.\n")
            virtualMachine = nil
            vmDelegateAdapter = nil
            vsockListenerAdapter = nil
            vsockConnections = []
            consolePipe = nil
            inputPipe = nil
            diskImageAccessToken?.stopAccessingSecurityScopedResource()
            diskImageAccessToken = nil
        } catch {
            vmState = .error("Shutdown error: \(error.localizedDescription)")
        }
    }

    // MARK: - Console

    func appendConsole(_ text: String) {
        consoleOutput.append(text)
        if consoleOutput.count > 100_000 {
            consoleOutput = String(consoleOutput.suffix(80_000))
        }
    }

    // MARK: - Configuration

    private func buildConfiguration() -> VZVirtualMachineConfiguration? {
        guard let diskURL = findAndPrepareDiskImage() else {
            vmState = .error("Disk image not found. Use 'Locate Disk Image…' in the VM Console to point to ros2_ubuntu2204.img")
            appendConsole("[VMManager] Disk image not found. Use the VM Console to locate it.\n")
            return nil
        }

        appendConsole("[VMManager] Using disk image: \(diskURL.path)\n")

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = memorySizeMB * 1024 * 1024

        // Boot loader (Linux EFI)
        let bootLoader = VZEFIBootLoader()
        if let nvramURL = nvramURL() {
            if FileManager.default.fileExists(atPath: nvramURL.path) {
                bootLoader.variableStore = VZEFIVariableStore(url: nvramURL)
            } else {
                do {
                    bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
                    appendConsole("[VMManager] Created new NVRAM store.\n")
                } catch {
                    appendConsole("[VMManager] Warning: could not create NVRAM store: \(error.localizedDescription)\n")
                }
            }
        }
        config.bootLoader = bootLoader

        // Platform
        config.platform = VZGenericPlatformConfiguration()

        // Storage
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        } catch {
            vmState = .error("Could not attach disk image: \(error.localizedDescription)")
            appendConsole("[VMManager] Disk attach error: \(error.localizedDescription)\n")
            return nil
        }

        // Network — NAT (host reachable at 10.0.2.2 inside the VM)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Serial console — bidirectional pipe
        // inputPipe.fileHandleForReading  → framework reads → data goes TO the VM
        // outputPipe.fileHandleForWriting → framework writes → data comes FROM the VM
        let outputPipe = Pipe()
        let inPipe = Pipe()
        consolePipe = outputPipe
        inputPipe = inPipe
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting)
        config.serialPorts = [serialPort]
        startConsoleReading(pipe: outputPipe)

        // VirtioSocket device — allows guest to connect directly to host port 8765
        // without going through the network stack (bypasses macOS firewall)
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        return config
    }

    // MARK: - VirtioSocket Bridge

    private func setupVsockListener() {
        guard let vsockDevice = virtualMachine?.socketDevices.first as? VZVirtioSocketDevice else {
            appendConsole("[VMManager] Note: vsock device unavailable — using TCP bridge only.\n")
            return
        }
        let adapter = VsockListenerAdapter { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.vsockConnections.append(connection)
                // Wrap the bidirectional socket fd as a single FileHandle
                let fh = FileHandle(fileDescriptor: connection.fileDescriptor,
                                    closeOnDealloc: false)
                self.vsockConnectionHandler?(fh)
                self.appendConsole("[VMManager] Guest connected via vsock (port 8765).\n")
            }
        }
        vsockListenerAdapter = adapter
        let listener = VZVirtioSocketListener()
        listener.delegate = adapter
        vsockDevice.setSocketListener(listener, forPort: 8765)
        appendConsole("[VMManager] VirtioSocket listener ready on port 8765.\n")
    }

    // MARK: - Disk Image Search

    private func findAndPrepareDiskImage() -> URL? {
        let filename = "\(diskImageName).\(diskImageExtension)"

        // 1. Resolve a saved security-scoped bookmark (survives sandbox across launches).
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                   options: .withSecurityScope,
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &isStale) {
                if url.startAccessingSecurityScopedResource() {
                    diskImageAccessToken = url
                }
                if isStale {
                    // Refresh the bookmark.
                    if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                    }
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    resolvedDiskImageURL = url
                    return url
                }
            }
        }

        // 2. App Support directory (writable — preferred for distribution).
        let appSupportURL = appSupportDirectory()?.appendingPathComponent(filename)
        if let url = appSupportURL, FileManager.default.fileExists(atPath: url.path) {
            resolvedDiskImageURL = url
            return url
        }

        // 3. App bundle resources — copy to App Support first (bundle is read-only).
        if let bundleURL = Bundle.main.url(forResource: diskImageName, withExtension: diskImageExtension),
           let destURL = appSupportURL {
            appendConsole("[VMManager] Copying disk image from bundle to App Support (first launch)…\n")
            do {
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: bundleURL, to: destURL)
                resolvedDiskImageURL = destURL
                return destURL
            } catch {
                appendConsole("[VMManager] Copy failed: \(error.localizedDescription)\n")
            }
        }

        // 4. Common development locations.
        let devPaths: [String] = [
            Bundle.main.bundleURL.deletingLastPathComponent().path,
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ProjectAmbrosia/Scripts").path,
            FileManager.default.homeDirectoryForCurrentUser.path
        ]
        for dir in devPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                resolvedDiskImageURL = candidate
                return candidate
            }
        }

        return nil
    }

    // MARK: - Support Paths

    private func appSupportDirectory() -> URL? {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls.first?.appendingPathComponent("MacRoboSim", isDirectory: true)
        if let d = dir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return dir
    }

    private func nvramURL() -> URL? {
        appSupportDirectory()?.appendingPathComponent("nvram.bin")
    }

    // MARK: - Console Pipe

    private func startConsoleReading(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            let bytes = [UInt8](data)
            // Fire raw-byte callback (for terminal emulator) and keep text log
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onOutput?(bytes)
                if let text = String(data: data, encoding: .utf8) {
                    self.appendConsole(text)
                }
            }
        }
    }
}

// MARK: - VM Delegate Adapter

private final class VMDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    weak var manager: VMManager?
    init(manager: VMManager) { self.manager = manager }

    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.vmState = .error(error.localizedDescription)
            self?.manager?.appendConsole("[VMManager] VM stopped with error: \(error.localizedDescription)\n")
        }
    }

    func guestDidStop(_ vm: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            self?.manager?.vmState = .stopped
            self?.manager?.appendConsole("[VMManager] Guest stopped cleanly.\n")
        }
    }
}

// MARK: - VsockListenerAdapter

private final class VsockListenerAdapter: NSObject, VZVirtioSocketListenerDelegate {
    private let handler: (VZVirtioSocketConnection) -> Void
    init(handler: @escaping (VZVirtioSocketConnection) -> Void) { self.handler = handler }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        handler(connection)
        return true
    }
}

