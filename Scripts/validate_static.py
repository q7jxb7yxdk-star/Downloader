#!/usr/bin/env python3
"""Local/CI structural checks. No app build, app tests, network or user-data access."""
import argparse
import ast
import json
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-syntax", action="store_true", help="Parse Swift sources with the existing local compiler; never build or type-check")
    args = parser.parse_args()
    run("git", "diff", "--check")
    run("git", "diff", "--cached", "--check")
    for path in (ROOT / "Scripts").glob("*.sh"):
        run("bash", "-n", str(path))
    for folder in ("Scripts", "Tests/HTTP"):
        for path in (ROOT / folder).glob("*.py"):
            ast.parse(path.read_text(), filename=str(path))
    resources = ROOT / "Downloader Safari Extension/Resources"
    for folder in (resources, ROOT / "SafariExtension"):
        for path in folder.glob("*.js"):
            run("node", "--check", str(path))
    manifest = json.loads((resources / "manifest.json").read_text())
    for icon in list(manifest["icons"].values()) + list(manifest["browser_action"]["default_icon"].values()):
        require((resources / icon).is_file(), f"Missing extension icon: {icon}")
    for script in manifest["background"]["scripts"]:
        require((resources / script).is_file(), f"Missing background script: {script}")
    for content in manifest["content_scripts"]:
        for script in content["js"]:
            require((resources / script).is_file(), f"Missing content script: {script}")
    for path in ROOT.glob("Downloader*/**/*.plist"):
        plistlib.loads(path.read_bytes())
    for path in ROOT.glob("Downloader*/*.entitlements"):
        plistlib.loads(path.read_bytes())
    project = (ROOT / "Downloader.xcodeproj/project.pbxproj").read_text()
    versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
    require(len(set(versions)) == 1 and versions[0] == manifest["version"], "App/extension marketing versions differ")
    builds = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)
    require(len(set(builds)) == 1, "App/extension build versions differ")
    targets = set(re.findall(r"([A-F0-9]{24})[^\n]* = \{\s*isa = PBXNativeTarget;", project))
    for scheme in ROOT.glob("Downloader.xcodeproj/xcshareddata/xcschemes/*.xcscheme"):
        for reference in ET.parse(scheme).iter("BuildableReference"):
            require(reference.attrib["BlueprintIdentifier"] in targets, "Scheme references a missing target")
    for name in ("PendingSafariDownloadQueue.swift", "THIRD_PARTY_NOTICES.txt"):
        require(name in project, f"Missing Xcode reference: {name}")
    for path in (ROOT / "Tests/Fixtures/Persistence").glob("*.json"):
        try:
            json.loads(path.read_text())
            require("corrupt" not in path.name, "Corruption fixture unexpectedly valid")
        except json.JSONDecodeError:
            require("corrupt" in path.name, f"Invalid JSON fixture: {path}")
    run(sys.executable, str(ROOT / "Scripts/dependency_inventory.py"))
    if args.swift_syntax:
        compiler = shutil.which("swiftc")
        require(compiler is not None, "Swift compiler unavailable; structural checks completed but Swift syntax unverified")
        sources = [str(path) for folder in ("Downloader", "Downloader Safari Extension", "Shared") for path in (ROOT / folder).rglob("*.swift")]
        run(compiler, "-frontend", "-parse", *sources)
    print("Static checks passed. Build, type-checking, app tests, simulator and runtime checks were not run.")


if __name__ == "__main__":
    main()
