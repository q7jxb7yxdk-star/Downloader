# Bundled libtorrent

Downloader will bundle `libtorrent-rasterbar` inside the app. End users should not install Homebrew, vcpkg, Boost, OpenSSL, or libtorrent.

Build the vendored XCFramework during development or release packaging:

```bash
Scripts/build_libtorrent_xcframework.sh
```

For a universal Intel + Apple Silicon build:

```bash
Scripts/build_libtorrent_xcframework.sh --universal
```

Expected output:

```text
Vendor/Libtorrent/libtorrent-rasterbar.xcframework
```

After the XCFramework exists, link it from the app target and embed/sign it in the app bundle.
