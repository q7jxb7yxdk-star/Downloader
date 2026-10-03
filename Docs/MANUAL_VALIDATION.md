# Manual Regression Matrix

All scenarios are pending runtime verification. Use an isolated macOS account/app-data directory and disposable download folder. Never replace production `downloads.json`, queue or bookmarks for fixture experiments. The maintainer starts/stops fixture processes and runs Xcode; static validation does neither.

Record date, commit/diff, macOS, Safari, Xcode, architecture, app/extension version, scenario, expected/actual result and redacted logs in `Docs/VALIDATION_RECORD.md`. A parse pass is not a runtime pass.

## HTTP fixture

Start manually in a terminal and stop with Control-C:

```zsh
cd '/Users/sunnyyu/Documents/Xcode/Downloader'
python3 Tests/HTTP/fixture_server.py --port 8877
```

The server binds only `127.0.0.1`, produces deterministic 8 MiB bytes and prints SHA256 values. Compare downloaded hashes with `shasum -a 256 '/path/to/disposable/output'`. If local-network permissions prevent access, record the failure instead of changing app security settings without review.

| Scenario | Input/action | Expected result |
| --- | --- | --- |
| Ordinary/segmented | `http://127.0.0.1:8877/file.bin` | Completion hash matches fixture; no duplicate bytes |
| Range ignored | `/no-range` | Safe single-stream fallback; complete file hash matches |
| Redirect | `/redirect` | Final content downloaded once |
| Unknown length | `/unknown-length` | Completion without false percentage or truncated content |
| Filename | `/filename`, also import from Safari | UTF-8 filename handled safely; file content unchanged |
| Rate limit | `/rate-limit` | Bounded retries/failure; no endless active task or bad final file |
| Connection interruption | `/disconnect` | Retry or useful failure; never mark incomplete content complete |
| Pause/resume | Throttled local source or a larger disposable payload; pause and resume | Preserved partial bytes; final SHA matches original |
| Restart resume | Quit during partial download, reopen and resume | Paused state restored; no fake running state; final SHA correct |
| Changed resource | Download part of `/file.bin`, pause; replace server content at the same URL, then resume | No mixed old/new payload accepted as complete; currently unverified |
| Disk full / permission revoked | Disposable volume or folder only | Visible error; originals preserved; no success notification |
| Same name | Two downloads with same destination filename | No unexplained overwrite/corruption; record observed policy |

`/changed` has reversed bytes and a different ETag, but changing the URL does not simulate an identity change at the same URL. For that case, deliberately substitute the fixture's payload under the same route in a disposable copy before restarting the server. The fixture is not a full TLS, auth, latency or HTTP conformance test. HTTP validator-based safe resume remains an explicit assessment item; the current engine has Content-Range checks but no ETag/If-Range mechanism was found during inspection.

## Persistence

Fixtures are in `Tests/Fixtures/Persistence`. Exercise these in a disposable environment after building; they are input samples, not an installed XCTest target.

| Scenario | Expected result |
| --- | --- |
| Legacy array | Stable ID preserved, downloading restored as paused, speeds zero; next save uses schema 1 |
| Schema 1 | List loads; sequential saves leave the previous valid snapshot in `.backup` |
| Corrupt primary + valid backup | Exact corrupt bytes preserved under a unique filename, backup loaded, recovery warning shown |
| Corrupt primary without usable backup | Save blocked, original retained; adding a task does not start an engine |
| Unsupported schema + valid older backup | No silent downgrade; save blocked and original retained |
| Unreadable primary or failed preservation | Save blocked; no replacement |
| Failed backup write / disk full | Primary not replaced; error shown |
| Rollback to old app | Pre-upgrade snapshot used; newer schema not silently discarded |

## Safari handoff

- App closed, app open, and app showing a filtered list: eligible link arrives in All and is selected.
- Multiple rapid links and concurrent app acknowledgment: each accepted queue ID survives until task persistence.
- Interrupt between task save and queue acknowledgment: restart imports no second task for the same ID and does not restart an existing engine.
- Lock contention: queue remains intact and app retries; failed extension acceptance leaves browser navigation usable.
- Corrupt/invalid queue, unwritable queue, failed task save: content retained, warning appears where applicable, no false acceptance.
- Legacy string/object queues: UUID migration saved before import; restart preserves IDs.
- Direct and ambiguous probed downloads: queued=false/error falls back to navigation; queued=true avoids duplicate browser download.
- Capture setting disabled, permissions revoked, extension reload and fresh Safari startup: setting/menu behavior correct.
- Context-menu command, external-app navigation, magnet and remote `.torrent`: handoff works and logs do not expose signed URLs.
- Update app and extension together; do not run an old extension process against the new queue protocol.

## Torrent, file actions and UI

Use a local/test torrent containing disposable files with independently known hashes and a controlled peer; do not use copyrighted downloads or production peers as validation fixtures.

- Magnet metadata, local and remote `.torrent`, multi-file selection, changing selection during transfer.
- Pause/resume/restart, no peers, seeding pause/resume, completion notification delivered once.
- Final file hashes and incomplete `.tmp` naming.
- Delete → Restore preserves tasks; Delete with Files and permanent Trash deletion move only intended files to system Trash.
- Missing bookmark/folder, filename Unicode, multi-selection and Finder reveal.
- App bundle contains `THIRD_PARTY_NOTICES.txt`; sandbox/bookmark access and main/extension versions match.

## Pass policy

Do not release with a failed or unverified data-integrity scenario. Record externally dependent scenarios separately from local ones. Do not claim macOS 14 or Intel compatibility until those configurations have an approved successful build and runtime pass.
