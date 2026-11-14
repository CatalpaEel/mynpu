"""Same JTAG-only continuous CPU-in-loop test on FPGA and ASIC storage backends."""
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
sys.path.insert(0, str(NPU / "scripts"))
from sim_sources import macro_wrapper
sys.path.insert(0, str(HERE))
from jtag_validation import validate_assets


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--memory", choices=("fpga", "asic"), required=True)
    p.add_argument("--macro-model", type=Path)
    p.add_argument("--assets", type=Path, required=True)
    p.add_argument("--frames", type=int, default=20)
    p.add_argument("--boots", type=int, default=2)
    p.add_argument("--seed", type=int, default=20261113)
    p.add_argument("--clock-mhz", type=int, choices=(10,25,50), default=50)
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    if a.frames<2 or a.boots<1:
        p.error("frames >= 2 and boots >= 1 required")
    if a.memory=="asic" and (not a.macro_model or not a.macro_model.is_file()):
        p.error("ASIC requires a private --macro-model; it is never committed")
    validate_assets(a.assets)
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    subprocess.run([sys.executable,str(NPU / "scripts/gen_sources.py")],check=True)
    files = [Path(line) for line in (NPU / "build/sources.f").read_text().splitlines()]
    if a.memory=="asic":
        wrapper=out / "npu_soc_macro.sv"
        wrapper.write_text(macro_wrapper((NPU / "rtl/top/npu_soc.sv").read_text()))
        files=[f for f in files if f.name not in ("npu_soc.sv","sram_ff.sv")]
        files += [wrapper,a.macro_model.resolve()]
    else:
        files += [HERE / "ego1_soc_top.sv",HERE / "sim_clock_primitives.sv"]
    files += [HERE / "tb_validation.sv"]
    for f in a.assets.iterdir():
        if f.is_file() and (f.name.endswith(".hex") or f.name=="test_meta.svh"):
            shutil.copy2(f,out / f.name)
    config=json.loads((NPU / "build_config.json").read_text())
    names={"rf_bank_words":"NPU_RF_BANK_WORDS","matrix_queue_depth":"NPU_MATRIX_QUEUE_DEPTH",
           "vector_queue_depth":"NPU_VECTOR_QUEUE_DEPTH","cnn_queue_depth":"NPU_CNN_QUEUE_DEPTH",
           "stream_fifo_depth":"NPU_STREAM_FIFO_DEPTH"}
    defines=[f"+define+{v}={config[k]}" for k,v in names.items()]
    defines += ["+define+VALIDATION_ASIC"] if a.memory=="asic" else ["+define+NPU_FPGA_TEST"]
    inputs=files+[NPU / "tb/db_jtag_tasks.svh",a.assets / "manifest.json"]
    before={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
    cmd=["vcs","-full64","-sverilog","-timescale=1ns/1ps","-top","tb_validation",
         f"-pvalue+tb_validation.FRAMES={a.frames}",f"-pvalue+tb_validation.BOOTS={a.boots}",
         f"-pvalue+tb_validation.BOARD_MHZ={a.clock_mhz}",
         "+incdir+"+str(NPU / "tb"),"+incdir+"+str(out),
         "+incdir+"+str(NPU.parent / "external/lab3-ST/SoC_cv32e40p/cpu_cv32e40p/include"),
         *defines,*map(str,files),"-o",str(out / "simv")]
    result={"passed":False,"memory":a.memory,"frames_per_boot":a.frames,"boots":a.boots,
            "clock_hz":a.clock_mhz*1000000,
            "seed":a.seed,"source_sha256":before,
            "scope":"JTAG-only CPU-in-loop functional simulation; not physical board or timing signoff",
            "macro_timing_checks_disabled":a.memory=="asic"}
    try:
        with (out / "compile.log").open("w") as log:
            subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
        run=[str(out / "simv"),f"+ntb_random_seed={a.seed}"]
        if a.memory=="asic":run += ["+notimingcheck","+no_notifier"]
        with (out / "sim.log").open("w") as log:
            subprocess.run(run,cwd=out,stdout=log,stderr=subprocess.STDOUT,check=True)
        text=(out / "sim.log").read_text()
        match=re.search(r"EGO1 STRESS PASS frames=(\d+) boots=(\d+) checks=(\d+)",text)
        if not match or "Fatal:" in text or int(match[1])!=a.frames*a.boots:
            raise RuntimeError("Missing/invalid success marker")
        result.update(frames_checked=int(match[1]),checks=int(match[3]))
        result["changed_during_run"]=[str(f) for f in inputs if hashlib.sha256(f.read_bytes()).hexdigest()!=before[str(f)]]
        if result["changed_during_run"]:raise RuntimeError("Inputs changed during simulation")
        result["passed"]=True
        print(match[0])
    except Exception as exc:
        result["error"]=f"{type(exc).__name__}: {exc}"
        raise
    finally:
        (out / "result.json").write_text(json.dumps(result,indent=2)+"\n")


if __name__=="__main__":main()
