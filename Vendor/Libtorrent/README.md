# Bundled libtorrent

Downloader will bundle `libtorrent-rasterbar` inside the app. End users should not install Homebrew, vcpkg, Boost, OpenSSL, or libtorrent.

Inspect the existing artifact without rebuilding:

```bash
python3 Scripts/dependency_inventory.py
```

`DEPENDENCIES.json` records existing header versions and binary/tree hashes.
The current libtorrent headers identify 2.0.11.0 while framework metadata labels
2.0.12; this is an unresolved provenance mismatch, not verified binary version evidence.
The build script pins vcpkg commit `ce613c41372b23b1f51333815feb3edd87ef8a8b`
and derives future framework labels from installed headers.

Only after explicit build approval, build the vendored XCFramework during development or release packaging:

```bash
Scripts/build_libtorrent_xcframework.sh
```

For a proposed universal Intel + Apple Silicon build (current artifact is arm64 only; target/header settings also require review):

```bash
Scripts/build_libtorrent_xcframework.sh --universal
```

Expected output:

```text
Vendor/Libtorrent/libtorrent-rasterbar.xcframework
```

After the XCFramework exists, link it from the app target and embed/sign it in the app bundle.

The script fetches/builds dependencies, replaces its output and invokes
`xcodebuild -create-xcframework`; static validation never runs it. `_build/` is
excluded from Git. `THIRD_PARTY_NOTICES.txt` contains exact installed-package
notices and is an app resource. Update notices and the inventory deliberately
after an approved dependency change; never mask unexpected hash drift.
