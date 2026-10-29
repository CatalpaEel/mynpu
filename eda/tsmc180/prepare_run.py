#!/usr/bin/python3
"""Freeze current mynpu inputs and prepare a separate TSMC180 run directory."""
import argparse
import hashlib
import json
import shutil
import subprocess
from datetime import datetime
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    bundle = Path(__file__).resolve().parent
    project = bundle.parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--pdk', type=Path, default=Path('/home/almalinux/tsmc180'))
    parser.add_argument('--macro', type=Path)
    parser.add_argument('--mapped-torus-run',type=Path,help='Reuse unchanged PE gates from a completed matching full-chip run')
    parser.add_argument('--cache-words',type=int,choices=(16,32,64),default=32)
    parser.add_argument('--mapped-pe-run', type=Path,
                        help='Reuse a completed, source/library-matched standalone PE mapping for fast area')
    parser.add_argument('--bottom-routing-layer', choices=('METAL1','METAL2'), default='METAL2',
                        help='Course default METAL2; METAL1 enables additional legal signal-routing resources')
    parser.add_argument('--topology', choices=('layered','mesh','torus'),default='torus')
    args = parser.parse_args()
    run, pdk = args.out.resolve(), args.pdk.resolve()
    candidates = [project.parent / 'soc_cv32e40p_template_pnr-stu',
                  Path.home() / 'soc_cv32e40p_template_pnr-stu']
    macro = args.macro.resolve() if args.macro else next(
        (p / 'src/macro/RA1SHD_2048x32M8' for p in candidates
         if (p / 'src/macro/RA1SHD_2048x32M8/RA1SHD_2048x32M8.gds').is_file()), None)
    if run.exists():
        parser.error('Output already exists: ' + str(run))
    if not pdk.is_dir() or macro is None:
        parser.error('PDK or SRAM macro directory missing; set --pdk and --macro')
    for path in (run, pdk, macro):
        if any(c in str(path) for c in '{}\n\r'):
            parser.error('Paths containing braces or newlines are unsupported')
    macro_files = [macro / ('RA1SHD_2048x32M8' + suffix) for suffix in (
        '.v', '.gds', '.vclef', '_ant.lef', '.cdl', '_tt_1p8_25C_syn.lib')]
    std = pdk / 'tcb018gbwp7t_290a/TSMCHOME/digital'
    tech_files = [std / path for path in (
        'Front_End/timing_power_noise/NLDM/tcb018gbwp7t_270a/tcb018gbwp7ttc.lib',
        'Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef',
        'Back_End/lef/tcb018gbwp7t_270a/techfiles/captable/t018lo_1p6m_typical.captable',
        'Back_End/lef/tcb018gbwp7t_270a/techfiles/gds2.map')]
    for path in macro_files + tech_files:
        if not path.is_file():
            parser.error('Missing library input: ' + str(path))
    mapped_pe = None
    if args.mapped_pe_run:
        origin = args.mapped_pe_run.resolve()
        origin_manifest = json.loads((origin/'inputs/source_manifest.json').read_text())
        pe_name = 'cnn_npu_int8/rtl/cnn_npu_tile.sv'
        if origin_manifest['file_sha256'].get(pe_name) != digest(project/pe_name):
            parser.error('Mapped PE RTL differs from current PE source')
        if any(origin_manifest['library_sha256'].get(str(p)) != digest(p)
               for p in macro_files + tech_files):
            parser.error('Mapped PE library inputs differ')
        logs = list((origin/'mynpu').glob('tile*launcher.log'))
        tile_log = origin/'mynpu/tile_synth/launcher.log'
        if tile_log.is_file():
            logs.append(tile_log)
        if not any('PE_TILE_FAST_AREA_PASS\n' in p.read_text(errors='replace') and
                   'Normal exit.' in p.read_text(errors='replace') for p in logs):
            parser.error('Mapped PE run has no completed synthesis log')
        netlist = origin/'mynpu/tile_synth/tile.postsyn.v'
        if not netlist.is_file():
            parser.error('Mapped PE netlist missing')
        tile_script = origin/'scripts/synth_tile_area.tcl'
        if origin_manifest['script_sha256'].get(tile_script.name) != digest(tile_script):
            parser.error('Mapped PE synthesis script differs from its frozen manifest')
        mapped_pe = dict(origin_run=str(origin), netlist_sha256=digest(netlist),
                         source_sha256=digest(project/pe_name))
    mapped_torus=None
    if args.mapped_torus_run:
        from mapped_torus import extract
        mapped_torus=extract(args.mapped_torus_run.resolve(),project,macro_files+tech_files)
    filelist = project / 'sim/soc.f'
    files = {filelist, project / 'rtl/mynpu_sram_2048x32_asic.sv'}
    for line in filelist.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('+incdir+'):
            continue
        if line.startswith(('+', '-', '#', '//')):
            parser.error('Review unsupported filelist line: ' + line)
        files.add(project / line)
    for folder in ('rtl', 'cnn_npu_int8/rtl',
                   'third_party/lab3/cpu_cv32e40p/include',
                   'third_party/lab3/cpu_cv32e40p/rtl',
                   'third_party/lab3/soc/rtl'):
        files.update(p for p in (project / folder).rglob('*')
                     if p.is_file() and p.suffix in ('.sv', '.v', '.svh', '.vh'))
    for path in files:
        if not path.is_file():
            parser.error('Missing RTL input: ' + str(path))
    run.mkdir(parents=True)
    shutil.copytree(str(bundle / 'scripts'), str(run / 'scripts'),
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copy2(str(bundle/'run_stage.sh'),str(run/'scripts/frozen_run_stage.sh'))
    frozen_flow=(bundle/'run_flow.py').read_text().replace(
        'ROOT=Path(__file__).resolve().parents[2]','ROOT=Path('+repr(str(project))+')')
    (run/'scripts/frozen_run_flow.py').write_text(frozen_flow)
    topology={'full':0,'layered':1,'mesh':2,'torus':3}[args.topology]
    shell=run/'scripts/mynpu_asic_top.sv'
    shell.write_text(shell.read_text().replace('GRID_TOPOLOGY = 2','GRID_TOPOLOGY = '+str(topology)).replace('.NPU_GRID_CACHE_WORDS(16)','.NPU_GRID_CACHE_WORDS('+str(args.cache_words)+')'))
    if args.bottom_routing_layer != 'METAL2':
        for script in (run/'scripts').glob('*.tcl'):
            script.write_text(script.read_text().replace('-bottomRoutingLayer METAL2',
                              '-bottomRoutingLayer '+args.bottom_routing_layer))
    if mapped_torus:
        (run/'inputs').mkdir(exist_ok=True)
        (run/'inputs/mapped_torus_pe.v').write_text(mapped_torus.pop('leaf'))
        (run/'inputs/mapped_torus_wrapper.sv').write_text(mapped_torus.pop('wrapper'))
    (run / 'setup').mkdir()
    if mapped_pe:
        (run/'inputs').mkdir()
        shutil.copy2(str(netlist),str(run/'inputs/mapped_pe.v'))
    shutil.copy2(str(bundle / 'reference/native_io_m4_geometry.json'),
                 str(run / 'setup/native_io_m4_geometry.json'))
    (run / 'scripts/flow_paths.tcl').write_text(
        'set pdk [file normalize {' + str(pdk) + '}]\n' +
        'set macro [file normalize {' + str(macro) + '}]\n')
    audit = run / 'scripts/audit_io.py'
    audit.write_text(audit.read_text().replace('/home/almalinux/tsmc180', str(pdk)))
    hashes = {}
    for path in sorted(files):
        relative = path.relative_to(project)
        dest = run / 'inputs/mynpu' / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(path), str(dest))
        hashes[str(relative)] = digest(dest)
    manifest = {
        'created_utc': datetime.utcnow().isoformat() + 'Z',
        'source_project': str(project),
        'git_head': subprocess.check_output(
            ['git', '-C', str(project), 'rev-parse', 'HEAD']).decode().strip(),
        'git_status': subprocess.check_output(
            ['git', '-C', str(project), 'status', '--short']).decode(),
        'configuration': dict(NPU_LANES=4, CPU_SRAM_BYTES=8192,
                              NPU_SRAM_BYTES=8192, USE_ASIC_SRAM=1, USE_FPGA_BRAM=0,
                              DUAL_BANK_SHARED=1, NPU_MMIO_GRID=1, JTAG_BOOT_CONTROL=1,
                              NPU_GRID_CACHE_WORDS=args.cache_words, COMPACT_HOST_BUS=1,NPU_GRID_TOPOLOGY=topology),
        'pdk_root': str(pdk), 'macro_root': str(macro),
        'physical_configuration': dict(bottom_routing_layer=args.bottom_routing_layer,
                                       top_routing_layer='METAL6'),
        'file_sha256': hashes,
        'library_sha256': {str(p): digest(p) for p in macro_files + tech_files},
        'script_sha256': {p.name: digest(p) for p in (run / 'scripts').iterdir() if p.is_file()},
    }
    if mapped_pe:
        manifest['mapped_pe'] = mapped_pe
    if mapped_torus:manifest['mapped_torus_pe']=mapped_torus
    (run / 'inputs/source_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for folder in ('mynpu/synth', 'mynpu/chip_synth', 'mynpu/tile_synth', 'mynpu/torus_pe_synth', 'mynpu/pnr', 'validation', 'gui'):
        (run / folder).mkdir(parents=True)
    print(run)
    print('Frozen RTL inputs: {}'.format(len(hashes)))


if __name__ == '__main__':
    main()
