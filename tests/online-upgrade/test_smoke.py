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
