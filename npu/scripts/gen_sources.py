from pathlib import Path
root=Path(__file__).resolve().parents[1]
external=root.parent/'external/lab3-ST/SoC_cv32e40p'
cpu=external/'cpu_cv32e40p'
files=[cpu/'include'/p for p in ['cv32e40p_pkg.sv','cv32e40p_apu_core_pkg.sv','cv32e40p_fpu_pkg.sv']]
files += [external/'soc/rtl/mem/sram_ff.sv']
files += sorted(p for p in (cpu/'rtl').glob('*.sv') if p.name!='cv32e40p_fp_wrapper.sv')
files += sorted((root/'rtl').glob('*.sv'))
(root/'build/sources.f').write_text('\n'.join(map(str,files))+'\n')
(root/'build/sources.tcl').write_text('set npu_sources {\n'+''.join('  {'+str(p)+'}\n' for p in files)+'}\n')
print(len(files),'SystemVerilog sources')
(root/'build/asic_sources.f').write_text('\n'.join(str(p) for p in files if p.name not in ['sram_ff.sv','npu_soc.sv','npu_noc_soc.sv'])+'\n')
