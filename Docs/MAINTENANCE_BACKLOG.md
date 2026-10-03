# Maintenance Backlog

Updated: 2026-10-03 (Asia/Hong_Kong). This file tracks Downloader-specific work and successful inspection periods. See `../MAINTENANCE.md` for execution and approval rules. Cross-project coordination records are local-only and are not required to use this backlog.

## Cadence state

| Field | Value |
| --- | --- |
| Scheduled cadence | Monthly local check, day 1 at 10:00 Asia/Hong_Kong |
| Last observed successful scheduled run | None observed |
| Last completed monthly inspection period | Not recorded; the initial OpenSSL lookup was not a complete monthly inspection |
| Last completed quarterly assessment period | Not recorded |
| Next monthly inspection due | 2026-10 |
| Next quarterly assessment due | 2026-Q4 |

After a successful monthly inspection or quarterly assessment, record its period and evidence in the run log. Derive subsequent due periods from the current calendar month/quarter; retry missed/failed checks rather than assuming completion. The next planned monthly opportunity is 2026-11-01, conditional on local scheduler availability. October/Q4 checks remain unrecorded and may be performed immediately on request; immediate completion uses the same period tracking. Missed historical runs must not be recorded as successful.

## Standing authorization

Direct user approval covers factual ongoing updates to `MAINTENANCE.md`, this file and `Docs/VALIDATION_RECORD.md`. App code, scripts, fixtures, dependencies, other files, Build/Test, simulators, installation, service changes, Git operations and releases need specific authorization. Read-only investigation may proceed immediately.

## Active items

| ID / priority | State | Scope and acceptance | Approval / evidence | Next action |
| --- | --- | --- | --- | --- |
| M-001 / P0 | Awaiting runtime validation | Existing DownloadStore, DownloadManager and Safari handoff changes. Corrupt/future-schema data remains protected; accepted queue entries persist before acknowledgment; restart/concurrency/fallback scenarios pass on recorded versions. | Initial implementation approved in this chat; static checks passed in the earlier implementation record. No runtime pass or new write authorization. | Review source read-only; consolidate exact manual scenarios and request actual Xcode/runtime results. Preserve the implementation and unrelated local changes. |
| M-002 / P1 | To investigate | Dependency provenance and security. Choose exact supported libtorrent/Boost/OpenSSL baseline, establish compatibility and artifact provenance, then validate a separately approved rebuild. | `DEPENDENCIES.json` and `DEPENDENCY_UPDATE_PROPOSAL.md` contain header/hash evidence and an initial advisory assessment. No upgrade/build approval. | Read current official release/advisory sources; present the pinned-version proposal and necessary build scope. |
| M-003 / P1 | To investigate | HTTP resource identity on resume at the same URL. No mixed old/new bytes accepted as a completed file; local repeatable scenario with hash verification. | Existing manual matrix records no ETag/If-Range mechanism found; runtime behavior unverified. Investigation allowed; new implementation requires approval. | Inspect current resume paths and propose a narrow validator/update batch with affected files. |
| M-004 / P1 | To investigate | Supported macOS/toolchain/architecture baseline matches actual build and runtime results. | Targets specify 27.0; project-level settings 14.0; current XCFramework arm64-only. No support-setting change approval. | Inspect SDK/API requirements read-only; obtain the intended support range and actual successful Xcode version before proposing setting changes. |
| M-005 / P2 | Awaiting approval | Native regression target and controlled fixtures cover persistence, queue and HTTP edge cases; tests execute meaningfully. | Input fixtures and manual checklist exist; no native test target or executed app tests. | Prepare a bounded test-target proposal; obtain implementation and execution authorization separately. |
| M-006 / P2 | Awaiting runtime validation | Release gate: validated implementation, consistent versions/docs, bundled notices, preserved pre-upgrade data and prior artifact; approved release actions. | Workflow/checklists prepared; no dependency rebuild, runtime pass or release authorization. | Track M-001 through M-005 results; prepare a release candidate only when relevant gates pass. Never set a release date solely from the schedule. |
| M-007 / P1 | In progress | Downloader participation in local monthly maintenance and durable records. Preserve project findings and verify actual scheduler execution. | Maintenance workflow and three-file standing authorization approved 2026-10-03; cadence revised to monthly on direct user request. Saved monthly configuration verified; actual scheduling not yet observed. | Observe the first actual monthly run and record Downloader evidence before marking operationally complete. |

Priority order: P0 data-integrity investigation first; perform due monthly/quarterly checks and independent read-only work while manual validation or approval is pending. Do not equate a proposal or a prepared input fixture with completed implementation/test execution.

## Run log

| Date / trigger | Work / evidence | Status / next action |
| --- | --- | --- |
| 2026-10-03 / user approval | Replaced the monthly-only maintenance design with a weekly continuation workflow; established lifecycle, standing document authorization and pending acceptance gates. Saved TOML verified: same ID/chat, ACTIVE, Monday 10:00; document/diff checks passed. | First planned opportunity 2026-10-05; no actual scheduled run, app Build/Test, code change or release performed in this batch. |
| 2026-10-03 / user cadence change | Replaced the same heartbeat with day 1 monthly 10:00; retained quarterly due checks, approval limits and same chat. Immediate user requests follow the same workflow and period tracking. | Next planned run 2026-11-01; October/Q4 inspections still due. No app source, Build/Test or release changes. |
| 2026-10-03 / portfolio approval | Local cross-project scheduling coordination established; Downloader M-001 through M-007 findings retained. | No monthly, quarterly or runtime inspection marked complete by enrollment; record Downloader results here after actual inspection. |

Append concise entries for meaningful work, completed period checks and failures. Do not append repetitive unchanged entries or use this log as substitute authorization. Remove a due flag only after recording successful completion.
