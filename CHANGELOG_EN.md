# Changelog

English | [简体中文](CHANGELOG.md)

This file records notable features, fixes, and compatibility changes for Mi BE6500 Pro Monitor.

## [1.1.0] - 2026-07-16

### Fixed

- Fixed an issue where the dashboard and `/metrics.json` could take several minutes to respond after the service had been running for a long time.
- Added periodic listener wake-ups to prevent a missed accept event from leaving the HTTP server blocked on the Xiaomi router kernel.
- Added request-header, read, write, and idle timeouts so abnormal connections cannot hold server resources indefinitely.
- Cached the embedded dashboard and ECharts assets in memory when the server starts instead of reading them again for every request.
- Hardened PID, lock-file, and background-process detection to reduce duplicate starts, incorrect stops, and stale locks.

### Added

- Added `rmmon check-update`, `rmmon update`, and matching online-update entries in the interactive menu.
- Added a version file and `router-monitor -version`; the management menu now displays the installed version.
- Added automatic fallback between GitHub Raw and jsDelivr update sources.
- Added a dedicated log file and the `rmmon log` command.

### Security and reliability

- Install and update packages are verified against a fixed SHA-256 manifest.
- Updates are transactional: the current installation is backed up first, and startup or health-check failures automatically restore the previous version.
- Listening port, sampling interval, update source, and boot settings are preserved during updates.
- Update sources must use HTTPS by default; HTTP is available only through an explicitly enabled insecure test mode.
- Configuration files are parsed through a field allowlist instead of being executed as shell code.
- Installation paths are restricted to `/data/other_vol/`, with traversal and symbolic-link bypass protection.

### Tests and builds

- GitHub Actions runs Go unit tests, integration tests, BusyBox `ash` compatibility checks, and release-asset validation.
- Linux ARM64 binaries and `checksums.txt` are generated automatically.
- Installation, reinstallation, online checks, port-conflict rollback, and service health were verified on a Xiaomi BE6500 Pro.

Earlier versions did not maintain a dedicated changelog; refer to the repository commit history for older changes.
