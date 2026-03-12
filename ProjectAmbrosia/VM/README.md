# VM Architecture — MacRoboSim

## Overview

```
┌────────────────────────────────────────────────────────┐
│  macOS Host (Apple Silicon)                            │
│                                                        │
│  ┌─────────────────────┐   TCP :8765 (NW.framework)    │
│  │  Swift App          │◄──────────────────────────┐   │
│  │  ROSBridge          │                           │   │
│  │  VMManager          │                           │   │
│  └─────────────────────┘                           │   │
│           │ Virtualization.framework               │   │
│           ▼                                        │   │
│  ┌────────────────────────────────────────────┐    │   │
│  │  Ubuntu 22.04 ARM64 VM (QEMU/VF2)          │    │   │
│  │                                            │    │   │
│  │  ROS 2 Humble ──► /joint_states topic      │    │   │
│  │                                            │    │   │
│  │  ros2_swift_bridge.py                      │    │   │
│  │    subscribes: /joint_states               │    │   │
│  │               /robot_description           │    │   │
│  │    publishes:  /cmd_vel                    │    │   │
│  │               /joint_cmd                   │    │   │
│  │    TCP client → 10.0.2.2:8765 ─────────────┘    │   │
│  └────────────────────────────────────────────┘    │   │
└────────────────────────────────────────────────────────┘
```

## Network Topology

| Endpoint | Address |
|---|---|
| Host Mac (from inside VM) | `10.0.2.2` (QEMU NAT gateway) |
| Swift TCP server | `0.0.0.0:8765` |
| Python bridge connects TO | `10.0.2.2:8765` |

**Swift never initiates a connection into the VM.**
The Python bridge in the VM connects outward to the host.

## VM Disk Image

The disk image (`ros2_ubuntu2204.img`) is **not** in the repository.

Build it once:
```bash
cd ProjectAmbrosia/Scripts
chmod +x build_vm_image.sh
./build_vm_image.sh
```

Then in Xcode:
1. Drag `ros2_ubuntu2204.img` into the Resources group
2. Ensure it appears in **Build Phases → Copy Bundle Resources**

## VM Setup (inside the VM after OS install)

```bash
# 1. Install ROS 2 Humble
sudo apt update && sudo apt install -y ros-humble-ros-base python3-colcon-common-extensions

# 2. Copy bridge script
scp ros2_swift_bridge.py ubuntu@<vm_ip>:~/

# 3. Create systemd service
sudo tee /etc/systemd/system/ros2-swift-bridge.service <<'EOF'
[Unit]
Description=ROS 2 Swift Bridge
After=network.target

[Service]
User=ubuntu
ExecStart=/bin/bash -c "source /opt/ros/humble/setup.bash && python3 /home/ubuntu/ros2_swift_bridge.py"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable ros2-swift-bridge
sudo systemctl start ros2-swift-bridge
```

## Graceful Degradation

If the disk image is absent at launch:
- `VMManager` transitions to `.error("Disk image not found…")` 
- `ROSBridge` stays in `.listening` state
- All other app features (URDF loading, manual joint control, simulation) work normally
