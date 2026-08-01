#!/bin/bash
# wp-clamav-scan - scan every served WordPress installation with ClamAV.
#
# The point of this script is the discovery step, not the scanner. Scanning "the web root"
# on a multi-site host tends to miss containerised sites and waste hours on archived copies
# nobody serves. This finds the live set, deduplicates it, and scans that.
#
# Usage:
#   wp-clamav-scan.sh          scan
#   wp-clamav-scan.sh --list   show what would be scanned, then exit
#
# Environment:
#   WP_SCAN_LOG    default /var/log/clamav/wp_scan.log
#   WP_ALERT_LOG   default /var/log/clamav/wp_scan_INFECTED.log
#   WP_ALERT_ENV   default ./alert.env  (see alert.env.example - optional)
#   plus every WP_/OLS_ variable understood by wp-discover.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=wp-discover.sh
. "$HERE/wp-discover.sh"

LOG="${WP_SCAN_LOG:-/var/log/clamav/wp_scan.log}"
ALERT="${WP_ALERT_LOG:-/var/log/clamav/wp_scan_INFECTED.log}"
ALERT_ENV="${WP_ALERT_ENV:-./alert.env}"
LIST_ONLY=0; [ "${1:-}" = "--list" ] && LIST_ONLY=1

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
ts(){ date '+%F %T'; }

# If the log cannot be appended to, the redirection below fails before clamscan ever runs and
# bash returns 1 - which in ClamAV's own convention means "infections found". An entirely
# unperformed scan would then be indistinguishable from a completed one. Fail here instead.
for _f in "$LOG" "$ALERT"; do
  if ! : 2>/dev/null >> "$_f"; then
    echo "cannot write to $_f - refusing to run a scan whose results cannot be recorded" >&2
    exit 2
  fi
done

wp_discover

if [ "$LIST_ONLY" = "1" ]; then
  echo "discovered ${#WP_TARGETS[@]} wp-content target(s):"
  [ "${#WP_TARGETS[@]}" -gt 0 ] && printf '  %s\n' "${WP_TARGETS[@]}"
  [ "${#WP_CONTAINER_TARGETS[@]}" -gt 0 ] && { echo 'container targets:'; printf '  %s\n' "${WP_CONTAINER_TARGETS[@]}"; }
  [ "${#WP_CONTAINER_BLIND[@]}" -gt 0 ] && { echo 'WARNING - host-scan blind containers:'; printf '  %s\n' "${WP_CONTAINER_BLIND[@]}"; }
  exit 0
fi

if [ "${#WP_TARGETS[@]}" -eq 0 ]; then
  echo "[$(ts)] no WordPress targets discovered" >> "$LOG"
  exit 0
fi

command -v clamscan >/dev/null 2>&1 || { echo "clamscan not found - install clamav first" >&2; exit 3; }

{
  echo "===== ClamAV WordPress scan START $(ts) ====="
  echo "targets: ${#WP_TARGETS[@]}"
  [ "${#WP_CONTAINER_TARGETS[@]}" -gt 0 ] && printf 'container target: %s\n' "${WP_CONTAINER_TARGETS[@]}"
  [ "${#WP_CONTAINER_BLIND[@]}" -gt 0 ] && printf 'WARNING host-scan blind: %s\n' "${WP_CONTAINER_BLIND[@]}"
} >> "$LOG" 2>&1

# Capture the scanner's status from the scanner, not by reading it back out of the log: a log
# that is unwritable, rotated mid-run, or written to concurrently would hand back a fabricated 0.
nice -n 19 ionice -c3 clamscan -r -i \
  --exclude-dir='(node_modules|\.git|/cache|wflogs|uploads/cache|backup|backups|\.archived)' \
  --max-filesize=20M --max-scansize=100M "${WP_TARGETS[@]}" >> "$LOG" 2>&1
SCAN_RC=$?

{
  echo "clamscan rc=$SCAN_RC"
  echo "===== END $(ts) ====="
} >> "$LOG" 2>&1

