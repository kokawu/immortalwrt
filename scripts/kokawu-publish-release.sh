#!/usr/bin/env bash
# Called only by the serialized release job, after the complete artifact exists.
set -euo pipefail
repo=kokawu/immortalwrt
[[ ${GITHUB_REPOSITORY:?} == "$repo" ]]
version=$(python3 -c 'import json; print(json.load(open("artifacts/manifest.json"))["version"])')
commit=$(python3 -c 'import json; print(json.load(open("artifacts/manifest.json"))["commit"])')
[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2,}$ && $commit =~ ^[0-9a-f]{40}$ ]]
tag="v$version"
notes="自动构建的 x86-64 定制固件（APK-only）。源码：$commit

在线升级只支持 squashfs combined BIOS/EFI 原始镜像，QCOW2 仅用于虚拟磁盘部署。
分区规格：内核 128 MiB、rootfs 1024 MiB；分区有扩容或自定义调整时会拒绝在线升级。
升级会中断网络，请先备份配置。保留配置不等于保留手动安装的软件。
构建成功不代表已完成实机回归测试，请自行确认此版本适用。"
# Publish immutable per-run assets first. A failed upload leaves a draft, not a channel update.
gh release create "$tag" --verify-tag --repo "$repo" --target "$commit" --draft --title "$version" --notes "$notes"
gh release upload "$tag" artifacts/* --repo "$repo"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# Query the channel via the authenticated API, avoiding stale CDN content when
# deciding whether an older long-running build may replace a newer one.
gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[] | select(.tag_name == "online-latest")' > channel-release.json
if [[ -s channel-release.json ]]; then
    asset_id=$(python3 - <<'PY'
import json
r = json.load(open('channel-release.json'))
assets = [a for a in r['assets'] if a['name'] == 'manifest.json']
if len(assets) != 1:
    raise SystemExit('Existing channel has no unique manifest; repair it before publishing')
print(assets[0]['id'])
PY
    )
    gh api -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$asset_id" > channel-current.json
    newer=$(python3 - <<'PY'
import json
old = json.load(open('channel-current.json'))
new = json.load(open('artifacts/manifest.json'))
assert old['schema'] == 1 and old['repository'] == new['repository'] and old['channel'] == new['channel']
assert isinstance(old['build_id'], int)
print('yes' if new['build_id'] > old['build_id'] else 'no')
PY
    )
    if [[ $newer != yes ]]; then
        echo "Published $version without moving channel: a newer build is already available."
        exit 0
    fi
    # The only mutable asset is this small manifest; it points to completed,
    # version-specific downloads. A brief 404 during replacement fails closed.
    gh release upload online-latest artifacts/manifest.json --repo "$repo" --clobber
else
    gh release create online-latest artifacts/manifest.json --repo "$repo" --target "$commit" \
        --title '在线升级 stable 渠道' --latest=false \
        --notes '仅存放在线升级清单；固件位于清单指向的独立版本 Release。不会自动刷机。'
fi
echo "Online channel now points to $version"
