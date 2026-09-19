from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'package/luci-app-kokawu-upgrade/root/usr/libexec/kokawu-upgrade-layout'


class LayoutGateTests(unittest.TestCase):
    def test_overlay_backing_exact_names_only(self):
        text = HELPER.read_text()
        gate = text[text.index('case "$backing" in'):text.index('[ -b "/dev/$rootdev" ]')]
        for rootdev in ('vda2', 'sda2', 'nvme0n1p2'):
            for backing in ('/' + rootdev, '/dev/' + rootdev, '/mnt/extroot/' + rootdev,
                            '/dev/sdb2', '/dev/vda3', '', '/dev/../' + rootdev):
                with self.subTest(rootdev=rootdev, backing=backing):
                    result = subprocess.run(['sh', '-c', gate, 'gate'],
                                            env={'rootdev': rootdev, 'backing': backing},
                                            capture_output=True)
                    self.assertEqual(result.returncode == 0,
                                     backing in ('/' + rootdev, '/dev/' + rootdev))

    def test_header_read_handles_short_pipe_chunks(self):
        line = next(line for line in HELPER.read_text().splitlines()
                    if line.startswith('get_image "$image" |'))
        data = bytes(range(256)) * 200
        # The real producer may return SIGPIPE after the requested prefix.
        # The consumer must read the full header, not 63 short pipe records.
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'header'
            script = ('set -e\nget_image() { python3 -c '
                      + "'import os; d=bytes(range(256))*200; [os.write(1,d[i:i+97]) for i in range(0,len(d),97)]'"
                      + '; }\n' + line)
            result = subprocess.run(['sh', '-c', script],
                                    env={'PATH': '/usr/bin:/bin', 'image': 'unused', 'header': str(target)},
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_bytes(), data[:32256])

    def test_truncated_header_not_padded(self):
        line = next(line for line in HELPER.read_text().splitlines()
                    if line.startswith('get_image "$image" |'))
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'header'
            result = subprocess.run(['sh', '-c', 'set -e; get_image() { printf short; }; ' + line],
                                    env={'PATH': '/usr/bin:/bin', 'image': 'unused', 'header': str(target)},
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_bytes(), b'short')
            # upgrade_layout.parse requires exactly 32256 bytes; existing Lua tests cover rejection.


if __name__ == '__main__':
    unittest.main()
