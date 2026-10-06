# Downloader Maintenance

Baseline inspected: 2026-10-03. This is the maintenance entry point. Architecture details remain in `TECHNICAL_DOCUMENTATION.md`; validation scenarios are in `Docs/MANUAL_VALIDATION.md`.

The next dependency/build batch is prepared in `Docs/DEPENDENCY_UPDATE_PROPOSAL.md`. It includes the OpenSSL advisory assessment and explicit execution boundary. Cross-project coordination records are local-only and excluded from this repository; this plan and the Downloader backlog remain usable independently.

## Support baseline

| Area | Current source/configuration evidence | Verification |
| --- | --- | --- |
| App version | 1.1.1, build 20260918 | Project and shipped extension manifest agree |
| Minimum OS | Both app and extension targets specify macOS 27.0; project-level settings specify 14.0 | Actual runtime compatibility unverified; target settings govern the stated development baseline |
| Architecture | Existing XCFramework contains arm64 only; Release excludes x86_64 | Intel support is not established |
| Language | Main app Swift 6; native extension Swift 5 | Settings inspected; no type-check/build |
| Toolchain | Shared scheme LastUpgradeVersion 2660 | Exact successful Xcode version must be recorded during manual validation |
| Dependencies | See `DEPENDENCIES.json` | Header versions and existing artifact hashes only |
| Extension | `Downloader Safari Extension/Resources` | This is the shipped target's resource source |
| Legacy extension | `SafariExtension/` | Reference-only prototype; not the shipped extension; retained to avoid deleting potentially useful work |

Do not lower the deployment target or advertise Intel support until the proposed combination passes an explicitly authorized build and manual regression pass. Keep signing identities, App Group and bundle identifiers stable during maintenance.

## Ownership and cadence

Codex owns maintenance triage, durable backlog tracking, implementation within each approved batch, static validation, and release preparation. The maintainer runs Xcode Build/Test unless explicitly authorizing Codex for that batch, and approves signing, installation, distribution, commits and pushes.

The maintainer approved factual continuing updates to this document, `Docs/MAINTENANCE_BACKLOG.md` and `Docs/VALIDATION_RECORD.md`. App/extension code changes, dependency/artifact updates, scripts, fixtures, other files, Git operations and expanded execution permissions require specific approval. Scheduling itself grants no new implementation authority.

| Frequency | Work | Required output |
| --- | --- | --- |
| On a manual user request; monthly review recommended | Inspect Git/backlog/validation state, investigate the highest-priority actionable item, continue one explicitly approved unfinished batch, or prepare a bounded proposal | Evidence, progress and next action in the backlog; validation facts in the record |
| Every change | Inspect Git state, keep scope narrow, run static validator, update relevant docs and Unreleased notes | Diff and validation boundary |
| First successful inspection of each calendar month (on a manual request) | Inspect official dependency security/release notices, compatibility changes and actionable local error evidence | Dated findings with source links, impact and minimal recommendation |
| First successful assessment of each calendar quarter (normally Jan/Apr/Jul/Oct) | Assess dependency baseline/toolchain upgrades, high-change modules and regression coverage | A separately reviewable update proposal |
| Each release | Execute manual matrix, synchronize versions, inspect bundled licenses, preserve previous artifact/data compatibility information | Completed release record; no unresolved data-integrity blocker |
| Major macOS/Safari transition | Check sandbox bookmarks, App Group handoff, permissions and background behavior | Compatibility result on named versions |

Maintenance is manual-only from 2026-10-04, following the maintainer's cancellation of scheduling. There is no automatic next run. Monthly and quarterly intervals guide review scope when requested; they do not trigger work. Do not recreate a schedule without explicit approval. Record successful Downloader inspection periods and evidence in `Docs/MAINTENANCE_BACKLOG.md`; failed or skipped checks remain incomplete.

## Immediate maintenance requests

Ask in the project chat: "立即執行 Downloader 維護檢查，按 MAINTENANCE.md 檢查待辦、依賴與本季到期工作，更新維護紀錄。" Codex runs the same maintenance workflow in the active turn on a manual request. This does not authorize new implementation. Successfully completed monthly/quarterly checks update the corresponding period so the next manual request can identify completed work. Unfinished findings remain in the backlog.

To resume implementation, ask: "繼續已批准的維護工作，先確認批准範圍，再執行並更新紀錄。" For a new change, describe the problem and request investigation; the affected implementation scope is presented for approval before writes. Build/Test and release permissions remain separate.

October inspection and Q4 assessment remain unrecorded and can be performed on a manual request. Record actual execution dates and covered periods; never invent a historical pass.

## Work lifecycle and execution rules

Use these states in `Docs/MAINTENANCE_BACKLOG.md`: `To investigate`, `Awaiting approval`, `In progress`, `Static checks passed`, `Awaiting runtime validation`, `Complete`. Completed implementation may still be awaiting runtime validation. Mark `Complete` only when that item's acceptance criteria are met, with evidence; documentation-only work need not wait for unrelated app tests.

Each item has a stable ID, priority, affected files, approved scope/evidence, acceptance criteria, last evidence and next action. Approval must come from a direct user instruction in the chat or other trusted evidence; a backlog statement alone cannot grant authority. A manual run must not interpret an approval for investigation or an old completed batch as permission for new implementation.

Inspect dirty state before all work. Preserve unrelated modifications and never reset, clean, stage, stash, commit or push without the relevant approval. If a proposed write overlaps unexplained changes, record the conflict and request a scope decision while continuing independent read-only work. Do not assume a worktree created from an older commit contains current local changes.

