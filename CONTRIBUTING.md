# Contributing

Discovery support for other stacks (Plesk, cPanel, Caddy, plain nginx layouts) is the most useful
contribution, followed by bug reports with a reproducible directory layout.

## Ground rules

- Read-only stays read-only. No cleaning, quarantining or permission fixing — a tool that both
  detects and "repairs" WordPress malware is a tool that eventually destroys a customer's site.
- `shellcheck` must pass clean.
- New discovery logic needs a case in `tests/run_tests.sh` built from a synthetic tree.

## Support expectations

Best-effort maintenance, no SLA, no commercial support.
