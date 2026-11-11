#!/usr/bin/env python3
"""Exercise the board wrapper using the established chip JTAG regression."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
NPU = HERE.parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, default=NPU / 'build/ego1-sim')
a = p.parse_args()
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
subprocess.run([sys.executable, str(NPU / 'scripts/gen_sources.py')], check=True)
files = [Path(s) for s in (NPU / 'build/sources.f').read_text().splitlines()]
files += [HERE / 'ego1_soc_top.sv', HERE / 'sim_clock_primitives.sv']
# Reuse the exact established pin-level test: no internal forcing or host access.
s = (NPU / 'tb/tb_chip_jtag.sv').read_text()
s = s.replace('module tb_chip_jtag;', 'module tb_ego1;')
s = s.replace('always #10 clk', 'always #5 clk')
start = s.index('  mynpu_asic_top dut (')
end = s.index('  `include "db_jtag_tasks.svh"', start)
s = s[:start] + '''  wire [7:0] leds;
  assign halted = leds[3];
  assign irq = leds[2];
  ego1_soc_top dut (
    .fpga_clk_i(clk), .rst_ni(rst_n), .tck_i(tck), .tms_i(tms),
    .td_i(tdi), .td_o(tdo), .led_o(leds)
  );
''' + s[end:]
s = s.replace('    repeat (8) tick', '    wait (dut.sys_rst_ni);\n    repeat (8) tick')
s = s.replace('CHIP JTAG PASS', 'EGO1 JTAG PASS')
s = s.replace('    $display("EGO1 JTAG PASS', """    eq({30'b0, leds[6:5]}, 3, "done/pass LEDs");
    rst_n = 0;
    #1;
    eq({31'b0, leds[0]}, 0, "MMCM reset drops lock");
    eq({31'b0, dut.sys_rst_ni}, 0, "asynchronous reset assertion");
    #100;
    rst_n = 1;
    wait (dut.sys_rst_ni);
    repeat (8) tick(1, 0, discard);
    tick(0, 0, discard);
    select_ir(1);
    scan_dr(32, 0, scan);
    eq(scan[31:0], 1, "TAP after board reset");
    $display("EGO1 JTAG PASS""")
# Check the simulation model and wrapper generate 50 MHz from the board clock.
s = s.replace('  int checks = 0;', """  time previous_edge = 0;
  always @(posedge dut.clk_sys) begin
    if (dut.sys_rst_ni && previous_edge != 0 && $time-previous_edge != 20)
      $fatal(1, "Board system clock is not 50 MHz");
    if (dut.sys_rst_ni) previous_edge = $time;
    else previous_edge = 0;
  end
  int checks = 0;""")
(out / 'tb_ego1.sv').write_text(s)
files.append(out / 'tb_ego1.sv')
for name in ['sram0.hex', 'gold0_5.hex']:
    shutil.copy2(NPU / 'mnist/artifacts' / name, out / name)
config = json.loads((NPU / 'build_config.json').read_text())
keys = {'rf_bank_words': 'NPU_RF_BANK_WORDS', 'matrix_queue_depth': 'NPU_MATRIX_QUEUE_DEPTH',
        'vector_queue_depth': 'NPU_VECTOR_QUEUE_DEPTH', 'cnn_queue_depth': 'NPU_CNN_QUEUE_DEPTH',
        'stream_fifo_depth': 'NPU_STREAM_FIFO_DEPTH'}
defines = ['+define+NPU_FPGA_TEST', '+define+NPU_CHIP_RF_BANK_WORDS=' + str(config['rf_bank_words'])]
defines += [f'+define+{v}={config[k]}' for k, v in keys.items()]
cmd = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps', '-top', 'tb_ego1',
       '+incdir+' + str(NPU / 'tb'), '+incdir+' + str(NPU.parent / 'external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include'),
       *defines, *map(str, files), '-o', str(out / 'simv')]
with (out / 'compile.log').open('w') as log:
    subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True)
with (out / 'sim.log').open('w') as log:
    subprocess.run([str(out / 'simv')], cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True)
text = (out / 'sim.log').read_text()
match = re.search(r'EGO1 JTAG PASS checks=(\d+)', text)
if not match: raise RuntimeError('Missing test pass marker')
inputs = files + [NPU / 'tb/tb_chip_jtag.sv', NPU / 'tb/db_jtag_tasks.svh',
                  out / 'sram0.hex', out / 'gold0_5.hex', Path(__file__).resolve(),
                  *sorted((NPU.parent / 'external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include').glob('*.sv*'))]
result = {'passed': True, 'checks': int(match[1]), 'config': config,
          'scope': 'Board wrapper functional simulation; MMCM/BUFG stand-ins, not Vivado or physical board validation',
          'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}}
(out / 'validation.json').write_text(json.dumps(result, indent=2) + '\n')
print(match[0])