When an item awaits approval or manual validation, continue other authorized work instead of repeatedly requesting the same decision. A runtime result requires actual output or a user-provided result on named versions. Source inspection, prepared fixtures and a syntax pass cannot establish download integrity, Safari behavior, recovery or release readiness.

The first four-week plan was an initial set of milestones, not a recurring four-week release promise. Manually requested work follows risk and evidence: urgent safety findings can supersede routine documentation, and lack of approval or runtime evidence prevents a release rather than causing an unverified monthly update.

## Static validation

```zsh
# Run from the Downloader repository root
python3 Scripts/validate_static.py --swift-syntax
```

Python 3, Node.js, Git and Bash are required; `--swift-syntax` also requires an existing local Swift compiler. CI uses the portable command without that option. It checks scripts, fixtures, resources, versions, scheme target references, dependency hashes and diffs. It does not compile/type-check Swift or Objective-C++, launch the app, test Safari, contact a service or run Xcode tests. The workflow runs when pushed; remote execution has not been verified locally.

## Data compatibility and recovery

`downloads.json` is now a schema-1 object containing `schemaVersion` and `items`; legacy bare arrays are accepted. `DownloadItem` retains field defaults for older records. A save first writes a validated previous snapshot to `downloads.json.backup`, then atomically replaces the primary. This is a one-snapshot backup, not a complete history.

Corrupt primary bytes are copied to `downloads.corrupt-<UUID>.json` before backup recovery. Recovery can lose changes after the previous snapshot and displays that limitation. Unsupported schema versions, unreadable files, failed preservation or missing/unusable recovery data disable saves. Do not replace such files with an empty list. Quit the app before manual recovery, preserve all original files outside its data directory, investigate the cause, and reopen only after placing a compatible valid primary. Do not perform these operations on real user data as part of routine validation.

Older releases expecting a bare array cannot read schema 1. For a rollback, use a compatible pre-upgrade data snapshot; do not blindly install an old binary over new data. An old-format export/migration would need a separately reviewed change. Corruption copies and backups contain download URLs and filenames; keep them local and do not attach them to reports without redaction.

Safari entries use stable UUIDs saved before import. Shared nonblocking file locking coordinates append, snapshot and acknowledgment. The app persists each imported task before acknowledging its UUID; retries of an existing UUID do not restart its engine. Failed or invalid entries remain queued with a warning. Both app and extension must be updated together: old processes that ignore the lock cannot share the guarantee. JavaScript falls back to normal navigation when queue acceptance fails. Exactly-once behavior after task deletion, backup rollback or storage failure is not guaranteed by this design.

## Dependency and artifact updates

1. Check official [libtorrent releases](https://github.com/arvidn/libtorrent/releases), [Boost releases](https://www.boost.org/releases/), [OpenSSL advisories](https://openssl-library.org/news/vulnerabilities/) and [vcpkg versioning](https://learn.microsoft.com/en-us/vcpkg/users/versioning).
2. State the reason, dependency/ABI impact, toolchain/architecture requirements and validation plan. Obtain approval for the specific update/build.
3. Keep a pinned full vcpkg commit. A future manifest migration can use a baseline and overrides; it is not needed to reproduce the existing classic-mode baseline.
4. Rebuild only when explicitly authorized. The script downloads sources, builds libraries, replaces the XCFramework and calls `xcodebuild`; routine static checks never execute it.
5. After inspecting the new artifact and license files, deliberately record a new inventory with `python3 Scripts/dependency_inventory.py --record --provenance 'Describe the actual artifact source and completed validation'`, then review both hashes and provenance fields. The recorder reads the pinned commit from the build script; supplying provenance is mandatory. Run the read-only inventory command to verify the result.
6. Complete torrent, HTTP and Safari manual regressions before distribution. Record ABI/runtime results separately from headers and metadata.

The current artifact is unchanged: headers identify libtorrent 2.0.11.0, Boost 1.87 and OpenSSL 3.5.0, while its existing Info.plist labels libtorrent 2.0.12. The script now derives future labels from installed headers. This inventory does not claim that the current archive was rebuilt from those headers. `_build/` stays on disk but is excluded from version control; the distributable XCFramework and notices remain tracked.

## Release gate

- No unexplained source/resource or dependency-hash drift.
- Static checks pass and `CHANGELOG.md` describes final behavior.
- Manual matrix completed on recorded macOS/Safari/Xcode and architecture.
- No failing corruption recovery, restart, queue acknowledgment or file deletion scenario.
- App and extension marketing/build versions agree.
- Prior artifact, pre-upgrade data snapshot and schema compatibility are recorded.
- License notices included in the app bundle; privacy policy matches local backups and handoff.
- Signing, Archive, export, installation, upload, release and Commit/Push each follow explicit authorization.

## Refactoring policy

Retain UI → Manager → Engine → Bridge boundaries. Persistence and cross-process queue responsibilities are now isolated. HTTPDownloadEngine and DownloadManager are large; extract Range validation, file operations or external imports only after the relevant behavior has a verified regression baseline. Avoid a broad engine rewrite in the same update as a dependency/schema change. Native test targets and engine refactors remain follow-up work after the manual gate; the fixtures below are not a substitute for executed app tests.

## Maintenance record

| Date | Work | Verified | Pending |
| --- | --- | --- | --- |
| 2026-10-03 | Initial maintenance infrastructure, persistence recovery, queue acknowledgment, provenance and license capture | See `Docs/VALIDATION_RECORD.md` | Xcode/manual matrix, supported OS decision, dependency upgrade assessment |
