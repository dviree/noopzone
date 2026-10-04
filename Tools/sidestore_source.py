#!/usr/bin/env python3
"""Write a SideStore / AltStore source for the rolling testing build.

The fork's "Testing build (fork)" workflow publishes the sideload .ipa to a rolling `testing-latest`
release. This writes the matching source JSON (AltStore source format, which SideStore reads) and the
workflow uploads it to the SAME release, so the source URL never changes:

    https://github.com/<owner>/<repo>/releases/download/testing-latest/sidestore-source.json

Add that URL once in SideStore (Sources > +) and every new testing build shows up as an update. The
entry carries the real version, build number, file size and download URL of the .ipa just built, so
SideStore can tell a new build of the same marketing version apart by its build number.

Usage:
  python3 Tools/sidestore_source.py --repo OWNER/REPO --tag testing-latest \\
      --version 11.9.0 --build 433 --ipa NOOP-ios-unsigned-v11.9.0.ipa [--date YYYY-MM-DD] \\
      [--out sidestore-source.json]
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys

BUNDLE_IDENTIFIER = "com.noopapp.noop"
SOURCE_FILENAME = "sidestore-source.json"
MIN_OS_VERSION = "17.0"
TINT = "44E2B0"
ICON_PATH = "Strand/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png"


def release_asset_url(repo: str, tag: str, name: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{name}"


def build_source(repo: str, tag: str, version: str, build: str, ipa_name: str, size: int,
                 date: str) -> dict:
    icon = f"https://github.com/{repo}/raw/main/{ICON_PATH}"
    return {
        "name": "NOOP (testing)",
        "identifier": f"io.github.{repo.split('/')[0].lower()}.noop.testing",
        "sourceURL": release_asset_url(repo, tag, SOURCE_FILENAME),
        "subtitle": "Rolling testing builds of NOOP from this fork.",
        "description": "SideStore / AltStore source for the testing builds of this NOOP fork. Each new build "
                       "of the Testing build workflow replaces the previous one and appears here as an update.",
        "iconURL": icon,
        "website": f"https://github.com/{repo}",
        "tintColor": TINT,
        "apps": [
            {
                "name": "NOOP",
                "bundleIdentifier": BUNDLE_IDENTIFIER,
                "developerName": repo.split("/")[0],
                "subtitle": "Read your own WHOOP strap, fully offline.",
                "localizedDescription": "Testing build of NOOP: Zone training, 4x4 intervals and the rest of "
                                        "this fork's changes. Independent and experimental; not affiliated "
                                        "with WHOOP.",
                "iconURL": icon,
                "tintColor": TINT,
                "category": "health",
                "screenshotURLs": [],
                "versions": [
                    {
                        "version": version,
                        "buildVersion": str(build),
                        "date": date,
                        "localizedDescription": f"NOOP {version} ({build}), testing build.",
                        "downloadURL": release_asset_url(repo, tag, ipa_name),
                        "size": size,
                        "minOSVersion": MIN_OS_VERSION,
                    }
                ],
                "appPermissions": {"entitlements": [], "privacy": {}},
            }
        ],
        "news": [],
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, help="owner/repo")
    ap.add_argument("--tag", required=True, help="release tag the .ipa is attached to")
    ap.add_argument("--version", required=True, help="marketing version, e.g. 11.9.0")
    ap.add_argument("--build", required=True, help="build number, e.g. 433")
    ap.add_argument("--ipa", required=True, help="path to the .ipa that was uploaded")
    ap.add_argument("--date", default=_dt.date.today().isoformat())
    ap.add_argument("--out", default=SOURCE_FILENAME)
    a = ap.parse_args(argv[1:])

    source = build_source(a.repo, a.tag, a.version, a.build, os.path.basename(a.ipa),
                          os.path.getsize(a.ipa), a.date)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {a.out} for {a.version} ({a.build})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
