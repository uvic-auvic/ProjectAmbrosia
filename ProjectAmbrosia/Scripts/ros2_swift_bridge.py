#!/usr/bin/env python3
"""
ros2_swift_bridge.py
ROS 2 Python node that runs INSIDE the Ubuntu 22.04 VM.

Bridges ROS 2 topics ↔ connection to the Swift host app.

Connection priority:
  1. VirtioSocket (AF_VSOCK, CID=2, port=8765) — direct host channel,
     works with Virtualization.framework, bypasses macOS firewall entirely.
     Requires: sudo modprobe vmw_vsock_virtio_transport
  2. TCP to detected gateway (QEMU NAT = 10.0.2.2, or vf NAT gateway).

Usage (inside the VM):
    source /opt/ros/humble/setup.bash
    python3 ros2_swift_bridge.py
"""

import json
import socket
import threading
import time
import sys

try:
    import rclpy
    from rclpy.node import Node
    from sensor_msgs.msg import JointState
    from geometry_msgs.msg import Twist
    from std_msgs.msg import String
except ImportError:
    print("[bridge] ERROR: rclpy not found. Source ROS 2 before running.", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VSOCK_CID_HOST = 2   # Host's CID in virtio-vsock
BRIDGE_PORT    = 8765

def _try_vsock() -> "socket.socket | None":
    """Return a connected AF_VSOCK socket to the host, or None if unavailable."""
    if not hasattr(socket, "AF_VSOCK"):
        return None
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((VSOCK_CID_HOST, BRIDGE_PORT))
        s.settimeout(None)
        return s
    except OSError:
        return None

def _get_tcp_host() -> str:
    """Detect the host Mac IP — works for QEMU NAT and Virtualization.framework NAT."""
    import subprocess
    try:
        result = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True, text=True, timeout=3)
        parts = result.stdout.split()
        if "via" in parts:
            return parts[parts.index("via") + 1]
    except Exception:
        pass
    return "10.0.2.2"  # QEMU NAT fallback

def _try_tcp(host: str) -> "socket.socket | None":
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect((host, BRIDGE_PORT))
        s.settimeout(None)
        return s
    except OSError:
        return None

RECONNECT_DELAY = 3.0

# ---------------------------------------------------------------------------
# Bridge Node
# ---------------------------------------------------------------------------

class SwiftBridgeNode(Node):
    def __init__(self):
        super().__init__("swift_bridge")
        self._sock = None
        self._send_lock = threading.Lock()
        self._connected = False
        self._recv_buffer = b""

        # ROS 2 subscriptions
        self.joint_state_sub = self.create_subscription(
            JointState, "/joint_states", self._on_joint_states, 10)
        self.description_sub = self.create_subscription(
            String, "/robot_description", self._on_robot_description, 1)

        # ROS 2 publishers
        self.cmd_vel_pub = self.create_publisher(Twist, "/cmd_vel", 10)
        self.joint_cmd_pub = self.create_publisher(String, "/joint_cmd", 10)

        self._thread = threading.Thread(target=self._connection_loop, daemon=True)
        self._thread.start()
        self.get_logger().info("Swift bridge started.")

    # -----------------------------------------------------------------------
    # Connection loop
    # -----------------------------------------------------------------------

    def _connection_loop(self):
        while rclpy.ok():
            sock = None
            transport = "?"

            # 1. Try VirtioSocket (fastest, no firewall issues)
            sock = _try_vsock()
            if sock:
                transport = "vsock"
            else:
                # 2. Fall back to TCP
                host = _get_tcp_host()
                self.get_logger().info(f"vsock unavailable, trying TCP → {host}:{BRIDGE_PORT}")
                sock = _try_tcp(host)
                if sock:
                    transport = f"tcp:{host}"

            if sock:
                self._sock = sock
                self._connected = True
                self.get_logger().info(f"Connected to Swift host via {transport}.")
                try:
                    self._recv_loop(sock)
                except Exception as e:
                    self.get_logger().warn(f"Recv error: {e}")
                finally:
                    self._connected = False
                    try: sock.close()
                    except: pass
                    self._sock = None
            else:
                self.get_logger().warn(
                    f"Connection failed (vsock + TCP). Retrying in {RECONNECT_DELAY}s…\n"
                    "  If using Virtualization.framework VM, load vsock module:\n"
                    "    sudo modprobe vmw_vsock_virtio_transport")
            time.sleep(RECONNECT_DELAY)

    def _recv_loop(self, sock):
        while rclpy.ok():
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    self.get_logger().info("Connection closed by host.")
                    return
                self._recv_buffer += chunk
                while b"\n" in self._recv_buffer:
                    line, self._recv_buffer = self._recv_buffer.split(b"\n", 1)
                    self._handle_message(line)
            except Exception as e:
                self.get_logger().warn(f"Recv error: {e}")
                return

    def _handle_message(self, data: bytes):
        try:
            msg = json.loads(data)
        except json.JSONDecodeError:
            return
        t = msg.get("type")
        if t == "cmd_vel":
            twist = Twist()
            lin = msg.get("linear", {})
            ang = msg.get("angular", {})
            twist.linear.x = float(lin.get("x", 0))
            twist.linear.y = float(lin.get("y", 0))
            twist.linear.z = float(lin.get("z", 0))
            twist.angular.x = float(ang.get("x", 0))
            twist.angular.y = float(ang.get("y", 0))
            twist.angular.z = float(ang.get("z", 0))
            self.cmd_vel_pub.publish(twist)
        elif t == "joint_cmd":
            raw = json.dumps({"name": msg.get("name"), "position": msg.get("position")})
            self.joint_cmd_pub.publish(String(data=raw))
        elif t == "ping":
            self._send({"type": "pong"})

    # -----------------------------------------------------------------------
    # ROS 2 callbacks (called from ROS executor thread)
    # -----------------------------------------------------------------------

    def _on_joint_states(self, msg: JointState):
        payload = {
            "type": "joint_states",
            "joints": [
                {
                    "name": name,
                    "position": float(pos) if i < len(msg.position) else 0.0,
                    "velocity": float(vel) if i < len(msg.velocity) else 0.0,
                    "effort": float(eff) if i < len(msg.effort) else 0.0,
                }
                for i, (name, pos, vel, eff) in enumerate(
                    zip(
                        msg.name,
                        list(msg.position) + [0.0] * len(msg.name),
                        list(msg.velocity) + [0.0] * len(msg.name),
                        list(msg.effort) + [0.0] * len(msg.name),
                    )
                )
            ],
        }
        self._send(payload)

    def _on_robot_description(self, msg: String):
        self._send({"type": "robot_description", "urdf": msg.data})

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def _send(self, obj: dict):
        if not self._connected or self._sock is None:
            return
        try:
            data = json.dumps(obj).encode() + b"\n"
            with self._send_lock:
                self._sock.sendall(data)
        except Exception as e:
            self.get_logger().warn(f"Send error: {e}")
            self._connected = False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    rclpy.init()
    node = SwiftBridgeNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
