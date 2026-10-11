#!/usr/bin/env bash
set -euo pipefail

# gdb-multiarch is the Ubuntu package equivalent of riscv-none-elf-gdb for
# this connection. It accepts the RV32 target and does not need a local ELF
# unless symbols/disassembly are desired.
exec gdb-multiarch -ex 'set architecture riscv:rv32' "$@"
