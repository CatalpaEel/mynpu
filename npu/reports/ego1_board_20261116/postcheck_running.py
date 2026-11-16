import sys,json,re,time
from pathlib import Path
run=Path(__file__).resolve().parent
result=json.loads((run/'continuous-running-physical-100khz/result.json').read_text())
assert result['passed'] and result['frames_checked']==2000
npu=run.parents[1]
sys.path.insert(0,str(npu/'fpga/ego1'))
from jtag_validation import OpenOCD,PASS,RESULT
meta=(npu/'build/ego1-sba-board-kit-53655b5-20261115/assets/test_meta.svh').read_text()
cnn=int(re.search(r'STREAM_TASKS=(\d+)',meta)[1])
matrix=int(re.search(r'NPU_EXPECTED_MATRIX_JOBS (\d+)',meta)[1])
io=OpenOCD();io.running_access_active=True
report={'passed':False,'no_cpu_halt_or_reset':True,'last_batch_frames':1000}
try:
 io.assert_running()
 report['dmstatus']=hex(int(io.command('riscv dmi_read 0x11'),0))
 report['result']=hex(io.read(RESULT)[0])
 report['matrix_completed']=io.read(0x40000128)[0]
 report['cnn_completed']=io.read(0x4000065c)[0]
 report['expected_matrix_completed']=matrix*1000
 report['expected_cnn_completed']=cnn*1000
 assert report['result']==hex(PASS)
 assert report['matrix_completed']==matrix*1000
 assert report['cnn_completed']==cnn*1000
 for _ in range(100):
  sbcs=int(io.command('riscv dmi_read 0x38'),0)
  if not sbcs&(1<<21):break
  time.sleep(0.001)
 assert not sbcs&((1<<22)|(1<<21)|0x7000)
 report['sbcs']=hex(sbcs)
 io.assert_running();report['passed']=True
 print(json.dumps(report,indent=2),flush=True)
finally:
 io.close();(run/'postcheck-running.json').write_text(json.dumps(report,indent=2)+'\n')
