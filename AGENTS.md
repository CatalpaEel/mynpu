# Project requirements

- The primary deliverable is the complete 0.18um ASIC SoC. FPGA validates the
  same architecture, replacing the two RA1SHD_2048x32M8 macros with equivalent
  synchronous single-port BRAM wrappers. Do not optimize only the FPGA path.
- Do not edit `third_party/lab3`. Keep experimental architectures on their branch.
- Shared-bank design principle: data needed in the same cycle should be in
  different physical banks or already buffered in registers. Two logical
  request ports do not create a second physical port on either macro.
- The user explicitly rejected duplicating/mirroring weights across banks.
  Keep a single packed weight copy. Use placement, prefetch, small caches and
  elastic bank arbitration to handle conflicts. Keep cache/lane sizes configurable.
- Preserve JTAG -> DMI -> Debug Module SBA firmware/input/result access.
  Do not introduce UART/SPI loading. CPU fetch/data accesses must wait correctly
  when contending with the NPU; never return a busy marker as an instruction.
- External FPGA debug follows the user's Lab6: board USB-JTAG configures the
  FPGA; a separate FT232H/channel0/J5 chain connects OpenOCD/GDB to the RISC-V
  DM. Keep private/shared 4-lane projects and matching host cold-load assets.
  Report real external-probe board tests separately from USB/VIO or RTL tests.
- Verify repeated inference, independent integer golden and recorded PyTorch
  outputs, both ASIC/FPGA backends and CPU-in-loop whole-SoC behavior.
- Real macro timing checks and PDK signoff are explicitly out of scope.
  Never publish the proprietary SRAM model. Do not call RTL functional results
  physical ASIC frequency, area, power, or signoff results.
