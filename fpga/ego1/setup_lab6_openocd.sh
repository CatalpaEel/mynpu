#!/usr/bin/env bash
set -euo pipefail
# Lab6 section 9.2: build the RISC-V OpenOCD fork, retaining distro fallback.
# Run: wsl -d Ubuntu -u root -- bash <repo>/fpga/ego1/setup_lab6_openocd.sh
if [[ "$(id -u)" -ne 0 ]]; then echo 'Run as root (or sudo bash this script).' >&2; exit 1; fi
revision=10b7a647da03cb64fd25db76261712c388ad6468
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git make gcc g++ autoconf automake \
  libtool texinfo pkg-config libftdi1-dev libusb-1.0-0-dev libjim-dev \
  gdb-multiarch usbutils python3
source_dir=/opt/mynpu/riscv-openocd-src
mkdir -p /opt/mynpu
if [[ ! -d "$source_dir/.git" ]]; then
  git clone https://github.com/riscv/riscv-openocd.git "$source_dir"
fi
git -C "$source_dir" fetch origin "$revision"
git -C "$source_dir" checkout --detach "$revision"
git -C "$source_dir" submodule update --init --recursive
cd "$source_dir"
./bootstrap
./configure --enable-ftdi --disable-werror --prefix=/usr/local
make -j2
make install
/usr/local/bin/openocd --version
printf 'Lab6 OpenOCD installed from revision %s\n' "$revision"
