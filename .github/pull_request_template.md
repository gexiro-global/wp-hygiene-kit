## Summary

Describe the change and why it is needed.

## Verification

- [ ] `shellcheck wp-discover.sh wp-clamav-scan.sh wp-permissions-check.sh tests/run_tests.sh` is clean
- [ ] `./tests/run_tests.sh` passes
- [ ] Any new fail-open path (an incomplete scan/check reported as clean) has a regression test

## Safety

These tools run as root. They do not modify site files; they scan/inspect and write only their
own logs and alert records.

- [ ] The change never reports "clean" when a discovered target was not actually scanned
      (e.g. a blind container) or when nothing was inspected.
- [ ] Configuration (`alert.env`) is parsed as data, never sourced as code.
- [ ] `Signed-off-by:` (DCO) present.
