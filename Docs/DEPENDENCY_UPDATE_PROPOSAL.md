# Dependency Update Proposal

Prepared 2026-10-03. No dependency was upgraded or rebuilt in this maintenance change.

## Evidence and priority

The existing XCFramework headers identify OpenSSL 3.5.0, Boost 1.87 and libtorrent 2.0.11.0. Its binary provenance is not conclusively established, because the existing framework label says libtorrent 2.0.12. The inventory preserves this discrepancy instead of changing metadata to assert an unverified binary version.

The official [OpenSSL vulnerability list](https://openssl-library.org/news/vulnerabilities/) places 3.5.0 in affected ranges for subsequent advisories, including CVE-2025-9230 (CMS password-based decryption), CVE-2025-9231 (SM2 on 64-bit ARM) and CVE-2025-9232 (OpenSSL HTTP-client no_proxy handling). Those entries list fixes in 3.5.4. This is evidence that 3.5.0 needs review, not a claim that all these code paths are reachable in Downloader. Later 2026 advisories also exist, so 3.5.4 is not being recommended as the current upgrade destination. Select a currently supported patched version after inspecting the complete advisory list at update time.

## Proposed next batch

1. Choose a pinned vcpkg commit containing a supported patched OpenSSL release and compatible libtorrent/Boost packages, using official upstream release/security notes. Record exact versions and potential API/ABI changes before editing the baseline.
2. Keep Apple Silicon as the current scope. Adding Intel or lowering macOS minimum requires separate compatibility work, including the hard-coded arm64 header path.
3. Rebuild the dependency artifact in an isolated staging directory; retain the current XCFramework until headers, archive, licenses, versions and hashes have been inspected. The current script replaces its output, so prepare isolation before invoking it.
4. Update script/inventory/notices from the inspected result. Complete an authorized Xcode build and the HTTP/torrent/Safari regression matrix. Do not distribute solely on syntax or hash checks.

## Approval boundary

The next batch downloads sources, executes third-party build tooling, writes build outputs and invokes `xcodebuild -create-xcframework`. App Build/Test and runtime validation also require explicit authorization under the supplied AGENTS.md. This proposal is reviewable preparation; none of those commands were run. Commit/Push, signing, installation and publication remain separate operations.

## Other follow-up gates

- Validate HTTP resume when the server changes bytes at the same URL. No ETag/If-Range mechanism was found in the current engine; Content-Range validation alone does not establish resource identity. A narrowly scoped validator/resume update should follow the manual baseline.
- Establish a real native test target only after Xcode build/test scope is agreed; the current input fixtures and checklist do not execute app behavior.
- Reconcile supported macOS versions with actual SDK and runtime results before changing target settings or advertising older-system support.
