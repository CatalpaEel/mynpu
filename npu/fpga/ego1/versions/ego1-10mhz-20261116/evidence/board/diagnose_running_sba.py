import sys,json,time,struct
from pathlib import Path
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'fpga/ego1'))
from jtag_validation import OpenOCD,RESULT,PASS
out=Path(__file__).with_name('running-sba-diagnosis.json')
assert not out.exists()
io=OpenOCD();io.running_access_active=True
report={'passed':False,'no_cpu_halt_or_reset':True,'openocd_version':io.command('version')}
def dmi_read(a):return int(io.command(f'riscv dmi_read {a:#x}'),0)
def dmi_write(a,d):io.command(f'riscv dmi_write {a:#x} {d:#x}')
def wait_sba():
 for _ in range(100):
  s=dmi_read(0x38)
  if s&0x7000 or s&(1<<22):raise RuntimeError(f'SBA error {s:#x}')
  if not s&(1<<21):return s
  time.sleep(0.001)
 raise TimeoutError('SBA busy')
def raw_read(a):
 wait_sba();dmi_write(0x38,0x140000);dmi_write(0x39,a);wait_sba();return dmi_read(0x3c)
try:
 io.assert_running()
 report['initial_dmstatus']=hex(dmi_read(0x11));report['initial_sbcs']=hex(dmi_read(0x38))
 report['initial_virt2phys_mode']=io.command('riscv virt2phys_mode')
 report['raw_result']=hex(raw_read(RESULT))
 words=[raw_read(0x80001400+i*4) for i in range(3)]
 report['raw_logits']=list(struct.pack('<3I',*words)[:10])
 gold=root/'build/ego1-sba-board-kit-53655b5-20261115/assets/gold0_5.hex'
 report['expected_logits']=[int(x,16) for x in gold.read_text().split()]
 assert report['raw_logits']==report['expected_logits']
 assert report['raw_result']==hex(PASS)
 report['ab_tests']=[]
 for mode in ['sw','off','sw','off']:
  io.command('riscv virt2phys_mode '+mode);io.assert_running()
  item={'mode':mode,'dmstatus_before':hex(dmi_read(0x11))}
  try:item['value']=hex(io.read(RESULT)[0]);item['read_passed']=True
  except RuntimeError as e:item['read_passed']=False;item['error']=str(e)
  item['dmstatus_after']=hex(dmi_read(0x11));io.assert_running();report['ab_tests'].append(item)
 assert [x['read_passed'] for x in report['ab_tests']]==[False,True,False,True]
 assert all(x.get('value')==hex(PASS) for x in report['ab_tests'] if x['read_passed'])
 report['final_dmstatus']=hex(dmi_read(0x11));report['passed']=True
 print(json.dumps(report,indent=2),flush=True)
finally:
 io.close();out.write_text(json.dumps(report,indent=2)+'\n')
