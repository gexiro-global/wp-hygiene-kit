# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Security
- `wp-clamav-scan.sh` locks a validated, owner-checked `/run/lock` directory opened
  read-only (whole ancestor chain validated), replacing a predictable `/tmp` lock file
  opened with `>` that a local user could redirect at an arbitrary root-writable file
  (CWE-59). Lock env var is now `WP_SCAN_LOCK_DIR`.
- `alert.env` is no longer sourced as shell code. It is opened once with `O_NOFOLLOW`,
  the open descriptor is validated (regular file, owned by root/you, not group/world-
  writable, trusted parent), and only allowlisted keys are parsed as data - closing a
  stat-then-source symlink TOCTOU that could run attacker code as root.

### Fixed
- A clean scan of the visible targets no longer reports "clean" when a discovered
  container could not be resolved to a host path and was never scanned: it exits `2`
  (incomplete) unless `WP_ALLOW_BLIND=1`.
- `wp-permissions-check.sh` exits `2` when it inspected nothing (missing/unreadable
  vhost tree or no eligible WordPress vhost) instead of reporting a clean `0`.

### Added
- Initial public release.
- `wp-discover.sh`: served-vhost, declared-root and Docker bind-mount discovery with realpath dedup,
  plus explicit reporting of containers a host-side scan cannot reach.
- `wp-clamav-scan.sh`: low-priority ClamAV sweep of the discovered set, per-run alert extraction,
  optional Telegram and webhook transports.
- `wp-permissions-check.sh`: PHP user vs `wp-content` owner mismatch report.
- Offline test suite against a synthetic vhost tree.
