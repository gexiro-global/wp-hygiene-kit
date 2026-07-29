# Security Policy

## Supported Versions

`wp-hygiene-kit` v0.x is maintained on the latest v0.x release line.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if enabled, otherwise email `admin@gexiro.com`.

Reproduce against the synthetic tree built by `tests/run_tests.sh`. Do not send real vhost
configurations, site paths, or scan output from a production host.

## Threat model

These scripts read vhost configuration, stat directories, and invoke `clamscan`. They write only to
their own log files.

Two things to be aware of before running them as root:

- Discovery follows `docRoot` values out of configuration files and resolves symlinks. If an
  untrusted party can write your vhost configs, they can direct the scanner at arbitrary paths.
- `wp-clamav-scan` sources `alert.env` as shell. That file must be operator-owned and `chmod 600`;
  anything writable by a site user becomes code execution as the scanning user.

A clean ClamAV result is not an assurance of integrity. Do not use this kit as the sole basis for
declaring a compromised site clean.
