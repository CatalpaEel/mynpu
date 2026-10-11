#!/usr/bin/env bash
set -euo pipefail

# Lab 6 host-side setup. Run this inside the Ubuntu WSL distribution:
#   bash fpga/ego1/setup_wsl.sh
# The RISC-V cross compiler is not needed for attaching GDB to an existing
# FPGA image; gdb-multiarch understands the RV32 target used by this SoC.

if [[ "$(id -u)" -eq 0 ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openocd gdb-multiarch usbutils libusb-1.0-0
else
  if [[ ! -t 0 ]]; then
    echo "This command needs an interactive WSL terminal for the sudo password." >&2
    echo "Run it from Ubuntu WSL, or use: wsl -d Ubuntu -u root -- bash fpga/ego1/setup_wsl.sh" >&2
    exit 1
  fi
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openocd gdb-multiarch usbutils libusb-1.0-0
fi

echo
openocd --version | head -n 1
gdb-multiarch --version | head -n 1
echo "WSL tools are ready. Attach the FT232H with attach_ft232h.ps1 from Windows."