# clamscan: 0 = clean, 1 = infections found, 2+ = the scanner itself failed. Treating a
# scanner failure as a clean result is how an unscanned host gets reported as healthy.
if [ "${SCAN_RC:-2}" -ge 2 ]; then
  echo "[$(ts)] SCAN-ERROR clamscan exited $SCAN_RC - results are incomplete, do NOT treat as clean" >> "$ALERT"
  echo "SCAN-ERROR: clamscan exited $SCAN_RC - results are incomplete" >&2
  command -v logger >/dev/null 2>&1 && logger -t wp-clamav-scan "SCAN-ERROR rc=$SCAN_RC"
  exit 2
fi

# Alert on THIS run's block only. Tailing a fixed number of lines re-alerts on old hits
# whenever a later run happens to be short.
HITS=$(awk '/===== ClamAV WordPress scan START/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$LOG" \
        | grep ' FOUND$' || true)
[ -z "$HITS" ] && exit 0

N=$(printf '%s\n' "$HITS" | grep -c 'FOUND')
{ echo "[$(ts)] ClamAV reported $N infected file(s) under WordPress - investigate:"; printf '%s\n' "$HITS"; } >> "$ALERT"
command -v logger >/dev/null 2>&1 && logger -t wp-clamav-scan "INFECTED: $N hit(s), see $ALERT"

[ -f "$ALERT_ENV" ] || exit 1

# This file is executed as shell code, so refuse it unless only its owner can write to it.
# A group- or world-writable alert.env is arbitrary code execution as whoever runs the scan,
# typically root.
#
# `find -perm /022` is a GNU extension: on BSD and macOS it errors out, and with stderr
# discarded that reads as "not writable" - the check would fail OPEN on exactly the systems it
# was not tested on. This uses python3 and refuses to source the file if the mode cannot be
# determined at all.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$ALERT_ENV" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
try:
    st = os.stat(path)
except OSError:
    sys.exit(1)                      # cannot tell -> treat as unsafe

if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
    sys.exit(1)                      # someone else can rewrite it

# Mode alone is not enough. A file owned by a site user, mode 600, is still that user's code
# running as whoever launched the scan - typically root. Accept it only if it belongs to the
# running user or to root.
if st.st_uid not in (os.geteuid(), 0):
    sys.exit(2)

# The directory it sits in must not be writable by others either, or the file can be replaced.
parent = os.path.dirname(os.path.abspath(path)) or "."
try:
    pst = os.stat(parent)
except OSError:
    sys.exit(1)
if pst.st_mode & stat.S_IWOTH and not (pst.st_mode & stat.S_ISVTX):
    sys.exit(3)
sys.exit(0)
PY
  rc=$?
  case "$rc" in
    0) ;;
    2) echo "refusing to source $ALERT_ENV: it is not owned by the user running the scan or by root" >&2; exit 2 ;;
    3) echo "refusing to source $ALERT_ENV: its directory is world-writable, so the file can be replaced" >&2; exit 2 ;;
    *) echo "refusing to source $ALERT_ENV: it is group/world-writable or its mode cannot be read" >&2; exit 2 ;;
  esac
else
  echo "refusing to source $ALERT_ENV: python3 is unavailable, so its permissions cannot be verified" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$ALERT_ENV"
MSG="ClamAV: $N infected file(s) under WordPress on $(hostname). First lines: $(printf '%s\n' "$HITS" | head -5)"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -s --max-time 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${MSG}" >/dev/null 2>&1 \
    || logger -t wp-clamav-scan 'telegram alert failed'
fi

if [ -n "${ALERT_WEBHOOK:-}" ]; then
  curl -s --max-time 15 -H 'Content-Type: application/json' -X POST "$ALERT_WEBHOOK" \
    --data "$(printf '%s' "$MSG" | python3 -c 'import json,sys;print(json.dumps({"text":sys.stdin.read()}))')" >/dev/null 2>&1 \
    || logger -t wp-clamav-scan 'webhook alert failed'
fi
