"""Host protocol fault handling; RTL hardware checks live in tb_soc_jtag.sv."""
import contextlib,io,json,socket,sys,threading,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from jtag_host import OpenOcd,MAIL,read_bundle,run,wait_mail,ROOT

class FakeSba:
    def __init__(self,layout,corrupt=False,drop_irq=False):
        self.layout=layout;self.m=read_bundle(layout)[1];self.memory={};self.corrupt=corrupt;self.drop_irq=drop_irq
        self.vectors=json.loads((ROOT/'generated/jtag/vectors/mnist.json').read_text())['vectors']
    def command(self,script):
        if script=='mynpu_reset':self.memory={0x10030:0,0x10034:self.m['build_id'],0x10038:self.m['cache_words']}
        elif script=='mynpu_run':self.memory[MAIL]=0x5354524d;self.memory[MAIL+60]=self.m['build_id']
        else:raise AssertionError(script)
    def read(self,address,count=1):return [self.memory.get(address+i*4,0)for i in range(count)]
    def write(self,address,words):
        for i,w in enumerate(words):self.memory[address+i*4]=w
        if address==MAIL and len(words)==1 and words[0]&0xffff0000==0x53540000:
            seq=words[0]&0xffff;vector=self.vectors[seq%len(self.vectors)];output=vector['integer'][:]
            self.memory.update({MAIL:0x444f0000+seq,MAIL+4:0,MAIL+8:max(range(10),key=output.__getitem__),MAIL+12:35574,
              MAIL+56:seq+(0 if self.drop_irq else 1),MAIL+60:self.m['build_id']})
            if self.corrupt:output[0]^=1
            for i,w in enumerate(output):self.memory[MAIL+16+i*4]=w

class HostTests(unittest.TestCase):
    def test_repeated_both_layouts(self):
        with contextlib.redirect_stdout(io.StringIO()):
            for layout in ('private','shared'):
                result=run(FakeSba(layout),layout,65,2,1,32)
                self.assertEqual(result['inferences'],130)
    def test_bad_output_rejected(self):
        with contextlib.redirect_stdout(io.StringIO()),self.assertRaisesRegex(RuntimeError,'golden mismatch'):
            run(FakeSba('shared',corrupt=True),'shared',1,1,1,32)
    def test_lost_irq_rejected(self):
        with contextlib.redirect_stdout(io.StringIO()),self.assertRaisesRegex(RuntimeError,'IRQ count'):
            run(FakeSba('private',drop_irq=True),'private',1,1,1,32)
    def test_wrong_hardware_rejected_before_load(self):
        class Wrong(FakeSba):
            def command(self,script):super().command(script);self.memory[0x10034]^=0x100
        with self.assertRaisesRegex(RuntimeError,'Wrong bitstream'):run(Wrong('private'),'private',1,1,1,32)
    def test_timeout(self):
        with self.assertRaises(TimeoutError):wait_mail(FakeSba('private'),1,0.001)
    def test_fragmented_rpc_and_error(self):
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen()
        def server():
            conn,_=listener.accept()
            with conn:
                for response in (b'OK:0x00000001 0x00000002\x1a',b'ERROR:SBA busy timeout\x1a'):
                    command=b''
                    while b'\x1a'not in command:command+=conn.recv(4096)
                    for byte in response:conn.sendall(bytes([byte]))
            listener.close()
        thread=threading.Thread(target=server);thread.start()
        client=OpenOcd(port=listener.getsockname()[1])
        try:
            self.assertEqual(client.read(0x80000000,2),[1,2])
            with self.assertRaisesRegex(RuntimeError,'SBA busy timeout'):client.read(0)
        finally:client.close();thread.join()
if __name__=='__main__':unittest.main()
