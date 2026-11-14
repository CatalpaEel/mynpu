"""Host-side fault detection tests. These do not simulate or validate the SoC."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch

from jtag_validation import (OpenOCD, PASS, FAIL, RESULT, check_output, upload,
                             validate_assets, wait_value)


class Memory:
    def __init__(self, corrupt=False):
        self.words = {}
        self.corrupt = corrupt

    def write(self, address, words):
        for i, word in enumerate(words):
            self.words[address+i*4] = word

    def read(self, address, count=1):
        return [self.words.get(address+i*4, 0) ^ int(self.corrupt) for i in range(count)]


class ValidationTests(unittest.TestCase):
    def test_full_upload_and_bank_boundary(self):
        io = Memory()
        payload = bytes(range(256))*64
        upload(io, 0x80000000, payload, chunk_words=63)
        self.assertEqual(io.read(0x80001FFC)[0], struct.unpack_from('<I', payload, 8192-4)[0])
        self.assertEqual(io.read(0x80002000)[0], struct.unpack_from('<I', payload, 8192)[0])
        self.assertEqual(len(io.words), 4096)

    def test_download_corruption_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'readback mismatch'):
            upload(Memory(corrupt=True), 0x80000000, b'\0'*256)

    def test_partial_word_rejected(self):
        with self.assertRaises(ValueError):
            upload(Memory(), 0x80000000, b'123')

    def test_all_ten_logits_compared(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder/'gold0_5.hex').write_text(' '.join(f'{i:02x}' for i in range(10)))
            words = list(struct.unpack('<3I', bytes(range(10))+b'\0\0'))
            self.assertEqual(check_output(folder, 0, words), 9)
            words[0] ^= 1  # argmax stays 9, but the mismatch must still fail.
            with self.assertRaisesRegex(RuntimeError, 'Logits mismatch'):
                check_output(folder, 0, words)

    def test_final_frame_completion_race(self):
        class Race:
            def __init__(self): self.reads = 0
            def read(self, address):
                if address == RESULT: return [PASS]
                self.reads += 1
                return [0 if self.reads==1 else 7]
        wait_value(Race(), 0x80001FA8, 7, 1)

    def test_firmware_error_is_not_success(self):
        class Error:
            def read(self, address): return [FAIL if address==RESULT else 0]
        with self.assertRaises(RuntimeError): wait_value(Error(), 0x80001FA8, 1, 1)

    def test_future_sequence_rejected(self):
        class Future:
            def read(self, address): return [0 if address==RESULT else 99]
        with self.assertRaisesRegex(RuntimeError, 'Unexpected sequence'):
            wait_value(Future(), 0x80001FA8, 1, 1)

    def test_timeout(self):
        with patch('jtag_validation.time.sleep'):
            with self.assertRaises(TimeoutError): wait_value(Memory(), RESULT, PASS, 0.001)

    def test_manifest_corruption_before_connect(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            for name in ('stream_sram.bin', *(f'sram{i}.bin' for i in range(10))):
                (folder/name).write_bytes(b'\0'*16384)
            manifest={'format':'ego1-jtag-validation-v1','sha256':{
                p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.iterdir()}}
            (folder/'manifest.json').write_text(json.dumps(manifest))
            validate_assets(folder)
            (folder/'sram0.bin').write_bytes(b'X'*16384)
            with self.assertRaisesRegex(ValueError,'hash mismatch'):validate_assets(folder)

    def test_unaligned_and_out_of_range_sba_rejected(self):
        io=object.__new__(OpenOCD)
        with self.assertRaises(ValueError):io.write(3,[0])
        with self.assertRaises(ValueError):io.write(4,[-1])
        with self.assertRaises(ValueError):io.read(1)
        with self.assertRaises(ValueError):io.read(4,257)

    def test_fragmented_openocd_rpc_response(self):
        sock=Mock()
        sock.recv.side_effect=[b'OK 0x1234',b' 5678',b'\x1a']
        with patch('jtag_validation.socket.create_connection',return_value=sock):
            io=OpenOCD()
            self.assertEqual(io.read(0x80000000,2),[0x1234,5678])
        self.assertTrue(sock.sendall.call_args.args[0].endswith(b'\x1a'))

    def test_openocd_error_propagates(self):
        sock=Mock()
        sock.recv.return_value=b'ERR target not halted\x1a'
        with patch('jtag_validation.socket.create_connection',return_value=sock):
            io=OpenOCD()
            with self.assertRaisesRegex(RuntimeError,'target not halted'):io.command('halt')

    def test_failed_implementation_cannot_be_packaged(self):
        from package_validation import package
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with self.assertRaisesRegex(ValueError,'FPGA is not ready'):
                package(root,root,root/'kit')
            self.assertFalse((root/'kit').exists())


if __name__=='__main__':unittest.main(verbosity=2)
