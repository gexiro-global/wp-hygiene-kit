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
#   WP_ALERT_ENV   default ./alert.env  (parsed as data, never sourced; see .example)
#   WP_SCAN_LOCK_DIR default /run/lock/wp-clamav-scan (root). A non-symlink directory
#                  you own, flock'd read-only (never truncated).
#   WP_ALLOW_BLIND set to 1 to accept containers that could not be resolved to a host
#                  path (otherwise a clean visible scan with a blind container exits 2)
#
# Exit: 0 clean | 1 infections found | 2 the scan could not be trusted | 3 clamscan missing
#       4 another scan was already running, so this one did not happen
#   plus every WP_/OLS_ variable understood by wp-discover.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=wp-discover.sh disable=SC1091
. "$HERE/wp-discover.sh"

LOG="${WP_SCAN_LOG:-/var/log/clamav/wp_scan.log}"
ALERT="${WP_ALERT_LOG:-/var/log/clamav/wp_scan_INFECTED.log}"
ALERT_ENV="${WP_ALERT_ENV:-./alert.env}"
LIST_ONLY=0; [ "${1:-}" = "--list" ] && LIST_ONLY=1

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
ts(){ date '+%F %T'; }


wp_discover

if [ "$LIST_ONLY" = "1" ]; then
  echo "discovered ${#WP_TARGETS[@]} WordPress target(s):"
  [ "${#WP_TARGETS[@]}" -gt 0 ] && printf '  %s\n' "${WP_TARGETS[@]}"
  [ "${#WP_CONTAINER_TARGETS[@]}" -gt 0 ] && { echo 'container targets:'; printf '  %s\n' "${WP_CONTAINER_TARGETS[@]}"; }
  [ "${#WP_CONTAINER_BLIND[@]}" -gt 0 ] && { echo 'WARNING - host-scan blind containers:'; printf '  %s\n' "${WP_CONTAINER_BLIND[@]}"; }
  exit 0
fi

# If the log cannot be appended to, the redirection below fails before clamscan ever runs and
# bash returns 1 - which in ClamAV's own convention means "infections found". An entirely
# unperformed scan would then be indistinguishable from a completed one. Fail here instead.
for _f in "$LOG" "$ALERT"; do
  if ! : 2>/dev/null >> "$_f"; then
    echo "cannot write to $_f - refusing to run a scan whose results cannot be recorded" >&2
    exit 2
  fi
done

if [ "${#WP_TARGETS[@]}" -eq 0 ]; then
  # Finding nothing to scan is not the same as finding nothing wrong. Exit non-zero so a
  # cron job cannot report a misconfigured host as a clean one.
  echo "[$(ts)] no WordPress targets discovered" >> "$LOG"
  echo "no WordPress installations discovered - check OLS_VHOST_DIR / WP_EXTRA_ROOTS" >&2
  exit 1
fi

command -v clamscan >/dev/null 2>&1 || { echo "clamscan not found - install clamav first" >&2; exit 3; }

# Two overlapping runs would interleave the shared log, which is also what the alert is
# extracted from - so a concurrent run can corrupt the very block used to decide whether
# anything was found. Take an exclusive lock and skip rather than queue.
# Fail closed, like the rest: the log this run appends to is also the source the alert is
# extracted from, so two overlapping scans can corrupt the very block used to decide whether
# anything was found. If the lock cannot be taken, do not scan.
# Lock a validated, owner-checked directory under /run/lock, opened READ-ONLY (a
# directory cannot be truncated). A fixed /tmp lock file opened with `>` let a local
# user pre-plant a symlink and make root truncate an arbitrary file (CWE-59). The
# whole ancestor chain is validated so a symlink/untrusted-owner parent cannot
# redirect where we create and open the lock.
command -v flock >/dev/null 2>&1 \
  || { echo "flock is required so two scans cannot interleave their log" >&2; exit 2; }
