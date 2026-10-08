#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source /home/zzh/vivado/config/env_2025.2.sh
python3 "$root/scripts/gen_sources.py"
mkdir -p "$root/build/noc" "$root/reports/noc"
python3 - "$root" <<'PY'
import sys,json,hashlib
from pathlib import Path
r=Path(sys.argv[1]);files=[Path(p) for p in (r/'build/sources.f').read_text().splitlines()]
(r/'build/noc/synthesis_inputs.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
PY
cd "$root/build/noc"
vivado -mode batch -nojournal -log vivado.log -source "$root/scripts/build_noc.tcl"
cp synthesis_inputs.json "$root/reports/noc/synthesis_inputs.json"
