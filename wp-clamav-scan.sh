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
  nice -n 19 ionice -c3 clamscan -r -i \
    --exclude-dir='(node_modules|\.git|/cache|wflogs|uploads/cache|backup|backups|\.archived)' \
    --max-filesize=20M --max-scansize=100M "${WP_TARGETS[@]}"
  echo "clamscan rc=$?"
  echo "===== END $(ts) ====="
} >> "$LOG" 2>&1

# clamscan: 0 = clean, 1 = infections found, 2+ = the scanner itself failed. Treating a
# scanner failure as a clean result is how an unscanned host gets reported as healthy.
SCAN_RC=$(awk '/^clamscan rc=/{r=$0} END{sub(/^clamscan rc=/,"",r); print r+0}' "$LOG")
if [ "${SCAN_RC:-0}" -ge 2 ]; then
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
# A group- or world-writable alert.env in the working directory is arbitrary code execution
# as whoever runs the scan, which is typically root.
if [ -n "$(find "$ALERT_ENV" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
  echo "refusing to source a group/world-writable $ALERT_ENV (chmod 600 it)" >&2
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
