#!/usr/bin/env bash
set -euo pipefail
npu_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source /home/zzh/vivado/config/env_2025.2.sh
python3 "$npu_root/sw/gen_boot.py"
python3 "$npu_root/scripts/gen_sources.py"
cp "$npu_root/sw/boot.hex" "$npu_root/build/boot.hex"
cd "$npu_root/build"
python3 - "$npu_root" <<'PYCODE'
import sys,json,hashlib
from pathlib import Path
root=Path(sys.argv[1]);files=[Path(x) for x in (root/'build/sources.f').read_text().splitlines()]
manifest={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(root/'build/synthesis_inputs.json').write_text(json.dumps(manifest,indent=2))
PYCODE
vivado -mode batch -nojournal -log vivado_build.log -source "$npu_root/scripts/build_vivado.tcl"
cp synthesis_inputs.json "$npu_root/reports/synthesis_inputs.json"
