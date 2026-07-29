# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Added
- Initial public release.
- `wp-discover.sh`: served-vhost, declared-root and Docker bind-mount discovery with realpath dedup,
  plus explicit reporting of containers a host-side scan cannot reach.
- `wp-clamav-scan.sh`: low-priority ClamAV sweep of the discovered set, per-run alert extraction,
  optional Telegram and webhook transports.
- `wp-permissions-check.sh`: PHP user vs `wp-content` owner mismatch report.
- Offline test suite against a synthetic vhost tree.
