import copy
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/kokawu-online-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = release.config_values(ROOT / "seed.config")
        self.meta = release.identity(self.config, 123, 1, "a" * 40, "2026.09.17-01")

    def test_identity(self):
        self.assertEqual(self.meta["build_id"], 12301)
        self.assertEqual(self.meta["version"], "2026.09.17-01")

    def test_wrong_layout_rejected(self):
        self.config["CONFIG_TARGET_ROOTFS_PARTSIZE"] = "2048"
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 1, "a" * 40, "2026.09.17-01")

    def test_opkg_rejected(self):
        self.config["CONFIG_PACKAGE_opkg"] = "y"
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 1, "a" * 40, "2026.09.17-01")

    def test_plugin_required(self):
        self.config.pop("CONFIG_PACKAGE_luci-app-kokawu-upgrade")
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 1, "a" * 40, "2026.09.17-01")

    def test_ext4_rejected(self):
        self.config["CONFIG_TARGET_ROOTFS_EXT4FS"] = "y"
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 1, "a" * 40, "2026.09.17-01")

    def test_bad_commit(self):
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 1, "not-a-commit", "2026.09.17-01")

    def test_no_sequence_collisions(self):
        with self.assertRaises(ValueError):
            release.identity(self.config, 123, 100, "a" * 40, "2026.09.17-01")

    def test_bad_date_versions(self):
        for version in ('2026.02.30-01', '2026.13.01-01', '2026.09.17-00', '../bad'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.date_version(version)

    def test_reserved_sequence_and_commit(self):
        day = release.datetime.now(release.ZoneInfo('Asia/Shanghai')).strftime('%Y.%m.%d')
        refs = json.dumps([{'ref': f'refs/tags/v{day}-01'}, {'ref': f'refs/tags/v{day}-03'}])
        with patch.object(release.subprocess, 'check_output', return_value=refs), \
             patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(release.reserve_version('a' * 40), day + '-04')
            self.assertIn('sha=' + 'a' * 40, run.call_args.args[0])

    def test_reservation_error_fails_closed(self):
        failed = SimpleNamespace(returncode=1, stderr='network failure')
        with patch.object(release.subprocess, 'check_output', return_value='[]'), \
             patch.object(release.subprocess, 'run', return_value=failed), self.assertRaises(RuntimeError):
            release.reserve_version('a' * 40)

    def test_reservation_collision_retries(self):
        day = release.datetime.now(release.ZoneInfo('Asia/Shanghai')).strftime('%Y.%m.%d')
        refs = json.dumps([{'ref': f'refs/tags/v{day}-01'}])
        with patch.object(release.subprocess, 'check_output', side_effect=['[]', refs]), \
             patch.object(release.subprocess, 'run', side_effect=[
                 SimpleNamespace(returncode=1), SimpleNamespace(returncode=0), SimpleNamespace(returncode=0)]):
            self.assertEqual(release.reserve_version('a' * 40), day + '-02')

    @staticmethod
    def image(folder, boot, wrong_header=False):
        suffix = "-efi" if boot == "efi" else ""
        path = Path(folder) / f"immortalwrt-x86-64-generic-squashfs-combined{suffix}.img.gz"
        data = bytearray(os.urandom(2 * 1024 * 1024))
        data[510:512] = b"\x55\xaa"
        data[512:520] = b"EFI PART" if (boot == "efi") != wrong_header else b"\0" * 8
        with gzip.open(path, "wb", compresslevel=1) as stream:
            stream.write(data)
        # OpenWrt appends fwtool metadata after the gzip stream.
        with path.open("ab") as stream:
            stream.write(b"fwtool-metadata-trailer")
        return path

    def test_manifest_hashes_and_version_urls(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            for boot in ("bios", "efi"):
                self.image(folder, boot)
            # Deployment-only formats must never enter the online upgrade manifest.
            (Path(folder) / "disk.qcow2").write_bytes(b"deployment")
            result = release.manifest(self.meta, folder)
            self.assertEqual(len(result["images"]), 2)
            for image in result["images"]:
                data = (Path(folder) / image["name"]).read_bytes()
                self.assertEqual(image["size"], len(data))
                self.assertEqual(image["sha256"], hashlib.sha256(data).hexdigest())
                self.assertIn("/releases/download/v2026.09.17-01/", image["url"])
                self.assertNotIn("qcow2", image["name"])

    def test_missing_image_rejected(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            self.image(folder, "bios")
            with self.assertRaises(ValueError):
                release.manifest(self.meta, folder)

    def test_mislabelled_boot_rejected(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            self.image(folder, "bios", wrong_header=True)
            self.image(folder, "efi")
            with self.assertRaises(ValueError):
                release.manifest(self.meta, folder)

    def test_duplicate_image_rejected(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            image = self.image(folder, "bios")
            image.with_name("extra-" + image.name).write_bytes(image.read_bytes())
            with self.assertRaises(ValueError):
                release.manifest(self.meta, folder)

    def test_acl_is_scoped(self):
        root = ROOT / "package/luci-app-kokawu-upgrade/root"
        acl = json.loads((root / "usr/share/rpcd/acl.d/luci-app-kokawu-upgrade.json").read_text())
        scope = acl["luci-app-kokawu-upgrade"]
        self.assertEqual(scope["read"], {"ubus": {"kokawu.upgrade": ["status"]}})
        self.assertEqual(scope["write"], {"ubus": {"kokawu.upgrade": ["check", "upgrade"]}})
        cron = (root / "etc/uci-defaults/95-kokawu-upgrade").read_text()
        self.assertIn("/usr/sbin/kokawu-upgrade check", cron)
        self.assertNotIn("sysupgrade", cron)


if __name__ == "__main__":
    unittest.main()
