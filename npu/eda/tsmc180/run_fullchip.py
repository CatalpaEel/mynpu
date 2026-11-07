"""Execute restartable frozen stages of the native-pad full-chip reference flow."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--run", type=Path, required=True)
p.add_argument("--stages", nargs="+", default=["01", "02", "03", "04", "04b", "05", "06", "07"])
p.add_argument("--macro-plan", choices=["left", "diagonal"], default="left")
p.add_argument("--tag", default="first")
p.add_argument("--compact-core", action="store_true")
p.add_argument("--opt-max-density", type=float, default=0.99)
p.add_argument(
    "--skip-route-setup-fix",
    action="store_true",
    help="Routability trial only; still report final setup violations",
)
p.add_argument(
    "--skip-route-hold-fix",
    action="store_true",
    help="Routability trial only; still report final hold violations",
)
p.add_argument(
    "--stage-script",
    type=Path,
    help="Explicit single-stage Tcl override, frozen into its execution record",
)
a = p.parse_args()
assert a.stage_script is None or len(a.stages) == 1
assert 0 < a.opt_max_density < 1
r = a.run.resolve()
sha = lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
assert a.tag.replace("_", "").replace("-", "").isalnum()
assert "FLOW_STAGE_OK_CHIP_SYNTHESIS" in (r / "mynpu/chip_synth/launcher.log").read_text()
stages = {
    "01": ("pnr_01_floorplan_io.tcl", "FLOW_STAGE_OK_CHIP_IO_FLOORPLAN"),
    "02": ("pnr_02_powerplan.tcl", "FLOW_STAGE_OK_CHIP_POWERPLAN"),
    "03": ("pnr_03_place.tcl", "FLOW_STAGE_OK_CHIP_TIE_PRECTS_COMMANDS_COMPLETED"),
    "03a": ("pnr_03a_reclaim.tcl", "FLOW_STAGE_OK_CHIP_RECLAIM_COMMANDS_COMPLETED"),
    "04": ("pnr_04_cts.tcl", "FLOW_STAGE_OK_CHIP_CTS_COMMANDS_COMPLETED"),
    "04b": ("pnr_04b_holdfix.tcl", "FLOW_STAGE_OK_CHIP_CTS_HOLDFIX_COMMANDS_COMPLETED"),
    "04c": ("pnr_04c_legalize.tcl", "FLOW_STAGE_OK_CHIP_CTS_LEGALIZED_COMMANDS_COMPLETED"),
    "05": ("pnr_05_route.tcl", "FLOW_STAGE_OK_CHIP_ROUTE_COMMANDS_COMPLETED"),
    "06": ("pnr_06_finish.tcl", "FLOW_STAGE_OK_CHIP_FINISH_COMMANDS_COMPLETED"),
    "07": ("pnr_07_export.tcl", "FLOW_STAGE_OK_CHIP_FINAL_EXPORT"),
}
(r / "logs").mkdir(exist_ok=True)
for stage in a.stages:
    script, marker = stages[stage]
    log = r / "logs" / f"{stage}-{a.tag}.log"
    result = log.with_suffix(".json")
    assert not log.exists() and not result.exists(), log
    snap = r / "scripts" / f"{stage}-{a.tag}-executed.tcl"
    source_script = a.stage_script.resolve() if a.stage_script else r / "scripts" / script
    shutil.copy2(source_script, snap)
    tracked = [
        *list((r / "scripts").glob("*.tcl")),
        *list((r / "scripts").glob("*.py")),
        r / "mynpu/chip_synth/mynpu_asic_top.postsyn.v",
    ]
    hashes = {str(f): sha(f) for f in tracked}
    cmd = ["innovus", "-no_gui", "-batch", "-files", str(r / "scripts/batch_stage.tcl")]
    env = {
        **os.environ,
        "FLOW_STAGE_SCRIPT": str(snap),
        "CHIP_MACRO_PLAN": a.macro_plan,
        "CHIP_COMPACT_CORE": "1" if a.compact_core else "0",
        "FLOW_FIX_ROUTE_SETUP": "0" if a.skip_route_setup_fix else "1",
        "FLOW_FIX_ROUTE_HOLD": "0" if a.skip_route_hold_fix else "1",
        "FLOW_SETUP_MARGIN_NS": "0.30",
        "FLOW_OPT_MAX_DENSITY": str(a.opt_max_density),
    }
    with log.open("w") as f:
        rc = subprocess.run(cmd, cwd=r, env=env, stdout=f, stderr=subprocess.STDOUT).returncode
    changed = [name for name, h in hashes.items() if sha(name) != h]
    completed = rc == 0 and marker in log.read_text() and not changed
    result.write_text(
        json.dumps(
            {
                "command_completed": completed,
                "stage": stage,
                "macro_plan": a.macro_plan,
                "returncode": rc,
                "opt_max_density": a.opt_max_density,
                "route_setup_fix": not a.skip_route_setup_fix,
                "route_hold_fix": not a.skip_route_hold_fix,
                "command": cmd,
                "script_sha256": sha(snap),
                "source_script": str(source_script),
                "sha256": hashes,
                "log_sha256": sha(log),
                "changed_during_run": changed,
                "scope": "Command completion does not imply DRC/connectivity/timing closure.",
            },
            indent=2,
        )
        + "\n"
    )
    print(stage, "COMPLETED" if completed else "FAILED", flush=True)
    if not completed:
        raise SystemExit(1)
