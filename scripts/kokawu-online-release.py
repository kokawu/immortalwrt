#!/usr/bin/env python3
"""Create build identity before compilation and a fail-closed update manifest after it."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re

REPOSITORY = "kokawu/immortalwrt"
LAYOUT = "x86-64-k128-r1024-v1"


def config_values(path):
    return dict(line.split("=", 1) for line in Path(path).read_text().splitlines()
                if line.startswith("CONFIG_") and "=" in line)


def identity(config, run_id, attempt, commit):
    required = {
        "CONFIG_TARGET_x86_64": "y",
        "CONFIG_TARGET_x86_64_DEVICE_generic": "y",
        "CONFIG_USE_APK": "y",
        "CONFIG_PACKAGE_apk-openssl": "y",
        "CONFIG_PACKAGE_luci-app-kokawu-upgrade": "y",
        "CONFIG_GRUB_IMAGES": "y",
        "CONFIG_GRUB_EFI_IMAGES": "y",
        "CONFIG_TARGET_IMAGES_GZIP": "y",
        "CONFIG_TARGET_ROOTFS_SQUASHFS": "y",
        "CONFIG_TARGET_KERNEL_PARTSIZE": "128",
        "CONFIG_TARGET_ROOTFS_PARTSIZE": "1024",
    }
    for key, value in required.items():
        if config.get(key) != value:
            raise ValueError(f"Unsupported online-update config: {key} must be {value}")
    if config.get("CONFIG_TARGET_ROOTFS_EXT4FS") == "y":
        raise ValueError("First version supports squashfs only")
    if any(re.fullmatch(r"CONFIG_PACKAGE_(opkg|luci-app-opkg|luci-i18n-opkg-.+)", k)
           and v in ("y", "m") for k, v in config.items()):
        raise ValueError("opkg is not allowed")
    if not 1 <= run_id <= 80000000000000 or not 1 <= attempt <= 99:
        raise ValueError("Invalid GitHub build identity")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected full source commit SHA")
    return dict(schema=1, repository=REPOSITORY, channel="stable",
                version=f"online-{run_id}-{attempt}", build_id=run_id * 100 + attempt,
                target="x86/64", profile="generic", filesystem="squashfs",
                layout=LAYOUT, commit=commit)


def manifest(metadata, directory):
    result = dict(metadata)
    result["images"] = []
    for boot in ("bios", "efi"):
        suffix = "-efi" if boot == "efi" else ""
        pattern = re.compile(r"[\w.-]+-x86-64-generic-squashfs-combined" + suffix + r"\.img\.gz", re.ASCII)
        candidates = [p for p in Path(directory).iterdir() if pattern.fullmatch(p.name) and p.is_file()]
        if len(candidates) != 1:
            raise ValueError(f"Expected exactly one {boot} squashfs combined .img.gz, got {len(candidates)}")
        image = candidates[0]
        size = image.stat().st_size
        if not 1048576 <= size <= 1073741824:
            raise ValueError(f"Unsupported compressed image size: {image.name}")
        with gzip.open(image, "rb") as stream:
            header = stream.read(32256)
        if len(header) != 32256 or header[510:512] != b"\x55\xaa":
            raise ValueError("Invalid raw disk image header")
        if (header[512:520] == b"EFI PART") != (boot == "efi"):
            raise ValueError("Boot mode disagrees with disk image header")
        digest = hashlib.sha256()
        with image.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        result["images"].append(dict(boot=boot, name=image.name, size=size,
                                     sha256=digest.hexdigest(),
                                     url=f"https://github.com/{REPOSITORY}/releases/download/{metadata['version']}/{image.name}"))
    return result


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["identity", "manifest"])
    parser.add_argument("--config", default=".config")
    parser.add_argument("--metadata", default="files/etc/kokawu-release.json")
    parser.add_argument("--artifacts", default="artifacts")
    args = parser.parse_args()
    if args.mode == "identity":
        if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
            raise ValueError("This update channel is pinned to kokawu/immortalwrt")
        data = identity(config_values(args.config), int(os.environ["GITHUB_RUN_ID"]),
                        int(os.environ["GITHUB_RUN_ATTEMPT"]), os.environ["GITHUB_SHA"])
        write_json(args.metadata, data)
    else:
        data = json.loads(Path(args.metadata).read_text())
        write_json(Path(args.artifacts) / "manifest.json", manifest(data, args.artifacts))
        write_json(Path(args.artifacts) / "kokawu-release.json", data)


if __name__ == "__main__":
    main()
