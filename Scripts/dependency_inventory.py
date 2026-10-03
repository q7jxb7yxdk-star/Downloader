#!/usr/bin/env python3
"""Inspect vendored files without installing, building, or contacting a server."""
import argparse
import hashlib
import json
import plistlib
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "DEPENDENCIES.json"
FRAMEWORK = ROOT / "Vendor/Libtorrent/libtorrent-rasterbar.xcframework"


def inspect():
    info = plistlib.loads((FRAMEWORK / "Info.plist").read_bytes())
    libraries = []
    digest = hashlib.sha256()
    for entry in sorted(FRAMEWORK.rglob("*")):
        if entry.is_file():
            digest.update(entry.relative_to(FRAMEWORK).as_posix().encode() + b"\0")
            digest.update(hashlib.sha256(entry.read_bytes()).digest())
    for library in info["AvailableLibraries"]:
        path = FRAMEWORK / library["LibraryIdentifier"] / library["LibraryPath"]
        headers = path / "Headers"
        def macro(relative, name):
            source = (headers / relative).read_text()
            match = re.search(r'^\s*#\s*define\s+' + name + r'\s+"([^"]+)"', source, re.M)
            if not match:
                raise ValueError(f"Missing {name} in {relative}")
            return match.group(1)
        versions = {
            "libtorrent": macro("libtorrent/version.hpp", "LIBTORRENT_VERSION"),
            "boost": macro("boost/version.hpp", "BOOST_LIB_VERSION").replace("_", "."),
            "openssl": macro("openssl/opensslv.h", "OPENSSL_VERSION_TEXT"),
        }
        framework_info = plistlib.loads((path / "Info.plist").read_bytes())
        binary = path / framework_info["CFBundleExecutable"]
        libraries.append({
            "identifier": library["LibraryIdentifier"],
            "architectures": library["SupportedArchitectures"],
            "headerVersions": versions,
            "frameworkVersionLabel": framework_info["CFBundleShortVersionString"],
            "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "xcframeworkTreeSHA256": digest.hexdigest(),
        })
    return libraries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true", help="Explicitly replace the checked-in inventory after an approved artifact change")
    parser.add_argument("--provenance", help="Required with --record: explain artifact source and verification boundary")
    args = parser.parse_args()
    script = (ROOT / "Scripts/build_libtorrent_xcframework.sh").read_text()
    commit_match = re.search(r'^VCPKG_COMMIT="([0-9a-f]{40})"$', script, re.M)
    if not commit_match:
        raise SystemExit("Build script must pin a full vcpkg commit.")
    libraries = inspect()
    if args.record:
        if not args.provenance:
            parser.error("--record requires --provenance; do not invent binary provenance from headers")
        record = {
            "inventoryVersion": 1,
            "recordedOn": datetime.now(ZoneInfo("Asia/Hong_Kong")).date().isoformat(),
            "vcpkgCommit": commit_match.group(1),
            "evidenceBoundary": args.provenance,
            "libraries": libraries,
        }
        BASELINE.write_text(json.dumps(record, indent=2) + "\n")
        print("Recorded DEPENDENCIES.json")
    else:
        record = json.loads(BASELINE.read_text())
        if record["vcpkgCommit"] != commit_match.group(1):
            raise SystemExit("Build script vcpkg commit differs from recorded provenance.")
        if record["libraries"] != libraries:
            raise SystemExit("Dependency inventory differs; inspect the change before recording a new baseline.")
        print("Dependency hashes and header versions match the recorded baseline.")
        for library in libraries:
            print(f'{library["identifier"]}: {library["headerVersions"]}; existing framework label {library["frameworkVersionLabel"]}')


if __name__ == "__main__":
    main()
