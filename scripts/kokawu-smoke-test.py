#!/usr/bin/env python3
"""Boot disposable BIOS/EFI VMs and test real LuCI/runtime, never a live router."""
import argparse
import json
import os
import shlex
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time
import zlib


def unpack(source, target):
    # fwtool metadata follows the gzip member; it is not a second gzip stream.
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    with source.open('rb') as src, target.open('wb') as dst:
        while block := src.read(65536):
            dst.write(decoder.decompress(block))
            if decoder.eof:
                break
        if not decoder.eof:
            raise ValueError('Truncated gzip image')


def attach_guest_script(command, folder, script):
    # Avoid the bounded BusyBox ash interactive serial input buffer.
    data = script.encode()
    disk = folder / "test-script.img"
    disk.write_bytes(data + bytes(-len(data) % 512))
    command += ["-drive", f"file={disk},format=raw,if=virtio,readonly=on"]
    return (f"head -c {len(data)} /dev/vdc > /tmp/kokawu-smoke.sh && "
            "sh /tmp/kokawu-smoke.sh\n").encode()


def boot(image, boot_mode, version, folder, digest):
    raw = folder / 'disk.img'
    unpack(image, raw)
    payload = folder / 'payload.img'
    shutil.copyfile(image, payload)
    with payload.open('ab') as stream:
        stream.truncate((image.stat().st_size + 511) // 512 * 512)
    command = ['qemu-system-x86_64', '-machine', 'q35', '-accel', 'tcg',
               '-m', '1536', '-smp', '2', '-display', 'none', '-monitor', 'none',
               '-serial', 'stdio', '-no-reboot', '-snapshot',
               '-drive', f'file={raw},format=raw,if=virtio',
               '-drive', f'file={payload},format=raw,if=virtio,readonly=on',
               '-netdev', 'user,id=net0,restrict=on', '-device', 'virtio-net-pci,netdev=net0']
    if boot_mode == 'efi':
        code = Path('/usr/share/OVMF/OVMF_CODE_4M.fd')
        var_source = Path('/usr/share/OVMF/OVMF_VARS_4M.fd')
        if not code.exists() or not var_source.exists():
            raise RuntimeError('Missing OVMF 4M firmware')
        variables = folder / 'vars.fd'
        shutil.copyfile(var_source, variables)
        command += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}',
                    '-drive', f'if=pflash,format=raw,file={variables}']
    # Emit split markers: terminal command echo cannot falsely satisfy the test.
    lua = ("local s=require('kokawu.upgrade').status(); "
           f"assert(s.current and s.current.version=={version!r}); assert(s.boot=={boot_mode!r}); "
           "assert(require('nixio.fs').stat('/tmp/kokawu-upgrade').type=='dir')")
    # Password changes affect only this disposable -snapshot VM.
    import secrets
    password = secrets.token_hex(24)
    http_script = Path(__file__).with_name('kokawu-smoke-http.sh').read_text()
    http_test = (f"printf '%s\n%s\n' {password} {password} | passwd root && "
                 f"SMOKE_PASSWORD={password} sh -c " + shlex.quote(http_script))
    test = ("ucode -e 'import * as m from \"math\"; print(m.floor(1.5));' && "
            + 'lua -e ' + shlex.quote(lua) + ' && '
            + "ubus call kokawu.upgrade status > /tmp/rpc-status.json && "
            + "grep -q 'current' /tmp/rpc-status.json && "
            + http_test + " && "
            + f"head -c {image.stat().st_size} /dev/vdb > /tmp/kokawu-upgrade/firmware.img.gz && "
            + f"echo '{digest}  /tmp/kokawu-upgrade/firmware.img.gz' | sha256sum -c - && "
            + "sh -x /usr/libexec/kokawu-upgrade-layout && "
            + "sysupgrade -T /tmp/kokawu-upgrade/firmware.img.gz")
    script = "( " + test + " ) && printf '\\nKOKAWU_%s\\n' PASS || printf '\\nKOKAWU_%s\\n' FAIL\n"
    launcher = attach_guest_script(command, folder, script)
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 480
    next_probe = time.monotonic() + 45
    log = Path(f'smoke-{boot_mode}.log')
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=1):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    raise RuntimeError('VM exited before smoke test completed')
                output.extend(chunk)
                if b'KOKAWU_PASS' in output:
                    print(f'{boot_mode}: LuCI/RPC/version/nixio/layout/sysupgrade -T checks passed')
                    return
                if b'KOKAWU_FAIL' in output:
                    raise RuntimeError(f'{boot_mode}: guest runtime smoke test failed')
            now = time.monotonic()
            if not sent and now >= next_probe:
                process.stdin.write(b"\n\nprintf 'KOKAWU_%s\\n' READY\n")
                process.stdin.flush()
                next_probe = now + 15
            if not sent and b'KOKAWU_READY' in output:
                process.stdin.write(launcher)
                process.stdin.flush()
                sent = True
        raise RuntimeError(f'{boot_mode}: timed out waiting for guest tests')
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        selector.close()
        log.write_bytes(output)
        if b'KOKAWU_PASS' not in output:
            print(output[-12000:].decode(errors='replace'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', default='artifacts')
    args = parser.parse_args()
    artifacts = Path(args.artifacts).resolve()
    manifest = json.loads((artifacts / 'manifest.json').read_text())
    for image in manifest['images']:
        with tempfile.TemporaryDirectory(prefix='smoke-', dir='.') as temporary:
            boot(artifacts / image['name'], image['boot'], manifest['version'], Path(temporary), image['sha256'])


if __name__ == '__main__':
    main()
