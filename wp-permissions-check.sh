#!/bin/bash
# wp-permissions-check - report vhosts where the PHP user does not own wp-content.
#
# On OpenLiteSpeed/CyberPanel each vhost runs PHP as an external user (extUser). When
# wp-content is owned by a different user the usual outcomes are: WordPress cannot write
# (updates and uploads fail), or the permissions get widened until it can - which is how
# a single compromised site ends up able to write into its neighbours.
#
# This script only reports. It changes no ownership and no permissions.
#
# Usage: wp-permissions-check.sh [--quiet]
# Environment: OLS_VHOST_DIR (default /usr/local/lsws/conf/vhosts)
# Exit: 0 no mismatches | 1 at least one mismatch
set -uo pipefail

VHOST_DIR="${OLS_VHOST_DIR:-/usr/local/lsws/conf/vhosts}"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
MISMATCH=0; CHECKED=0

[ "$QUIET" = "0" ] && echo '=== WordPress ownership check ==='

for vhost in "$VHOST_DIR"/*/vhost.conf; do
  [ -f "$vhost" ] || continue
  domain=$(basename "$(dirname "$vhost")")
  extuser=$(grep -i 'extUser' "$vhost" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*[eE][xX][tT][uU][sS][eE][rR][[:space:]]+//; s/[[:space:]]+$//')
  # Strip the directive name rather than taking field 2, so a docRoot containing spaces is
  # checked instead of silently skipped.
  docroot=$(grep -iE '^[[:space:]]*docRoot' "$vhost" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*[dD][oO][cC][rR][oO][oO][tT][[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$docroot" ] && continue
  docroot=${docroot//\$VH_ROOT/${WP_VHOST_HOME:-/home}/${domain}}
  [ -d "$docroot/wp-content" ] || continue

  CHECKED=$((CHECKED+1))
  owner=$(stat -c '%U' "$docroot/wp-content" 2>/dev/null || echo UNKNOWN)
  [ -z "$extuser" ] && extuser=UNSET

  if [ "$extuser" != "$owner" ]; then
    MISMATCH=$((MISMATCH+1))
    echo "MISMATCH  $domain"
    echo "          php user : $extuser"
    echo "          wp-content owner: $owner"
    echo "          path     : $docroot"
  fi
done

if [ "$QUIET" = "0" ]; then
  echo "=== checked $CHECKED WordPress vhost(s), $MISMATCH mismatch(es) ==="
fi
[ "$MISMATCH" -eq 0 ]
