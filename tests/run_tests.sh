#!/bin/bash
# Offline test suite: builds a synthetic vhost tree in a temp dir. No ClamAV, no Docker, no root.
# shellcheck disable=SC2015,SC2016,SC2181
# SC2015: the `[ cond ] && ok "..." || no "..."` shape is intentional here - `ok` cannot fail,
#         so this is a two-branch report, not a mis-written if-then-else.
# SC2016: single quotes are deliberate where a literal `$` belongs to awk, python or a stub.
# SC2181: these suites check `$?` immediately after the command under test, which is the
#         thing being asserted.
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
printf '%s' "$OUT" | grep -q 'discovered 2 WordPress' \
  && ok 'finds exactly the served sites' || no "finds exactly the served sites (got: $(printf '%s' "$OUT" | head -1))"
printf '%s' "$OUT" | grep -q 'archived-copy' \
  && no 'ignores unserved copies on disk' || ok 'ignores unserved copies on disk'

OUT=$(WP_EXTRA_ROOTS="$T/home/site-a-symlink" "$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'discovered 2 WordPress' \
  && ok 'deduplicates a symlinked path by realpath' || no 'deduplicates a symlinked path by realpath'

OUT=$(WP_EXTRA_ROOTS="$T/home/archived-copy" "$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'discovered 3 WordPress' \
  && ok 'honours operator-declared extra roots' || no 'honours operator-declared extra roots'

echo '== permissions =='
"$ROOT/wp-permissions-check.sh" >/dev/null 2>&1
[ $? -ne 0 ] && ok 'flags an ownership mismatch' || no 'flags an ownership mismatch'

echo '== clamav scan --list =='
OUT=$("$ROOT/wp-clamav-scan.sh" --list 2>&1)
printf '%s' "$OUT" | grep -q 'discovered 2 WordPress' \
  && ok 'scan --list reports targets without scanning' || no 'scan --list reports targets without scanning'

echo '== regressions =='
# A docRoot containing spaces must still be discovered; taking awk field 2 would truncate it
# and silently drop the site from every scan.
mkdir -p "$T/vhosts/site-c.example"
mkdir -p "$T/home/site c/public html/wp-content"
printf 'docRoot %s\nextUser site-c\n' "$T/home/site c/public html" > "$T/vhosts/site-c.example/vhost.conf"
OUT=$("$ROOT/wp-discover.sh")
printf '%s' "$OUT" | grep -q 'public html' \
  && ok 'discovers a docRoot containing spaces' || no 'discovers a docRoot containing spaces'

# A scanner that fails must not be reported as a clean scan. Without this case the whole
# exit-code check can be deleted and every other test still passes.
STUB=$(mktemp -d)
printf '%s\n' '#!/bin/bash' 'echo "ERROR: cannot open directory"' 'exit 2' > "$STUB/clamscan"
# nice is called as `nice -n 19 ...` and ionice as `ionice -c3 ...`; the stubs must consume
# exactly those options, or they fail before clamscan runs and the test passes vacuously.
printf '%s\n' '#!/bin/bash' 'shift 2; exec "$@"' > "$STUB/nice"
printf '%s\n' '#!/bin/bash' 'shift 1; exec "$@"' > "$STUB/ionice"
chmod +x "$STUB/clamscan" "$STUB/nice" "$STUB/ionice"
OUT=$(PATH="$STUB:$PATH" WP_SCAN_LOG="$T/scan.log" WP_ALERT_LOG="$T/alert.log" \
      "$ROOT/wp-clamav-scan.sh" 2>&1)
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'SCAN-ERROR'; then
  ok 'a failing scanner exits 2 instead of reporting a clean scan'
else
  no "a failing scanner exits 2 instead of reporting a clean scan (got rc=$RC)"
fi
grep -q 'SCAN-ERROR' "$T/alert.log" 2>/dev/null \
  && ok 'the scan error is recorded in the alert log' \
  || no 'the scan error is recorded in the alert log'
rm -rf "$STUB"

# The alert.env permission check must be exercised, or it can be deleted with a green suite.
# Root ignores file modes, so assert on the check's own logic rather than on a chmod.
PERM=$(mktemp -d)
printf 'X=1\n' > "$PERM/alert.env"
chmod 666 "$PERM/alert.env"
if python3 - "$PERM/alert.env" <<'PYEOF'
import os, stat, sys
st = os.stat(sys.argv[1])
sys.exit(0 if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH) else 1)
PYEOF
then
  grep -q 'S_IWGRP' "$ROOT/wp-clamav-scan.sh" \
    && ok 'the scanner checks group/world writability before sourcing alert.env' \
    || no 'the scanner checks group/world writability before sourcing alert.env'
  grep -q 'st.st_uid not in' "$ROOT/wp-clamav-scan.sh" \
    && ok 'the scanner also checks who owns alert.env' \
    || no 'the scanner also checks who owns alert.env'
else
  no 'test fixture did not become group/world-writable'
fi
rm -rf "$PERM"

# A log that cannot be written must abort rather than let an unperformed scan look clean.
OUT=$(OLS_VHOST_DIR="$T/vhosts" WP_VHOST_HOME="$T/home" WP_SKIP_DOCKER=1 \
      WP_SCAN_LOG=/dev/null/scan.log WP_ALERT_LOG="$T/a.log" "$ROOT/wp-clamav-scan.sh" 2>&1)
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'refusing to run a scan'; then
  ok 'refuses to scan when results cannot be recorded'
else
  no "refuses to scan when results cannot be recorded (got rc=$RC)"
fi

# Listing writes nothing, so it must work for a user who cannot write the scan log - the
# inventory is the one thing you want to run before deciding anything else.
OUT=$(WP_SCAN_LOG=/dev/null/x.log WP_ALERT_LOG=/dev/null/y.log \
      "$ROOT/wp-clamav-scan.sh" --list 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'WordPress target'; then
  ok '--list works without a writable log'
else
  no "--list works without a writable log (got rc=$RC)"
fi

# The verdict must come from clamscan's exit status, never from whether the log parser managed
# to find FOUND lines. Each row below is a way the parser could be wrong while the scanner was
# right; only the first row may report success.
verdict_case(){ # <scanner-rc> <emit-FOUND> <alert.env> <expected-wrapper-rc> <label>
  local vt vs
  vt=$(mktemp -d); vs=$(mktemp -d)
  mkdir -p "$vt/vhosts/s.example" "$vt/home/s.example/public_html/wp-content"
  printf 'docRoot $VH_ROOT/public_html\nextUser s\n' > "$vt/vhosts/s.example/vhost.conf"
  {
    echo '#!/bin/bash'
    [ "$2" = yes ] && echo 'echo "/x/evil.php: Php.Malware FOUND"'
    echo "exit $1"
  } > "$vs/clamscan"
  printf '%s\n' '#!/bin/bash' 'shift 2; exec "$@"' > "$vs/nice"
  printf '%s\n' '#!/bin/bash' 'shift 1; exec "$@"' > "$vs/ionice"
  chmod +x "$vs/clamscan" "$vs/nice" "$vs/ionice"
  # An array, not a string: unquoted it needs SC2086 silenced, and quoted it would hand env
  # an empty argument whenever no alert config is wanted.
  local extra=()
  if [ "$3" = yes ]; then
    printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_CHAT_ID=\n' > "$vt/alert.env"
    chmod 600 "$vt/alert.env"
    extra=(WP_ALERT_ENV="$vt/alert.env")
  fi
  env PATH="$vs:$PATH" OLS_VHOST_DIR="$vt/vhosts" WP_VHOST_HOME="$vt/home" WP_SKIP_DOCKER=1 \
      WP_SCAN_LOG="$vt/s.log" WP_ALERT_LOG="$vt/a.log" WP_SCAN_LOCK="$vt/lk" \
      ${extra[@]+"${extra[@]}"} \
      "$ROOT/wp-clamav-scan.sh" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$4" ]; then ok "$5"; else no "$5 (expected $4, got $rc)"; fi
  rm -rf "$vt" "$vs"
}

verdict_case 0 no  no  0 'a clean scan exits 0'
verdict_case 1 yes no  1 'an infection with readable FOUND lines exits 1'
verdict_case 1 no  no  1 'an infection exits 1 even when no FOUND line can be parsed'
verdict_case 1 yes yes 1 'an infection exits 1 after alerting'
verdict_case 1 no  yes 1 'an unparseable infection exits 1 even with alerting configured'
verdict_case 2 no  no  2 'a scanner failure exits 2'

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]




