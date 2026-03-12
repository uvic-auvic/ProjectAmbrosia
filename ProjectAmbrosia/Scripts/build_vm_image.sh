#!/usr/bin/env bash
# build_vm_image.sh
# One-time script that builds the Ubuntu 22.04 ARM64 disk image
# with ROS 2 Humble and the Swift bridge pre-installed.
#
# Requirements:
#   brew install qemu wget
#
# Output:
#   ros2_ubuntu2204.img  (in the current directory)
#   Add this file to the Xcode project under Resources and mark it in
#   Build Phases → Copy Bundle Resources.

set -euo pipefail

IMAGE_NAME="ros2_ubuntu2204.img"
IMAGE_SIZE="20G"
UBUNTU_ISO_URL="https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-live-server-arm64.iso"
UBUNTU_ISO="ubuntu-22.04.5-live-server-arm64.iso"

echo "==> MacRoboSim VM Image Builder"
echo "==> Output: ${IMAGE_NAME}"
echo ""

# Check prerequisites
for cmd in qemu-img qemu-system-aarch64 wget; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Install with: brew install qemu wget"
    exit 1
  fi
done

# Download Ubuntu ISO if needed
if [ ! -f "$UBUNTU_ISO" ]; then
  echo "==> Downloading Ubuntu 22.04 ARM64 Server ISO…"
  wget -c "$UBUNTU_ISO_URL" -O "$UBUNTU_ISO"
else
  echo "==> Ubuntu ISO already present, skipping download."
fi

# Create blank disk image
if [ ! -f "$IMAGE_NAME" ]; then
  echo "==> Creating ${IMAGE_SIZE} disk image…"
  qemu-img create -f raw "$IMAGE_NAME" "$IMAGE_SIZE"
else
  echo "==> Disk image already exists: ${IMAGE_NAME}"
fi

# EFI firmware — use the copy bundled with Homebrew QEMU (no download needed)
OVMF_CODE="OVMF_CODE.fd"
OVMF_VARS="OVMF_VARS.fd"
if [ ! -f "$OVMF_CODE" ]; then
  echo "==> Copying EFI firmware from Homebrew QEMU…"
  BREW_FIRMWARE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
  if [ ! -f "$BREW_FIRMWARE" ]; then
    echo "ERROR: EFI firmware not found at $BREW_FIRMWARE"
    echo "Try: brew install qemu"
    exit 1
  fi
  cp "$BREW_FIRMWARE" "$OVMF_CODE"
  dd if=/dev/zero of="$OVMF_VARS" bs=1m count=64 2>/dev/null
fi

echo ""
echo "==> Starting QEMU for interactive Ubuntu installation…"
echo "==> After installation:"
echo "    1. Install ROS 2 Humble: https://docs.ros.org/en/humble/Installation/Ubuntu-Install-Debians.html"
echo "    2. Copy ros2_swift_bridge.py to the VM"
echo "    3. Add to /etc/rc.local or a systemd service:"
echo "       source /opt/ros/humble/setup.bash && python3 /home/ubuntu/ros2_swift_bridge.py &"
echo "    4. Shut down the VM cleanly (sudo poweroff)"
echo ""

qemu-system-aarch64 \
  -M virt \
  -accel hvf \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive if=pflash,format=raw,file="$OVMF_CODE",readonly=on \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$IMAGE_NAME",format=raw,if=virtio \
  -drive file="$UBUNTU_ISO",format=raw,if=virtio,media=cdrom,readonly=on \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
  -nographic \
  -serial mon:stdio

echo ""
echo "==> Image build complete: ${IMAGE_NAME}"
echo "==> Add it to Xcode: drag into Resources group, enable 'Copy Bundle Resources'."
