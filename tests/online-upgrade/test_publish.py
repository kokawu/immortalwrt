"""Exercise the actual publication script with a fake gh; never contacts GitHub."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE_GH = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open('calls.jsonl', 'a') as f:
    f.write(json.dumps(args) + '\\n')
mode = os.environ['MOCK_MODE']
if args[:3] == ['release', 'upload', 'online-123-1'] and mode == 'upload-failure':
    sys.exit(1)
if args[0] == 'api':
    if any('/releases/assets/' in a for a in args):
        if mode == 'api-failure': sys.exit(1)
        print(json.dumps(dict(schema=1, repository='kokawu/immortalwrt', channel='stable',
                              build_id=99999 if mode == 'older' else 100)))
    elif mode != 'bootstrap':
        print(json.dumps(dict(tag_name='online-latest', assets=[dict(name='manifest.json',id=42)])))
'''


class PublishTests(unittest.TestCase):
    def run_publish(self, mode):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as name:
            path = Path(name).resolve()
            (path / 'gh').write_text(FAKE_GH)
            (path / 'gh').chmod(0o755)
            (path / 'artifacts').mkdir()
            (path / 'artifacts/manifest.json').write_text(json.dumps(dict(
                schema=1, repository='kokawu/immortalwrt', channel='stable',
                version='online-123-1', build_id=12301, commit='a' * 40)))
            env = dict(os.environ, PATH=str(path) + os.pathsep + os.environ['PATH'],
                       MOCK_MODE=mode, GITHUB_REPOSITORY='kokawu/immortalwrt')
            result = subprocess.run(['bash', str(ROOT / 'scripts/kokawu-publish-release.sh')],
                                    cwd=path, env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in (path / 'calls.jsonl').read_text().splitlines()]
            return result, calls

    def test_bootstrap_orders_upload_before_channel(self):
        result, calls = self.run_publish('bootstrap')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0][:3], ['release', 'create', 'online-123-1'])
        self.assertIn('--draft', calls[0])
        self.assertEqual(calls[1][:3], ['release', 'upload', 'online-123-1'])
        self.assertIn('--draft=false', calls[2])
        self.assertEqual(calls[-1][:3], ['release', 'create', 'online-latest'])

    def test_existing_channel_update_is_last(self):
        result, calls = self.run_publish('update')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][:3], ['release', 'upload', 'online-latest'])
        self.assertIn('--clobber', calls[-1])

    def test_old_build_does_not_move_channel(self):
        result, calls = self.run_publish('older')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:3] == ['release', 'upload', 'online-latest'] for c in calls))

    def test_failed_asset_upload_leaves_draft_and_channel_unchanged(self):
        result, calls = self.run_publish('upload-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)

    def test_channel_api_error_is_not_treated_as_bootstrap(self):
        result, calls = self.run_publish('api-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:3] in (['release', 'upload', 'online-latest'],
                                      ['release', 'create', 'online-latest']) for c in calls))


if __name__ == '__main__':
    unittest.main()
