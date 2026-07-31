#!/bin/bash
# Offline test suite: builds a synthetic vhost tree in a temp dir. No ClamAV, no Docker, no root.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
PASS=0; FAIL=0
ok(){ echo "  ok   - $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# synthetic host: two served sites, one archived copy, one symlink duplicate
mkdir -p "$T/vhosts/site-a.example" "$T/vhosts/site-b.example"
mkdir -p "$T/home/site-a.example/public_html/wp-content"
mkdir -p "$T/home/site-b.example/public_html/wp-content"
mkdir -p "$T/home/archived-copy/wp-content"
ln -s "$T/home/site-a.example/public_html" "$T/home/site-a-symlink"
printf 'docRoot $VH_ROOT/public_html\nextUser site-a\n' > "$T/vhosts/site-a.example/vhost.conf"
printf 'docRoot $VH_ROOT/public_html\nextUser site-b\n' > "$T/vhosts/site-b.example/vhost.conf"

export OLS_VHOST_DIR="$T/vhosts" WP_VHOST_HOME="$T/home" WP_SKIP_DOCKER=1

echo '== discovery =='
OUT=$("$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'discovered 2 wp-content' \
  && ok 'finds exactly the served sites' || no "finds exactly the served sites (got: $(printf '%s' "$OUT" | head -1))"
printf '%s' "$OUT" | grep -q 'archived-copy' \
  && no 'ignores unserved copies on disk' || ok 'ignores unserved copies on disk'

OUT=$(WP_EXTRA_ROOTS="$T/home/site-a-symlink" "$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'discovered 2 wp-content' \
  && ok 'deduplicates a symlinked path by realpath' || no 'deduplicates a symlinked path by realpath'

OUT=$(WP_EXTRA_ROOTS="$T/home/archived-copy" "$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'discovered 3 wp-content' \
  && ok 'honours operator-declared extra roots' || no 'honours operator-declared extra roots'

echo '== permissions =='
"$ROOT/wp-permissions-check.sh" >/dev/null 2>&1
[ $? -ne 0 ] && ok 'flags an ownership mismatch' || no 'flags an ownership mismatch'

echo '== clamav scan --list =='
OUT=$("$ROOT/wp-clamav-scan.sh" --list 2>&1)
printf '%s' "$OUT" | grep -q 'discovered 2 wp-content' \
  && ok 'scan --list reports targets without scanning' || no 'scan --list reports targets without scanning'

echo '== regressions =='
# A docRoot containing spaces must still be discovered; taking awk field 2 would truncate it
# and silently drop the site from every scan.
mkdir -p "$T/vhosts/site-c.example"
mkdir -p "$T/home/site c/public html/wp-content"
printf 'docRoot %s\nextUser site-c\n' "$T/home/site c/public html" > "$T/vhosts/site-c.example/vhost.conf"
OUT=$("$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'public html/wp-content' \
  && ok 'discovers a docRoot containing spaces' || no 'discovers a docRoot containing spaces'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