MY_UID=$(id -u)
if [ -n "${WP_SCAN_LOCK_DIR:-}" ]; then LOCK_DIR="$WP_SCAN_LOCK_DIR"
elif [ "$MY_UID" = "0" ]; then LOCK_DIR=/run/lock/wp-clamav-scan
elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then LOCK_DIR="$XDG_RUNTIME_DIR/wp-clamav-scan"
else LOCK_DIR="${TMPDIR:-/tmp}/wp-clamav-scan-$MY_UID"; fi
# Validate the whole ancestor chain: reject a symlink, an untrusted owner, or a
# world-writable ancestor that is NOT sticky. (A sticky world-writable dir such as
# /run/lock or /tmp is fine: sticky means only the owner can rename/delete an entry,
# so an attacker cannot swap our validated, owner-checked lock directory once created.)
_lp=$(dirname "$LOCK_DIR")
while :; do
  if [ -L "$_lp" ]; then echo "lock path ancestor is a symlink: $_lp" >&2; exit 2; fi
  if [ -e "$_lp" ]; then
    _lo=$(stat -c %u "$_lp" 2>/dev/null)
    if [ "$_lo" != "0" ] && [ "$_lo" != "$MY_UID" ]; then
      echo "lock path ancestor $_lp is owned by uid $_lo (not root or you)" >&2; exit 2
    fi
    _lm=$(stat -c %a "$_lp" 2>/dev/null); _lm=${_lm:-0}
    if [ "$(( (8#$_lm) & 2 ))" -ne 0 ] && [ "$(( (8#$_lm) & 512 ))" -eq 0 ]; then
      echo "lock path ancestor $_lp is world-writable and not sticky" >&2; exit 2
    fi
  fi
  _lpar=$(dirname "$_lp"); [ "$_lpar" = "$_lp" ] && break; _lp="$_lpar"
done
mkdir -p "$LOCK_DIR" 2>/dev/null
if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ] || [ "$(stat -c %u "$LOCK_DIR" 2>/dev/null)" != "$MY_UID" ]; then
  echo "unsafe lock dir $LOCK_DIR (must be a non-symlink directory owned by uid $MY_UID)" >&2; exit 2
fi
if ! { exec 8<"$LOCK_DIR"; } 2>/dev/null; then
  echo "cannot open lock dir $LOCK_DIR - refusing to scan unserialised" >&2
  exit 2
fi
# Exit 4, not 0: no scan was performed, and 0 is documented as "completed, nothing found".
# A cron job that treats a skipped run as a clean one is how a host stops being scanned
# without anyone noticing.
flock -n 8 || { echo "another scan is already running - skipping" >&2; exit 4; }

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

# Nothing found in the VISIBLE targets: the one path that may report success - but
# only if every discovered install was actually scanned. Containers whose host path
# could not be resolved were never scanned, so a clean visible result is INCOMPLETE,
# not clean, unless the operator explicitly accepts blind targets.
if [ "$SCAN_RC" -eq 0 ]; then
  if [ "${#WP_CONTAINER_BLIND[@]}" -gt 0 ] && [ "${WP_ALLOW_BLIND:-0}" != "1" ]; then
    echo "[$(ts)] INCOMPLETE visible targets clean, but ${#WP_CONTAINER_BLIND[@]} discovered container(s) could not be resolved to a host path and were NOT scanned - refusing to report clean (set WP_ALLOW_BLIND=1 to accept)" >> "$ALERT"
    printf 'not scanned (blind container): %s\n' "${WP_CONTAINER_BLIND[@]}" >> "$ALERT"
    echo "INCOMPLETE: ${#WP_CONTAINER_BLIND[@]} blind container(s) were not scanned; refusing to report clean" >&2
    exit 2
  fi
  exit 0
fi

