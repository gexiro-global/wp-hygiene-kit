#!/bin/bash
# wp-discover - find every WordPress installation actually being served on this host.
#
# Sourced by the other scripts, and runnable on its own to see what they would act on.
#
# Discovery sources:
#   1. OpenLiteSpeed / CyberPanel vhost docRoots  (the SERVED set, not whatever is on disk)
#   2. Extra roots you name yourself                (WP_EXTRA_ROOTS)
#   3. Docker containers whose name looks like WordPress, via their host bind mounts
#
# Results are deduplicated by realpath, so symlinked release directories, stale copies and
# the same site reached through two vhosts are counted once.
#
# Environment:
#   OLS_VHOST_DIR    default /usr/local/lsws/conf/vhosts
#   WP_VHOST_HOME    default /home            (used to expand $VH_ROOT in docRoot values)
#   WP_EXTRA_ROOTS   space-separated globs, e.g. "/srv/sites/*/public"
#   WP_SKIP_DOCKER   set to 1 to skip container discovery
set -uo pipefail

declare -A _WP_SEEN
WP_TARGETS=(); WP_CONTAINER_TARGETS=(); WP_CONTAINER_BLIND=()

_wp_add(){
  local d="$1" rp
  [ -d "$d" ] || return 0
  rp=$(realpath "$d" 2>/dev/null || echo "$d")
  [ -n "${_WP_SEEN[$rp]:-}" ] && return 0
  _WP_SEEN[$rp]=1
  WP_TARGETS+=("$rp")
}

wp_discover(){
  local vhost_dir="${OLS_VHOST_DIR:-/usr/local/lsws/conf/vhosts}"
  local vhost_home="${WP_VHOST_HOME:-/home}"

  # 1. served vhosts
  local f dom dr
  for f in "$vhost_dir"/*/vhost.conf; do
    [ -f "$f" ] || continue
    dom=$(basename "$(dirname "$f")")
    dr=$(grep -iE '^[[:space:]]*docRoot' "$f" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$dr" ] && continue
    dr=${dr//\$VH_ROOT/${vhost_home}/${dom}}
    _wp_add "$dr/wp-content"
  done

  # 2. operator-declared extra roots
  local glob d
  for glob in ${WP_EXTRA_ROOTS:-}; do
    for d in $glob; do
      [ -d "$d/wp-content" ] && _wp_add "$d/wp-content"
      [ "$(basename "$d")" = "wp-content" ] && _wp_add "$d"
    done
  done

  # 3. docker bind mounts
  if [ "${WP_SKIP_DOCKER:-0}" != "1" ] && command -v docker >/dev/null 2>&1; then
    local c src found
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'wordpress|wp[-_]'); do
      found=0
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        if [ -d "$src/wp-content" ]; then
          _wp_add "$src/wp-content"; WP_CONTAINER_TARGETS+=("$c -> $src/wp-content"); found=1
        elif [ "$(basename "$src")" = "wp-content" ] && [ -d "$src" ]; then
          _wp_add "$src"; WP_CONTAINER_TARGETS+=("$c -> $src"); found=1
        fi
      done < <(docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
      [ "$found" = 0 ] && WP_CONTAINER_BLIND+=("$c")
    done
  fi
}

# Standalone mode: print what was found and exit.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  wp_discover
  echo "discovered ${#WP_TARGETS[@]} wp-content target(s):"
  [ "${#WP_TARGETS[@]}" -gt 0 ] && printf '  %s\n' "${WP_TARGETS[@]}"
  if [ "${#WP_CONTAINER_TARGETS[@]}" -gt 0 ]; then
    echo 'container targets:'; printf '  %s\n' "${WP_CONTAINER_TARGETS[@]}"
  fi
  if [ "${#WP_CONTAINER_BLIND[@]}" -gt 0 ]; then
    echo 'WARNING - containers with no resolvable host path (a host-side scan cannot see these):'
    printf '  %s\n' "${WP_CONTAINER_BLIND[@]}"
  fi
fi
