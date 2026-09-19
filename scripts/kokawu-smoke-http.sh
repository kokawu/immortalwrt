#!/bin/sh
# Runs inside a disposable VM; the caller supplies its temporary root password.
set -eu
: "${SMOKE_PASSWORD:?missing VM test password}"
base=${SMOKE_BASE_URL:-http://127.0.0.1}
work=${SMOKE_HTTP_DIR:-/tmp/kokawu-smoke-http}
mkdir -p "$work"
chmod 700 "$work"
trap 'rm -f "$work/cookies"' EXIT
check_html() {
    grep -qi '<html' "$work/body" &&
    ! grep -Eq 'Unhandled exception|No module named|runtime.uc.*line' "$work/body"
}
request() {
    expected=$1
    shift
    code=$(curl -sS --max-time 30 -D "$work/headers" -o "$work/body" -w '%{http_code}' "$@")
    if [ "$code" != "$expected" ]; then
        echo "LuCI HTTP check: expected $expected, got $code" >&2
        head -c 2048 "$work/body" >&2
        return 1
    fi
    check_html
}
# LuCI deliberately returns 403 for its unauthenticated login form.
echo 'Checking LuCI login form'
request 403 "$base/cgi-bin/luci/"
grep -qi '^X-LuCI-Login-Required: yes' "$work/headers"
grep -q 'luci_username' "$work/body"
# Login redirects (302) and must set a session cookie; don't accept another login form.
echo 'Checking LuCI password login'
code=$(curl -sS --max-time 30 -c "$work/cookies" -o "$work/body" -w '%{http_code}' \
    --data-urlencode 'luci_username=root' --data-urlencode "luci_password=$SMOKE_PASSWORD" \
    "$base/cgi-bin/luci/")
[ "$code" = 302 ] || { echo "LuCI login failed: HTTP $code" >&2; exit 1; }
grep -q 'sysauth_http' "$work/cookies"
for page in admin/status/overview admin/system/kokawu-upgrade; do
    echo "Checking authenticated LuCI page: $page"
    request 200 -b "$work/cookies" "$base/cgi-bin/luci/$page"
    if grep -qi '^X-LuCI-Login-Required:' "$work/headers" ||
       grep -q 'name="luci_password"' "$work/body"; then
        echo "LuCI returned a login page instead of $page" >&2
        exit 1
    fi
done
