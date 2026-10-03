# Changelog

## Unreleased

- Add schema-versioned download storage, a prior valid snapshot backup, corrupt-data preservation and visible persistence notices. Legacy arrays remain readable; unsupported data blocks saves.
- Save Safari imports before acknowledging queue entries. Coordinate cross-process queue changes with a lock and stable IDs; retain failed/invalid entries and fall back to browser navigation when acceptance fails.
- Remove raw download URLs/header details from native extension diagnostic logs.
- Pin the existing vcpkg baseline to its full commit; derive future libtorrent framework labels from installed headers.
- Record existing dependency hashes/header versions, bundle third-party notices and exclude intermediate `_build` data from Git while preserving local files.
- Add static validation CI, manual HTTP/persistence fixtures, a regression matrix, maintenance cadence and release gates. Remove the scheme reference to a nonexistent UI-test target.
- Correct documented deployment/architecture baseline. Runtime compatibility and current framework label mismatch remain explicitly unverified.

Validation: static checks only. Build/Test and manual regressions pending; this section is not a release announcement.

## 1.1.1 — existing baseline

Project version 1.1.1, build 20260918. Latest inspected commit `ff46fca` fixes Safari extension icons and context-menu initialization. This entry is derived from repository configuration/history; publication status is unverified.