# clamscan exited 1: infections were found. Everything below only decides how loudly to say
# so - the outcome is already settled.
#
# Alert on THIS run's block only. Tailing a fixed number of lines re-alerts on old hits
# whenever a later run happens to be short.
HITS=$(awk '/===== ClamAV WordPress scan START/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$LOG" \
        | grep ' FOUND$' || true)
# Deliberately NOT `[ -z "$HITS" ] && exit 0`. The verdict belongs to clamscan, which already
# told us it found something; the log parser only fills in the alert body. A format change, a
# truncated log or a missed match must never downgrade an infection to a clean run.
if [ -z "$HITS" ]; then
  HITS="(clamscan reported infections, but no FOUND lines could be read back from the log)"
  N="an unknown number of"
else
  N=$(printf '%s\n' "$HITS" | grep -c 'FOUND')
fi


{ echo "[$(ts)] ClamAV reported $N infected file(s) under WordPress - investigate:"; printf '%s\n' "$HITS"; } >> "$ALERT"
command -v logger >/dev/null 2>&1 && logger -t wp-clamav-scan "INFECTED: $N hit(s), see $ALERT"

# From here on an infection has been found. Whatever happens with alert delivery, this run
# must exit 1: a failed notification is not a reason to tell cron the host is clean.
[ -f "$ALERT_ENV" ] || exit 1

# The alert config is NOT sourced as shell code. Sourcing by pathname after a separate
# stat() is a TOCTOU: an attacker who controls a symlink in a sticky directory can point
# it at a safe file during the check and swap it before the source, running arbitrary
# code as root. Instead python3 opens the file ONCE with O_NOFOLLOW, validates that same
# file descriptor (fstat: regular file, owner root/us, not group/world-writable, trusted
# parent), reads it from that descriptor, and emits ONLY the allowlisted keys as
# shell-quoted assignments. There is no re-open by name and no code execution.
command -v python3 >/dev/null 2>&1 \
  || { echo "refusing to read $ALERT_ENV: python3 is unavailable, so it cannot be validated safely" >&2; exit 2; }
_alert_kv=$(python3 - "$ALERT_ENV" <<'PY'
import os, stat, sys, shlex
path = sys.argv[1]
ALLOW = {"TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "ALERT_WEBHOOK"}
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)   # never follow a final symlink
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)                                  # validate the OPEN fd, not a path
    if not stat.S_ISREG(st.st_mode):
        sys.exit(1)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        sys.exit(1)                                    # someone else can rewrite it
    if st.st_uid not in (os.geteuid(), 0):
        sys.exit(2)                                    # owned by a site user = their code
    parent = os.path.dirname(os.path.abspath(path)) or "."
    pst = os.stat(parent)
    if (pst.st_mode & stat.S_IWOTH) and not (pst.st_mode & stat.S_ISVTX):
        sys.exit(3)                                    # world-writable, non-sticky parent
    if pst.st_uid not in (os.geteuid(), 0):
        sys.exit(3)                                    # untrusted parent owner
    data = os.fdopen(fd, "r", closefd=False).read()
finally:
    os.close(fd)
out = []
for line in data.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].strip()
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    k = k.strip()
    if k not in ALLOW:
        continue
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    out.append("%s=%s" % (k, shlex.quote(v)))
print("\n".join(out))
PY
)
rc=$?
case "$rc" in
  0) ;;
  2) echo "refusing to read $ALERT_ENV: not owned by the scan user or root" >&2; exit 2 ;;
  3) echo "refusing to read $ALERT_ENV: its directory is world-writable or foreign-owned" >&2; exit 2 ;;
  *) echo "refusing to read $ALERT_ENV: group/world-writable, a symlink, or its mode cannot be read" >&2; exit 2 ;;
esac
# Only KEY='shell-quoted-value' for the three allowlisted keys reaches here, produced by
# shlex.quote - so this assigns data, it does not execute the file.
# shellcheck disable=SC2086
eval "$_alert_kv"
MSG="ClamAV: $N infected file(s) under WordPress on $(hostname). First lines: $(printf '%s\n' "$HITS" | head -5)"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  # The token goes in the URL, so passing it as an argument would expose it in the process list
  # to every local user. Hand curl the URL through a config stream on stdin instead.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
    | curl -s --max-time 15 -K - \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${MSG}" >/dev/null 2>&1 \
    || logger -t wp-clamav-scan 'telegram alert failed'
fi

if [ -n "${ALERT_WEBHOOK:-}" ]; then
  # A webhook URL frequently embeds a token in its path or query, so it is kept out of argv too.
  printf 'url = "%s"\n' "$ALERT_WEBHOOK" \
    | curl -s --max-time 15 -K - -H 'Content-Type: application/json' -X POST \
        --data "$(printf '%s' "$MSG" | python3 -c 'import json,sys;print(json.dumps({"text":sys.stdin.read()}))')" >/dev/null 2>&1 \
    || logger -t wp-clamav-scan 'webhook alert failed'
fi

# Explicit and unconditional: this run found an infection.
exit 1
