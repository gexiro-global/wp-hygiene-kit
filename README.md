# wp-hygiene-kit

[![CI](https://github.com/dzeusking-dev/wp-hygiene-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/dzeusking-dev/wp-hygiene-kit/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Read-only hygiene checks for hosts that serve many WordPress sites, built around one idea:
**find the sites you are actually serving, not the ones that happen to be on disk.**

| Script | What it does |
|---|---|
| `wp-discover.sh` | Lists every live WordPress install: served vhosts, extra roots you declare, Docker bind mounts. Deduplicated by realpath. Returns the installation root, so a scan covers core files and `wp-admin`, not only `wp-content`. |
| `wp-clamav-scan.sh` | Runs ClamAV across that set, at low priority, with per-run alerting. |
| `wp-permissions-check.sh` | Reports vhosts where the PHP user does not own `wp-content`. |

None of them modify, quarantine or repair a WordPress installation. `wp-clamav-scan.sh` does
write its own log files (and creates their directory), and sends an alert if you configure one -
that is the only thing any of them writes.

## Why discovery is the hard part

On a box with twenty sites, `clamscan -r /home` is the obvious approach and the wrong one. It
scans archived copies, old release directories and backup folders that are not served by anything,
which is where most of the runtime goes — and it silently misses containerised sites whose files
live under a Docker volume path you never listed.

`wp-discover` starts from the served set: vhost `docRoot` values, plus roots you explicitly name,
plus host paths resolved from running WordPress containers. Everything is deduplicated by
`realpath`, so a symlinked release directory and the vhost pointing at it count once.

It also tells you what it *cannot* see: containers with no resolvable host path are reported as
`host-scan blind`, because a host-side scanner genuinely cannot reach them and silently skipping
them would be worse than saying so.

## Install

```bash
git clone https://github.com/dzeusking-dev/wp-hygiene-kit.git
cd wp-hygiene-kit
./wp-discover.sh          # see what it finds before running anything else
```

Requires `bash`. `wp-clamav-scan.sh` additionally needs `clamav`; Docker discovery needs the
`docker` CLI and is skipped automatically if absent.

Tested against OpenLiteSpeed and CyberPanel vhost layouts. Other stacks work through
`WP_EXTRA_ROOTS`.

## Usage

```bash
./wp-discover.sh                                   # list live installs
./wp-permissions-check.sh                          # report ownership mismatches
./wp-clamav-scan.sh --list                         # dry inventory
sudo ./wp-clamav-scan.sh                           # scan

# non-OpenLiteSpeed hosts
WP_EXTRA_ROOTS="/srv/sites/*/public /var/www/*" ./wp-discover.sh
```

Nightly, via cron:

```cron
30 3 * * * cd /opt/wp-hygiene-kit && ./wp-clamav-scan.sh
```

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `WP_CONTENT_ONLY` | `0` | Set to `1` to scan only `wp-content` instead of the whole installation |
| `WP_SCAN_LOCK_DIR` | `/run/lock/wp-clamav-scan` (root) | Directory flock'd (opened read-only, never truncated) to prevent two concurrent scans; must be a non-symlink directory you own |
| `WP_ALLOW_BLIND` | unset | Set to `1` to accept containers with no resolvable host path; otherwise a clean visible scan with a blind container exits `2` (incomplete) |
| `OLS_VHOST_DIR` | `/usr/local/lsws/conf/vhosts` | Vhost config root |
| `WP_VHOST_HOME` | `/home` | Expansion for `$VH_ROOT` in `docRoot` |
| `WP_EXTRA_ROOTS` | *(unset)* | Space-separated globs of additional site roots |
| `WP_SKIP_DOCKER` | `0` | Set to `1` to skip container discovery |
| `WP_SCAN_LOG` | `/var/log/clamav/wp_scan.log` | Scan log |
| `WP_ALERT_LOG` | `/var/log/clamav/wp_scan_INFECTED.log` | Hits only |
| `WP_ALERT_ENV` | `./alert.env` | Optional Telegram/webhook credentials |

### Alerting

Copy `alert.env.example` to `alert.env`, `chmod 600`, fill in a Telegram bot or a JSON webhook.
`alert.env` is gitignored. If the file is absent, alerts go to the log and syslog only.

The alert reads **only the current run's block** from the log. A fixed `tail -n` re-alerts on old
hits every time a later run happens to be shorter, which trains you to ignore the alert.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Scan completed, nothing found |
| `1` | No WordPress installations were discovered - a configuration problem, deliberately not reported as "clean" |
| `2` | The scanner failed, or `alert.env` was refused; results are incomplete |
| `3` | `clamscan` is not installed |
| `4` | Another scan held the lock, so this run did not scan anything |

A scan that could not run is never reported as a clean one - including the case where another
run held the lock, which exits `4` rather than `0`.

## What this kit does NOT do

- It does not clean, quarantine, delete or repair anything. The only files any script writes
  are its own logs.
- It does not change ownership or permissions — `wp-permissions-check` reports, nothing else.
- ClamAV is a signature scanner. It catches commodity PHP malware and known droppers. It will not
  reliably catch a targeted or obfuscated backdoor, and a clean scan is not proof of a clean site.
- It scans the WordPress installation directory - core files, `wp-admin`, `wp-includes`,
  `wp-content` and anything else dropped in the document root. Set `WP_CONTENT_ONLY=1` for the
  narrower sweep if runtime matters more to you than coverage.
- It does not scan the database, and a large share of real WordPress compromise lives there.
- It does not check plugin or core versions. Use a dedicated tool for that.

## Limitations

Discovery is a text scan of vhost configuration files. Unusual layouts, include chains or templated
`docRoot` values can hide a site from it — always sanity-check `./wp-discover.sh` output against what
you know you host before trusting a scan to be complete.

## Testing

```bash
./tests/run_tests.sh
```

Runs against a synthetic vhost tree in a temp directory, with a stubbed scanner for the failure
paths. No real ClamAV, no Docker, no root, no network.

## License

Apache-2.0. See [LICENSE](LICENSE). These are server-side administration scripts and do not link
or derive from WordPress code, so no GPL obligation is inherited.

Built and maintained by Gexiro Global Enterprises Ltd.
