import gzip
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('smoke', ROOT / 'scripts/kokawu-smoke-test.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class SmokeTests(unittest.TestCase):
    def test_unpack_ignores_fwtool_trailer(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            source, target = Path(temp) / 'image.gz', Path(temp) / 'image.img'
            data = b'raw firmware image' * 4096
            source.write_bytes(gzip.compress(data) + b'fwtool metadata')
            smoke.unpack(source, target)
            self.assertEqual(target.read_bytes(), data)

    def test_truncated_image_rejected(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            source, target = Path(temp) / 'image.gz', Path(temp) / 'image.img'
            source.write_bytes(gzip.compress(b'test image')[:-6])
            with self.assertRaises(ValueError):
                smoke.unpack(source, target)

    def test_long_script_uses_disk_not_serial(self):
        import subprocess
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temp:
            folder = Path(temp)
            script = '# ' + 'x' * 8192 + chr(10) + 'echo "quoted script"' + chr(10)
            command = ['qemu-system-x86_64']
            launcher = smoke.attach_guest_script(command, folder, script)
            disk = folder / 'test-script.img'
            data = disk.read_bytes()
            self.assertEqual(len(data) % 512, 0)
            self.assertEqual(data[:len(script.encode())], script.encode())
            self.assertEqual(data[len(script.encode()):].strip(bytes(1)), b'')
            self.assertLess(len(launcher), 200)
            self.assertEqual(launcher.count(bytes([10])), 1)
            self.assertNotIn(b'quoted', launcher)
            self.assertIn('readonly=on', command[-1])
            local = launcher.decode().replace('/dev/vdc', str(disk)).replace(
                '/tmp/kokawu-smoke.sh', str(folder / 'guest.sh'))
            result = subprocess.run(['sh', '-c', local], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'quoted script' + chr(10))
