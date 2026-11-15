"""Exercise recovery with real local Git refs and a fake GitHub boundary."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/kokawu-ensure-build.sh'


class SyncRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = self.folder / 'repo'
        self.remote = self.folder / 'remote.git'
        self.git('init', '--bare', str(self.remote), cwd=self.folder)
        self.git('init', str(self.repo), cwd=self.folder)
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Test')
        self.git('commit', '--allow-empty', '-m', 'test')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.sha = self.git('rev-parse', 'HEAD').stdout.strip()
        self.tag = 'build-auto-sha-' + self.sha
        self.bin = self.folder / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text('''#!/bin/bash
set -eu
if [ "$1 $2" = "run list" ]; then
    [ "$QUERY_FAIL" = 0 ] || exit 9
    echo "$COVERED"
else
    echo "$*" >> "$DISPATCH_LOG"
    [ "$DISPATCH_FAIL" = 0 ] || exit 8
fi
''')
        gh.chmod(0o755)
        self.log = self.folder / 'dispatch.log'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        GITHUB_REPOSITORY='owner/repo', COVERED='false', QUERY_FAIL='0',
                        DISPATCH_FAIL='0', DISPATCH_LOG=str(self.log))

    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd or self.repo,
                              capture_output=True, text=True, check=True)

    def run_script(self):
        return subprocess.run(['bash', str(SCRIPT)], cwd=self.repo, env=self.env,
                              capture_output=True, text=True)

    def test_missing_tag_recovered_and_active_build_skipped(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'rev-parse',
                                  'refs/tags/' + self.tag).stdout.strip(), self.sha)
        self.env['COVERED'] = 'true'
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_dispatch_failure_recovers_with_existing_tag(self):
        self.env['DISPATCH_FAIL'] = '1'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.env['DISPATCH_FAIL'] = '0'
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)

    def test_query_failure_does_not_dispatch(self):
        self.env['QUERY_FAIL'] = '1'
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_mismatched_remote_tag_rejected(self):
        self.git('commit', '--allow-empty', '-m', 'other')
        other = self.git('rev-parse', 'HEAD').stdout.strip()
        self.git('push', 'origin', other + ':refs/tags/' + self.tag)
        self.git('checkout', self.sha)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_push_failure_bounded_and_no_dispatch(self):
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Tag push failed', result.stderr)
        self.assertFalse(self.log.exists())

    def test_transient_push_failure_retried(self):
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nif [ ! -f retry-seen ]; then touch retry-seen; exit 1; fi\n')
        hook.chmod(0o755)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue(self.log.exists())


if __name__ == '__main__':
    unittest.main()
