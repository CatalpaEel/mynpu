"""Lab6 OpenOCD/SBA loader and repeated CPU-in-loop MNIST checks (stdlib only)."""
from __future__ import annotations
import argparse,hashlib,json,socket,struct,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MAIL=0x80001fc0

class OpenOcd:
    def __init__(self,host='127.0.0.1',port=6666,timeout=120):
        self.sock=socket.create_connection((host,port),timeout);self.pending=b''
    def close(self):self.sock.close()
    def command(self,script):
        wrapped='if {[catch {'+script+'} __mynpu_value]} {format "ERROR:%s" $__mynpu_value} else {format "OK:%s" $__mynpu_value}'
        self.sock.sendall(wrapped.encode()+b'\x1a')
        while b'\x1a' not in self.pending:
            part=self.sock.recv(65536)
            if not part:raise ConnectionError('OpenOCD disconnected; reconnect and reload after reset')
            self.pending+=part
            if len(self.pending)>8*1024*1024:raise RuntimeError('Oversize OpenOCD response')
        frame,self.pending=self.pending.split(b'\x1a',1)
        text=frame.decode(errors='replace')
        if not text.startswith('OK:'):raise RuntimeError('OpenOCD command failed: '+text)
        return text[3:].strip()
    def read(self,address,count=1):
        values=[int(v,0)for v in self.command('mynpu_read_words %d %d'%(address,count)).split()]
        if len(values)!=count:raise RuntimeError('Truncated SBA read')
        return values
    def write(self,address,words):
        self.command('mynpu_write_words %d {%s}'%(address,' '.join('0x%08x'%(v&0xffffffff)for v in words)))

def words_from_hex(path):
    return [int(v,16) for v in path.read_text().split()]

def read_bundle(layout):
    folder=ROOT/'generated/jtag'/layout
    manifest=json.loads((folder/'manifest.json').read_text())
    if manifest['layout']!=layout or manifest['protocol_version']!=1:raise ValueError('Unsupported bundle')
    if len(manifest['loads'])!=2:raise ValueError('Expected CPU and model images')
    for item in manifest['loads']:
        name=item['file']
        if name not in ('cpu.hex','model.hex'):raise ValueError('Unexpected bundle file')
        path=folder/name
        if hashlib.sha256(path.read_bytes()).hexdigest()!=manifest['sha256'][name]:raise ValueError('Bundle hash mismatch: '+name)
        values=words_from_hex(path)
        if len(values)*4!=item['bytes'] or any(v<0 or v>0xffffffff for v in values):raise ValueError('Invalid load image')
        if name=='cpu.hex' and (item['address']!=0x80000000 or item['bytes']>2048):raise ValueError('CPU reservation exceeded')
        if name=='model.hex':
            expected=(0x70005000,9216)if layout=='shared'else(0x70004000,8192)
            if (item['address'],item['bytes'])!=expected:raise ValueError('Model load range does not match layout')
    return folder,manifest

def wait_mail(io,expected,timeout):
    deadline=time.monotonic()+timeout
    value=None
    while time.monotonic()<deadline:
        value=io.read(MAIL)[0]
        if value==0xdeadbeef:raise RuntimeError('CPU firmware error: 0x%08x'%io.read(MAIL+4)[0])
        if value==expected:return
        time.sleep(0.01)
    raise TimeoutError('Mailbox timeout: wanted 0x%08x, last %s'%(expected,hex(value)if value is not None else 'unread'))

