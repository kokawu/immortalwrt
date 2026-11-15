#!/bin/bash
# Recover after sync even if tag push or dispatch previously failed.
set -euo pipefail
: "${GITHUB_REPOSITORY:?missing repository}"
sha=$(git rev-parse HEAD)
tag="build-auto-sha-$sha"

# An active or successful build for this exact commit is sufficient.
# Query errors must stop the script, not look like an empty run list.
covered=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow build.yml \
    --commit "$sha" --limit 100 --json status,conclusion \
    --jq 'any(.[]; .status != "completed" or .conclusion == "success")')
case "$covered" in
    true) echo "Build already active or successful for $sha"; exit 0;;
    false) ;;
    *) echo "Invalid build query result: $covered" >&2; exit 1;;
esac

# Lightweight, commit-addressed tag: retries reuse it, never move it.
for attempt in 1 2 3; do
    remote=$(git ls-remote --refs origin "refs/tags/$tag")
    if [ -n "$remote" ]; then
        [ "${remote%%[[:space:]]*}" = "$sha" ] || {
            echo "Refusing to move existing tag $tag" >&2; exit 1;
        }
        break
    fi
    if git push origin "$sha:refs/tags/$tag"; then
        break
    fi
    if [ "$attempt" = 3 ]; then
        echo "Tag push failed; rerun Sync upstream to recover" >&2
        exit 1
    fi
done
# An ambiguous dispatch response is recovered by querying runs on the next sync.
gh workflow run build.yml --repo "$GITHUB_REPOSITORY" --ref "$tag"
echo "Triggered firmware build for $tag"
