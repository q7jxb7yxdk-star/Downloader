#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/Libtorrent"
BUILD_DIR="$VENDOR_DIR/_build"
VCPKG_DIR="$BUILD_DIR/vcpkg"
INSTALL_DIR="$BUILD_DIR/install"
FRAMEWORK_DIR="$BUILD_DIR/framework"
OUTPUT_XCFRAMEWORK="$VENDOR_DIR/libtorrent-rasterbar.xcframework"
# Immutable commit behind the previously used 2025.04.09 tag.
VCPKG_COMMIT="ce613c41372b23b1f51333815feb3edd87ef8a8b"

ARCHS=("arm64")

usage() {
  cat <<EOF
Usage: $(basename "$0") [--universal]

Builds a bundled libtorrent-rasterbar XCFramework for Downloader.

Options:
  --universal   Build arm64 and x86_64 slices. Default builds arm64 only.

Output:
  $OUTPUT_XCFRAMEWORK

Notes:
  This is a developer/package-time step. App users do not install Homebrew,
  vcpkg, libtorrent, Boost, or OpenSSL.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      ARCHS=("arm64" "x86_64")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required build tool: $1" >&2
    exit 1
  fi
}

require_tool git
require_tool curl
require_tool pkg-config
require_tool xcodebuild

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$FRAMEWORK_DIR"

if [[ ! -d "$VCPKG_DIR/.git" ]]; then
  git clone https://github.com/microsoft/vcpkg.git "$VCPKG_DIR"
fi

git -C "$VCPKG_DIR" fetch --tags --quiet
git -C "$VCPKG_DIR" checkout "$VCPKG_COMMIT"
"$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics

make_triplet() {
  local arch="$1"
  local triplet="$BUILD_DIR/${arch}-osx-static.cmake"
  cat > "$triplet" <<EOF
set(VCPKG_TARGET_ARCHITECTURE ${arch})
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_OSX_DEPLOYMENT_TARGET 14.0)
EOF
  echo "$triplet"
}

framework_for_arch() {
  local arch="$1"
  local triplet_file
  triplet_file="$(make_triplet "$arch")"
  local triplet_name
  triplet_name="$(basename "$triplet_file" .cmake)"
  local prefix="$VCPKG_DIR/installed/$triplet_name"
  local framework="$FRAMEWORK_DIR/$arch/libtorrent-rasterbar.framework"

  "$VCPKG_DIR/vcpkg" install "libtorrent" \
    "--overlay-triplets=$BUILD_DIR" \
    "--triplet=$triplet_name" >&2

  if [[ ! -d "$prefix/lib" || ! -d "$prefix/include" ]]; then
    echo "vcpkg did not produce expected install prefix: $prefix" >&2
    exit 1
  fi

  rm -rf "$framework"
  mkdir -p "$framework/Headers" "$framework/Modules"

  static_libs=(
    "$prefix/lib/libtorrent-rasterbar.a"
    "$prefix/lib/libssl.a"
    "$prefix/lib/libcrypto.a"
  )

  while IFS= read -r lib; do
    static_libs+=("$lib")
  done < <(find "$prefix/lib" -maxdepth 1 -name 'libboost_*.a' -print | sort)

  libtool -static "${static_libs[@]}" -o "$framework/libtorrent-rasterbar"

  rsync -a "$prefix/include/" "$framework/Headers/"

  cat > "$framework/Modules/module.modulemap" <<'EOF'
framework module libtorrent_rasterbar {
  umbrella header "libtorrent_rasterbar.h"
  export *
  module * { export * }
}
EOF

  cat > "$framework/Headers/libtorrent_rasterbar.h" <<'EOF'
#pragma once
#include <libtorrent/session.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_status.hpp>
EOF

  # Use the installed headers instead of claiming a hard-coded version.
  local torrent_version
  torrent_version="$(awk '/^#define LIBTORRENT_VERSION_(MAJOR|MINOR|TINY) / {printf "%s%s", separator, $3; separator="."}' "$prefix/include/libtorrent/version.hpp")"
  if [[ ! "$torrent_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unable to read the installed libtorrent version" >&2
    exit 1
  fi

  cat > "$framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>libtorrent-rasterbar</string>
  <key>CFBundleIdentifier</key>
  <string>org.libtorrent.rasterbar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>libtorrent-rasterbar</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>$torrent_version</string>
  <key>CFBundleVersion</key>
  <string>$torrent_version</string>
</dict>
</plist>
EOF

  printf '%s\n' "$framework"
}

framework_args=()
for arch in "${ARCHS[@]}"; do
  framework_args+=("-framework" "$(framework_for_arch "$arch")")
done

rm -rf "$OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework "${framework_args[@]}" -output "$OUTPUT_XCFRAMEWORK"

echo "Built $OUTPUT_XCFRAMEWORK"