def run(io,layout,runs,boots,timeout,chunk_words):
    folder,m=read_bundle(layout)
    vector_file=ROOT/'generated/jtag/vectors/mnist.json'
    vectors=json.loads(vector_file.read_text())
    if runs<1 or runs>65535 or boots<1 or chunk_words<1 or chunk_words>256:raise ValueError('Invalid runs/boots/chunk size')
    records=[]
    for boot in range(boots):
        io.command('mynpu_reset')
        target_id=io.read(m['boot_id'])[0]
        if target_id!=m['build_id']:raise RuntimeError('Wrong bitstream/layout/lanes: hardware 0x%08x, bundle 0x%08x'%(target_id,m['build_id']))
        if io.read(0x10038)[0]!=m['cache_words']:raise RuntimeError('Cache parameter differs from bundle')
        if io.read(m['boot_control'])[0]!=0:raise RuntimeError('CPU boot gate did not reset')
        for item in m['loads']:
            words=words_from_hex(folder/item['file'])
            print('Loading:',item['file'],item['bytes'],'bytes, boot',boot,flush=True)
            for start in range(0,len(words),chunk_words):
                batch=words[start:start+chunk_words];address=item['address']+start*4
                io.write(address,batch)
                if io.read(address,len(batch))!=batch:raise RuntimeError('Load readback mismatch at 0x%08x'%address)
            print('Readback verified:',item['file'],flush=True)
        io.write(MAIL,[0]*16)
        io.command('mynpu_run')
        wait_mail(io,0x5354524d,timeout)
        if io.read(MAIL+60)[0]!=m['build_id']:raise RuntimeError('Firmware layout ID mismatch')
        print('CPU READY:',layout,'boot',boot,flush=True)
        for seq in range(runs):
            vector=vectors['vectors'][seq%vectors['count']]
            codes=bytes(vector['input'])
            if len(codes)!=784:raise ValueError('Invalid input vector')
            words=list(struct.unpack('<196I',codes))
            for start in range(0,len(words),chunk_words):io.write(m['input_address']+start*4,words[start:start+chunk_words])
            began=time.monotonic();io.write(MAIL,[0x53540000+seq])
            wait_mail(io,0x444f0000+seq,timeout)
            result=io.read(MAIL,16);output=result[4:14]
            if output!=vector['integer']:raise RuntimeError('Integer golden mismatch: boot=%d seq=%d got=%s expected=%s'%(boot,seq,output,vector['integer']))
            pt_error=max(abs(x-y)for x,y in zip(output,vector['pytorch']))
            if pt_error>vectors['pytorch_max_code_error']:raise RuntimeError('PyTorch code error exceeded exported bound')
            best=max(range(10),key=output.__getitem__)
            if result[1]!=0 or result[2]!=best or result[3]==0 or result[14]!=seq+1:raise RuntimeError('Mailbox error/class/cycle/IRQ count failed: '+str(result))
            records.append(dict(boot=boot,sequence=seq,vector=seq%vectors['count'],output=output,
              integer=vector['integer'],pytorch=vector['pytorch'],pytorch_max_code_error=pt_error,
              predicted_class=best,cycles=result[3],irq_count=result[14],host_wait_s=time.monotonic()-began))
            print('PASS boot=%d seq=%d class=%d cycles=%d IRQs=%d'%(boot,seq,best,result[3],result[14]),flush=True)
    return dict(layout=layout,boots=boots,inferences=len(records),all_integer_bitexact=True,
      vectors_sha256=hashlib.sha256(vector_file.read_bytes()).hexdigest(),records=records)

def prepare(layout,host,port):
    folder,m=read_bundle(layout)
    out=ROOT/'build/jtag'/layout;out.mkdir(parents=True,exist_ok=True)
    commands=['set pagination off','set architecture riscv:rv32','target remote %s:%d'%(host,port),
      'monitor mynpu_reset','monitor mynpu_expect 0x%08x %d'%(m['build_id'],m['cache_words']),
      'monitor riscv set_mem_access sysbus']
    for item in m['loads']:
        path=out/(Path(item['file']).stem+'.bin')
        words=words_from_hex(folder/item['file'])
        path.write_bytes(struct.pack('<%dI'%len(words),*words))
        commands.append('restore "%s" binary 0x%08x'%(path.as_posix(),item['address']))
    for i in range(16):commands.append('set {unsigned int}0x%08x = 0'%(MAIL+i*4))
    commands+=['set $pc = 0x00010000','set {unsigned int}0x00010030 = 1',
      'echo Loaded '+layout+'. Type continue; Ctrl+C later to inspect READY mailbox.\\n']
    script=out/'load.gdb';script.write_text('\n'.join(commands)+'\n')
    first=json.loads((ROOT/'generated/jtag/vectors/mnist.json').read_text())['vectors'][0]
    input_file=out/'first-input.bin';input_file.write_bytes(bytes(first['input']))
    (out/'first-input.gdb').write_text(
      'if *(unsigned int*)0x80001fc0 != 0x5354524d\n'+
      '  echo CPU must be at READY before sequence zero.\\n\nelse\n'+
      '  restore "%s" binary 0x%08x\n'%(input_file.as_posix(),m['input_address'])+
      '  set {unsigned int}0x80001fc0 = 0x53540000\n  continue\nend\n')
    (out/'first-expected.json').write_text(json.dumps(dict(integer=first['integer'],pytorch=first['pytorch']),indent=2)+'\n')
    print('GDB script:',script)
    return script

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--layout',choices=['private','shared'],required=True)
    p.add_argument('--host',default='127.0.0.1');p.add_argument('--port',type=int,default=6666)
    p.add_argument('--runs',type=int,default=64);p.add_argument('--boots',type=int,default=3)
    p.add_argument('--timeout',type=float,default=120);p.add_argument('--chunk-words',type=int,default=32)
    p.add_argument('--prepare-gdb',action='store_true');p.add_argument('--gdb-port',type=int,default=3333)
    p.add_argument('--output',type=Path);a=p.parse_args()
    if a.prepare_gdb:prepare(a.layout,a.host,a.gdb_port);return
    output=a.output or ROOT/'build/jtag'/('board-'+a.layout+'.json')
    output.parent.mkdir(parents=True,exist_ok=True);io=None
    try:
        io=OpenOcd(a.host,a.port,a.timeout)
        result=run(io,a.layout,a.runs,a.boots,a.timeout,a.chunk_words)
        output.write_text(json.dumps(result,indent=2)+'\n')
        print('JTAG REGRESSION PASS:',result['inferences'],'inferences; log',output)
    except Exception as exc:
        output.write_text(json.dumps(dict(layout=a.layout,passed=False,error=str(exc)),indent=2)+'\n')
        raise SystemExit(str(exc))from exc
    finally:
        if io:
            try:io.command('poll on')
            except Exception:pass
            io.close()
if __name__=='__main__':main()
